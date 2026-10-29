import Foundation
import OSLog
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
            return "The device needs at least \(minimumBytes) bytes; this is "
                + "\(bytes)."
        case .tooLong(let bytes):
            return "The device takes at most \(maximumBytes) bytes; this is "
                + "\(bytes)."
        case .embeddedNul:
            return "The device cannot store a password containing a zero byte."
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

/// The protected Keychain database that holds the one combined credential
/// record. The login store is read only by the short, one-time transition from
/// the former file-backed item; normal app work uses Data Protection.
enum CredentialKeychainStore: String, Equatable, Sendable {
    case dataProtection
    case login
}

protocol GenericPasswordKeychain: AnyObject {
    func data(
        service: String, account: String, in store: CredentialKeychainStore
    ) throws -> Data?
    func write(
        data: Data, service: String, account: String, in store: CredentialKeychainStore
    ) throws
    func remove(
        service: String, account: String, in store: CredentialKeychainStore
    ) throws
}

/// The Security.framework implementation behind the credential vault.
final class SecurityGenericPasswordKeychain: GenericPasswordKeychain {
    private static let logger = Logger(
        subsystem: AppIdentity.bundleIdentifier, category: "keychain")
    private static let accessGroup = AppIdentity.keychainAccessGroup

    func data(
        service: String, account: String, in store: CredentialKeychainStore
    ) throws -> Data? {
        var query = Self.identity(service: service, account: account, store: store)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        Self.log(
            operation: "SecItemCopyMatching data", service: service, account: account,
            store: store, status: status)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainCredentialVault.Failure.keychain(status: status)
        }
        return data
    }

    func write(
        data: Data, service: String, account: String, in store: CredentialKeychainStore
    ) throws {
        let identity = Self.identity(service: service, account: account, store: store)
        let values = [kSecValueData as String: data]
        let updated = SecItemUpdate(identity as CFDictionary, values as CFDictionary)
        Self.log(
            operation: "SecItemUpdate", service: service, account: account,
            store: store, status: updated)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw KeychainCredentialVault.Failure.keychain(status: updated)
        }
        var item = identity
        item[kSecValueData as String] = data
        let added = SecItemAdd(item as CFDictionary, nil)
        Self.log(
            operation: "SecItemAdd", service: service, account: account,
            store: store, status: added)
        guard added == errSecSuccess else {
            throw KeychainCredentialVault.Failure.keychain(status: added)
        }
    }

    func remove(
        service: String, account: String, in store: CredentialKeychainStore
    ) throws {
        let status = SecItemDelete(
            Self.identity(service: service, account: account, store: store) as CFDictionary)
        Self.log(
            operation: "SecItemDelete", service: service, account: account,
            store: store, status: status)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialVault.Failure.keychain(status: status)
        }
    }

    private static func identity(
        service: String, account: String, store: CredentialKeychainStore
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if store == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static func log(
        operation: String, service: String, account: String,
        store: CredentialKeychainStore, status: OSStatus
    ) {
        logger.notice(
            "Keychain \(operation, privacy: .public) store \(store.rawValue, privacy: .public) service \(service, privacy: .public) account \(account, privacy: .private(mask: .hash)) OSStatus \(status, privacy: .public)")
    }
}

/// The versioned payload stored in the app's only WiFi/OTA credential item.
/// Passwords remain in the Keychain, never in settings or device records.
struct CredentialVaultPayload: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    var wifiPasswords: [String: String]
    var otaPasswords: [String: String]

    init(
        version: Int = currentVersion,
        wifiPasswords: [String: String] = [:],
        otaPasswords: [String: String] = [:]
    ) {
        self.version = version
        self.wifiPasswords = wifiPasswords
        self.otaPasswords = otaPasswords
    }
}

