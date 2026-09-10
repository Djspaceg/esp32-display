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
    var usbPort: String?
    /// Stable identity of the manually selected USB device. Unlike `usbPort`,
    /// this survives the board resetting under a different macOS device node.
    var usbHardwareID: String?
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
    /// Firmware release family from mDNS (`c6`, `s3`, or `p4`).
    /// Discovery-scoped and deliberately excluded from `PersistedPanel`.
    var target: String?
    /// Runtime physical profile and partition evidence used with family/chip to
    /// select embedded firmware. Both are discovery-scoped.
    var profile: String?
    var partition: String?
    /// What this panel says its screen is, from its `res` TXT record, or nil when
    /// it did not say or said something `PanelGeometry.isStreamable` refused.
    ///
    /// nil is a real answer and the region path treats it as one: it means fall
    /// back to the compiled-in 172x320 rather than guess. Discovery-scoped and not
    /// persisted, for the same reason as `chip` - the region rectangle IS
    /// persisted, so a geometry remembered from a previous run could reshape a
    /// user's framing before the panel that justified it had said anything.
    var geometry: PanelGeometry?
    /// The network this panel actually reported joining, read over USB with
    /// CFGSHOW. nil until asked, and never learned any other way: EINF's
    /// network telemetry carries a `wifiConnected` flag but never the SSID
    /// string itself (see the comment on `deviceproto` field additions for
    /// why - a fixed-length parser on the sender side would reject the
    /// packet outright rather than degrade). Discovery-scoped and not
    /// persisted, for the same reason as `chip`/`geometry`: it is a fact
    /// about what the device is doing right now, and remembering a stale
    /// answer from a previous run would misrepresent it.
    var currentSSID: String?
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
    /// What the user chose this panel should show. Persisted, so a source picked
    /// once is still in effect after a restart.
    var source: PanelSource = .automatic
    /// What the session is actually capturing right now, which can differ from
    /// `source` while a display is being resolved or a window is missing.
    var sourceDescription = "Automatic"
    /// Lines to show on the panel's own status card while no sender is driving
    /// it. Persisted, and pushed to the device whenever it reports in.
    var idleText = ""
    /// Which gesture bindings this panel uses. Persisted, so a preset chosen once
    /// still applies after a restart.
    var gesturePreset: GesturePreset = .standard
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

    func isOnline(asOf now: Date) -> Bool {
        guard let lastHeartbeatAt else { return false }
        return now.timeIntervalSince(lastHeartbeatAt) < 10
    }

    func deviceListStatus(asOf now: Date) -> DeviceListStatus {
        guard isOnline(asOf: now) else {
            return discovered ? .connecting : .offline
        }
        if paused { return .paused }
        return captureStatus.isStreaming ? .streaming : .connected
    }

    func deviceListSortValue(asOf now: Date) -> DeviceListSortValue {
        DeviceListSortValue(
            displayName: displayName,
            stableIdentifier: id,
            dateAdded: dateAdded,
            status: deviceListStatus(asOf: now))
    }

    var sidebarStatusText: String {
        sidebarStatusText(asOf: Date())
    }

    /// The complete status line shown under this panel's name in the sidebar.
    ///
    /// This projects the same five states used for status sorting, so the visible
    /// vocabulary cannot drift from the ordering policy.
    func sidebarStatusText(asOf now: Date) -> String {
        switch deviceListStatus(asOf: now) {
        case .streaming:
            return String(format: "Online • %.1f fps", displayFPS)
        case .connected:
            return "Online • Not mirroring"
        case .paused:
            return "Paused"
        case .connecting:
            return "Connecting"
        case .offline:
            return "Offline"
        }
    }

    var statusText: String {
        if isOnline { return paused ? "Paused" : "Online" }
        if discovered { return "Connecting"
        }
        return "Offline"
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
