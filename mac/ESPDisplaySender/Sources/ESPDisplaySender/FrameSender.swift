import Foundation
import Network

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
    static let frameBytes = 172 * 320 * 2  // 110_080
    static let chunkPayload = 1376
    static let chunkCount = frameBytes / chunkPayload  // 80

    struct DeviceStats {
        var shown: UInt32 = 0
        var dropped: UInt32 = 0
        var skipped: UInt32 = 0
        var packets: UInt32 = 0
        var heap: UInt32 = 0
    }

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "espdisp.sender")
    private var connection: NWConnection?
    private var frameId: UInt16 = 0
    private var pingTimer: DispatchSourceTimer?

    private let lock = NSLock()
    private var _spacingMicros: UInt32
    private let spacingInitial: UInt32
    private var stallStreak = 0

    // Hill-climb state (touched only from the heartbeat receive path).
    private var climbFrames: Int64 = 0
    private var climbSamples = 0
    private var climbBaselineFps: Double?
    private var climbDirection = 0.85  // start by probing toward faster
    private var _lastHeartbeatAt: Date?
    private var _stats = DeviceStats()
    private var prevStats = DeviceStats()

    private(set) var framesSent: UInt64 = 0
    private(set) var sendErrors: UInt64 = 0

    /// Bounds for adaptive pacing (per-chunk usleep, microseconds). The max
    /// must leave room to throttle below a *degraded* link's clean capacity:
    /// measured on a marginal RSSI (-70dBm) link, ~900 pkt/s collapsed while
    /// ~600 pkt/s was lossless. 2500us/chunk ~= 4fps ~= 320 pkt/s floor.
    private let spacingMin: UInt32 = 120
    private let spacingMax: UInt32 = 2500
    let adaptivePacing: Bool

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

    init(host: String, port: UInt16, spacingMicros: UInt32 = 200, adaptivePacing: Bool = true) {
        self.host = host
        self.port = port
        self._spacingMicros = spacingMicros
        self.spacingInitial = spacingMicros
        self.adaptivePacing = adaptivePacing
    }

    private static let ipCachePath = "/tmp/espdisplaysender-device-ip"

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

    private func connect(to endpointHost: String, timeoutSeconds: Double) async throws {
        connection?.cancel()

        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo
        let conn = NWConnection(
            host: NWEndpoint.Host(endpointHost),
            port: NWEndpoint.Port(rawValue: port)!,
            using: params
        )
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
                logResolvedPath(conn)
                // Grace period: treat "connected just now" as a fresh
                // heartbeat so staleness is measured from this attempt -
                // a permanently dead device keeps re-triggering reconnects.
                lock.lock()
                _lastHeartbeatAt = Date()
                lock.unlock()
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
                try? String(bare).write(
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
        // "EHB1" + shown/dropped/skipped/packets/heap as u32 LE.
        guard data.count == 24, data.prefix(4) == Data("EHB1".utf8) else { return }
        func u32(_ offset: Int) -> UInt32 {
            let b = [UInt8](data[(4 + offset * 4)..<(8 + offset * 4)])
            return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
        }
        let stats = DeviceStats(
            shown: u32(0), dropped: u32(1), skipped: u32(2), packets: u32(3), heap: u32(4))

        lock.lock()
        _lastHeartbeatAt = Date()
        let prev = prevStats
        prevStats = stats
        _stats = stats
        var spacing = _spacingMicros
        lock.unlock()

        guard adaptivePacing else { return }
        // Auto-tune pacing from the delta since the previous heartbeat.
        // Counters reset on device reboot; skip those samples.
        let shownDelta = Int64(stats.shown) - Int64(prev.shown)
        let droppedDelta = Int64(stats.dropped) - Int64(prev.dropped)
        guard shownDelta >= 0, droppedDelta >= 0, shownDelta + droppedDelta > 0 else { return }

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

    /// Send one full frame. `pixels` must be exactly 110,080 bytes of
    /// big-endian RGB565. Synchronous chunking with pacing; sends are async
    /// on the connection's queue.
    func send(frame pixels: [UInt8], landscape: Bool = false) {
        precondition(pixels.count == Self.frameBytes, "bad frame size \(pixels.count)")
        guard let conn = connection else { return }
        let id = frameId
        frameId &+= 1
        let countField = UInt16(Self.chunkCount) | (landscape ? 0x8000 : 0)
        let spacing = spacingMicros

        for chunk in 0..<Self.chunkCount {
            var packet = Data(capacity: 6 + Self.chunkPayload)
            packet.append(UInt8(id & 0xFF))
            packet.append(UInt8(id >> 8))
            packet.append(UInt8(chunk & 0xFF))
            packet.append(UInt8(chunk >> 8))
            packet.append(UInt8(countField & 0xFF))
            packet.append(UInt8(countField >> 8))
            let start = chunk * Self.chunkPayload
            packet.append(contentsOf: pixels[start..<(start + Self.chunkPayload)])

            conn.send(
                content: packet,
                completion: .contentProcessed { [weak self] error in
                    if error != nil {
                        self?.sendErrors &+= 1
                    }
                })
            // Pace every packet: the ESP32's WiFi/lwIP receive path drops
            // heavily above ~3000 packets/s; unpaced 80-packet bursts lose
            // nearly everything.
            if spacing > 0 {
                usleep(spacing)
            }
        }
        framesSent &+= 1
    }
}
