import Foundation
import SenderProtocol

/// The live view of a panel: persisted identity merged with whatever the
/// device has reported during this run. Intentionally not `Codable` — see
/// `PersistedPanel` for the subset that reaches disk.
struct PanelSnapshot: Identifiable, Equatable {
    var id: String { serviceName }

    var serviceName: String
    var displayName: String
    /// When this display record was created on this Mac. Unlike `lastSeen`, this
    /// never changes when discovery drops out or the panel returns. The existing
    /// ISO-8601 store writes whole seconds, so creation uses the same precision
    /// and a save/reload cannot alter ordering.
    var dateAdded: Date = Date(
        timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    var hardwareID: String?
    var address: String?
    /// The hardware ID this record's board reported over USB. A record is
    /// paired with a port only by the ID a board there reports, never by the
    /// port's path: the path is where the board happens to be plugged in.
    var usbHardwareID: String?
    /// The USB serial numbers macOS reports for the devices this board's
    /// console has answered behind - the board's own USB identity, not a
    /// port. Learned only where CFGSHOW answered with this record's ID, so a
    /// silent board can be paired on any path from the IORegistry alone.
    var usbSerialNumbers: [String] = []
    var discovered = false
    var lastSeen: Date?
    var lastHeartbeatAt: Date?
    var rssi: Int?
    var displayFPS = 0.0
    var framesSent: UInt64 = 0
    var sendErrors: UInt64 = 0
    var diffPercent = 0.0
    var framesShown: UInt32 = 0
    var framesDropped: UInt32 = 0
    var freeHeap: UInt32 = 0
    var spacingMicros: UInt32 = 0
    var firmwareVersion: String?
    /// Which build is running, from mDNS `src` or CFGSHOW `src=`, and the
    /// version it was reported alongside. Read through `currentFirmwareSource`,
    /// which only answers while that version is still the one running: the
    /// build and the version arrive by different routes (mDNS or USB, and
    /// EINF), in either order, so a build is tied to its version rather than
    /// cleared by whichever arrives second. Discovery-scoped like `chip`.
    private(set) var firmwareSource: FirmwareSourceIdentity?
    private(set) var firmwareSourceVersion: String?

    /// The reported build, when it belongs to the version running now.
    var currentFirmwareSource: FirmwareSourceIdentity? {
        guard let firmwareSourceVersion, firmwareSourceVersion == firmwareVersion
        else { return nil }
        return firmwareSource
    }

    /// Record what one report said: `source` nil means that firmware does not
    /// name its build, which is an answer too.
    mutating func noteFirmwareSource(
        _ source: FirmwareSourceIdentity?, reportedWith version: String
    ) {
        firmwareSource = source
        firmwareSourceVersion = version
    }
    /// Which chip this panel is, from its `chip` mDNS TXT record: `esp32c6`,
    /// `esp32s3`, or `unknown` from a build that could not name its own. nil
    /// means the panel never sent the record, i.e. firmware older than it.
    ///
    /// Discovery-scoped and deliberately not persisted: it is a fact about the
    /// hardware, but the only thing that will use it is matching a firmware
    /// bundle's images against this panel, and doing that against a token
    /// remembered from a previous run would risk pushing an image chosen from
    /// stale information. A panel has to be discovered to be pushed to anyway.
    var chip: String?
    /// Firmware release family from mDNS (`c3`, `c6`, `s3`, or `p4`).
    /// Discovery-scoped and deliberately excluded from `PersistedPanel`.
    var target: String?
    /// Runtime physical profile and partition evidence used with family/chip to
    /// select embedded firmware. Both are discovery-scoped.
    var profile: String? {
        didSet {
            if let profile, GeneratedBoardCatalog.encoderProfiles.contains(profile) {
                knobReported = true
            }
        }
    }
    /// Whether a reported board profile is one with no screen (the bare XIAO
    /// ESP32-S3), from the board descriptors. An unknown or absent profile
    /// is not taken to have none.
    static func profileHasNoScreen(_ profile: String?) -> Bool {
        guard let profile else { return false }
        return GeneratedBoardCatalog.headlessProfiles.contains(profile)
    }

    /// The board has no screen: nothing to stream to, capture for, rotate or
    /// dim. It is still flashed, set up for WiFi, restarted and updated.
    var hasNoScreen: Bool { reportedNoScreen || Self.profileHasNoScreen(profile) }
    /// The firmware announced `res=0x0`: no screen, whatever its profile says
    /// (an unidentified board reports `auto`; a board whose panel did not come
    /// up reports its own). Discovery-scoped like `geometry`.
    var reportedNoScreen = false

    /// The board has shown it has a knob this launch: by reporting a knob
    /// profile, or by sending a knob gesture. Kept when `profile` is cleared
    /// with discovery, because the knob keeps working over the session.
    var knobReported = false
    var partition: String?
    /// The panel's native screen size, from its `res` TXT record or from a known
    /// USB `board` identity. nil means neither source established a usable size.
    ///
    /// nil is a real answer and the region path treats it as one: it does not
    /// guess. Discovery-scoped and not persisted, for the same reason as `chip`
    /// - the region rectangle IS
    /// persisted, so a geometry remembered from a previous run could reshape a
    /// user's framing before the panel that justified it had said anything.
    var geometry: PanelGeometry?
    /// The network this panel reports it is set to join, read over USB with
    /// CFGSHOW ("" when none is set); nil until asked. The network it has
    /// joined, announced over WiFi, is `announcedSSID`. EINF carries neither:
    /// a fixed-length parser on the sender side would reject a longer packet
    /// outright (see the comment on `deviceproto` field additions).
    /// Discovery-scoped and not persisted, for the same reason as
    /// `chip`/`geometry`: it is a fact about what the device is doing right
    /// now, and remembering a stale answer from a previous run would
    /// misrepresent it.
    var currentSSID: String?
    /// CFGSHOW's `connected=` beside it: whether the board has actually joined
    /// `currentSSID`. nil until asked, discovery-scoped like `currentSSID`.
    var networkConnected: Bool?
    /// When that USB report arrived, so a later silence over WiFi can outrank it.
    var networkReportedAt: Date?
    /// The network the panel announces it has joined, from its mDNS `ssid`
    /// record. Kept apart from `currentSSID` (USB) because a cached
    /// announcement can outlive a change made over USB, and cleared with the
    /// other discovery records when the service goes away.
    var announcedSSID: String?
    /// When `announcedSSID` last changed. Not refreshed by a browse result that
    /// repeats it, which is how a stale cached record keeps coming back.
    var announcedAt: Date?
    /// When the device last really answered over WiFi. Not `lastHeartbeatAt`,
    /// which every reconnect refreshes whether or not the device replies.
    var lastReplyAt: Date?
    var frameProtocolVersion: Int?
    var controlProtocolVersion: Int?
    var capabilitiesRaw: UInt32 = 0
    var uptimeSeconds: UInt32 = 0
    /// Last battery report, on a panel that sends them. Both touch boards can
    /// report a level: S3 uses its AXP2101 gauge, while C6 estimates from its
    /// GPIO0 divider and necessarily reports an unknown charge state.
    var battery: DeviceProtocol.BatteryStatus?
    /// When that report arrived, so it can be aged out. A panel whose PMU dies
    /// keeps heartbeating and simply stops sending EBAT, so without this the last
    /// percentage would stand for as long as the app ran.
    var batteryAt: Date?
    var brightness: Int = 0
    var brightnessHigh = true
    var flipped = false
    /// Mounting rotation in clockwise quarter turns, reported by the device
    /// (EINF/EACK flags bits 5-6). Only meaningful on a panel advertising
    /// `.rotate`; older firmware reports its 180 through `flipped` alone and
    /// leaves this 0, which is why the UI keeps the flip toggle there.
    var rotation = 0
    var sleeping = false
    var idle = false
    /// The user's standing "display off" instruction, reported by the device
    /// (EINF/EACK flags bit 7). Independent of `sleeping`/`idle`, which the
    /// device clears on its own; this stays true until the user turns the
    /// panel back on. See `DeviceProtocol.Capabilities.power`.
    var manuallyOff = false
    var paused = false
    /// The session is held, not sending, until the board's EINF proves it is
    /// this record's hardware (`PanelManager.register`). Reported apart from
    /// `paused`, which is only ever the user's choice.
    var awaitingIdentity = false
    /// What the user chose this panel should show. Persisted, so a source picked
    /// once is still in effect after a restart.
    var source: PanelSource = .automatic
    /// What the session is actually capturing right now, which can differ from
    /// `source` while a display is being resolved or a window is missing.
    var sourceDescription = "Automatic"
    /// Lines to show on the panel's own status card while no sender is driving
    /// it. Persisted, and pushed to the device whenever it reports in. Blank
    /// means never set; read `screensaverTemplate` for what is in effect.
    var idleText = ""
    /// The screensaver template in effect: the stored one, or the app's default
    /// for a panel that was never given one.
    var screensaverTemplate: String { ScreensaverTemplate.effective(idleText) }
    /// Which gesture bindings this panel uses. Persisted, so a preset chosen once
    /// still applies after a restart.
    var gesturePreset: GesturePreset = .standard
    /// The user's own assignments, each overriding what the preset gives that
    /// input. Persisted; choosing a preset clears them.
    var inputAssignments: [DeviceProtocol.TouchGesture: InputFunction] = [:]
    /// What the board last said about its inputs (EINP), on firmware that
    /// stores a map. Discovery-scoped: never persisted.
    var inputReport: DeviceProtocol.InputReport?
    /// The display speaker's volume, 0...1, applied by scaling the samples
    /// this Mac sends. 1 is the loudest the display plays; a display nobody
    /// has set starts at `PanelSpeakerVolume.default`.
    var speakerVolume: Double = PanelSpeakerVolume.default
    /// Orientation of the last frame sent to this panel. Reported by the session,
    /// and needed to read a swipe: which axis is the panel's long one depends on
    /// it, and so does what the settings window says a gesture will do.
    var landscape = false
    /// Why this panel is not usable, when the reason is something the user
    /// would otherwise only find in the log. Cleared as soon as the device
    /// reports in again.
    var lastError: String?
    /// What the capture side is doing. Held separately from `lastError`, which
    /// every device heartbeat clears - a capture problem outlives the
    /// heartbeats, because the panel keeps answering perfectly well while
    /// receiving nothing.
    var captureStatus: CaptureStatus = .waiting("Starting up…")
    /// When a frame was last captured and sent for this panel.
    var lastFrameAt: Date?
    /// Live audio state and diagnostics. Discovery-only and never persisted.
    var audioStatus: PanelAudioSnapshot?

    var capabilities: DeviceProtocol.Capabilities {
        DeviceProtocol.Capabilities(rawValue: capabilitiesRaw)
    }

    /// How long since a frame was last captured and sent, or nil if none ever
    /// has been.
    ///
    /// Deliberately not treated as an error signal on its own:
    /// ScreenCaptureKit delivers nothing at all while the source is static, so
    /// a large age is normal for an unchanging window. `captureStatus` is the
    /// authority on whether something is wrong; this is the supporting detail.
    var frameAge: TimeInterval? {
        lastFrameAt.map { Date().timeIntervalSince($0) }
    }

    /// The frame age as it reads in the preview row.
    var frameAgeDescription: String {
        guard let age = frameAge else { return "No frames yet" }
        if age < 1 { return "Live" }
        if age < 60 { return "Last frame \(Int(age))s ago" }
        let minutes = Int(age / 60)
        return "Last frame \(minutes)m ago"
    }

    var isOnline: Bool {
        isOnline(asOf: Date())
    }

    /// The "Connected WiFi" row for this panel, from the newest evidence.
    ///
    /// A reply over WiFi within the online window is the board on WiFi, named
    /// by its announcement (the network joined) or else by USB. Replies that
    /// stopped after the last USB report mean the Mac no longer hears it - not
    /// that it left its network, which only the board can say: a board can
    /// stay joined while nothing it sends reaches the Mac. Otherwise the USB
    /// report stands: it is newer than anything heard over WiFi, and a cached
    /// announcement from before a change over USB must not outrank it.
    func boardNetworkDescription(asOf now: Date) -> String {
        let usbName = currentSSID.flatMap { $0.isEmpty ? nil : $0 }
        if let lastReplyAt, now.timeIntervalSince(lastReplyAt) < 10 {
            let usbIsNewer = networkReportedAt.map { reported in
                announcedAt.map { reported > $0 } ?? true
            } ?? false
            if let usbName, usbIsNewer || announcedSSID == nil { return usbName }
            return announcedSSID ?? "Connected (name not reported)"
        }
        if let lastReplyAt, networkReportedAt.map({ lastReplyAt > $0 }) ?? true {
            if let usbName { return "Not answering (set to \"\(usbName)\")" }
            if let announcedSSID { return "Not answering (last on \"\(announcedSSID)\")" }
            return "Not answering"
        }
        return PanelManager.boardNetworkDescription(
            reportedSSID: currentSSID, connected: networkConnected)
    }

    /// The network name behind `boardNetworkDescription`, by the same
    /// evidence and precedence, for the WiFi pop-up's selection. nil when the
    /// board has named none.
    func boardSSID(asOf now: Date) -> String? {
        let usbName = currentSSID.flatMap { $0.isEmpty ? nil : $0 }
        if let lastReplyAt, now.timeIntervalSince(lastReplyAt) < 10 {
            let usbIsNewer = networkReportedAt.map { reported in
                announcedAt.map { reported > $0 } ?? true
            } ?? false
            if let usbName, usbIsNewer || announcedSSID == nil { return usbName }
            return announcedSSID
        }
        if let lastReplyAt, networkReportedAt.map({ lastReplyAt > $0 }) ?? true {
            return usbName ?? announcedSSID
        }
        return usbName
    }

    func isOnline(asOf now: Date) -> Bool {
        guard let lastHeartbeatAt else { return false }
        return now.timeIntervalSince(lastHeartbeatAt) < 10
    }

    func deviceListStatus(
        asOf now: Date,
        connectedViaUSB: Bool
    ) -> DeviceListStatus {
        guard isOnline(asOf: now) else {
            if discovered { return .connecting }
            if connectedViaUSB { return .connectedViaUSB }
            return .offline
        }
        if awaitingIdentity { return .connecting }
        if paused { return .paused }
        return captureStatus.isStreaming ? .streaming : .connected
    }

    func deviceListSortValue(
        asOf now: Date,
        connectedViaUSB: Bool
    ) -> DeviceListSortValue {
        DeviceListSortValue(
            displayName: displayName,
            stableIdentifier: id,
            dateAdded: dateAdded,
            status: deviceListStatus(
                asOf: now,
                connectedViaUSB: connectedViaUSB))
    }

    /// The complete user-facing status line for this panel.
    ///
    /// This projects the same six states used for status sorting, so the visible
    /// vocabulary cannot drift from the ordering policy.
    func statusText(
        asOf now: Date,
        connectedViaUSB: Bool
    ) -> String {
        switch deviceListStatus(
            asOf: now,
            connectedViaUSB: connectedViaUSB
        ) {
        case .streaming:
            return String(format: "Online • %.1f fps", displayFPS)
        case .connected:
            return "Online • Not mirroring"
        case .paused:
            return "Paused"
        case .connectedViaUSB:
            return "Connected via USB"
        case .connecting:
            return "Connecting"
        case .offline:
            return "Offline"
        }
    }

    var signalDescription: String {
        guard let rssi else { return "—" }
        return "\(signalWord) (\(rssi) dBm)"
    }

    /// Signal strength as a single word, for the `{signal}` screensaver token
    /// and as the basis of `signalDescription`, so the two cannot disagree.
    var signalWord: String {
        guard let rssi else { return "" }
        if rssi >= -55 { return "Excellent" }
        if rssi >= -65 { return "Good" }
        if rssi >= -75 { return "Fair" }
        return "Weak"
    }

    /// What this panel's screensaver tokens currently stand for.
    ///
    /// Unknown values are left empty rather than filled with a placeholder: an
    /// empty token drops its line, which is better than a panel reading
    /// "wifi —" across the room.
    var screensaverValues: ScreensaverTemplate.Values {
        ScreensaverTemplate.Values(
            name: displayName,
            address: address ?? "",
            signal: signalWord,
            rssi: rssi.map { "\($0) dBm" } ?? "",
            version: firmwareVersion ?? "",
            uptime: uptimeSeconds > 0 ? uptimeDescription : "")
    }

    /// The battery as one phrase for the manager.
    var batteryDescription: String { batteryDescription(asOf: Date()) }

    /// The battery as one phrase, as of a given moment.
    ///
    /// Four states, all of them different answers a user needs to tell apart. A
    /// panel advertising the capability but not having reported yet says so,
    /// rather than showing 0% - an unknown battery and a flat one must never read
    /// the same. "No battery" is a real answer too: the PMU reports whether a
    /// cell is attached, and a 1.75C running on USB alone genuinely has none.
    ///
    /// And a reading expires. EBAT arrives on the panel's own 10s timer and only
    /// when a sample succeeded, so a PMU that stops answering produces silence,
    /// not a correction - the panel goes on heartbeating and the row would
    /// otherwise show its last percentage indefinitely. Past
    /// `DeviceProtocol.batteryMaxAge` the row says the reading stopped instead of
    /// quoting it, which is the honest thing for a field whose only job is to
    /// tell the truth about the cell. The age is taken from `now` rather than
    /// read here so this is testable without waiting.
    func batteryDescription(asOf now: Date) -> String {
        guard let battery else { return "Waiting for a reading" }
        if let at = batteryAt,
           now.timeIntervalSince(at) > DeviceProtocol.batteryMaxAge {
            return "No recent reading"
        }
        guard battery.present else {
            return battery.externalPower ? "No battery (USB power)" : "No battery"
        }
        let level = battery.percent.map { "\($0)%" } ?? "Level unknown"
        switch battery.state {
        case .charging: return "\(level), charging"
        case .discharging: return "\(level), on battery"
        case .standby: return battery.externalPower ? "\(level), USB power" : level
        case .unknown: return level
        }
    }

    var uptimeDescription: String {
        guard uptimeSeconds > 0 else { return "—" }
        let days = uptimeSeconds / 86_400
        let hours = (uptimeSeconds % 86_400) / 3_600
        let minutes = (uptimeSeconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

extension String {
    /// Sentence-cases a phrase for use at the start of a title, without
    /// touching the rest of the words.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
