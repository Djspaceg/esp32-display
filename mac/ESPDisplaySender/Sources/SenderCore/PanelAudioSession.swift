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
    let uplinkLostPackets: UInt64
    let uplinkLatePackets: UInt64
    let playbackQueueDrops: UInt64
}

/// Accumulates arbitrary capture callback sizes into MTU-safe EAUD payloads.
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

/// Thin macOS adapter around the pure descriptor, wire, timing, and selection
/// types. One instance belongs to one DeviceSession.
final class PanelAudioSession {
    private let descriptor: AudioStreamDescriptor
    private let addressProvider: @Sendable () -> String?
    private let onUpdate: @Sendable (PanelAudioSnapshot) -> Void
    private let queue = DispatchQueue(label: "espdisp.audio")

    private var preferences: AudioDevicePreferences
    private var tuning: AudioRuntimeTuning
    private var requested = false
    private var enabled = true
    private var stopped = false
    private var permissionRequestInFlight = false
    private var restartPending = false

    private var connection: NWConnection?
    private var captureEngine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    private var captureInput: AVAudioInputNode?
    private var captureConverter: AVAudioConverter?
    private var captureFormat: AVAudioFormat?
    private var player: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private var engineObservers = [NSObjectProtocol]()
    private var captureTapInstalled = false

    private var chunker: AudioPCMChunker
    private var sequence = UInt16.random(in: 1...UInt16.max)
    private var streamGeneration = UInt16.random(in: 1...UInt16.max)
    private var sampleCounter: UInt32 = 0
    private var streamStartedNanos = DispatchTime.now().uptimeNanoseconds

    private var inputName = AudioDeviceResolver.systemDefaultName
    private var outputName = AudioDeviceResolver.systemDefaultName
    private var message = "Waiting for the panel audio socket."
    private var state = PanelAudioState.waiting
    private var panelStatus: AudioProtocol.Status?
    private var sequenceTracker = AudioSequenceTracker()
    private var packetPacer = AudioPacketPacer()
    private var capturePending = [Data]()
    private var captureSendScheduled = false
    private var downlinkQueueDrops: UInt64 = 0
    private var playbackPending = [AudioProtocol.PCM]()
    private var playbackPendingFrames = 0
    private var playbackScheduledFrames = 0
    private var playbackStarted = false
    private var playbackQueueDrops: UInt64 = 0
    private var lastStatusPublishNanos: UInt64 = 0

