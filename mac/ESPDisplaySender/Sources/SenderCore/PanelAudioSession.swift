import AVFoundation
import Foundation
import Network
import SenderProtocol

enum PanelAudioState: Equatable, Sendable {
    case waiting
    case streaming
    case paused
    case recovering
    case failed

    var label: String {
        switch self {
        case .waiting: return "Waiting"
        case .streaming: return "Streaming"
        case .paused: return "Paused"
        case .recovering: return "Recovering"
        case .failed: return "Unavailable"
        }
    }
}

struct PanelAudioSnapshot: Equatable, Sendable {
    let state: PanelAudioState
    let message: String
    let inputName: String
    let outputName: String
    let descriptor: AudioStreamDescriptor
    let tuning: AudioRuntimeTuning
    let panelStatus: AudioProtocol.Status?
    let downlinkQueueDrops: UInt64
    let captureCallbackDrops: UInt64
    let uplinkLostFrames: UInt64
    let uplinkLatePackets: UInt64
    let playbackQueueDrops: UInt64
    let downlinkCorrectionPPM: Double
    let uplinkCorrectionPPM: Double
}

/// Accumulates arbitrary converted sizes into MTU-safe EAUD payloads.
struct AudioPCMChunker: Equatable, Sendable {
    let packetFrames: Int
    let channels: Int
    private(set) var pending = Data()

    init(packetFrames: Int, channels: Int) {
        self.packetFrames = packetFrames
        self.channels = channels
    }

    mutating func append(_ samples: Data) -> [Data] {
        pending.append(samples)
        let packetBytes = packetFrames * channels * 2
        guard packetBytes > 0 else { return [] }
        var chunks = [Data]()
        while pending.count >= packetBytes {
            chunks.append(Data(pending.prefix(packetBytes)))
            pending.removeFirst(packetBytes)
        }
        return chunks
    }
}

/// How many silent packets to keep queued when there is no Mac microphone.
/// Two keeps `AudioPacketPacer` from ever running dry, so its drift-corrected
/// deadlines, not the generator, decide the rate.
enum AudioSilenceFeed {
    static let queuedPackets = 2

    /// Never deeper than the downlink ceiling holds, or `sendCaptured` would
    /// drop each top-up as soon as it is queued.
    static func packetsToQueue(
        pending: Int, ceilingFrames: Int, packetFrames: Int
    ) -> Int {
        let depth = min(queuedPackets, max(1, ceilingFrames / max(1, packetFrames)))
        return max(0, depth - pending)
    }
}

/// Opens the Mac microphone: a capture engine on the chosen input device and
/// the input format this session can convert. Injectable so a test can stand
/// in a Mac with no usable input without opening a real one.
struct MicrophoneCaptureSource: Sendable {
    let open: @Sendable (AudioDeviceID?) throws -> (AVAudioEngine, AVAudioFormat)

    static let system = MicrophoneCaptureSource(open: { deviceID in
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try CoreAudioDeviceCatalog.setDevice(deviceID, on: input)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0,
              format.channelCount > 0,
              format.channelCount <= 2,
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved
        else {
            throw NSError(
                domain: "ESPDisplaySender.Audio",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "The selected microphone has no non-interleaved Float32 format."])
        }
        return (engine, format)
    })
}

/// The TCC microphone check, injectable so a test can refuse it without
/// touching the real permission.
struct MicrophoneAccess: Sendable {
    let status: @Sendable () -> AVAuthorizationStatus
    let request: @Sendable (@escaping @Sendable (Bool) -> Void) -> Void

    static let system = MicrophoneAccess(
        status: { AVCaptureDevice.authorizationStatus(for: .audio) },
        request: { AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0) })
}

/// One queue owns every mutable adapter field. The only cross-queue operation
/// is the input tap's bounded write into SenderAudioRT's preallocated SPSC ring.
final class PanelAudioSession: @unchecked Sendable {
    private let descriptor: AudioStreamDescriptor
    private let peerAddress: PanelPeerAddress
    private let radioBudget: PanelRadioBudget
    private let onUpdate: @Sendable (PanelAudioSnapshot) -> Void
    private let microphoneAccess: MicrophoneAccess
    private let captureSource: MicrophoneCaptureSource
    private let queue = DispatchQueue(label: "espdisp.audio")

    private var preferences: AudioDevicePreferences
    private var tuning: AudioRuntimeTuning
    private var requested = false
    private var enabled = true
    private var stopped = false
    private var permissionRequestInFlight = false
    private var microphoneRefusal: MicrophoneRefusal?
    private var restartPending = false

    private var connection: NWConnection?
    private var connectedPeer: PanelPeerAddressSnapshot?
    private var connectionReadyNanos: UInt64?
    private var lastValidInboundNanos: UInt64?
    private var livenessTimer: DispatchSourceTimer?

