import Foundation

/// Builders for the firmware's USB serial config commands. Everything is
/// base64-encoded, which keeps spaces, emoji, and any other bytes safe in a
/// space-delimited line.
public enum ConfigCommands {

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

    public static func setBrightnessLevel(_ level: Int) -> String? {
        guard DeviceProtocol.brightnessLevelRange.contains(level) else { return nil }
        return "CFGBRIGHT \(level)"
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