    init(
        descriptor: AudioStreamDescriptor,
        preferences: AudioDevicePreferences = AudioDevicePreferences(),
        tuning: AudioRuntimeTuning = AudioRuntimeTuning(),
        addressProvider: @escaping @Sendable () -> String?,
        onUpdate: @escaping @Sendable (PanelAudioSnapshot) -> Void
    ) {
        self.descriptor = descriptor
        self.preferences = preferences
        self.tuning = tuning.validated
        self.addressProvider = addressProvider
        self.onUpdate = onUpdate
        self.chunker = AudioPCMChunker(
            packetFrames: AudioTiming.packetFrames(
                descriptor: descriptor, tuning: tuning),
            channels: Int(descriptor.playbackChannels))
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
            self.chunker = AudioPCMChunker(
                packetFrames: AudioTiming.packetFrames(
                    descriptor: self.descriptor, tuning: validated),
                channels: Int(self.descriptor.playbackChannels))
            self.restart(reason: "Audio settings changed.")
        }
    }

    func devicesChanged() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.restart(reason: "The available CoreAudio devices changed.")
        }
    }

    private func beginIfNeeded() {
        guard requested, enabled, !stopped, connection == nil,
              !permissionRequestInFlight
        else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            connect()
        case .notDetermined:
            permissionRequestInFlight = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                self?.queue.async {
                    guard let self else { return }
                    self.permissionRequestInFlight = false
                    if allowed {
                        self.beginIfNeeded()
                    } else {
                        self.state = .failed
                        self.message = "Microphone permission was denied."
                        self.publish()
                    }
                }
            }
        default:
            state = .failed
            message = "Allow microphone access in System Settings to stream audio."
            publish()
        }
    }

    private func connect() {
        guard let address = addressProvider(), !address.isEmpty else {
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
        parameters.serviceClass = .voice
        let connection = NWConnection(
            host: NWEndpoint.Host(address), port: port, using: parameters)
        self.connection = connection
        state = .waiting
        message = "Connecting panel audio."
        publish()
        connection.stateUpdateHandler = { [weak self, weak connection] newState in
            guard let self, let connection else { return }
            self.queue.async {
                guard self.connection === connection else { return }
                switch newState {
                case .ready:
                    self.receive(on: connection)
                    self.startEngine()
                case .failed(let error):
                    self.restart(reason: "Audio network failed: \(error.localizedDescription)")
                case .waiting(let error):
                    self.state = .recovering
                    self.message = "Audio network is waiting: \(error.localizedDescription)"
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
                    self.restart(reason:
                        "Audio receive failed: \(error.localizedDescription)")
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

        let captureEngine = AVAudioEngine()
        let playbackEngine = AVAudioEngine()
        let captureInput = captureEngine.inputNode
        let player = AVAudioPlayerNode()
        self.captureEngine = captureEngine
        self.playbackEngine = playbackEngine
        self.captureInput = captureInput
        self.player = player
        do {
            try CoreAudioDeviceCatalog.setDevice(
                CoreAudioDeviceCatalog.deviceID(
                    for: inputResolution.uid, direction: .input, in: devices),
                on: captureInput)
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
                throw NSError(
                    domain: "ESPDisplaySender.Audio",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The panel audio descriptor could not form an AVAudioFormat."
                    ])
            }
            let inputFormat = captureInput.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                  let converter = AVAudioConverter(
                      from: inputFormat, to: captureFormat)
            else {
                throw NSError(
                    domain: "ESPDisplaySender.Audio",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The selected microphone has no usable capture format."
                    ])
            }
            self.captureConverter = converter
            self.captureFormat = captureFormat
            self.playbackFormat = playbackFormat

            playbackEngine.attach(player)
            playbackEngine.connect(
                player, to: playbackEngine.mainMixerNode, format: playbackFormat)
            let inputFrames = max(
                1,
                Int(ceil(
                    Double(chunker.packetFrames)
                        * inputFormat.sampleRate
                        / Double(descriptor.sampleRateHz))))
            captureInput.installTap(
                onBus: 0,
                bufferSize: AVAudioFrameCount(inputFrames),
                format: inputFormat
            ) { [weak self] buffer, _ in
                self?.capture(buffer)
            }
            captureTapInstalled = true

            playbackEngine.prepare()
            captureEngine.prepare()
            try playbackEngine.start()
            try captureEngine.start()
            observeEngine(captureEngine)
            observeEngine(playbackEngine)
            resetStreamState()
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
        } catch {
            stopEngine()
            restart(reason: "Audio engine failed: \(error.localizedDescription)")
        }
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
                self.restart(reason: "The selected audio device configuration changed.")
            }
        }
        engineObservers.append(observer)
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let converter = captureConverter,
              let captureFormat,
              buffer.frameLength > 0
        else { return }
        let scale = captureFormat.sampleRate / buffer.format.sampleRate
        let capacity = max(
            1,
            Int(ceil(Double(buffer.frameLength) * scale)) + 1)
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: captureFormat,
            frameCapacity: AVAudioFrameCount(capacity))
        else { return }
        var providedInput = false
        var conversionError: NSError?
        let conversionStatus = converter.convert(
            to: converted,
            error: &conversionError
        ) { _, inputStatus in
            guard !providedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            providedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if conversionStatus == .error {
            let detail = conversionError?.localizedDescription
                ?? "CoreAudio returned a conversion error."
            queue.async { [weak self] in
                self?.restart(reason: "Microphone conversion failed: \(detail)")
            }
            return
        }
        guard let channelData = converted.floatChannelData else { return }
        let frameCount = Int(converted.frameLength)
        let channelCount = Int(converted.format.channelCount)
        var samples = Data(capacity: frameCount * channelCount * 2)
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let value = min(max(channelData[channel][frame], -1), 1)
                let signed = Int16(clamping: Int((value * 32_767).rounded()))
                let bits = UInt16(bitPattern: signed)
                samples.append(UInt8(bits & 0xFF))
                samples.append(UInt8(bits >> 8))
            }
        }
        queue.async { [weak self] in
            self?.sendCaptured(samples)
        }
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
            sampleRateHz: descriptor.sampleRateHz)
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
            connection.send(
                content: packet,
                completion: .contentProcessed { [weak self] error in
                    guard let error else { return }
                    self?.queue.async {
                        self?.restart(reason:
                            "Audio send failed: \(error.localizedDescription)")
                    }
                })
        }
        drainCaptureQueue(on: connection)
    }

    private func handleInbound(_ data: Data) {
        guard let datagram = try? AudioProtocol.decode(data) else { return }
        switch datagram {
        case .status(let status):
            guard status.sampleRateHz == descriptor.sampleRateHz else { return }
            panelStatus = status.status
            let now = DispatchTime.now().uptimeNanoseconds
            let interval = UInt64(tuning.statusPublishMilliseconds * 1_000_000)
            if now - lastStatusPublishNanos >= interval {
                lastStatusPublishNanos = now
                publish()
            }
        case .pcm(let pcm):
            guard pcm.kind == .pcmUplink,
                  pcm.sampleRateHz == descriptor.sampleRateHz,
                  pcm.channels == descriptor.captureChannels,
                  sequenceTracker.accept(
                    sequence: pcm.sequence,
                    streamGeneration: pcm.streamGeneration)
            else { return }
            enqueuePlayback(pcm)
        }
    }

    private func enqueuePlayback(_ pcm: AudioProtocol.PCM) {
        guard player != nil, playbackFormat != nil else { return }
        let target = AudioTiming.frames(
            milliseconds: tuning.uplinkTargetMilliseconds,
            sampleRateHz: descriptor.sampleRateHz)
        let ceiling = AudioTiming.frames(
            milliseconds: tuning.uplinkCeilingMilliseconds,
            sampleRateHz: descriptor.sampleRateHz)

        if playbackStarted {
            guard playbackScheduledFrames + Int(pcm.frameCount) <= ceiling else {
                playbackQueueDrops &+= 1
                publish()
                return
            }
            schedulePlayback(pcm)
            return
        }

        playbackPending.append(pcm)
        playbackPendingFrames += Int(pcm.frameCount)
        while playbackPendingFrames > ceiling, !playbackPending.isEmpty {
            let dropped = playbackPending.removeFirst()
            playbackPendingFrames -= Int(dropped.frameCount)
            playbackQueueDrops &+= 1
        }
        guard playbackPendingFrames >= target else { return }
        let ready = playbackPending
        playbackPending.removeAll(keepingCapacity: true)
        playbackPendingFrames = 0
        playbackStarted = true
        for packet in ready {
            schedulePlayback(packet)
        }
        player?.play()
    }

    private func schedulePlayback(_ pcm: AudioProtocol.PCM) {
        guard let player, let format = playbackFormat,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(pcm.frameCount)),
              let channels = buffer.floatChannelData
        else { return }
        buffer.frameLength = AVAudioFrameCount(pcm.frameCount)
        let bytes = [UInt8](pcm.samples)
        for frame in 0..<Int(pcm.frameCount) {
            for channel in 0..<Int(pcm.channels) {
                let offset = (frame * Int(pcm.channels) + channel) * 2
                let raw = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                channels[channel][frame] =
                    Float(Int16(bitPattern: raw)) / 32_768
            }
        }
        let frames = Int(pcm.frameCount)
        playbackScheduledFrames += frames
        player.scheduleBuffer(buffer) { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self.playbackScheduledFrames = max(
                    0, self.playbackScheduledFrames - frames)
                if self.playbackScheduledFrames == 0 {
                    self.playbackStarted = false
                }
            }
        }
    }

    private func resetStreamState() {
        sequence = UInt16.random(in: 1...UInt16.max)
        streamGeneration &+= 1
        sampleCounter = 0
        streamStartedNanos = DispatchTime.now().uptimeNanoseconds
        chunker = AudioPCMChunker(
            packetFrames: AudioTiming.packetFrames(
                descriptor: descriptor, tuning: tuning),
            channels: Int(descriptor.playbackChannels))
        packetPacer.reset()
        capturePending.removeAll(keepingCapacity: true)
        captureSendScheduled = false
        sequenceTracker = AudioSequenceTracker()
        playbackPending.removeAll(keepingCapacity: true)
        playbackPendingFrames = 0
        playbackScheduledFrames = 0
        playbackStarted = false
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
        connection?.cancel()
        connection = nil
        stopEngine()
    }

    private func stopEngine() {
        for observer in engineObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        engineObservers.removeAll(keepingCapacity: true)
        if captureTapInstalled {
            captureInput?.removeTap(onBus: 0)
            captureTapInstalled = false
        }
        player?.stop()
        captureEngine?.stop()
        playbackEngine?.stop()
        captureEngine = nil
        playbackEngine = nil
        captureInput = nil
        captureConverter = nil
        captureFormat = nil
        player = nil
        playbackFormat = nil
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
            uplinkLostPackets: sequenceTracker.lostPackets,
            uplinkLatePackets: sequenceTracker.latePackets,
            playbackQueueDrops: playbackQueueDrops))
    }
}