    private var captureEngine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    private var captureInput: AVAudioInputNode?
    private var captureConverter: AVAudioConverter?
    private var captureReadBuffer: AVAudioPCMBuffer?
    private var captureConvertedBuffer: AVAudioPCMBuffer?
    private var captureRingLifetime: AudioCaptureRingLifetime?
    private var captureWorkerTimer: DispatchSourceTimer?
    private var captureTapInstalled = false
    private var lastRingDropped: UInt64 = 0
    private var silenceLastPermissionCheckNanos: UInt64 = 0
    private var outputUsedFallback = false
    private static let outputFallbackNote =
        " The saved output device vanished; using System Default."

    private var player: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private var playbackFramesEnqueued: UInt64 = 0
    private var playbackScheduledFrames = 0
    private var engineObservers = [NSObjectProtocol]()

    private var chunker: AudioPCMChunker
    private var sequence = UInt16.random(in: 1...UInt16.max)
    private var streamGeneration = UInt16.random(in: 1...UInt16.max)
    private var sampleCounter: UInt32 = 0
    private var streamStartedNanos = DispatchTime.now().uptimeNanoseconds
    private var packetPacer = AudioPacketPacer()
    private var capturePending = [Data]()
    private var captureSendScheduled = false

    private var jitter: AudioJitterBuffer
    private var downlinkDrift = AudioDriftController()
    private var uplinkDrift = AudioDriftController()
    private var downlinkResampler = AudioVariableRateResampler()
    private var uplinkResampler = AudioVariableRateResampler()

    private var inputName = AudioDeviceResolver.systemDefaultName
    private var outputName = AudioDeviceResolver.systemDefaultName
    private var message = "Waiting for the panel audio socket."
    private var state = PanelAudioState.waiting
    private var panelStatus: AudioProtocol.Status?
    private var downlinkQueueDrops: UInt64 = 0
    private var captureCallbackDrops: UInt64 = 0
    private var uplinkLostFrames: UInt64 = 0
    private var uplinkLatePackets: UInt64 = 0
    private var playbackQueueDrops: UInt64 = 0
    private var lastStatusPublishNanos: UInt64 = 0

