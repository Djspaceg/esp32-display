import Foundation
import Network
import SenderProtocol

/// Sends raw RGB565 (big-endian) frames to the ESP32 over UDP, chunked to
/// match the firmware protocol:
///   packet = [frame_id u16 LE][band_index u16 LE][band_count u16 LE][payload]
/// The top bit of band_count carries orientation (1 = landscape); band
/// geometry derives from the panel's advertised resolution (BandProtocol).
/// To a panel advertising `compressedBands`, dirty bands go as packed
/// packets instead - several RLE-compressed or raw band records per
/// datagram (BandPacker) - because the panel's receive path tops out at a
/// datagram rate, so fewer, denser datagrams is what raises the frame rate.
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

    /// Panel geometry for this sender. Defaults to the 172x320 panel; sessions
    /// driving other resolutions pass the device's advertised geometry.
    let geometry: PanelGeometry

    typealias DeviceStats = BandProtocol.DeviceStats

    enum DeviceEvent {
        case heartbeat(DeviceStats)
        case info(DeviceProtocol.DeviceInfo)
        case acknowledgement(DeviceProtocol.ControlAck)
        case touch(DeviceProtocol.TouchEvent)
        case battery(DeviceProtocol.BatteryStatus)
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
    /// Whether the panel has advertised `compressedBands` over EINF, read on
    /// the send path. Off until the first EINF arrives (a couple of seconds),
    /// during which frames go in the classic one-raw-band-per-packet format -
    /// which is also everything a panel that never advertises it ever gets.
    private var _peerAcceptsPackedBands = false
    /// Whether the panel has advertised `tileStream` over EINF. Mutually
    /// exclusive with `compressedBands` on the wire (both formats claim bit
    /// 15 of the header's second field - see TileProtocol), so a panel sets
    /// at most one of these and the send path picks by whichever arrived.
    /// Off until the first EINF, during which the classic band format flows
    /// - the fallback every firmware accepts.
    private var _peerAcceptsTileStream = false
    /// The tile grid for this panel's geometry, present only when the
    /// geometry can carry the tile protocol at all (every square panel can;
    /// this exists so a hostile mDNS geometry cannot reach tile arithmetic).
    private let tileGeometry: TileGeometry?
    /// Which tiles this panel can actually show. Built from
    /// `Capabilities.roundDisplay` on the first EINF; nil until then, which
    /// means "send everything" - the safe direction, since a tile sent
    /// needlessly costs bandwidth while a tile skipped wrongly is permanent
    /// corruption.
    private var _tileMask: TileMask?
    /// The roundness the panel last advertised, so the mask is rebuilt on a
    /// change rather than on every 2-second EINF.
    private var _peerRoundDisplay: Bool?
    /// When BC1 may win a run - the user's quality lever (settings UI).
    private var _tileLossyPolicy: TileLossyPolicy = .auto
    /// Tile-diff state (touched only on sendQueue), separate from prevFrame
    /// deliberately: the band path's diff invalidation rules keep their own
    /// variable so nothing about that path's reasoning changes.
    private var prevTileFrame: [UInt8]?
    private var prevTileLandscape = false
    private var lastTileKeyframeAt = Date.distantPast
    /// Set when a diff frame's estimated cost exceeded the pacing budget
    /// even at BC1 rates: the NEXT diff frame is dropped outright (its dirt
    /// accumulates into the one after), halving the offered frame rate
    /// instead of flooding the panel's receive queue - the last rung of the
    /// degradation ladder (docs/tile-stream-plan.md section 6.6 step 3c).
    /// sendQueue-only.
    private var skipNextTileFrame = false
    /// The frame rate the degradation ladder defends. Below the 60 target
    /// deliberately: forcing BC1 (rung a) engages when lossless could not
    /// sustain this, and frame skipping (rung c) only when even BC1 cannot.
    private static let degradeTargetFps = 30.0

    // Per-stage cost of the tile send path, accumulated on sendQueue and
    // reported every `tileStatInterval`. Added because the sender's own
    // cadence was the one limit in docs/tile-stream-plan.md section 12.3
    // that had never been measured - the panel's side was instrumented from
    // phase 0, the Mac's side not at all, and "it is probably the encoder"
    // is exactly the kind of guess this project has been wrong about before.
    private var tileStatFrames = 0
    private var tileStatTiles = 0
    private var tileStatPackets = 0
    private var tileStatDiffNs: UInt64 = 0
    private var tileStatEncodeNs: UInt64 = 0
    private var tileStatSendNs: UInt64 = 0
    private var tileStatSleepNs: UInt64 = 0
    private var tileStatAt = Date.distantPast
    private let tileStatInterval: TimeInterval = 5

    /// Absolute time the next datagram is due, in `DispatchTime` nanoseconds.
    /// Persists across sends so the datagram rate holds across frames; see
    /// `sendPaced`. sendQueue-only.
    private var pacingDeadline: UInt64 = 0
    /// Orientation of the most recent frame sent, readable from any thread.
    ///
    /// This is the frame the panel currently has on screen, and so the frame its
    /// touch controller maps a finger into. That makes it the orientation a
    /// gesture binding has to be read against: which axis is the panel's long one
    /// depends on it.
    private var _currentLandscape = false
    private var lastSendAt = Date.distantPast
    /// How often an unchanging screen gets a full repaint. One keyframe -
    /// geometry.bandCount packets uncompressed (80 on the 172x320, 466 on the
    /// 466x466), far fewer packed - and bounds how long a UDP-lost band can
    /// stay visible.
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
    /// Coalescing state for the brightness slider, guarded by `lock`.
    ///
    /// A drag emits far more values than either the link or the panel's
    /// control queue can absorb, and only the newest one matters, so pending
    /// values are replaced rather than queued. `_brightnessSettled` tracks
    /// whether the value the drag ended on has been re-sent with the usual
    /// redundancy - during the drag single datagrams are enough because a loss
    /// is superseded within an interval, but the final one has to arrive.
    private var _pendingBrightnessLevel: Int?
    private var _lastBrightnessSent: Int?
    private var _brightnessFlushScheduled = false
    private var _brightnessSettled = true
    /// Minimum gap between brightness datagrams while the slider is moving.
    /// Well inside a frame interval, so the panel tracks the cursor visibly
    /// but the stream cannot crowd out actual frames.
    private let brightnessInterval: TimeInterval = 0.05
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

    /// Widest range the pacing knob accepts anywhere (per-packet usleep,
    /// microseconds). The settings slider offers exactly this, and an explicit
    /// user value clamps to it; the CONTROLLER is bounded tighter, per panel,
    /// by `spacingBounds(for:)` below.
    ///
    /// Static so the settings UI offers exactly the range the sender enforces,
    /// rather than a second copy of these numbers that could drift.
    static let spacingRange: ClosedRange<UInt32> = 120...2500

    /// Fastest packet rate the controller may offer. 120us between packets =
    /// ~8300 pkt/s, the same cap the fixed 120us floor always was; the panel
    /// accepts what its receive path can take and the climb settles there.
    static let maxOfferedPacketsPerSecond: UInt32 = 1_000_000 / spacingRange.lowerBound

    /// The frame rate the controller must never be able to sit below, counted
    /// against the worst case of one packet per band (an uncompressed
    /// keyframe). Packets per second is the invariant here - the panel's
    /// ceiling is a datagram rate - so the spacing ceiling has to derive from
    /// geometry.bandCount: the fixed 2500us ceiling meant a 5 fps floor on
    /// the 80-band 172x320 but 0.86 fps on the 466-band 466x466, which is the
    /// bug where the pacing hill-climb parked a panel at ~1 fps.
    static let minWorstCaseFps: UInt32 = 5

    /// Controller bounds for a panel: the offered-rate cap as the floor, and
    /// a ceiling that keeps `minWorstCaseFps * bandCount` packets per second
    /// flowing in the orientation with the most bands.
    static func spacingBounds(for geometry: PanelGeometry) -> ClosedRange<UInt32> {
        let bands = UInt32(max(geometry.bandCount(landscape: false),
                               geometry.bandCount(landscape: true)))
        let floor = spacingRange.lowerBound
        let ceiling = max(floor, 1_000_000 / (minWorstCaseFps * bands))
        return floor...ceiling
    }

    /// Datagrams sent back-to-back before pausing for their whole quota.
    ///
    /// Sleeping after EVERY datagram cannot pace at these intervals, which
    /// instrumenting the send path made obvious: `usleep(333)` measured
    /// ~890us on this machine and sometimes 2.5ms, because a sub-millisecond
    /// sleep is dominated by syscall cost and macOS timer coalescing rather
    /// than by the interval asked for. The result was a sender capped near
    /// ~1120 datagrams/s while the panel accepts ~2850/s (phase 6) - so the
    /// SENDER was the ceiling every earlier measurement blamed on ingest,
    /// and pacing was 83% of a frame's cost.
    ///
    /// Bursting amortizes that slop over several datagrams, and pacing
    /// against an absolute deadline (`pacingDeadline`) makes an overlong
    /// sleep shorten the next one instead of accumulating. 8 stays well
    /// under the ~44 datagrams the panel's 64 KB socket buffer absorbs,
    /// which is what makes bursting safe here rather than lossy.
    private static let pacingBurstPackets = 8

    /// Longest single pacing sleep, a failsafe against a pathological
    /// spacing x count product stalling the send queue.
    private static let pacingMaxSleepMicros: UInt32 = 50_000

    private let spacingBounds: ClosedRange<UInt32>
    private var spacingMin: UInt32 { spacingBounds.lowerBound }
    private var spacingMax: UInt32 { spacingBounds.upperBound }

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

    /// Set the tile-stream quality policy (see `TileLossyPolicy`). No effect
    /// on panels speaking the band protocol, which has no lossy codec.
    func setTileLossyPolicy(_ policy: TileLossyPolicy) {
        lock.lock()
        _tileLossyPolicy = policy
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

    /// Orientation of the last frame sent, i.e. what the panel is showing now.
    var currentLandscape: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _currentLandscape
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
         geometry: PanelGeometry = .panel172x320,
         onDeviceEvent: ((DeviceEvent) -> Void)? = nil) {
        self.host = host
        self.port = port
        self.serviceEndpoint = nil
        self.geometry = geometry
        self.tileGeometry = Self.tileGeometry(for: geometry)
        self.spacingBounds = Self.spacingBounds(for: geometry)
        self._spacingMicros = spacingMicros
        self.spacingInitial = spacingMicros
        self._adaptivePacing = adaptivePacing
        self.onDeviceEvent = onDeviceEvent
    }

    init(endpoint: NWEndpoint, spacingMicros: UInt32 = 200,
         adaptivePacing: Bool = true,
         geometry: PanelGeometry = .panel172x320,
         onDeviceEvent: ((DeviceEvent) -> Void)? = nil) {
        self.host = "\(endpoint)"
        self.port = 0
        self.serviceEndpoint = endpoint
        self.geometry = geometry
        self.tileGeometry = Self.tileGeometry(for: geometry)
        self.spacingBounds = Self.spacingBounds(for: geometry)
        self._spacingMicros = spacingMicros
        self.spacingInitial = spacingMicros
        self._adaptivePacing = adaptivePacing
        self.onDeviceEvent = onDeviceEvent
    }

    /// The tile grid for a panel geometry, or nil when the tile protocol
    /// cannot carry it. Nil disables the tile path outright, so a panel
    /// advertising `tileStream` against an implausible mDNS geometry
    /// degrades to bands instead of feeding bad numbers into grid math.
    static func tileGeometry(for geometry: PanelGeometry) -> TileGeometry? {
        let tiles = TileGeometry(width: geometry.width, height: geometry.height)
        return tiles.isStreamable ? tiles : nil
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
            _peerAcceptsPackedBands = info.capabilities.contains(.compressedBands)
            _peerAcceptsTileStream = info.capabilities.contains(.tileStream)
                && tileGeometry != nil
            // Round glass: rebuild the mask only when the advertised answer
            // changes. It is a per-panel constant, but EINF repeats every
            // 2 s and the classification walks every tile. Keyed on what the
            // panel SAID rather than on the resulting mask, so a round flag
            // the mask declines to honour (non-square glass, which no round
            // panel has) does not re-walk the grid every heartbeat.
            let round = info.capabilities.contains(.roundDisplay)
            if _peerRoundDisplay != round, let tiles = tileGeometry {
                _peerRoundDisplay = round
                _tileMask = TileMask(geometry: tiles, round: round)
            }
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
        if let touch = DeviceProtocol.parseTouch(data) {
            // Counts as a reply — the panel only sends this unprompted, so it
            // is proof the link works — but deliberately not as a heartbeat.
            // Heartbeat age drives the reconnect watchdog and the pacing
            // hill-climb, and a finger is not evidence that frames are landing.
            lock.withLock { _deviceReplies &+= 1 }
            onDeviceEvent?(.touch(touch))
            return
        }
        if let battery = DeviceProtocol.parseBattery(data) {
            // Same split as touch, for a stronger reason. It is a reply: the
            // panel sends it unprompted, so it proves the link works. It is not
            // a heartbeat: heartbeat age drives the reconnect watchdog and the
            // pacing hill-climb, and a battery reading says nothing about
            // whether frames are landing. It arrives on a 10s timer regardless
            // of the stream, so letting it stand in for a heartbeat would keep
            // a panel reading "Online" indefinitely after its stream died.
            lock.withLock { _deviceReplies &+= 1 }
            onDeviceEvent?(.battery(battery))
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
    ///
    /// Safe to call at whatever rate a slider produces: values are coalesced
    /// and sent on a background queue, so the caller never waits on the wire.
    func setBrightnessLevel(_ level: Int) {
        let clamped = min(
            max(level, DeviceProtocol.brightnessLevelRange.lowerBound),
            DeviceProtocol.brightnessLevelRange.upperBound)
        lock.lock()
        _pendingBrightnessLevel = clamped
        let needsSchedule = !_brightnessFlushScheduled
        _brightnessFlushScheduled = true
        lock.unlock()
        guard needsSchedule else { return }
        queue.asyncAfter(deadline: .now() + brightnessInterval) { [weak self] in
            self?.flushBrightnessLevel()
        }
    }

    /// Send the newest pending level and keep going while the slider moves.
    ///
    /// When a tick finds nothing pending the drag has stopped, so the value it
    /// ended on is re-sent redundantly and the loop retires. That guarantees
    /// the panel settles where the user left it even if the single datagram
    /// carrying the last value was dropped.
    private func flushBrightnessLevel() {
        lock.lock()
        let pending = _pendingBrightnessLevel
        _pendingBrightnessLevel = nil
        if let pending {
            _lastBrightnessSent = pending
            _brightnessSettled = false
        }
        let settleValue = pending == nil && !_brightnessSettled
            ? _lastBrightnessSent : nil
        if pending == nil {
            _brightnessSettled = true
            _brightnessFlushScheduled = false
        }
        lock.unlock()

        if let pending {
            transmitControl(.brightnessLevel, value: Int32(pending), repeats: 1)
            queue.asyncAfter(deadline: .now() + brightnessInterval) { [weak self] in
                self?.flushBrightnessLevel()
            }
        } else if let settleValue {
            transmitControl(.brightnessLevel, value: Int32(settleValue), repeats: 3)
        }
    }

    func setFlip(_ flipped: Bool) {
        sendManagementControl(.flip, value: flipped ? 1 : 0)
    }

    /// Set the mounting rotation in clockwise quarter turns. Only valid for
    /// firmware advertising `rotate` — older firmware refuses the opcode
    /// silently, which is why the caller gates on the capability and keeps
    /// `setFlip` for everything else.
    func setRotation(_ rotation: Int) {
        let clamped = min(
            max(rotation, DeviceProtocol.rotationRange.lowerBound),
            DeviceProtocol.rotationRange.upperBound)
        sendManagementControl(.rotate, value: Int32(clamped))
    }

    /// Turn the panel's display on or off. Independent of `sendDisplaySleep`/
    /// `sendDisplayWake` (ESLP/EWAK), which follow this Mac's own screens and
    /// clear on the next drawn frame - this is a standing instruction the
    /// panel keeps until told otherwise, persisted across its reboots too.
    /// Only valid for firmware advertising `power`, which every board does
    /// (see `DeviceProtocol.Capabilities.power`).
    func setPower(_ on: Bool) {
        sendManagementControl(.power, value: on ? 1 : 0)
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
        guard let packet = IdleText.packet(lines: lines) else { return }
        transmit(packet, repeats: 3)
    }

    private func sendManagementControl(
        _ opcode: DeviceProtocol.ControlOpcode, value: Int32
    ) {
        transmitControl(opcode, value: value, repeats: 3)
    }

    private func transmitControl(
        _ opcode: DeviceProtocol.ControlOpcode, value: Int32, repeats: Int
    ) {
        lock.lock()
        let sequence = nextControlSequence
        nextControlSequence &+= 1
        lock.unlock()
        let packet = DeviceProtocol.controlPacket(
            opcode: opcode, sequence: sequence, value: value)
        transmit(packet, repeats: repeats)
    }

    private func sendLegacyControl(_ tag: String) {
        transmit(Data(tag.utf8), repeats: 3)
    }

    /// Put a one-shot datagram on the wire, repeated and spaced so a single
    /// burst of loss cannot swallow the whole command.
    ///
    /// Always hops to `queue` first. This used to run inline on the caller's
    /// thread, which for anything driven from the UI meant the main actor sat
    /// through 60ms of spacing sleeps per call - tolerable for a button, and
    /// the reason a slider felt like treacle.
    private func transmit(_ packet: Data, repeats: Int) {
        let count = max(1, repeats)
        queue.async { [weak self] in
            guard let conn = self?.connection else { return }
            for index in 0..<count {
                conn.send(content: packet, completion: .contentProcessed { _ in })
                // No reason to sleep after the last one.
                if index + 1 < count { usleep(20_000) }
            }
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
        sendQueue.async { [weak self] in
            self?.prevFrame = nil
            self?.prevTileFrame = nil
        }
    }

    /// Send one frame, transmitting only the bands that changed since the
    /// previous frame (dirty-rectangle diffing at row-band granularity).
    /// `pixels` must be exactly `geometry.frameBytes` bytes of big-endian
    /// RGB565. Packet:
    /// [frame_id][band_index][dirty_count, bit15 = landscape][band payload].
    func send(frame pixels: [UInt8], landscape: Bool = false) {
        precondition(pixels.count == geometry.frameBytes, "bad frame size \(pixels.count)")
        guard let conn = connection else { return }

        lock.lock()
        let tileStream = _peerAcceptsTileStream
        let mask = _tileMask
        lock.unlock()
        if tileStream, let tiles = tileGeometry {
            sendTileFrame(pixels, landscape: landscape, tiles: tiles,
                          mask: mask, conn: conn)
            return
        }

        let bands = geometry.bandCount(landscape: landscape)

        var dirty: [Int]
        let keyframeDue = Date().timeIntervalSince(lastKeyframeAt) > keyframeInterval
        if prevFrame == nil || landscape != prevLandscape || keyframeDue {
            dirty = Array(0..<bands)
            lastKeyframeAt = Date()
        } else {
            dirty = BandProtocol.dirtyBands(new: pixels, previous: prevFrame!,
                                            geometry: geometry, landscape: landscape)
        }
        prevFrame = pixels
        prevLandscape = landscape
        bandsConsidered &+= UInt64(bands)
        guard !dirty.isEmpty else { return }  // identical frame: send nothing

        let id = frameId
        frameId &+= 1
        let spacing = spacingMicros
        lock.lock()
        let packBands = _peerAcceptsPackedBands
        lock.unlock()

        let packets: [Data]
        if packBands {
            // Packed: several RLE-compressed or raw band records per
            // datagram. The panel's receive path tops out at a datagram rate
            // (measured on the 466x466 S3: ~1826/s accepted regardless of
            // offered rate), so carrying more bands per datagram is the lever
            // that raises the frame rate.
            packets = BandPacker.packets(
                frameId: id, dirty: dirty, pixels: pixels,
                geometry: geometry, landscape: landscape)
        } else {
            // Classic format, byte-identical to what this sender always
            // emitted: one raw band per packet. Everything a panel that never
            // advertised `compressedBands` ever receives.
            packets = dirty.map { band in
                var packet = BandProtocol.packetHeader(
                    frameId: id, band: band, dirtyCount: dirty.count,
                    landscape: landscape)
                let start = geometry.bandOffset(index: band, landscape: landscape)
                let len = geometry.bandPayloadBytes(index: band, landscape: landscape)
                packet.append(contentsOf: pixels[start..<(start + len)])
                return packet
            }
        }

        // Pace the datagrams: the panel's receive path accepts a bounded
        // datagram rate (~2850/s measured on the S3 after phase 6, less on a
        // single-core C6) and unpaced bursts overflow it and lose nearly
        // everything. See sendPaced for why this bursts rather than sleeping
        // per packet.
        _ = sendPaced(packets, spacing: spacing, on: conn)
        bandsSent &+= UInt64(dirty.count)
        framesSent &+= 1
        lastSentFrame = pixels
        lastSentLandscape = landscape
        // Mirrored under the lock for cross-thread readers. `lastSentLandscape`
        // itself stays sendQueue-only so the existing serialization reasoning
        // around it does not have to change.
        lock.lock()
        _currentLandscape = landscape
        lock.unlock()
        lastSendAt = Date()
    }

    /// Send one frame over the tile-stream protocol (panels advertising
    /// `tileStream`): per-16x16-tile diff, horizontally merged runs, each
    /// encoded raw / RLE565 / BC1 with the smallest winning, packed greedily
    /// into 1472 B datagrams. The lever over bands is granularity - a small
    /// moving element dirties a few 512 B tiles instead of full 932 B rows -
    /// plus BC1's fixed 4:1 on content RLE cannot touch.
    ///
    /// Same keyframe triggers as the band path (first frame, orientation
    /// change, interval) and the same pacing loop; only the wire format and
    /// diff granularity differ.
    private func sendTileFrame(
        _ pixels: [UInt8], landscape: Bool, tiles: TileGeometry,
        mask: TileMask?, conn: NWConnection
    ) {
        let keyframeDue =
            Date().timeIntervalSince(lastTileKeyframeAt) > keyframeInterval
        let isKeyframe =
            prevTileFrame == nil || landscape != prevTileLandscape || keyframeDue
        if skipNextTileFrame {
            // The previous diff frame was over budget even at BC1 rates:
            // drop this one entirely. prevTileFrame is deliberately NOT
            // updated, so everything this frame changed lands in the next
            // frame's diff - deferred, never lost. Keyframes are exempt:
            // they exist to heal loss and must not themselves be skippable.
            skipNextTileFrame = false
            if !isKeyframe { return }
        }

        var dirty: [Int]
        let diffStart = DispatchTime.now().uptimeNanoseconds
        if isKeyframe {
            // Even a keyframe covers only what the glass can show: the tiles
            // behind a round bezel are not merely unchanged, they are
            // unseeable, so nothing is ever owed to them.
            dirty = mask?.visibleTiles ?? Array(0..<tiles.tileCount)
            lastTileKeyframeAt = Date()
        } else {
            dirty = TileProtocol.dirtyTiles(
                new: pixels, previous: prevTileFrame!, geometry: tiles,
                mask: mask)
        }
        tileStatDiffNs &+= DispatchTime.now().uptimeNanoseconds &- diffStart
        prevTileFrame = pixels
        prevTileLandscape = landscape
        bandsConsidered &+= UInt64(mask?.visibleTiles.count ?? tiles.tileCount)
        guard !dirty.isEmpty else { return }  // identical frame: send nothing

        let id = frameId
        frameId &+= 1
        let spacing = spacingMicros
        lock.lock()
        let policy = _tileLossyPolicy
        lock.unlock()

        // The degradation ladder (docs/tile-stream-plan.md section 6.6),
        // applied to diff frames only - a keyframe is a bounded 2-second
        // cost whose latency does not gate motion, and forcing it lossy
        // would leave a STATIC screen at BC1 quality forever (nothing dirty
        // afterward ever heals it). Budget = what the current pacing can
        // carry per frame at the fps the ladder defends; estimates use the
        // plan's flat per-tile figures (512 B raw, 128 B BC1 - edge tiles
        // only make them conservative).
        var forceLossy = false
        if !isKeyframe {
            let bytesPerSecond =
                1_472.0 * 1_000_000.0 / Double(max(spacing, 1))
            let budgetBytes = Int(bytesPerSecond / Self.degradeTargetFps)
            let rawEstimate = dirty.count * 512
            let bc1Estimate = dirty.count * 128
            // Rung (a): lossless would blow the budget - let BC1 win busy
            // runs regardless of variance. Only meaningful under .auto;
            // .losslessOnly is the user forbidding this trade.
            forceLossy = policy == .auto && rawEstimate > budgetBytes
            // Rung (c): even all-BC1 blows the budget (or, under
            // .losslessOnly, lossless does and no codec relief exists) -
            // halve the frame rate rather than flood the receive queue.
            let floorEstimate =
                policy == .losslessOnly ? rawEstimate : bc1Estimate
            skipNextTileFrame = floorEstimate > budgetBytes
        }

        let encodeStart = DispatchTime.now().uptimeNanoseconds
        let packets = TilePacker.packets(
            frameId: id, dirtyTiles: dirty, pixels: pixels,
            geometry: tiles, landscape: landscape,
            policy: policy, forceLossy: forceLossy)
        tileStatEncodeNs &+= DispatchTime.now().uptimeNanoseconds &- encodeStart

        let sendStart = DispatchTime.now().uptimeNanoseconds
        // Same per-datagram pacing as the band path: the panel's receive
        // ceiling is datagrams per second, whatever they carry.
        let sleepNs = sendPaced(packets, spacing: spacing, on: conn)
        tileStatSendNs &+= DispatchTime.now().uptimeNanoseconds &- sendStart
        tileStatSleepNs &+= sleepNs
        tileStatFrames += 1
        tileStatTiles += dirty.count
        tileStatPackets += packets.count
        reportTileStatsIfDue(tiles: tiles)
        bandsSent &+= UInt64(dirty.count)
        framesSent &+= 1
        lastSentFrame = pixels
        lastSentLandscape = landscape
        lock.lock()
        _currentLandscape = landscape
        lock.unlock()
        lastSendAt = Date()
    }

    /// Send datagrams at the target spacing and return the nanoseconds spent
    /// asleep (so callers can report pacing separately from work).
    ///
    /// The deadline persists across calls, so the datagram rate is honoured
    /// across frame boundaries too, not merely within one frame - the panel's
    /// ceiling is datagrams per second whatever frame they belong to. An idle
    /// gap resets it rather than letting a stale deadline authorize an
    /// unbounded burst on the next frame.
    private func sendPaced(
        _ packets: [Data], spacing: UInt32, on conn: NWConnection
    ) -> UInt64 {
        guard !packets.isEmpty else { return 0 }
        let spacingNs = UInt64(spacing) * 1_000
        let start = DispatchTime.now().uptimeNanoseconds
        if pacingDeadline < start { pacingDeadline = start }
        var slept: UInt64 = 0
        for (index, packet) in packets.enumerated() {
            conn.send(
                content: packet,
                completion: .contentProcessed { [weak self] error in
                    if error != nil {
                        self?.sendErrors &+= 1
                    }
                })
            guard spacingNs > 0 else { continue }
            pacingDeadline &+= spacingNs
            // Pause on burst boundaries only. The tail of a frame does not
            // sleep: its debt rides on `pacingDeadline` into the next call,
            // which is what keeps the rate honest without idling here.
            guard (index + 1) % Self.pacingBurstPackets == 0 else { continue }
            let now = DispatchTime.now().uptimeNanoseconds
            guard pacingDeadline > now else { continue }
            let micros = UInt32(
                min((pacingDeadline - now) / 1_000,
                    UInt64(Self.pacingMaxSleepMicros)))
            if micros > 0 {
                usleep(micros)
                slept &+= DispatchTime.now().uptimeNanoseconds &- now
            }
        }
        return slept
    }

    /// Report where the tile send path's time actually goes, every
    /// `tileStatInterval` of streaming. `sleep` is the pacing usleep and is a
    /// SUBSET of `send`, broken out because it is deliberate delay rather
    /// than work: if it dominates, the pacing controller is the ceiling, not
    /// the encoder. sendQueue-only, like the counters it reads.
    private func reportTileStatsIfDue(tiles: TileGeometry) {
        let now = Date()
        guard now.timeIntervalSince(tileStatAt) >= tileStatInterval else { return }
        defer {
            tileStatAt = now
            tileStatFrames = 0
            tileStatTiles = 0
            tileStatPackets = 0
            tileStatDiffNs = 0
            tileStatEncodeNs = 0
            tileStatSendNs = 0
            tileStatSleepNs = 0
        }
        guard tileStatFrames > 0, tileStatAt != .distantPast else { return }
        let frames = Double(tileStatFrames)
        func ms(_ ns: UInt64) -> Double { Double(ns) / 1_000_000 / frames }
        let dirtyPercent = Double(tileStatTiles) / frames
            / Double(max(tiles.tileCount, 1)) * 100
        print(String(
            format: "tile: %.1f frames/s, %.0f%% dirty, %.1f pkt/frame | "
                + "per frame: diff %.2fms encode %.2fms send %.2fms "
                + "(pacing %.2fms)",
            frames / now.timeIntervalSince(tileStatAt), dirtyPercent,
            Double(tileStatPackets) / frames, ms(tileStatDiffNs),
            ms(tileStatEncodeNs), ms(tileStatSendNs), ms(tileStatSleepNs)))
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
            self.prevTileFrame = nil  // and any lost tiles, same rule
            self.send(frame: frame, landscape: self.lastSentLandscape)
        }
        timer.resume()
        refreshTimer = timer
    }
}
