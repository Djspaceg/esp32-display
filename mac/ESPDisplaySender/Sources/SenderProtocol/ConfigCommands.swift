import Foundation

/// Builders for the firmware's USB serial config commands. Everything is
/// base64-encoded, which keeps spaces, emoji, and any other bytes safe in a
/// space-delimited line.
public enum ConfigCommands {
    public static let wifiPresetSlotRange = 1...10

    public struct WiFiPresetRoster: Equatable, Sendable {
        public var capacity: Int
        public var validSlots: Set<Int>
        public var activeSlot: Int?
        public var localSelectorAvailable: Bool

        public init(
            capacity: Int,
            validSlots: Set<Int>,
            activeSlot: Int?,
            localSelectorAvailable: Bool
        ) {
            self.capacity = capacity
            self.validSlots = validSlots
            self.activeSlot = activeSlot
            self.localSelectorAvailable = localSelectorAvailable
        }
    }

    public struct WiFiPresetSlot: Equatable, Sendable {
        public var slot: Int
        public var ssid: String
        public var hasPassword: Bool
        public var active: Bool

        public init(slot: Int, ssid: String, hasPassword: Bool, active: Bool) {
            self.slot = slot
            self.ssid = ssid
            self.hasPassword = hasPassword
            self.active = active
        }
    }

    /// What to do with the WiFi password when saving credentials.
    public enum PasswordChange: Equatable, Sendable {
        /// Leave the device's current password alone (blank field).
        case keepCurrent
        /// Join with no password at all.
        case openNetwork
        /// Set a new password.
        case set(String)
    }

    /// `CFGWIFI <b64 ssid> [<b64 pass>]`. Omitting the password argument
    /// tells the firmware to keep the password already in use - this is what
    /// makes a blank password field safe, instead of silently replacing a
    /// working password with an empty one.
    public static func setWifi(ssid: String, password: PasswordChange) -> String {
        let s = Data(ssid.utf8).base64EncodedString()
        switch password {
        case .keepCurrent:
            return "CFGWIFI \(s)"
        case .openNetwork:
            return "CFGWIFI \(s) "
        case .set(let value):
            return "CFGWIFI \(s) \(Data(value.utf8).base64EncodedString())"
        }
    }

    /// Store one complete credential in a device-side picker slot.
    public static func setWifiPreset(
        slot: Int, ssid: String, password: String
    ) -> String? {
        guard wifiPresetSlotRange.contains(slot),
              !ssid.isEmpty,
              ssid.utf8.count <= 32,
              password.utf8.count <= 64,
              !ssid.contains("\0"),
              !password.contains("\0")
        else { return nil }
        let encodedSSID = Data(ssid.utf8).base64EncodedString()
        let encodedPassword = password.isEmpty
            ? "-"
            : Data(password.utf8).base64EncodedString()
        return "CFGWIFISET \(slot) \(encodedSSID) \(encodedPassword)"
    }

    public static func clearWifiPreset(slot: Int) -> String? {
        guard wifiPresetSlotRange.contains(slot) else { return nil }
        return "CFGWIFICLEAR \(slot)"
    }

    public static func useWifiPreset(slot: Int) -> String? {
        guard wifiPresetSlotRange.contains(slot) else { return nil }
        return "CFGWIFIUSE \(slot)"
    }

    public static func showWifiPreset(slot: Int) -> String? {
        guard wifiPresetSlotRange.contains(slot) else { return nil }
        return "CFGWIFISHOW \(slot)"
    }

    public static let showWifiPresets = "CFGWIFISHOW"

    public static func wifiPresetRoster(from line: String) -> WiFiPresetRoster? {
        guard line.hasPrefix("CFGINFO wifi "),
              let capacityText = field("capacity=", from: line),
              let capacity = Int(capacityText),
              capacity == wifiPresetSlotRange.count,
              let validText = field("valid=", from: line),
              validText.hasPrefix("0x"),
              let validMask = Int(validText.dropFirst(2), radix: 16),
              validMask >= 0,
              validMask < (1 << capacity),
              let localText = field("local=", from: line),
              localText == "0" || localText == "1",
              let activeText = field("active=", from: line)
        else { return nil }

        let activeSlot: Int?
        if activeText == "direct" {
            activeSlot = nil
        } else if let parsed = Int(activeText), wifiPresetSlotRange.contains(parsed) {
            activeSlot = parsed
        } else {
            return nil
        }

        var validSlots = Set<Int>()
        for slot in wifiPresetSlotRange where validMask & (1 << (slot - 1)) != 0 {
            validSlots.insert(slot)
        }
        if let activeSlot, !validSlots.contains(activeSlot) { return nil }
        return WiFiPresetRoster(
            capacity: capacity,
            validSlots: validSlots,
            activeSlot: activeSlot,
            localSelectorAvailable: localText == "1")
    }