    init(
        descriptor: AudioStreamDescriptor,
        preferences: AudioDevicePreferences = AudioDevicePreferences(),
        tuning: AudioRuntimeTuning = AudioRuntimeTuning(),
        peerAddress: PanelPeerAddress,
        radioBudget: PanelRadioBudget,
        microphoneAccess: MicrophoneAccess = .system,
        captureSource: MicrophoneCaptureSource = .system,
        onUpdate: @escaping @Sendable (PanelAudioSnapshot) -> Void
    ) {
        let validated = tuning.validated
        self.descriptor = descriptor
        self.microphoneAccess = microphoneAccess
        self.captureSource = captureSource
        self.preferences = preferences
        self.tuning = validated
        self.peerAddress = peerAddress
        self.radioBudget = radioBudget
        self.onUpdate = onUpdate
        self.chunker = Self.makeChunker(
            descriptor: descriptor, tuning: validated)
        self.jitter = Self.makeJitter(
            descriptor: descriptor, tuning: validated)
        radioBudget.update(tuning: validated)
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.requested = true
            self.beginIfNeeded()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.requested = false
            self.stopPipeline()
        }
    }

    func setEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.enabled = enabled
            if enabled {
                self.beginIfNeeded()
            } else {
                self.stopPipeline()
                self.state = .paused
                self.message = "Audio streaming is paused."
                self.publish()
            }
        }
    }

    func update(
        preferences: AudioDevicePreferences,
        tuning: AudioRuntimeTuning
    ) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            let validated = tuning.validated
            guard self.preferences != preferences || self.tuning != validated else {
                return
            }
            self.preferences = preferences
            self.tuning = validated
            self.radioBudget.update(tuning: validated)
            self.chunker = Self.makeChunker(
                descriptor: self.descriptor, tuning: validated)
            self.jitter = Self.makeJitter(
                descriptor: self.descriptor, tuning: validated)
            self.restart(reason: "Audio settings changed.")
        }
    }

    func devicesChanged() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.restart(reason: "The CoreAudio route changed.")
        }
    }

    private static func makeChunker(
        descriptor: AudioStreamDescriptor,
        tuning: AudioRuntimeTuning
    ) -> AudioPCMChunker {
        AudioPCMChunker(
            packetFrames: AudioTiming.packetFrames(
                descriptor: descriptor, tuning: tuning),
            channels: Int(descriptor.playbackChannels))
    }

    private static func makeJitter(
        descriptor: AudioStreamDescriptor,
        tuning: AudioRuntimeTuning
    ) -> AudioJitterBuffer {
        let validated = tuning.validated
        return AudioJitterBuffer(
            targetFrames: AudioTiming.frames(
                milliseconds: validated.uplinkJitterMilliseconds,
                sampleRateHz: descriptor.sampleRateHz),
            ceilingFrames: AudioTiming.frames(
                milliseconds: validated.uplinkJitterCeilingMilliseconds,
                sampleRateHz: descriptor.sampleRateHz),
            reorderWindowPackets: validated.uplinkReorderPackets,
            reorderTimeoutNanos: UInt64(
                validated.uplinkReorderMilliseconds * 1_000_000))
    }

    private func beginIfNeeded() {
        guard requested, enabled, !stopped, connection == nil else { return }
        // An unanswered prompt (it can sit behind a login-time launch) must not
        // hold the panel microphone hostage: stream silence until it resolves.
        if permissionRequestInFlight {
            microphoneRefusal = .pending
            connect()
            return
        }
        switch microphoneAccess.status() {
        case .authorized:
            microphoneRefusal = nil
            connect()
        case .notDetermined:
            permissionRequestInFlight = true
            microphoneAccess.request { [weak self] allowed in
                guard let self else { return }
                self.queue.async {
                    self.permissionRequestInFlight = false
                    guard !self.stopped, self.requested, self.enabled else {
                        return
                    }
                    self.resolvePermissionRequest(allowed: allowed)
                }
            }
            microphoneRefusal = .pending
            connect()
        case .restricted:
            microphoneRefusal = .restricted
            connect()
        default:
            microphoneRefusal = .denied
            connect()
        }
    }

    /// A prompt answered while silence is already streaming: a grant restarts
    /// into capture, a refusal only corrects the reason shown.
    private func resolvePermissionRequest(allowed: Bool) {
        if allowed {
            if connection == nil {
                beginIfNeeded()
            } else {
                restart(reason: "Microphone access was granted.")
            }
            return
        }
        // Still undetermined after a refusal means macOS never showed the
        // prompt, which is what a hardened build without the audio-input
        // entitlement gets.
        microphoneRefusal = microphoneAccess.status() == .notDetermined
            ? .promptDisallowed
            : .denied
        if connection == nil {
            connect()
        } else if state == .streaming, let microphoneRefusal {
            message = microphoneRefusal.message
                + (outputUsedFallback ? Self.outputFallbackNote : "")
            publish()
        }
    }

    /// Why the Mac microphone is not captured. Without it the panel speaker is
    /// fed silence rather than nothing: the panel starts its audio backend and
    /// learns where to send its own microphone only from downlink packets.
    private enum MicrophoneRefusal {
        case pending
        case denied
        case promptDisallowed
        case restricted
        case captureUnavailable(String)

        var awaitsPermission: Bool {
            if case .captureUnavailable = self { return false }
            return true
        }

        var inputName: String {
            if case .captureUnavailable = self {
                return "Not captured (microphone unavailable)"
            }
            return "Not captured (no microphone access)"
        }

        var message: String {
            let lead = "Panel microphone plays on this Mac. The panel speaker gets "
                + "silence "
            switch self {
            case .pending:
                return lead + "until the macOS microphone prompt is answered."
            case .denied:
                return lead + "because ESPDisplaySender does not have microphone "
                    + "access; turn it on in System Settings > Privacy & Security "
                    + "> Microphone."
            case .promptDisallowed:
                return lead + "because macOS did not let ESPDisplaySender ask for "
                    + "microphone access; this build may be missing its "
                    + "microphone entitlement."
            case .restricted:
                return lead + "because microphone access is restricted on this Mac "
                    + "by a policy this app cannot change."
            case .captureUnavailable(let reason):
                return lead + "because the Mac microphone could not be opened: "
                    + reason
            }
        }
    }

    private func connect() {
        let peer = peerAddress.snapshot
        guard let address = peer.address, !address.isEmpty else {
            state = .waiting
            message = "Waiting for the panel network address."
            publish()
            scheduleRestart()
            return
        }
        guard let port = NWEndpoint.Port(rawValue: descriptor.port) else {
            state = .failed
            message = "The panel advertised an invalid audio port."
            publish()
            return
        }

        let parameters = NWParameters.udp
        parameters.serviceClass = .interactiveVoice
        let connection = NWConnection(
            host: NWEndpoint.Host(address), port: port, using: parameters)
        self.connection = connection
        connectedPeer = peer
        state = .waiting
        message = "Connecting panel audio."
        publish()
        connection.stateUpdateHandler = { [weak self, weak connection] newState in
            guard let self, let connection else { return }
            self.queue.async {
                guard self.connection === connection else { return }
                switch newState {
                case .ready:
                    let now = DispatchTime.now().uptimeNanoseconds
                    self.connectionReadyNanos = now
                    self.lastValidInboundNanos = nil
                    self.receive(on: connection)
                    self.startEngine()
                    if self.connection === connection {
                        self.startLivenessTimer()
                    }
                case .failed(let error):
                    self.restart(
                        reason: "Audio network failed: \(error.localizedDescription)")
                case .waiting(let error):
                    self.state = .recovering
                    self.message =
                        "Audio network is waiting: \(error.localizedDescription)"
                    self.publish()
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            self.queue.async {
                guard self.connection === connection else { return }
                if let data {
                    self.handleInbound(data)
                }
                if let error {
                    self.restart(
                        reason: "Audio receive failed: \(error.localizedDescription)")
                } else {
                    self.receive(on: connection)
                }
            }
        }
    }

    private func startEngine() {
        stopEngine()
        let devices = CoreAudioDeviceCatalog.devices()
        let inputResolution = AudioDeviceResolver.resolve(
            preferredUID: preferences.inputUID,
            direction: .input,
            devices: devices.map(\.option))
        let outputResolution = AudioDeviceResolver.resolve(
            preferredUID: preferences.outputUID,
            direction: .output,
            devices: devices.map(\.option))
        inputName = inputResolution.name
        outputName = outputResolution.name
        if let refusal = microphoneRefusal {
            startWithoutMicrophone(
                refusal: refusal,
                devices: devices,
                outputResolution: outputResolution)
            return
        }

        let playbackEngine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        self.playbackEngine = playbackEngine
        self.player = player

        do {
            let (captureEngine, inputFormat) = try capturing {
                try captureSource.open(
                    CoreAudioDeviceCatalog.deviceID(
                        for: inputResolution.uid, direction: .input, in: devices))
            }
            let captureInput = captureEngine.inputNode
            self.captureEngine = captureEngine
            self.captureInput = captureInput
            try CoreAudioDeviceCatalog.setDevice(
                CoreAudioDeviceCatalog.deviceID(
                    for: outputResolution.uid, direction: .output, in: devices),
                on: playbackEngine.outputNode)

            guard let captureFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(descriptor.sampleRateHz),
                channels: AVAudioChannelCount(descriptor.playbackChannels),
                interleaved: false),
                let playbackFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Double(descriptor.sampleRateHz),
                    channels: AVAudioChannelCount(descriptor.captureChannels),
                    interleaved: false)
            else {
                throw audioError(
                    code: 1,
                    message:
                        "The panel audio descriptor could not form an AVAudioFormat.")
            }

            guard let converter = AVAudioConverter(
                from: inputFormat, to: captureFormat)
            else {
                throw MicrophoneCaptureFailure(
                    reason: "The selected microphone format cannot be converted.")
            }

            let requestedInputFrames = max(
                1,
                Int(ceil(
                    Double(chunker.packetFrames)
                        * inputFormat.sampleRate
                        / Double(descriptor.sampleRateHz))))
            let slotFrames = max(
                requestedInputFrames,
                Int(ceil(
                    inputFormat.sampleRate
                        * tuning.captureRingSlotMilliseconds
                        / 1_000)))
            guard let ringLifetime = AudioCaptureRingLifetime(
                slotCount: UInt32(tuning.captureRingSlots),
                maximumFrames: UInt32(slotFrames),
                channels: UInt32(inputFormat.channelCount)),
                let readBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: AVAudioFrameCount(slotFrames))
            else {
                throw MicrophoneCaptureFailure(
                    reason: "The microphone capture ring could not be allocated.")
            }
            let convertedCapacity = max(
                1,
                Int(ceil(
                    Double(slotFrames)
                        * captureFormat.sampleRate
                        / inputFormat.sampleRate)) + 8)
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: captureFormat,
                frameCapacity: AVAudioFrameCount(convertedCapacity))
            else {
                throw MicrophoneCaptureFailure(
                    reason: "The microphone conversion buffer could not be allocated.")
            }

            self.captureConverter = converter
            self.captureReadBuffer = readBuffer
            self.captureConvertedBuffer = convertedBuffer
            self.captureRingLifetime = ringLifetime
            self.playbackFormat = playbackFormat

            playbackEngine.attach(player)
            playbackEngine.connect(
                player, to: playbackEngine.mainMixerNode, format: playbackFormat)

            let inputChannels = Int(inputFormat.channelCount)
            let callbackLease = ringLifetime.makeCallbackLease()
            captureInput.installTap(
                onBus: 0,
                bufferSize: AVAudioFrameCount(requestedInputFrames),
                format: inputFormat
            ) { [callbackLease] buffer, _ in
                guard buffer.frameLength > 0,
                      let channels = buffer.floatChannelData
                else { return }
                let channelZero = UnsafePointer(channels[0])
                let channelOne: UnsafePointer<Float>? = inputChannels > 1
                    ? UnsafePointer(channels[1])
                    : nil
                _ = callbackLease.write(
                    channelZero: channelZero,
                    channelOne: channelOne,
                    frameCount: UInt32(buffer.frameLength))
            }
            captureTapInstalled = true

            resetStreamState()
            playbackEngine.prepare()
            captureEngine.prepare()
            ringLifetime.setAccepting(true)
            try playbackEngine.start()
            try capturing { try captureEngine.start() }
            observeEngine(captureEngine)
            observeEngine(playbackEngine)
            startCaptureWorker()

            state = .streaming
            let fallbacks = [
                inputResolution.usedFallback ? "input" : nil,
                outputResolution.usedFallback ? "output" : nil,
            ].compactMap { $0 }
            message = fallbacks.isEmpty
                ? "Mac capture and panel microphone playback are active."
                : "The saved \(fallbacks.joined(separator: " and ")) device vanished; "
                    + "using System Default."
            publish()
        } catch let failure as MicrophoneCaptureFailure {
            // A missing or unconvertible microphone is a steady state, not a
            // fault to retry every second: stream silence so the panel
            // microphone still plays here. A CoreAudio device change restarts.
            stopEngine()
            let refusal = MicrophoneRefusal.captureUnavailable(failure.reason)
            microphoneRefusal = refusal
            startWithoutMicrophone(
                refusal: refusal,
                devices: devices,
                outputResolution: outputResolution)
        } catch {
            stopEngine()
            restart(reason: "Audio engine failed: \(error.localizedDescription)")
        }
    }

    private struct MicrophoneCaptureFailure: Error {
        let reason: String
    }

    private func capturing<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let failure as MicrophoneCaptureFailure {
            throw failure
        } catch {
            throw MicrophoneCaptureFailure(reason: error.localizedDescription)
        }
    }

    /// The uplink half of `startEngine`, with a silence generator standing in
    /// for the Mac microphone so the panel keeps its backend running and keeps
    /// sending its microphone here.
    private func startWithoutMicrophone(
        refusal: MicrophoneRefusal,
        devices: [CoreAudioDevice],
        outputResolution: AudioDeviceResolution
    ) {
        inputName = refusal.inputName
        let playbackEngine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        self.playbackEngine = playbackEngine
        self.player = player
        do {
            try CoreAudioDeviceCatalog.setDevice(
                CoreAudioDeviceCatalog.deviceID(
                    for: outputResolution.uid, direction: .output, in: devices),
                on: playbackEngine.outputNode)
            guard let playbackFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(descriptor.sampleRateHz),
                channels: AVAudioChannelCount(descriptor.captureChannels),
                interleaved: false)
            else {
                throw audioError(
                    code: 1,
                    message:
                        "The panel audio descriptor could not form an AVAudioFormat.")
            }
            self.playbackFormat = playbackFormat
            playbackEngine.attach(player)
            playbackEngine.connect(
                player, to: playbackEngine.mainMixerNode, format: playbackFormat)

            resetStreamState()
            playbackEngine.prepare()
            try playbackEngine.start()
            observeEngine(playbackEngine)
            startSilenceWorker()

            state = .streaming
            outputUsedFallback = outputResolution.usedFallback
            message = refusal.message
                + (outputUsedFallback ? Self.outputFallbackNote : "")
            publish()
        } catch {
            stopEngine()
            restart(reason: "Audio engine failed: \(error.localizedDescription)")
        }
    }

    /// Feeds the downlink the silence the Mac microphone would have supplied,
    /// through the same chunker and pacer. The pacer alone sets the
    /// drift-corrected rate; this only keeps it from running dry.
    private func startSilenceWorker() {
        captureWorkerTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(
                max(1, Int(tuning.captureWorkerMilliseconds.rounded()))))
        timer.setEventHandler { [weak self] in
            self?.generateSilence()
        }
        timer.resume()
        captureWorkerTimer = timer
    }

    private func generateSilence() {
        let now = DispatchTime.now().uptimeNanoseconds
        // Access granted in System Settings takes effect without a relaunch.
        if now - silenceLastPermissionCheckNanos >= 1_000_000_000 {
            silenceLastPermissionCheckNanos = now
            if microphoneRefusal?.awaitsPermission == true,
               microphoneAccess.status() == .authorized {
                restart(reason: "Microphone access was granted.")
                return
            }
        }
        let packets = AudioSilenceFeed.packetsToQueue(
            pending: capturePending.count,
            ceilingFrames: AudioTiming.frames(
                milliseconds: tuning.downlinkCeilingMilliseconds,
                sampleRateHz: descriptor.sampleRateHz),
            packetFrames: chunker.packetFrames)
        guard packets > 0 else { return }
        sendCaptured(Data(
            count: packets * chunker.packetFrames
                * Int(descriptor.playbackChannels) * 2))
    }

    private func audioError(code: Int, message: String) -> NSError {
        NSError(
            domain: "ESPDisplaySender.Audio",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func observeEngine(_ engine: AVAudioEngine) {
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self, weak engine] _ in
            guard let self, let engine else { return }
            self.queue.async {
                guard self.captureEngine === engine
                    || self.playbackEngine === engine
                else { return }
                self.restart(
                    reason: "The selected audio device configuration changed.")
            }
        }
        engineObservers.append(observer)
    }

    private func startCaptureWorker() {
        captureWorkerTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(
                max(1, Int(tuning.captureWorkerMilliseconds.rounded()))))
        timer.setEventHandler { [weak self] in
            self?.drainCaptureRing()
        }
        timer.resume()
        captureWorkerTimer = timer
    }

    private func drainCaptureRing() {
        guard let ringLifetime = captureRingLifetime,
              let readBuffer = captureReadBuffer,
              let channels = readBuffer.floatChannelData
        else { return }

        let channelOne = readBuffer.format.channelCount > 1 ? channels[1] : nil
        var frameCount: UInt32 = 0
        while ringLifetime.read(
            channelZero: channels[0],
            channelOne: channelOne,
            frameCapacity: UInt32(readBuffer.frameCapacity),
            frameCount: &frameCount)
        {
            readBuffer.frameLength = AVAudioFrameCount(frameCount)
            convertCaptured(readBuffer)
        }
        let dropped = ringLifetime.dropped
        if dropped > lastRingDropped {
            captureCallbackDrops &+= dropped - lastRingDropped
            lastRingDropped = dropped
        }
    }

    private func convertCaptured(_ input: AVAudioPCMBuffer) {
        guard let converter = captureConverter,
              let converted = captureConvertedBuffer
        else { return }

        converted.frameLength = 0
        var providedInput = false
        var conversionError: NSError?
        let status = converter.convert(
            to: converted,
            error: &conversionError,
            withInputFrom: { _, inputStatus in
                guard !providedInput else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                providedInput = true
                inputStatus.pointee = .haveData
                return input
            })
        if status == .error {
            restart(
                reason: "Microphone conversion failed: "
                    + (conversionError?.localizedDescription
                        ?? "CoreAudio returned a conversion error."))
            return
        }
        guard converted.frameLength > 0,
              let channelData = converted.floatChannelData
        else { return }

        let frames = Int(converted.frameLength)
        let channels = Int(converted.format.channelCount)
        var interleaved = [Float]()
        interleaved.reserveCapacity(frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                interleaved.append(channelData[channel][frame])
            }
        }
        let corrected = downlinkResampler.resample(
            interleavedSamples: interleaved,
            channels: channels,
            rateMultiplier: downlinkDrift.rateMultiplier)
        var samples = Data(capacity: corrected.count * 2)
        for value in corrected {
            let clamped = min(max(value, -1), 1)
            let signed = Int16(clamping: Int((clamped * 32_767).rounded()))
            let bits = UInt16(bitPattern: signed)
            samples.append(UInt8(bits & 0xFF))
            samples.append(UInt8(bits >> 8))
        }
        sendCaptured(samples)
    }

    private func sendCaptured(_ samples: Data) {
        guard state == .streaming, let connection else { return }
        capturePending.append(contentsOf: chunker.append(samples))
        let ceilingFrames = AudioTiming.frames(
            milliseconds: tuning.downlinkCeilingMilliseconds,
            sampleRateHz: descriptor.sampleRateHz)
        while capturePending.count * chunker.packetFrames > ceilingFrames {
            capturePending.removeFirst()
            downlinkQueueDrops &+= 1
        }
        drainCaptureQueue(on: connection)
    }

    private func drainCaptureQueue(on connection: NWConnection) {
        guard !captureSendScheduled, !capturePending.isEmpty else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let deadline = packetPacer.deadlineNanos(
            nowNanos: now,
            frameCount: chunker.packetFrames,
            sampleRateHz: descriptor.sampleRateHz,
            rateMultiplier: downlinkDrift.rateMultiplier)
        guard deadline > now else {
            sendNextCapturedChunk(on: connection)
            return
        }
        captureSendScheduled = true
        queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) {
            [weak self, weak connection] in
            guard let self, let connection else { return }
            guard self.connection === connection else { return }
            self.captureSendScheduled = false
            self.sendNextCapturedChunk(on: connection)
        }
    }

    private func sendNextCapturedChunk(on connection: NWConnection) {
        guard self.connection === connection, !capturePending.isEmpty else { return }
        let chunk = capturePending.removeFirst()
        let frameCount = chunk.count / (Int(descriptor.playbackChannels) * 2)
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedMicros = UInt32(
            truncatingIfNeeded: (now - streamStartedNanos) / 1_000)
        let pcm = AudioProtocol.PCM(
            kind: .pcmDownlink,
            sequence: sequence,
            streamGeneration: streamGeneration,
            sampleRateHz: descriptor.sampleRateHz,
            sampleCounter: sampleCounter,
            timestampMicros: elapsedMicros,
            frameCount: UInt16(frameCount),
            channels: descriptor.playbackChannels,
            samples: chunk)
        if let packet = try? AudioProtocol.encode(pcm) {
            sequence &+= 1
            sampleCounter &+= UInt32(frameCount)
            radioBudget.recordAudioDatagram(bytes: packet.count, nowNanos: now)
            connection.send(
                content: packet,
                completion: .contentProcessed {
                    [weak self, weak connection] error in
                    guard let self, let connection, let error else { return }
                    self.queue.async {
                        guard self.connection === connection else { return }
                        self.restart(
                            reason: "Audio send failed: "
                                + error.localizedDescription)
                    }
                })
        }
        drainCaptureQueue(on: connection)
    }

    private func handleInbound(_ data: Data) {
        guard let datagram = try? AudioProtocol.decode(data) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        switch datagram {
        case .status(let status):
            guard status.sampleRateHz == descriptor.sampleRateHz else { return }
            noteValidInbound(bytes: data.count, nowNanos: now)
            panelStatus = status.status
            let advertisedTarget = Int(status.status.targetFrames)
            _ = downlinkDrift.observe(
                timestampMicros: status.timestampMicros,
                fillFrames: Int(status.status.fillFrames),
                sampleRateHz: descriptor.sampleRateHz,
                tuning: tuning,
                targetFillFrames: advertisedTarget > 0
                    ? advertisedTarget
                    : AudioTiming.frames(
                        milliseconds: tuning.downlinkPanelTargetMilliseconds,
                        sampleRateHz: descriptor.sampleRateHz))
            let interval = UInt64(tuning.statusPublishMilliseconds * 1_000_000)
            if now - lastStatusPublishNanos >= interval {
                lastStatusPublishNanos = now
                publish()
            }
        case .pcm(let pcm):
            guard pcm.kind == .pcmUplink,
                  pcm.sampleRateHz == descriptor.sampleRateHz,
                  pcm.channels == descriptor.captureChannels
            else { return }
            noteValidInbound(bytes: data.count, nowNanos: now)
            let lostBefore = jitter.lostFrames
            let lateBefore = jitter.latePackets
            let chunks = jitter.insert(pcm, nowNanos: now)
            accountJitterChanges(
                lostBefore: lostBefore,
                lateBefore: lateBefore,
                nowNanos: now)
            schedulePlayout(chunks)
            updateUplinkDrift(nowNanos: now)
        }
    }

    private func noteValidInbound(bytes: Int, nowNanos: UInt64) {
        lastValidInboundNanos = nowNanos
        radioBudget.recordAudioDatagram(bytes: bytes, nowNanos: nowNanos)
    }

    private func accountInferredUplinkLoss(
        frames: UInt64, nowNanos: UInt64
    ) {
        guard frames > 0 else { return }
        let payload = frames * UInt64(descriptor.captureChannels) * 2
        let bounded = min(payload, UInt64(Int.max - AudioProtocol.headerBytes))
        radioBudget.recordAudioDatagram(
            bytes: Int(bounded) + AudioProtocol.headerBytes,
            nowNanos: nowNanos)
    }

    private func accountJitterChanges(
        lostBefore: UInt64,
        lateBefore: UInt64,
        nowNanos: UInt64
    ) {
        let newlyLost = jitter.lostFrames &- lostBefore
        uplinkLostFrames &+= newlyLost
        uplinkLatePackets &+= jitter.latePackets &- lateBefore
        accountInferredUplinkLoss(frames: newlyLost, nowNanos: nowNanos)
    }

    private func updateUplinkDrift(nowNanos: UInt64) {
        refreshPlaybackScheduledFrames()
        _ = uplinkDrift.observe(
            timestampMicros: UInt32(truncatingIfNeeded: nowNanos / 1_000),
            fillFrames: jitter.bufferedFrames + playbackScheduledFrames,
            sampleRateHz: descriptor.sampleRateHz,
            tuning: tuning,
            targetFillFrames: AudioTiming.frames(
                milliseconds: tuning.uplinkJitterMilliseconds,
                sampleRateHz: descriptor.sampleRateHz))
    }

    private func schedulePlayout(_ chunks: [AudioPlayoutChunk]) {
        guard !chunks.isEmpty else { return }
        for chunk in chunks {
            switch chunk {
            case .pcm(let pcm):
                schedulePlayback(samples: floatSamples(pcm), frames: Int(pcm.frameCount))
            case .silence(let frames):
                schedulePlayback(
                    samples: [Float](
                        repeating: 0,
                        count: frames * Int(descriptor.captureChannels)),
                    frames: frames)
            }
        }
    }

    private func floatSamples(_ pcm: AudioProtocol.PCM) -> [Float] {
        let bytes = [UInt8](pcm.samples)
        var samples = [Float]()
        samples.reserveCapacity(Int(pcm.frameCount) * Int(pcm.channels))
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            let raw = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            samples.append(Float(Int16(bitPattern: raw)) / 32_768)
        }
        return samples
    }

    private func schedulePlayback(samples: [Float], frames: Int) {
        guard frames > 0,
              let player,
              let format = playbackFormat
        else { return }
        let channels = Int(format.channelCount)
        let corrected = uplinkResampler.resample(
            interleavedSamples: samples,
            channels: channels,
            rateMultiplier: uplinkDrift.rateMultiplier)
        let outputFrames = corrected.count / channels
        guard outputFrames > 0 else { return }

        refreshPlaybackScheduledFrames()
        let ceiling = AudioTiming.frames(
            milliseconds: tuning.uplinkJitterCeilingMilliseconds,
            sampleRateHz: descriptor.sampleRateHz)
        guard AudioPlayoutCeiling.accepts(
            scheduledFrames: playbackScheduledFrames,
            incomingFrames: outputFrames,
            ceilingFrames: ceiling)
        else {
            playbackQueueDrops &+= 1
            publish()
            return
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(outputFrames)),
            let output = buffer.floatChannelData
        else {
            playbackQueueDrops &+= 1
            return
        }
        buffer.frameLength = AVAudioFrameCount(outputFrames)
        for frame in 0..<outputFrames {
            for channel in 0..<channels {
                output[channel][frame] = corrected[frame * channels + channel]
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        playbackFramesEnqueued &+= UInt64(outputFrames)
        playbackScheduledFrames += outputFrames
        if !player.isPlaying {
            player.play()
        }
    }

    private func refreshPlaybackScheduledFrames() {
        guard let player,
              let renderTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: renderTime),
              playerTime.sampleTime >= 0
        else { return }
        let rendered = UInt64(playerTime.sampleTime)
        playbackScheduledFrames = rendered >= playbackFramesEnqueued
            ? 0
            : Int(playbackFramesEnqueued - rendered)
    }

    private func startLivenessTimer() {
        livenessTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = AudioTiming.jitterPollMilliseconds(tuning: tuning)
        timer.schedule(deadline: .now() + .milliseconds(interval),
                       repeating: .milliseconds(interval))
        timer.setEventHandler { [weak self] in
            self?.checkLiveness()
        }
        timer.resume()
        livenessTimer = timer
    }

    private func checkLiveness() {
        guard connection != nil else { return }
        let peer = peerAddress.snapshot
        if let connectedPeer,
            peer.generation != connectedPeer.generation
                || peer.address != connectedPeer.address
        {
            restart(reason: "The panel video path resolved a new address.")
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let responseBase = lastValidInboundNanos ?? connectionReadyNanos
        let timeout = UInt64(tuning.responseTimeoutMilliseconds * 1_000_000)
        if let responseBase, now - responseBase > timeout {
            restart(reason: "The panel audio socket stopped responding.")
            return
        }

        let lostBefore = jitter.lostFrames
        let lateBefore = jitter.latePackets
        let chunks = jitter.poll(nowNanos: now)
        accountJitterChanges(
            lostBefore: lostBefore,
            lateBefore: lateBefore,
            nowNanos: now)
        schedulePlayout(chunks)
        updateUplinkDrift(nowNanos: now)
    }

    private func resetStreamState() {
        sequence = UInt16.random(in: 1...UInt16.max)
        streamGeneration &+= 1
        sampleCounter = 0
        streamStartedNanos = DispatchTime.now().uptimeNanoseconds
        chunker = Self.makeChunker(descriptor: descriptor, tuning: tuning)
        packetPacer.reset()
        capturePending.removeAll(keepingCapacity: true)
        captureSendScheduled = false
        jitter = Self.makeJitter(descriptor: descriptor, tuning: tuning)
        downlinkDrift.reset()
        uplinkDrift.reset()
        downlinkResampler.reset()
        uplinkResampler.reset()
        playbackFramesEnqueued = 0
        playbackScheduledFrames = 0
        panelStatus = nil
        lastStatusPublishNanos = 0
    }

    private func restart(reason: String) {
        guard requested, enabled, !stopped else { return }
        stopPipeline()
        state = .recovering
        message = reason
        publish()
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !restartPending, requested, enabled, !stopped else { return }
        restartPending = true
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.restartPending = false
            self.beginIfNeeded()
        }
    }

    private func stopPipeline() {
        livenessTimer?.cancel()
        livenessTimer = nil
        connection?.cancel()
        connection = nil
        connectedPeer = nil
        connectionReadyNanos = nil
        lastValidInboundNanos = nil
        stopEngine()
    }

    private func stopEngine() {
        captureWorkerTimer?.cancel()
        captureWorkerTimer = nil
        for observer in engineObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        engineObservers.removeAll(keepingCapacity: true)

        if let ringLifetime = captureRingLifetime {
            ringLifetime.setAccepting(false)
        }
        if captureTapInstalled {
            captureInput?.removeTap(onBus: 0)
            captureTapInstalled = false
        }
        captureEngine?.stop()
        playbackEngine?.stop()
        player?.stop()
        if let ringLifetime = captureRingLifetime {
            let dropped = ringLifetime.dropped
            if dropped > lastRingDropped {
                captureCallbackDrops &+= dropped - lastRingDropped
            }
        }

        captureEngine = nil
        playbackEngine = nil
        captureInput = nil
        captureConverter = nil
        captureReadBuffer = nil
        captureConvertedBuffer = nil
        captureRingLifetime = nil
        player = nil
        playbackFormat = nil
        lastRingDropped = 0
        resetStreamState()
    }

    private func publish() {
        onUpdate(PanelAudioSnapshot(
            state: state,
            message: message,
            inputName: inputName,
            outputName: outputName,
            descriptor: descriptor,
            tuning: tuning,
            panelStatus: panelStatus,
            downlinkQueueDrops: downlinkQueueDrops,
            captureCallbackDrops: captureCallbackDrops,
            uplinkLostFrames: uplinkLostFrames,
            uplinkLatePackets: uplinkLatePackets,
            playbackQueueDrops: playbackQueueDrops,
            downlinkCorrectionPPM: downlinkDrift.correctionPPM,
            uplinkCorrectionPPM: uplinkDrift.correctionPPM))
    }
}
