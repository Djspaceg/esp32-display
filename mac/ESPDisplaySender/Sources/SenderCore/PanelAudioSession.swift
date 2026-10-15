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
    /// What the display speaker is sent.
    let sourceName: String
    /// Where the display's microphone goes once it arrives here.
    let uplinkDestination: String
    let descriptor: AudioStreamDescriptor
    let tuning: AudioRuntimeTuning
    let panelStatus: AudioProtocol.Status?
    let downlinkQueueDrops: UInt64
    let captureCallbackDrops: UInt64
    let uplinkLostFrames: UInt64
    let uplinkLatePackets: UInt64
    let downlinkCorrectionPPM: Double
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

/// The per-display speaker volume. The display's DAC stays at the fixed level
/// the firmware takes from the board vendor's reference, so 100% is the
/// loudest the display plays and lower settings scale the samples here before
/// they are sent. A display nobody has set starts below that, so its first
/// sound is not a blast: 70% is about 6 dB under the ceiling.
enum PanelSpeakerVolume {
    static let `default` = 0.7

    static func clamped(_ volume: Double) -> Double {
        volume.isFinite ? min(max(volume, 0), 1) : `default`
    }

    /// Squared, so equal slider steps sound roughly equally far apart rather
    /// than the top half all sounding loud.
    static func gain(_ volume: Double) -> Float {
        let level = Float(clamped(volume))
        return level * level
    }
}

/// Float samples to the wire's PCM16 little-endian, scaled by `gain`.
enum AudioDownlinkPCM {
    static func encode(_ samples: [Float], gain: Float) -> Data {
        var data = Data(capacity: samples.count * 2)
        for value in samples {
            let clamped = min(max(value * gain, -1), 1)
            let signed = Int16(clamping: Int((clamped * 32_767).rounded()))
            let bits = UInt16(bitPattern: signed)
            data.append(UInt8(bits & 0xFF))
            data.append(UInt8(bits >> 8))
        }
        return data
    }
}

/// Where the display's microphone goes once it is out of the jitter buffer:
/// interleaved Float32 at the descriptor's rate and capture channels. Nothing
/// on this Mac plays it; a later audio driver makes the display a Mac input
/// and plugs in here.
struct PanelUplinkSink: Sendable {
    let deliver: @Sendable (_ samples: [Float], _ frames: Int) -> Void

    static let discard = PanelUplinkSink(deliver: { _, _ in })
}

/// Where the display speaker's sound comes from: this Mac's sound through the
/// process tap, or what macOS plays to the display's own output device
/// through ESPDisplayAudio.driver. Both arrive through `SystemAudioTap`, so
/// everything after the capture ring is shared.
struct PanelDownlinkSource: Sendable {
    /// Setting a source with the same key again changes nothing.
    let key: String
    let access: SystemAudioAccess
    let capture: SystemAudioCaptureSource
    let sourceName: String
    let streamingMessage: String
    /// Said when the source cannot be opened and silence is sent instead.
    let unavailableSourceName: String
    let unavailableLead: String
    /// The tap is rebuilt on every route change, since it depends on the
    /// default output. A display's own device does not: when the driver
    /// makes it again, its source's key (which carries the device's object
    /// ID) changes instead, so it restarts once rather than twice.
    var followsRouteChanges = true

    static let tapStreamingMessage = "Sending this Mac's sound to the display "
        + "speaker. The Mac's own speakers keep playing."

    /// The process tap. When another route was chosen and cannot be used, the
    /// route's own note says why, once, beside the choice.
    static func systemTap(
        access: SystemAudioAccess = .system,
        capture: SystemAudioCaptureSource = .system
    ) -> PanelDownlinkSource {
        PanelDownlinkSource(
            key: "tap",
            access: access,
            capture: capture,
            sourceName: PanelAudioSession.tappedSourceName,
            streamingMessage: tapStreamingMessage,
            unavailableSourceName: "Silence (this Mac's sound could not be recorded)",
            unavailableLead: "because this Mac's sound could not be recorded: ")
    }

