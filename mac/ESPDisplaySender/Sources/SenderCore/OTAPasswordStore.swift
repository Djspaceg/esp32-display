import Foundation
import Security

/// Whether a password is one the panel would accept, decided the same way the
/// panel decides it.
///
/// A pure mirror of `otapolicy::verifyPassword` in
/// `firmware/display_stream/ota_policy.h`, and mirrored rather than invented:
/// bounds guessed here would either refuse a password that works or offer one the
/// panel silently will not take. What this side cannot see is the base64 step -
/// `tools/espdisp.py set-password` owns that - so only the two judgements that
/// apply to the password itself are here.
enum OTAPasswordPolicy {
    /// 8 bytes. The security-relevant bound: there is no lockout on the panel, a
    /// push can be retried as fast as it will answer, and a successful guess is a
    /// firmware write.
    static let minimumBytes = 8
    /// 64 bytes. ArduinoOTA's practical limit, and what the sketch sizes its
    /// decode buffer for.
    static let maximumBytes = 64

    enum Verdict: Equatable {
        case accept
        case tooShort(bytes: Int)
        case tooLong(bytes: Int)
        /// A 0x00 byte. Refused for the reason ota_policy.h gives at length:
        /// every layer under the panel's OTA handles the password as a C string,
        /// so the stored secret would be cut at that byte and the length the
        /// panel checked would stop describing it.
        case embeddedNul

        var isAcceptable: Bool { self == .accept }
    }

    /// Judge a password.
    ///
    /// BYTES, NOT CHARACTERS, and that is the distinction to keep: `count` on a
    /// Swift String counts grapheme clusters, so "pässwörd" is 8 of those and 10
    /// UTF-8 bytes - and 10 is the number the panel measures, because base64 of
    /// the UTF-8 is what reaches it. Judging characters would refuse a password
    /// the panel accepts. `check_password_policy` in tools/espdisp.py draws the
    /// same distinction, for the same reason.
    static func judge(_ password: String) -> Verdict {
        let bytes = Array(password.utf8)
        // Checked before the bounds so the answer names the disqualifying
        // property rather than a length that was never going to be the stored
        // length - the same ordering ota_policy.h uses.
        if bytes.contains(0) { return .embeddedNul }
        if bytes.count < minimumBytes { return .tooShort(bytes: bytes.count) }
        if bytes.count > maximumBytes { return .tooLong(bytes: bytes.count) }
        return .accept
    }

    /// What to tell the user, in the terms the CLI uses, so a password refused
    /// here and a password refused by `set-password` read the same way.
    static func explain(_ verdict: Verdict) -> String? {
        switch verdict {
        case .accept:
            return nil
        case .tooShort(let bytes):
            return "The panel needs at least \(minimumBytes) bytes; this is "
                + "\(bytes)."
        case .tooLong(let bytes):
            return "The panel takes at most \(maximumBytes) bytes; this is "
                + "\(bytes)."
        case .embeddedNul:
            return "The panel cannot store a password containing a zero byte."
        }
    }
}

/// Where a panel's OTA password is kept between pushes.
///
/// A protocol with an injectable implementation for one specific reason: `swift
/// test` runs unsigned test binaries, and an unsigned binary touching the login
/// keychain either prompts or writes items that outlive the test run. No test may
/// reach the real keychain, so nothing in this app may reach it through a
/// hardcoded call.
protocol OTAPasswordStoring: AnyObject {
    /// The remembered password for a panel, or nil if none is stored.
    func password(forHardwareID hardwareID: String) -> String?
    /// Remember a password, replacing any previous one for the same panel.
    func store(_ password: String, forHardwareID hardwareID: String) throws
    /// Forget it.
    func remove(forHardwareID hardwareID: String) throws
}

/// The real store: one generic-password item per panel in the login keychain.
///
/// KEYED BY HARDWARE ID, not by service name. The hardware ID is the 6-byte
/// deviceID from EINF, which survives a rename; the Bonjour service name does
/// not, and a rename is a normal thing to do (`tools/espdisp.py` renames, and so
/// does the manager window). Keying on the name would silently lose the password
/// the first time someone renamed a panel, at which point the next update would
/// ask for it again with no indication why.
///
/// The password does NOT go in `SenderSettings` or `PanelPersistence`. Both are
/// plain files - UserDefaults and a JSON record - and neither is a place for a
/// secret that grants a firmware write on the LAN.
final class KeychainOTAPasswordStore: OTAPasswordStoring {
    /// One service for the whole app, so every item is visible together in
    /// Keychain Access under a name that says what it is for.
    static let service = "com.espdisplay.sender.ota"

    enum Failure: Error, LocalizedError, Equatable {
        case keychain(status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String?
                return "The Keychain refused to store the password "
                    + "(\(detail ?? "OSStatus \(status)"))."
            }
        }
    }

    func password(forHardwareID hardwareID: String) -> String? {
        var query = Self.baseQuery(hardwareID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func store(_ password: String, forHardwareID hardwareID: String) throws {
        let data = Data(password.utf8)
        let query = Self.baseQuery(hardwareID)
        // Update in place when an item is already there. Adding over an existing
        // item returns errSecDuplicateItem rather than replacing it, so a changed
        // password would appear to save and then not be the one used.
        let update = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw Failure.keychain(status: updated)
        }
        var insert = query
        insert[kSecValueData as String] = data
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure.keychain(status: added) }
    }

    func remove(forHardwareID hardwareID: String) throws {
        let status = SecItemDelete(Self.baseQuery(hardwareID) as CFDictionary)
        // Already gone is the outcome the caller asked for.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.keychain(status: status)
        }
    }

    private static func baseQuery(_ hardwareID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hardwareID,
        ]
    }
}

/// A store that keeps passwords in memory for the life of the process.
///
/// Used by tests and by the SwiftUI previews, both of which run unsigned and
/// must not touch the login keychain. Lives here rather than in the test target
/// so the preview initialiser can use it too - a preview that prompted for
/// keychain access would be unusable in Xcode's canvas.
final class InMemoryOTAPasswordStore: OTAPasswordStoring {
    private var passwords: [String: String]
    /// Set to make every write fail, so the UI's error path is reachable in a
    /// test without a keychain to break.
    var writesFail = false

    init(_ passwords: [String: String] = [:]) {
        self.passwords = passwords
    }

    func password(forHardwareID hardwareID: String) -> String? {
        passwords[hardwareID]
    }

    func store(_ password: String, forHardwareID hardwareID: String) throws {
        if writesFail {
            throw KeychainOTAPasswordStore.Failure.keychain(status: errSecIO)
        }
        passwords[hardwareID] = password
    }

    func remove(forHardwareID hardwareID: String) throws {
        if writesFail {
            throw KeychainOTAPasswordStore.Failure.keychain(status: errSecIO)
        }
        passwords[hardwareID] = nil
    }
}