/// The shared credential vault for both saved WiFi and OTA passwords.
///
/// Normal reads and writes use the app's Data Protection Keychain entry. The
/// short login-keychain transition only moves the single combined item written
/// by the preceding release. It never searches for old per-password records.
final class KeychainCredentialVault: @unchecked Sendable {
    static let service = AppIdentity.credentialsService
    static let account = "credentials-v1"
    static let credentialStore = CredentialKeychainStore.dataProtection
    static let shared = KeychainCredentialVault(keychain: SecurityGenericPasswordKeychain())
    private static let logger = Logger(
        subsystem: AppIdentity.bundleIdentifier, category: "keychain")

    enum Failure: Error, LocalizedError, Equatable {
        case keychain(status: OSStatus)
        case invalidPayload
        case transitionVerificationFailed

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String?
                switch status {
                case errSecInteractionNotAllowed:
                    return "macOS did not allow ESPDisplaySender to read or write "
                        + "this login Keychain item (User interaction is not allowed; "
                        + "OSStatus \(status))."
                case errSecAuthFailed:
                    return "macOS rejected the older saved password's access rule "
                        + "(Authentication failed; OSStatus \(status))."
                case errSecParam:
                    return "macOS rejected the Keychain item attributes "
                        + "(Invalid parameter; OSStatus \(status))."
                default:
                    return "The Keychain refused the credential update "
                        + "(\(detail ?? "OSStatus \(status)"))."
                }
            case .invalidPayload:
                return "The shared WiFi and OTA password record is not valid."
            case .transitionVerificationFailed:
                return "The saved WiFi and OTA password record could not be verified "
                    + "after moving it to macOS's protected app Keychain."
            }
        }
    }

    private let keychain: GenericPasswordKeychain
    private let lock = NSLock()
    private var cachedPayload: CredentialVaultPayload?
    private var loginTransitionAttempted = false
    private var loginTransitionFailure: Error?

    init(keychain: GenericPasswordKeychain) {
        self.keychain = keychain
    }

    /// Reads the one app-owned record once at process startup. When the
    /// immediately previous release left it in the login Keychain, `payload`
    /// moves only that item into Data Protection before returning.
    func prepareForLaunch() throws {
        try lock.withLock {
            _ = try payload()
            if let loginTransitionFailure { throw loginTransitionFailure }
        }
    }

    func savedNetworkNames() throws -> [String] {
        try lock.withLock {
            return try payload().wifiPasswords.keys.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        }
    }

    func wifiCredential(for ssid: String) throws -> SavedWiFiCredential? {
        try lock.withLock {
            guard let password = try payload().wifiPasswords[ssid] else { return nil }
            return SavedWiFiCredential(ssid: ssid, password: password)
        }
    }

    func saveWiFiCredential(_ credential: SavedWiFiCredential) throws {
        try lock.withLock {
            var next = try writablePayload()
            next.wifiPasswords[credential.ssid] = credential.password
            try writeAndVerify(next)
            cachedPayload = next
        }
    }

    func removeWiFiCredential(ssid: String) throws {
        try lock.withLock {
            var next = try writablePayload()
            guard next.wifiPasswords.removeValue(forKey: ssid) != nil else { return }
            try writeAndVerify(next)
            cachedPayload = next
        }
    }

    func otaPassword(for hardwareID: String) throws -> String? {
        try lock.withLock {
            try payload().otaPasswords[hardwareID]
        }
    }

    func storeOTAPassword(_ password: String, for hardwareID: String) throws {
        try lock.withLock {
            var next = try writablePayload()
            next.otaPasswords[hardwareID] = password
            try writeAndVerify(next)
            cachedPayload = next
        }
    }

    func removeOTAPassword(for hardwareID: String) throws {
        try lock.withLock {
            var next = try writablePayload()
            guard next.otaPasswords.removeValue(forKey: hardwareID) != nil else { return }
            try writeAndVerify(next)
            cachedPayload = next
        }
    }

    private func payload() throws -> CredentialVaultPayload {
        if let cachedPayload { return cachedPayload }
        if let loginTransitionFailure { throw loginTransitionFailure }
        if let data = try keychain.data(
            service: Self.service, account: Self.account, in: Self.credentialStore)
        {
            let current = try decode(data)
            cachedPayload = current
            return current
        }
        if Self.credentialStore == .dataProtection, !loginTransitionAttempted {
            loginTransitionAttempted = true
            do {
                guard let data = try keychain.data(
                    service: Self.service, account: Self.account, in: .login)
                else {
                    let empty = CredentialVaultPayload()
                    cachedPayload = empty
                    return empty
                }
                let current = try decode(data)
                do {
                    try moveLoginItemToDataProtection(data, expected: current)
                } catch {
                    // The one source item is still intact. Its names and
                    // passwords stay available for reads this launch, but a
                    // later edit must not create a second divergent record.
                    // `prepareForLaunch` surfaces the move failure once.
                    cachedPayload = current
                    loginTransitionFailure = error
                    Self.logger.error(
                        "Credential transition retained the login record after failure: \(error.localizedDescription, privacy: .public)")
                    return current
                }
                cachedPayload = current
                return current
            } catch {
                loginTransitionFailure = error
                throw error
            }
        }
        let empty = CredentialVaultPayload()
        cachedPayload = empty
        return empty
    }

    private func writablePayload() throws -> CredentialVaultPayload {
        if let loginTransitionFailure { throw loginTransitionFailure }
        return try payload()
    }

    private func writeAndVerify(_ payload: CredentialVaultPayload) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(payload)
        } catch {
            throw Failure.invalidPayload
        }
        try keychain.write(
            data: data, service: Self.service, account: Self.account,
            in: Self.credentialStore)
        guard let stored = try keychain.data(
            service: Self.service, account: Self.account, in: Self.credentialStore),
              try decode(stored) == payload
        else {
            throw Failure.transitionVerificationFailed
        }
    }

    private func decode(_ data: Data) throws -> CredentialVaultPayload {
        guard let payload = try? JSONDecoder().decode(CredentialVaultPayload.self, from: data),
              payload.version == CredentialVaultPayload.currentVersion
        else {
            throw Failure.invalidPayload
        }
        return payload
    }

    /// The only transitional code retained after legacy imports were removed.
    /// It reads one prior combined item, writes and verifies its Data
    /// Protection replacement, then removes the prior item. A failed move
    /// leaves the login entry in place and removes the just-created
    /// Data-Protection entry when possible.
    private func moveLoginItemToDataProtection(
        _ data: Data, expected: CredentialVaultPayload
    ) throws {
        do {
            try keychain.write(
                data: data, service: Self.service, account: Self.account,
                in: .dataProtection)
            guard let copied = try keychain.data(
                service: Self.service, account: Self.account, in: .dataProtection),
                  try decode(copied) == expected
            else {
                throw Failure.transitionVerificationFailed
            }
            try keychain.remove(
                service: Self.service, account: Self.account, in: .login)
            Self.logger.notice(
                "Credential transition login-to-data-protection completed for the combined record")
        } catch {
            try? keychain.remove(
                service: Self.service, account: Self.account, in: .dataProtection)
            throw error
        }
    }
}

/// The real OTA store delegates to the shared WiFi/OTA Keychain payload while
/// preserving the protocol callers use. Hardware IDs remain the OTA map key so
/// a device rename cannot lose its remembered update password.
final class KeychainOTAPasswordStore: OTAPasswordStoring {
    static let service = KeychainCredentialVault.service
    static let account = KeychainCredentialVault.account
    typealias Failure = KeychainCredentialVault.Failure

    func password(forHardwareID hardwareID: String) -> String? {
        try? KeychainCredentialVault.shared.otaPassword(for: hardwareID)
    }

    func store(_ password: String, forHardwareID hardwareID: String) throws {
        try KeychainCredentialVault.shared.storeOTAPassword(password, for: hardwareID)
    }

    func remove(forHardwareID hardwareID: String) throws {
        try KeychainCredentialVault.shared.removeOTAPassword(for: hardwareID)
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
