import Foundation

/// Builders for the firmware's USB serial config commands. Everything is
/// base64-encoded, which keeps spaces, emoji, and any other bytes safe in a
/// space-delimited line.
public enum ConfigCommands {

    /// What to do with the WiFi password when saving credentials.
    public enum PasswordChange: Equatable {
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

    /// Decode a `key64=` field out of a CFGINFO reply line.
    public static func decodeField(_ key: String, from line: String) -> String? {
        guard let range = line.range(of: key) else { return nil }
        let b64 = String(line[range.upperBound...].prefix(while: { $0 != " " }))
        guard let data = Data(base64Encoded: b64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
