import Foundation
import Network
import SenderProtocol

/// Sends raw RGB565 (big-endian) frames to the ESP32 over UDP, chunked to
/// match the firmware protocol:
///   packet = [frame_id u16 LE][chunk_index u16 LE][chunk_count u16 LE][1376B payload]
/// The top bit of chunk_count carries orientation (1 = landscape 320x172).
/// 1376 bytes = 4 rows of 172 RGB565 pixels; 80 chunks per frame.
///
/// Resilience:
/// - Every 2s a 4-byte "EPNG" keepalive refreshes the firmware's reply
///   endpoint even when no frames flow (static screen).
/// - The firmware heartbeats back 1Hz ("EHB1" + stats). If heartbeats stop,
///   the supervisor calls reconnect(), which re-resolves the mDNS name -
///   this heals ESP32 reboots and DHCP address changes.
/// - Send pacing auto-tunes from the device's reported dropped-frame rate,
///   replacing a hand-tuned constant.
final class FrameSender {
    static let frameBytes = BandProtocol.frameBytes  // 110_080

    typealias DeviceStats = BandProtocol.DeviceStats

    enum DeviceEvent {
        case heartbeat(DeviceStats)
        case info(DeviceProtocol.DeviceInfo)
        case acknowledgement(DeviceProtocol.ControlAck)
    }

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "espdisp.sender")
    private var connection: NWConnection?
    private var frameId: UInt16 = 0
    private var pingTimer: DispatchSourceTimer?
    private var refreshTimer: DispatchSourceTimer?
    /// Last frame handed to send(), kept so a static screen can still be
    /// refreshed periodically (touched only on sendQueue).
    private var lastSentFrame: [UInt8]?
    private var lastSentLandscape = false
    private var lastSendAt = Date.distantPast
    /// How often an unchanging screen gets a full repaint. Cheap (80 packets)
    /// and bounds how long a UDP-lost band can stay visible.
    private let refreshInterval: TimeInterval = 5

    private let lock = NSLock()
    private var _spacingMicros: UInt32
    private let spacingInitial: UInt32
    private var stallStreak = 0

    // Hill-climb state (touched only from the heartbeat receive path).
    private var climbFrames: Int64 = 0
    private var climbSamples = 0
    private var climbBaselineFps: Double?
    private var climbDirection = 0.85  // start by probing toward faster
    private var prevFramesSentAtHb: UInt64 = 0
    private var _lastHeartbeatAt: Date?
    private var _stats = DeviceStats()
    private var _deviceInfo: DeviceProtocol.DeviceInfo?
    private var _lastControlAck: DeviceProtocol.ControlAck?
    private var _resolvedAddress: String?
    private var _paused = false
    private var _parked = false
    /// Genuine replies from the device: heartbeats, info, and control
    /// acknowledgements. Unlike `heartbeatAge` this is never advanced by the
    /// reconnect grace period, so it is the only sound evidence that the panel
    /// is really answering rather than merely having been reconnected to.
    private var _deviceReplies: UInt64 = 0
    private var nextControlSequence = UInt16.random(in: 1...UInt16.max)
    private var prevStats = DeviceStats()
    private let onDeviceEvent: ((DeviceEvent) -> Void)?

    private(set) var framesSent: UInt64 = 0
    private(set) var sendErrors: UInt64 = 0
    private(set) var bandsSent: UInt64 = 0
    private(set) var bandsConsidered: UInt64 = 0

    // Diffing state (touched only on sendQueue).
    private var prevFrame: [UInt8]?
    private var prevLandscape = false
    private var lastKeyframeAt = Date.distantPast
    /// Full-frame refresh cadence: bounds the staleness of any band the
    /// device missed (UDP loss on a band the diff then skips forever), and
    /// repaints everything after a device reboot.
    var keyframeInterval: TimeInterval = 2.0

    /// Bounds for adaptive pacing (per-chunk usleep, microseconds). The max
    /// must leave room to throttle below a *degraded* link's clean capacity:
    /// measured on a marginal RSSI (-70dBm) link, ~900 pkt/s collapsed while
    /// ~600 pkt/s was lossless. 2500us/chunk ~= 4fps ~= 320 pkt/s floor.
    ///
    /// Static so the settings UI offers exactly the range the sender enforces,
    /// rather than a second copy of these numbers that could drift.
    static let spacingRange: ClosedRange<UInt32> = 120...2500
    private var spacingMin: UInt32 { Self.spacingRange.lowerBound }
    private var spacingMax: UInt32 { Self.spacingRange.upperBound }

    private var _adaptivePacing: Bool

    var adaptivePacing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _adaptivePacing
    }

    /// Turn self-tuning on or off at runtime. Switching it off leaves pacing
    /// wherever the climb had reached, which is the value the user can then set
    /// explicitly.
    func setAdaptivePacing(_ enabled: Bool) {
        lock.lock()
        _adaptivePacing = enabled
        lock.unlock()
    }

    /// Set pacing explicitly. Ignored silently while self-tuning is on would be
    /// confusing, so the caller is expected to turn that off first; the value is
    /// still clamped to the range the climb itself respects.
    func setSpacingMicros(_ micros: UInt32) {
        lock.lock()
        _spacingMicros = min(max(micros, Self.spacingRange.lowerBound),
                            Self.spacingRange.upperBound)
        lock.unlock()
    }

    var spacingMicros: UInt32 {
        lock.lock()
        defer { lock.unlock() }
        return _spacingMicros
    }

    /// Seconds since the last device heartbeat; nil if none received yet.
    var heartbeatAge: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return _lastHeartbeatAt.map { Date().timeIntervalSince($0) }
    }

    var deviceStats: DeviceStats {
        lock.lock()
        defer { lock.unlock() }
        return _stats
    }

    var deviceInfo: DeviceProtocol.DeviceInfo? {
        lock.lock()
        defer { lock.unlock() }
        return _deviceInfo
    }

    var lastControlAck: DeviceProtocol.ControlAck? {
        lock.lock()
        defer { lock.unlock() }
        return _lastControlAck
    }

    var resolvedAddress: String? {
        lock.lock()
        defer { lock.unlock() }
        return _resolvedAddress
    }

    var paused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _paused
    }

    /// True while the session has parked this sender because the device stopped
    /// answering. Frames are dropped instead of queued and the periodic full
    /// repaint is skipped, so an unreachable panel stops costing send attempts.
    /// The keepalive ping keeps running: it is what makes a return noticeable.
    var parked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _parked
    }

    var deviceRepliesReceived: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _deviceReplies
    }

    func setParked(_ parked: Bool) {
        lock.lock()
        let changed = _parked != parked
        _parked = parked
        if parked { pendingFrame = nil }
        lock.unlock()
        // The panel's framebuffer is unknown after an absence, and the diff
        // would otherwise skip every band that has not changed since.
        if changed, !parked { forceKeyframe() }
    }

    func setPaused(_ paused: Bool) {
        lock.lock()
        _paused = paused
        if paused {
            pendingFrame = nil
        }
        lock.unlock()
        if !paused { forceKeyframe() }
    }

    /// - Parameters:
    ///   - host: device hostname or IP (typically the mDNS name).
    ///   - port: UDP port the firmware listens on.
    ///   - spacingMicros: initial per-chunk pacing sleep in microseconds.
    ///   - adaptivePacing: auto-tune pacing from device heartbeat stats.
    /// Bonjour service endpoint to connect to instead of host:port. Service
    /// endpoints re-resolve on every connection attempt, so reconnects heal
    /// device address changes with no name/IP bookkeeping at all.
    private let serviceEndpoint: NWEndpoint?

    init(host: String, port: UInt16, spacingMicros: UInt32 = 200,
         adaptivePacing: Bool = true,
         onDeviceEvent: ((DeviceEvent) -> Void)? = nil) {
        self.host = host
        self.port = port
        self.serviceEndpoint = nil
        self._spacingMicros = spacingMicros
        self.spacingInitial = spacingMicros
        self._adaptivePacing = adaptivePacing
        self.onDeviceEvent = onDeviceEvent
    }

    init(endpoint: NWEndpoint, spacingMicros: UInt32 = 200,
         adaptivePacing: Bool = true,
         onDeviceEvent: ((DeviceEvent) -> Void)? = nil) {
        self.host = "\(endpoint)"
        self.port = 0
        self.serviceEndpoint = endpoint
        self._spacingMicros = spacingMicros
        self.spacingInitial = spacingMicros
        self._adaptivePacing = adaptivePacing
        self.onDeviceEvent = onDeviceEvent
    }

    private static let ipCachePath = "/tmp/espdisplaysender-device-ip"

    /// The device IP cached from the last successful connection, or nil.
    /// Used as a unicast fallback when mDNS resolution fails.
    static func cachedIP() -> String? {
        guard let s = try? String(contentsOfFile: ipCachePath, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Connect, preferring the mDNS name but falling back to the device's
    /// last known IP.
    ///
    /// Why the fallback matters: mDNS is multicast, which WiFi sends at the
    /// lowest basic rate with no acks or retransmissions. On a marginal link
    /// it fails while unicast still works fine (measured: mDNS resolution
    /// timing out at RSSI -92 while ping ran at 0% loss). Without this the
    /// stream would be dead despite a perfectly usable path.
    func start(timeoutSeconds: Double = 8) async throws {
        // Service endpoints (from discovery) re-resolve themselves; only
        // host-based connections need the cached-IP fallback dance.
        if serviceEndpoint != nil {
            try await connect(to: nil, timeoutSeconds: timeoutSeconds)
            return
        }
        var candidates = [host]
        if let cached = Self.cachedIP(), cached != host {
            candidates.append(cached)
        }
        var lastError: Error?
        for candidate in candidates {
            do {
                try await connect(to: candidate, timeoutSeconds: timeoutSeconds)
                if candidate != host {
                    print("connected via cached IP \(candidate) (mDNS name did not resolve)")
                }
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
            ?? NSError(
                domain: "ESPDisplaySender", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "no reachable endpoint for \(host)"])
    }

    private func connect(to endpointHost: String?, timeoutSeconds: Double) async throws {
        connection?.cancel()

        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo
        let conn: NWConnection
        if let service = serviceEndpoint {
            conn = NWConnection(to: service, using: params)
        } else {
            conn = NWConnection(
                host: NWEndpoint.Host(endpointHost!),
                port: NWEndpoint.Port(rawValue: port)!,
                using: params
            )
        }
        connection = conn
        conn.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                FileHandle.standardError.write(Data("UDP connection failed: \(error)\n".utf8))
            case .ready:
                break
            default:
                break
            }
        }
        conn.start(queue: queue)

        // Poll for readiness rather than juggling continuation edge cases.
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        while Date() < deadline {
            if conn.state == .ready {
                startReceiveLoop(on: conn)
                startPingTimer()
                startRefreshTimer()
                logResolvedPath(conn)
                // Grace period: treat "connected just now" as a fresh
                // heartbeat so staleness is measured from this attempt -
                // a permanently dead device keeps re-triggering reconnects.
                lock.withLock {
                    _lastHeartbeatAt = Date()
                }
                return
            }
            if case .failed(let error) = conn.state {
                throw error
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        conn.cancel()
        throw NSError(
            domain: "ESPDisplaySender", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "timeout resolving \(host):\(port)"])
    }

    /// Tear down and re-resolve. Heals ESP32 reboots / IP changes.
    func reconnect() async {
        print("reconnecting to \(host):\(port) (re-resolving) ...")
        do {
            try await start()  // start() refreshes the heartbeat grace period
            // The device may have rebooted with an empty framebuffer; the
            // diff would otherwise skip every unchanged band forever.
            forceKeyframe()
        } catch {
            FileHandle.standardError.write(Data("reconnect failed: \(error)\n".utf8))
        }
    }

    private func logResolvedPath(_ conn: NWConnection) {
        guard let endpoint = conn.currentPath?.remoteEndpoint else {
            print("UDP ready")
            return
        }
        print("UDP ready -> \(endpoint)")
        // Cache the resolved address so a future mDNS failure isn't fatal.
        if case .hostPort(let host, _) = endpoint {
            var ip: String?
            switch host {
            case .ipv4(let addr): ip = "\(addr)"
            case .ipv6(let addr): ip = "\(addr)"
            default: break
            }
            // Strip any interface scope ("192.168.1.120%en0").
            if let raw = ip, let bare = raw.split(separator: "%").first {
                let address = String(bare)
                lock.lock()
                _resolvedAddress = address
                lock.unlock()
                try? address.write(
                    toFile: Self.ipCachePath, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: heartbeats

    private func startReceiveLoop(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.connection === conn else { return }
            if let data, error == nil {
                self.handleInbound(data)
            }
            if error == nil {
                self.startReceiveLoop(on: conn)
            }
        }
    }

    private func handleInbound(_ data: Data) {
        if let info = DeviceProtocol.parseInfo(data) {
            lock.lock()
            _deviceInfo = info
            _lastHeartbeatAt = Date()
            _deviceReplies &+= 1
            lock.unlock()
            onDeviceEvent?(.info(info))
            return
        }
        if let acknowledgement = DeviceProtocol.parseAck(data) {
            lock.withLock {
                _lastControlAck = acknowledgement
                _deviceReplies &+= 1
            }
            if !acknowledgement.succeeded {
                let message = "control \(acknowledgement.sequence) failed with status "
                    + "\(acknowledgement.status)\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
            onDeviceEvent?(.acknowledgement(acknowledgement))
            return
        }
        guard let stats = BandProtocol.parseHeartbeat(data) else { return }

        lock.lock()
        _lastHeartbeatAt = Date()
        _deviceReplies &+= 1
        let prev = prevStats
        prevStats = stats
        _stats = stats
        var spacing = _spacingMicros
        lock.unlock()
        onDeviceEvent?(.heartbeat(stats))

        // Counter regression = device rebooted with an empty framebuffer;
        // resend everything.
        let shownDelta = Int64(stats.shown) - Int64(prev.shown)
        let droppedDelta = Int64(stats.dropped) - Int64(prev.dropped)
        if shownDelta < 0 || droppedDelta < 0 {
            print("device counters reset (reboot?) - sending keyframe")
            forceKeyframe()
            return
        }

        guard adaptivePacing else { return }
        // With dirty-band diffing, offered load tracks content activity: a
        // static screen legitimately delivers ~0 fps. Feeding those windows
        // to the hill-climb would read as regression and send pacing
        // wandering; freeze the climb unless we actually sent frames.
        let sentNow = framesSent
        let sentDelta = Int64(sentNow) - Int64(prevFramesSentAtHb)
        prevFramesSentAtHb = sentNow
        guard sentDelta >= 3 else { return }
        guard shownDelta + droppedDelta > 0 else { return }

        // Sustained total failure (drops but zero completions) is a broken
        // link, not oversubscription - ratcheting pacing to max doesn't help
        // and makes recovery sluggish. Reset to the default and hold until
        // frames complete again (the device heals its own radio meanwhile).
        if shownDelta == 0 {
            stallStreak += 1
            if stallStreak == 15 {
                lock.lock()
                _spacingMicros = spacingInitial
                lock.unlock()
                climbFrames = 0
                climbSamples = 0
                climbBaselineFps = nil
                climbDirection = 0.85
                print("pacing: reset to \(spacingInitial)us (no frames completing - not a rate problem)")
            }
            if stallStreak >= 15 { return }
        } else {
            stallStreak = 0
        }

        let dropRatio = Double(droppedDelta) / Double(shownDelta + droppedDelta)
        let old = spacing

        // Collapse guard: extreme loss means the link is genuinely
        // oversubscribed (or the AP has downshifted rates), so react
        // immediately rather than waiting for a probe window.
        if dropRatio > 0.5 {
            spacing = min(UInt32(Double(spacing) * 1.4), spacingMax)
            climbFrames = 0
            climbSamples = 0
            climbBaselineFps = nil
            lock.lock()
            _spacingMicros = spacing
            lock.unlock()
            print(String(format: "pacing: %dus -> %dus (severe loss %.0f%%)",
                         old, spacing, dropRatio * 100))
            return
        }

        // Hill-climb on *delivered* frame rate. Optimizing for zero drops is
        // the wrong objective for a video stream - trading a few percent of
        // dropped frames for a much higher displayed rate is a clear win -
        // and a drop-ratio controller with thresholds also strands itself in
        // the dead band between them (measured: stuck at 600us / ~15fps with
        // drops sitting at 4%, when 200us delivered 33fps).
        climbFrames += shownDelta
        climbSamples += 1
        guard climbSamples >= 3 else { return }  // ~3s per probe: averages out jitter
        let fps = Double(climbFrames) / Double(climbSamples)
        climbFrames = 0
        climbSamples = 0

        guard let baseline = climbBaselineFps else {
            // First window: record and take one step to get a gradient.
            climbBaselineFps = fps
            spacing = clampSpacing(Double(spacing) * climbDirection)
            applySpacing(spacing, from: old, fps: fps)
            return
        }

        if fps > baseline * 1.03 {
            // Improving: keep stepping the same way.
        } else if fps < baseline * 0.97 {
            // Worse: reverse.
            climbDirection = climbDirection < 1 ? 1.18 : 0.85
        } else {
            // Plateau: nudge toward lower latency, since equal delivered fps
            // at tighter pacing means fresher frames.
            climbDirection = 0.92
        }
        climbBaselineFps = fps
        spacing = clampSpacing(Double(spacing) * climbDirection)
        applySpacing(spacing, from: old, fps: fps)
    }

    private func clampSpacing(_ value: Double) -> UInt32 {
        UInt32(max(Double(spacingMin), min(value, Double(spacingMax))))
    }

    private func applySpacing(_ new: UInt32, from old: UInt32, fps: Double) {
        guard new != old else { return }
        lock.lock()
        _spacingMicros = new
        lock.unlock()
        if abs(Int(new) - Int(old)) > Int(old) / 8 {
            print(String(format: "pacing: %dus -> %dus (delivering %.1f fps)", old, new, fps))
        }
    }

    /// Tell the device the Mac's displays slept, so it can kill its
    /// backlight instead of glowing on stale pixels all night. Sent a few
    /// times because it's UDP.
    func sendDisplaySleep() {
        sendLegacyControl("ESLP")
    }

    /// Explicit wake. Needed because the Mac may wake onto static content,
    /// in which case there is no frame to send and the panel would stay
    /// dark waiting for one.
    func sendDisplayWake() {
        sendLegacyControl("EWAK")
    }

    func setBrightness(high: Bool) {
        sendManagementControl(.brightness, value: high ? 1 : 0)
    }

    /// Set an exact backlight level. Only valid for firmware advertising
    /// `brightnessLevel`; older firmware rejects the opcode outright, which is
    /// why the caller gates on the capability.
    func setBrightnessLevel(_ level: Int) {
        let clamped = min(
            max(level, DeviceProtocol.brightnessLevelRange.lowerBound),
            DeviceProtocol.brightnessLevelRange.upperBound)
        sendManagementControl(.brightnessLevel, value: Int32(clamped))
    }

    func setFlip(_ flipped: Bool) {
        sendManagementControl(.flip, value: flipped ? 1 : 0)
    }

    func identify(seconds: Int = 8) {
        let bounded = min(
            max(seconds, DeviceProtocol.identifySecondsRange.lowerBound),
            DeviceProtocol.identifySecondsRange.upperBound)
        sendManagementControl(.identify, value: Int32(bounded))
    }

    func restartDevice() {
        sendManagementControl(.restart, value: 1)
    }

    /// Push the lines the panel should show while nothing is driving it. An
    /// empty array clears them. Only valid for firmware advertising `idleText`,
    /// which is why the caller gates on the capability.
    ///
    /// Repeated like the other one-shot commands because it is UDP: the panel
    /// only shows this when its sender has gone, which is exactly when a lost
    /// packet would be least recoverable.
    func sendIdleText(_ lines: [String]) {
        guard let conn = connection, let packet = IdleText.packet(lines: lines) else {
            return
        }
        for _ in 0..<3 {
            conn.send(content: packet, completion: .contentProcessed { _ in })
            usleep(20_000)
        }
    }

    private func sendManagementControl(
        _ opcode: DeviceProtocol.ControlOpcode, value: Int32
    ) {
        guard let conn = connection else { return }
        lock.lock()
        let sequence = nextControlSequence
        nextControlSequence &+= 1
        lock.unlock()
        let packet = DeviceProtocol.controlPacket(
            opcode: opcode, sequence: sequence, value: value)
        for _ in 0..<3 {
            conn.send(content: packet, completion: .contentProcessed { _ in })
            usleep(20_000)
        }
    }

    private func sendLegacyControl(_ tag: String) {
        guard let conn = connection else { return }
        for _ in 0..<3 {
            conn.send(content: Data(tag.utf8), completion: .contentProcessed { _ in })
            usleep(20_000)
        }
    }

    private func startPingTimer() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2.0)
        timer.setEventHandler { [weak self] in
            self?.connection?.send(
                content: Data("EPNG".utf8), completion: .contentProcessed { _ in })
        }
        timer.resume()
        pingTimer = timer
    }

    // MARK: frames

    private let sendQueue = DispatchQueue(label: "espdisp.send", qos: .userInteractive)
    private var pendingFrame: [UInt8]?
    private var pendingLandscape = false
    private var sendInFlight = false

    /// Queue a frame for sending, keeping only the newest.
    ///
    /// Sending is paced (80 chunks x spacing, tens of milliseconds), so doing
    /// it synchronously inside the ScreenCaptureKit callback back-pressures
    /// capture and puts stale frames on the wire. A depth-1 slot decouples
    /// the two: capture returns immediately and whatever frame is newest when
    /// the sender frees up is the one that goes out.
    func submit(frame: [UInt8], landscape: Bool) {
        lock.lock()
        guard !_paused, !_parked else {
            lock.unlock()
            return
        }
        pendingFrame = frame
        pendingLandscape = landscape
        let needsDispatch = !sendInFlight
        if needsDispatch { sendInFlight = true }
        lock.unlock()
        guard needsDispatch else { return }
        sendQueue.async { [weak self] in self?.drainPending() }
    }

    private func drainPending() {
        while true {
            lock.lock()
            guard let frame = pendingFrame else {
                sendInFlight = false
                lock.unlock()
                return
            }
            pendingFrame = nil
            let landscape = pendingLandscape
            lock.unlock()
            send(frame: frame, landscape: landscape)
        }
    }

    /// Force the next frame to be sent in full (after reconnects or a
    /// detected device reboot, when the device's buffer state is unknown).
    func forceKeyframe() {
        sendQueue.async { [weak self] in self?.prevFrame = nil }
    }

    /// Send one frame, transmitting only the bands that changed since the
    /// previous frame (dirty-rectangle diffing at row-band granularity).
    /// `pixels` must be exactly 110,080 bytes of big-endian RGB565. Packet:
    /// [frame_id][band_index][dirty_count, bit15 = landscape][band payload].
    func send(frame pixels: [UInt8], landscape: Bool = false) {
        precondition(pixels.count == Self.frameBytes, "bad frame size \(pixels.count)")
        guard let conn = connection else { return }
        let (bands, bandBytes) = BandProtocol.bandGeometry(landscape: landscape)

        var dirty: [Int]
        let keyframeDue = Date().timeIntervalSince(lastKeyframeAt) > keyframeInterval
        if prevFrame == nil || landscape != prevLandscape || keyframeDue {
            dirty = Array(0..<bands)
            lastKeyframeAt = Date()
        } else {
            dirty = BandProtocol.dirtyBands(new: pixels, previous: prevFrame!,
                                            landscape: landscape)
        }
        prevFrame = pixels
        prevLandscape = landscape
        bandsConsidered &+= UInt64(bands)
        guard !dirty.isEmpty else { return }  // identical frame: send nothing

        let id = frameId
        frameId &+= 1
        let spacing = spacingMicros

        for band in dirty {
            var packet = BandProtocol.packetHeader(
                frameId: id, band: band, dirtyCount: dirty.count, landscape: landscape)
            let start = band * bandBytes
            packet.append(contentsOf: pixels[start..<(start + bandBytes)])

            conn.send(
                content: packet,
                completion: .contentProcessed { [weak self] error in
                    if error != nil {
                        self?.sendErrors &+= 1
                    }
                })
            // Pace every packet: the ESP32's WiFi/lwIP receive path drops
            // heavily above ~3000 packets/s; unpaced bursts lose nearly
            // everything.
            if spacing > 0 {
                usleep(spacing)
            }
        }
        bandsSent &+= UInt64(dirty.count)
        framesSent &+= 1
        lastSentFrame = pixels
        lastSentLandscape = landscape
        lastSendAt = Date()
    }

    /// Periodically re-send the current frame when capture has gone quiet.
    ///
    /// ScreenCaptureKit delivers nothing at all while content is static, and
    /// the keyframe interval is evaluated inside send() - so on a still
    /// screen the "keyframe every 2s" guarantee never actually fired, and a
    /// band lost to UDP would stay wrong indefinitely. This timer makes the
    /// refresh real without spending bandwidth on unchanged content.
    private func startRefreshTimer() {
        refreshTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: sendQueue)
        timer.schedule(deadline: .now() + refreshInterval, repeating: refreshInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let frame = self.lastSentFrame else { return }
            guard !self.parked else { return }
            guard Date().timeIntervalSince(self.lastSendAt) >= self.refreshInterval else {
                return  // real frames are flowing; nothing to do
            }
            self.prevFrame = nil  // full repaint, healing any lost bands
            self.send(frame: frame, landscape: self.lastSentLandscape)
        }
        timer.resume()
        refreshTimer = timer
    }
}