    public static func wifiPresetSlot(from line: String) -> WiFiPresetSlot? {
        guard line.hasPrefix("CFGINFO wifi "),
              let slotText = field("slot=", from: line),
              let slot = Int(slotText),
              wifiPresetSlotRange.contains(slot),
              field("valid=", from: line) == "1",
              let activeText = field("active=", from: line),
              activeText == "0" || activeText == "1",
              let passwordText = field("pass=", from: line),
              passwordText == "open" || passwordText == "set",
              let ssid = decodeField("ssid64=", from: line),
              !ssid.isEmpty,
              ssid.utf8.count <= 32,
              !ssid.contains("\0")
        else { return nil }
        return WiFiPresetSlot(
            slot: slot,
            ssid: ssid,
            hasPassword: passwordText == "set",
            active: activeText == "1")
    }

    public static func setName(_ name: String) -> String {
        "CFGNAME \(Data(name.utf8).base64EncodedString())"
    }

    public static func setPower(_ on: Bool) -> String {
        "CFGPOWER \(on ? 1 : 0)"
    }

    public static func setFlip(_ flipped: Bool) -> String {
        "CFGFLIP \(flipped ? 1 : 0)"
    }

    public static func setRotation(_ rotation: Int) -> String? {
        guard DeviceProtocol.rotationRange.contains(rotation) else { return nil }
        return "CFGROT \(rotation)"
    }

    public static func setAutomaticRotation(_ enabled: Bool) -> String {
        "CFGAUTOROT \(enabled ? 1 : 0)"
    }

    public static func setBrightnessLevel(_ level: Int) -> String? {
        guard DeviceProtocol.brightnessLevelRange.contains(level) else { return nil }
        return "CFGBRIGHT \(level)"
    }

    public static func setBrightnessLevels(
        low: Int, high: Int, idle: Int, survey: Int
    ) -> String? {
        let range = DeviceProtocol.brightnessLevelRange
        guard range.contains(low), range.contains(high),
              range.contains(idle), range.contains(survey),
              low < high
        else { return nil }
        return "CFGBRIGHTLEVELS \(low) \(high) \(idle) \(survey)"
    }

    /// `CFGOTAPW <b64 password>`: enable OTA with this password, replacing
    /// any password already stored. Mirrors `otapolicy::CLEAR_TOKEN`'s sibling
    /// path in display_stream.ino - the firmware classifies the literal
    /// argument "clear" before attempting any base64 decode, so this builder
    /// and `clearOTAPassword` are two distinct commands rather than one
    /// taking an optional password, matching that split at the call site.
    public static func setOTAPassword(_ password: String) -> String {
        "CFGOTAPW \(Data(password.utf8).base64EncodedString())"
    }

    /// `CFGOTAPW clear`: forget the stored password, which turns OTA back off.
    public static let clearOTAPassword = "CFGOTAPW clear"

    /// Read one space-delimited `key=value` field from a CFGINFO reply.
    public static func field(_ key: String, from line: String) -> String? {
        for token in line.split(separator: " ", omittingEmptySubsequences: true) {
            guard token.hasPrefix(key) else { continue }
            return String(token.dropFirst(key.count))
        }
        return nil
    }

    /// Read an appended field from the right. CFGSHOW keeps a human-readable
    /// `ssid=` field for compatibility, and SSIDs may contain text resembling
    /// `key=value`; the real appended protocol field must win.
    public static func lastField(_ key: String, from line: String) -> String? {
        for token in line.split(separator: " ", omittingEmptySubsequences: true).reversed() {
            guard token.hasPrefix(key) else { continue }
            return String(token.dropFirst(key.count))
        }
        return nil
    }

    /// Decode a `key64=` field out of a CFGINFO reply line.
    public static func decodeField(_ key: String, from line: String) -> String? {
        guard let value = field(key, from: line),
              let data = Data(base64Encoded: value)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Normalize a six-byte MAC to the EINF/persistence spelling.
    public static func canonicalHardwareID(_ value: String?) -> String? {
        guard let value else { return nil }
        let compact = value.lowercased().filter { $0 != ":" && $0 != "-" }
        guard compact.count == 12,
              compact.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) })
        else { return nil }
        return compact
    }

    /// The station-MAC identity emitted by current firmware's CFGSHOW.
    public static func hardwareID(from line: String) -> String? {
        canonicalHardwareID(field("id=", from: line))
    }
}