    /// The display's own output device. No recording permission is involved:
    /// macOS mixes for the device because it is the Mac's output.
    static func displayDevice(
        name: String,
        route: MacAudioRoute,
        capture: SystemAudioCaptureSource,
        identity: String = ""
    ) -> PanelDownlinkSource {
        let output = "the \"\(name)\" output"
        // Only "the displays only" plays through a display's own device.
        let streaming = "Playing what this Mac sends to \(output), which is "
            + "the Mac's only output."
        return PanelDownlinkSource(
            key: "device|\(identity)|\(name)|\(route.rawValue)",
            access: .notRequired,
            capture: capture,
            sourceName: "Mac output \"\(name)\"",
            streamingMessage: streaming,
            unavailableSourceName: "Silence (\(output) is not ready)",
            unavailableLead: "because \(output) could not be read: ",
            followsRouteChanges: false)
    }
}

/// How many silent packets to keep queued when this Mac's sound is not sent.
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

/// One queue owns every mutable adapter field. The only cross-queue operation
/// is the tap's bounded write into SenderAudioRT's preallocated SPSC ring.
///
/// Downlink: this Mac's sound, through a Core Audio process tap that excludes
/// this app, scaled by the display's volume and sent to the display speaker.
/// The Mac's own speakers keep playing; the tap only listens. Without
/// permission to record it, the display speaker gets silence instead, because
/// the panel starts its audio backend and learns where to send its
/// microphone only from downlink packets (firmware audio_engine.cpp
/// claimPeer).
///
/// Uplink: the display's microphone is received and de-jittered, then handed
/// to `uplinkSink`. Nothing on this Mac plays it.
final class PanelAudioSession: @unchecked Sendable {
    static let tappedSourceName = "This Mac's sound"
    static let uplinkDestination = "Received, not played on this Mac"

    private let descriptor: AudioStreamDescriptor
    private let peerAddress: PanelPeerAddress
    private let radioBudget: PanelRadioBudget
    private let onUpdate: @Sendable (PanelAudioSnapshot) -> Void
    private var downlink: PanelDownlinkSource
    private let uplinkSink: PanelUplinkSink
    private let queue = DispatchQueue(label: "espdisp.audio")

    private var tuning: AudioRuntimeTuning
    private var speakerGain: Float
    private var requested = false
    private var enabled = true
    private var stopped = false
    private var permissionRequestInFlight = false
    /// Bumped whenever an in-flight request stops mattering, so its late
    /// answer cannot restart a session that has already moved on.
    private var permissionRequestGeneration: UInt64 = 0
    /// The permission when this run began; a tap opened under `.authorized`
    /// that later reads otherwise has had its permission taken away.
    private var permissionAtStart = SystemAudioPermission.unknown
    private var refusal: SystemAudioRefusal?
    private var restartPending = false

    private var connection: NWConnection?
    private var connectedPeer: PanelPeerAddressSnapshot?
    private var connectionReadyNanos: UInt64?
    private var lastValidInboundNanos: UInt64?
    private var livenessTimer: DispatchSourceTimer?

    private var tap: SystemAudioTap?
    private var captureWriter: SystemAudioRingWriter?
    private var captureConverter: AVAudioConverter?
    private var captureReadBuffer: AVAudioPCMBuffer?
    private var captureConvertedBuffer: AVAudioPCMBuffer?
    private var captureRingLifetime: AudioCaptureRingLifetime?
    private var captureWorkerTimer: DispatchSourceTimer?
    private var lastRingDropped: UInt64 = 0
    private var lastWriterSkipped: UInt64 = 0
    private var lastTapFramesNanos: UInt64 = 0
    private var lastPermissionCheckNanos: UInt64 = 0

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
    private var downlinkResampler = AudioVariableRateResampler()

    private var sourceName = PanelAudioSession.tappedSourceName
    private var message = "Waiting for the panel audio socket."
    private var state = PanelAudioState.waiting
    private var panelStatus: AudioProtocol.Status?
    private var downlinkQueueDrops: UInt64 = 0
    private var captureCallbackDrops: UInt64 = 0
    private var uplinkLostFrames: UInt64 = 0
    private var uplinkLatePackets: UInt64 = 0
    private var lastStatusPublishNanos: UInt64 = 0

    init(
        descriptor: AudioStreamDescriptor,
        tuning: AudioRuntimeTuning = AudioRuntimeTuning(),
        peerAddress: PanelPeerAddress,
        radioBudget: PanelRadioBudget,
        speakerVolume: Double = PanelSpeakerVolume.default,
        systemAudioAccess: SystemAudioAccess = .system,
        systemAudioSource: SystemAudioCaptureSource = .system,
        uplinkSink: PanelUplinkSink = .discard,
        downlink: PanelDownlinkSource? = nil,
        onUpdate: @escaping @Sendable (PanelAudioSnapshot) -> Void
    ) {
        let validated = tuning.validated
        self.descriptor = descriptor
        self.downlink = downlink ?? .systemTap(
            access: systemAudioAccess, capture: systemAudioSource)
        self.sourceName = self.downlink.sourceName
        self.uplinkSink = uplinkSink
        self.speakerGain = PanelSpeakerVolume.gain(speakerVolume)
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

    func update(tuning: AudioRuntimeTuning) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            let validated = tuning.validated
            guard self.tuning != validated else { return }
            self.tuning = validated
            self.radioBudget.update(tuning: validated)
            self.chunker = Self.makeChunker(
                descriptor: self.descriptor, tuning: validated)
            self.jitter = Self.makeJitter(
                descriptor: self.descriptor, tuning: validated)
            self.restart(reason: "Audio settings changed.")
        }
    }

    var speakerGainForTesting: Float { queue.sync { speakerGain } }

    /// Takes effect on the next samples sent, without a restart.
    func setSpeakerVolume(_ volume: Double) {
        queue.async { [weak self] in
            self?.speakerGain = PanelSpeakerVolume.gain(volume)
        }
    }

    /// Switch where the display speaker's sound comes from. The same source
    /// again is ignored; a different one restarts the session into it.
    func setDownlinkSource(_ source: PanelDownlinkSource) {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.downlink.key != source.key else { return }
            self.downlink = source
            // A prompt asked for the old source no longer matters.
            self.permissionRequestInFlight = false
            self.permissionRequestGeneration &+= 1
            self.refusal = nil
            self.sourceName = source.sourceName
            self.restart(reason: "The display speaker's source changed.")
        }
    }

    /// A route change, such as a new default output, rebuilds the tap on the
    /// device that now plays the Mac's sound.
    func devicesChanged() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            guard self.downlink.followsRouteChanges else { return }
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
        let status = downlink.access.status()
        permissionAtStart = status
        // A grant in System Settings can land while the prompt's own answer
        // is still outstanding. The status wins; the late answer is dropped.
        if status == .authorized, permissionRequestInFlight {
            permissionRequestInFlight = false
            permissionRequestGeneration &+= 1
        }
        // An unanswered prompt (it can sit behind a login-time launch) must not
        // hold the panel microphone hostage: stream silence until it resolves.
        if permissionRequestInFlight {
            refusal = .pending
            connect()
            return
        }
        switch status {
        case .authorized, .unknown:
            refusal = nil
        case .notDetermined:
            guard let request = downlink.access.request else {
                // Starting the tap is what raises the prompt.
                refusal = nil
                break
            }
            permissionRequestInFlight = true
            permissionRequestGeneration &+= 1
            let generation = permissionRequestGeneration
            request { [weak self] allowed in
                guard let self else { return }
                self.queue.async {
                    guard self.permissionRequestGeneration == generation else {
                        return
                    }
                    self.permissionRequestInFlight = false
                    guard !self.stopped, self.requested, self.enabled else {
                        return
                    }
                    self.resolvePermissionRequest(allowed: allowed)
                }
            }
            refusal = .pending
        case .denied:
            refusal = .denied
        }
        connect()
    }

    /// A prompt answered while silence is already streaming: a grant restarts
    /// into the tap, a refusal only corrects the reason shown.
    private func resolvePermissionRequest(allowed: Bool) {
        if allowed {
            if connection == nil {
                beginIfNeeded()
            } else {
                restart(reason: "Permission to record this Mac's sound was granted.")
            }
            return
        }
        // Still undetermined after a refusal means macOS never showed the
        // prompt.
        let refusal: SystemAudioRefusal =
            downlink.access.status() == .notDetermined ? .promptNotShown : .denied
        self.refusal = refusal
        if connection == nil {
            connect()
        } else if state == .streaming {
            sourceName = refusal.sourceName(downlink)
            message = refusal.message(downlink)
            publish()
        }
    }

    /// Why this Mac's sound is not sent. A refusal is not a failure: the
    /// panel speaker gets silence, so the panel keeps its audio running.
    private enum SystemAudioRefusal {
        case pending
        case denied
        case promptNotShown
        case captureUnavailable(String)

        var awaitsPermission: Bool {
            if case .captureUnavailable = self { return false }
            return true
        }

        func sourceName(_ downlink: PanelDownlinkSource) -> String {
            if case .captureUnavailable = self {
                return downlink.unavailableSourceName
            }
            return "Silence (no permission to record this Mac's sound)"
        }

        private static let settingsPath = "turn on ESPDisplaySender in System "
            + "Settings > Privacy & Security > Screen & System Audio Recording, "
            + "under System Audio Recording Only."

        func message(_ downlink: PanelDownlinkSource) -> String {
            let lead = "The display speaker gets silence "
            switch self {
            case .pending:
                return lead + "until the macOS prompt asking to record this "
                    + "Mac's sound is answered."
            case .denied:
                return lead + "because ESPDisplaySender is not allowed to record "
                    + "this Mac's sound. To send it, " + Self.settingsPath
            case .promptNotShown:
                return lead + "because macOS did not ask whether ESPDisplaySender "
                    + "may record this Mac's sound. To send it, " + Self.settingsPath
            case .captureUnavailable(let reason):
                return lead + downlink.unavailableLead + reason
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
        if let refusal {
            startSilence(refusal: refusal)
            return
        }
        do {
            try startTap()
            sourceName = downlink.sourceName
            state = .streaming
            message = downlink.streamingMessage
            publish()
        } catch {
            // A tap that cannot be opened is a steady state, not a fault to
            // retry every second: stream silence so the panel microphone still
            // arrives. A CoreAudio route change restarts and tries again.
            stopEngine()
            let refusal = SystemAudioRefusal.captureUnavailable(
                error.localizedDescription)
            self.refusal = refusal
            startSilence(refusal: refusal)
        }
    }

    private func startTap() throws {
        let tap = try downlink.capture.open()
        let tapFormat = tap.format
        guard tapFormat.commonFormat == .pcmFormatFloat32,
              tapFormat.sampleRate > 0,
              (1...2).contains(tapFormat.channelCount),
              let inputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: tapFormat.sampleRate,
                  channels: tapFormat.channelCount,
                  interleaved: false),
              let captureFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Double(descriptor.sampleRateHz),
                  channels: AVAudioChannelCount(descriptor.playbackChannels),
                  interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: captureFormat)
        else {
            throw audioError(
                code: 2,
                message: "This Mac's sound arrives in a format that cannot be "
                    + "converted for the display.")
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
            throw audioError(
                code: 4, message: "The capture ring could not be allocated.")
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
            throw audioError(
                code: 4, message: "The conversion buffer could not be allocated.")
        }

        let writer = SystemAudioRingWriter(
            lease: ringLifetime.makeCallbackLease(),
            channels: Int(inputFormat.channelCount),
            slotFrames: slotFrames)
        self.tap = tap
        captureWriter = writer
        captureConverter = converter
        captureReadBuffer = readBuffer
        captureConvertedBuffer = convertedBuffer
        captureRingLifetime = ringLifetime

        resetStreamState()
        lastTapFramesNanos = DispatchTime.now().uptimeNanoseconds
        ringLifetime.setAccepting(true)
        // Weak, so teardown never waits on the IO block being released: once
        // `captureWriter` is dropped, its lease goes with it and the ring's
        // quiesce barrier only waits out a callback already in flight.
        try tap.start { [weak writer] list in
            writer?.write(list)
        }
        startCaptureWorker()
    }

    /// The uplink half of `startEngine`, with a silence generator standing in
    /// for this Mac's sound so the panel keeps its backend running and keeps
    /// sending its microphone here.
    private func startSilence(refusal: SystemAudioRefusal) {
        resetStreamState()
        startSilenceWorker()
        sourceName = refusal.sourceName(downlink)
        state = .streaming
        message = refusal.message(downlink)
        publish()
    }

    /// Feeds the downlink silence through the same chunker and pacer. The
    /// pacer alone sets the drift-corrected rate; this only keeps it from
    /// running dry.
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
        // Permission granted in System Settings takes effect without a relaunch.
        if now - lastPermissionCheckNanos >= 1_000_000_000 {
            lastPermissionCheckNanos = now
            if refusal?.awaitsPermission == true,
               downlink.access.status() == .authorized {
                restart(reason: "Permission to record this Mac's sound was granted.")
                return
            }
        }
        queueSilence()
    }

    private func queueSilence() {
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
        // A refused tap records silence rather than failing, so a permission
        // turned off while streaming is noticed here and said so.
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastPermissionCheckNanos >= 1_000_000_000 {
            lastPermissionCheckNanos = now
            // Removing the app from the list can read as undetermined rather
            // than denied; either way the tap is recording silence.
            if permissionAtStart == .authorized {
                switch downlink.access.status() {
                case .denied, .notDetermined:
                    restart(
                        reason: "Permission to record this Mac's sound was turned off.")
                    return
                case .authorized, .unknown:
                    break
                }
            }
        }
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
            lastTapFramesNanos = now
            convertCaptured(readBuffer)
        }
        let dropped = ringLifetime.dropped
        if dropped > lastRingDropped {
            captureCallbackDrops &+= dropped - lastRingDropped
            lastRingDropped = dropped
        }
        if let skipped = captureWriter?.skipped, skipped > lastWriterSkipped {
            captureCallbackDrops &+= skipped - lastWriterSkipped
            lastWriterSkipped = skipped
        }
        // A tap that goes quiet (no IO cycles, or cycles it cannot read) must
        // not silence the downlink: the panel learns this Mac from downlink
        // packets alone, and without them the session would time out and
        // restart forever. Silence fills in until the tap delivers again.
        // The 100 ms floor sits well above any tap IO cycle, so short packets
        // or a large IO buffer never splice silence into real sound.
        let packetNanos = UInt64(chunker.packetFrames) * 1_000_000_000
            / UInt64(max(1, descriptor.sampleRateHz))
        if now - lastTapFramesNanos > max(2 * packetNanos, 100_000_000) {
            queueSilence()
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
                reason: "Converting this Mac's sound failed: "
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
        sendCaptured(AudioDownlinkPCM.encode(corrected, gain: speakerGain))
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
            deliverUplink(chunks)
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

    private func deliverUplink(_ chunks: [AudioPlayoutChunk]) {
        for chunk in chunks {
            switch chunk {
            case .pcm(let pcm):
                uplinkSink.deliver(floatSamples(pcm), Int(pcm.frameCount))
            case .silence(let frames):
                uplinkSink.deliver(
                    [Float](
                        repeating: 0,
                        count: frames * Int(descriptor.captureChannels)),
                    frames)
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
        deliverUplink(chunks)
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
        downlinkResampler.reset()
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

        captureRingLifetime?.setAccepting(false)
        tap?.stop()
        tap = nil
        // Dropping the writer releases the ring lease before the ring itself
        // is released below, whose deinit waits for any callback in flight.
        captureWriter = nil
        if let ringLifetime = captureRingLifetime {
            let dropped = ringLifetime.dropped
            if dropped > lastRingDropped {
                captureCallbackDrops &+= dropped - lastRingDropped
            }
        }

        captureConverter = nil
        captureReadBuffer = nil
        captureConvertedBuffer = nil
        captureRingLifetime = nil
        lastRingDropped = 0
        lastWriterSkipped = 0
        resetStreamState()
    }

    private func publish() {
        onUpdate(PanelAudioSnapshot(
            state: state,
            message: message,
            sourceName: sourceName,
            uplinkDestination: Self.uplinkDestination,
            descriptor: descriptor,
            tuning: tuning,
            panelStatus: panelStatus,
            downlinkQueueDrops: downlinkQueueDrops,
            captureCallbackDrops: captureCallbackDrops,
            uplinkLostFrames: uplinkLostFrames,
            uplinkLatePackets: uplinkLatePackets,
            downlinkCorrectionPPM: downlinkDrift.correctionPPM))
    }
}
