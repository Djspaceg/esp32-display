import Foundation
import SenderProtocol

/// The app's saved WiFi networks, edited in one place: Settings. Every board
/// gets the same list, in the same order, through the automatic preset sync
/// (`PanelManager+WifiPresetAutoSync`), so nothing here talks to a board.
///
/// The Keychain holds the credentials and `SenderSettings.wifiPresetOrder`
/// holds the order. Each change below writes the Keychain first and the order
/// second, then republishes `savedNetworkNames`, which is what pushes the new
/// collection to every attached board.
extension PanelManager {
    /// Why a network cannot be saved as typed, or nil when it can. Checked
    /// against the same device limits the sync applies, so a network the
    /// Settings list accepts is one every board accepts too.
    nonisolated static func savedNetworkProblem(
        ssid: String, password: String, isOpenNetwork: Bool
    ) -> WifiConfigUI.ConfigFailure? {
        guard !ssid.isEmpty, ssid.utf8.count <= 32 else {
            return WifiConfigUI.ConfigFailure(
                title: "Invalid network name",
                message: "The network name (SSID) must be 1 to 32 bytes.")
        }
        if !isOpenNetwork && password.isEmpty {
            return WifiConfigUI.ConfigFailure(
                title: "Password needed",
                message: "Enter the password for \"\(ssid)\", or mark it as an "
                    + "open network.")
        }
        let stored = isOpenNetwork ? "" : password
        guard ConfigCommands.setWifiPreset(
            slot: ConfigCommands.wifiPresetSlotRange.lowerBound,
            ssid: ssid, password: stored) != nil
        else {
            return WifiConfigUI.ConfigFailure(
                title: "Invalid WiFi credential",
                message: "The password must be at most 64 bytes, and neither "
                    + "field may contain a NUL character.")
        }
        return nil
    }

    /// Add a network, or replace the credential of one already saved. A new
    /// network goes to the end of the order; an existing one keeps its place.
    ///
    /// Returns nil on success. The empty-password rule from the Keychain store
    /// applies unchanged: an empty password is saved only as an explicit open
    /// network, carrying the open-network marker.
    func saveNetwork(
        ssid rawSSID: String, password: String, isOpenNetwork: Bool
    ) -> WifiConfigUI.ConfigFailure? {
        let ssid = rawSSID.trimmingCharacters(in: .whitespaces)
        if let problem = Self.savedNetworkProblem(
            ssid: ssid, password: password, isOpenNetwork: isOpenNetwork) {
            return problem
        }
        let credential = SavedWiFiCredential(
            ssid: ssid, password: isOpenNetwork ? "" : password,
            isOpenNetwork: isOpenNetwork)
        guard wifiCredentialWriter(credential) else {
            return WifiConfigUI.ConfigFailure(
                title: "Keychain storage failed",
                message: "\"\(ssid)\" could not be saved to your login Keychain, "
                    + "so nothing changed. Unlock the Keychain and try again.")
        }
        var order = settings.wifiPresetOrder ?? savedNetworkNames
        if !order.contains(ssid) { order.append(ssid) }
        // The same name may carry a new password, so the boards are told even
        // when the list of names did not change.
        wifiCredentialRevision += 1
        setWifiPresetOrder(order, keychainNames: wifiNetworkNamesReader())
        syncWifiPresetsToAttachedDevices()
        return nil
    }

    /// Delete a saved network from the Keychain and the order. The next sync
    /// clears it from every attached board's slots, except a slot a board is
    /// joined through, which the sync never touches.
    func removeSavedNetwork(_ ssid: String) -> WifiConfigUI.ConfigFailure? {
        guard wifiCredentialRemover(ssid) else {
            return WifiConfigUI.ConfigFailure(
                title: "Keychain removal failed",
                message: "\"\(ssid)\" could not be removed from your login "
                    + "Keychain, so it is still saved. Unlock the Keychain and "
                    + "try again.")
        }
        let order = (settings.wifiPresetOrder ?? savedNetworkNames)
            .filter { $0 != ssid }
        setWifiPresetOrder(order, keychainNames: wifiNetworkNamesReader())
        return nil
    }

    /// Move one network up (negative) or down (positive) in the order, which
    /// moves it between the slots every board receives.
    func moveSavedNetwork(_ ssid: String, by offset: Int) {
        var order = savedNetworkNames
        guard let from = order.firstIndex(of: ssid) else { return }
        let to = min(max(from + offset, 0), order.count - 1)
        guard to != from else { return }
        order.remove(at: from)
        order.insert(ssid, at: to)
        // Names the stored order keeps for a missing Keychain item stay at the
        // end, so they regain a place if the item comes back.
        let hidden = (settings.wifiPresetOrder ?? []).filter { !order.contains($0) }
        setWifiPresetOrder(order + hidden, keychainNames: wifiNetworkNamesReader())
    }

    /// Another path - onboarding, the WiFi dialog - wrote a credential to the
    /// Keychain. Its name may already be saved with an older password, which
    /// leaves the list of names unchanged, so the attached boards are told
    /// regardless, the same way an edit in Settings tells them.
    func savedCredentialsWereWritten() {
        wifiCredentialRevision += 1
        refreshSavedNetworks()
        syncWifiPresetsToAttachedDevices()
    }

    /// The saved credential behind a network, for the Settings editor.
    func savedCredential(for ssid: String) -> SavedWiFiCredential? {
        wifiCredentialLookup(ssid)
    }
}

/// Saved networks held in memory, for previews and tests, which run unsigned
/// and must never write the login Keychain. Keeps the open-network marker the
/// way the Keychain store does: an empty password is open only when saved as
/// open.
final class InMemoryWifiCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [String: SavedWiFiCredential]
    /// Set to make every write and removal fail, so the error paths are
    /// reachable without a Keychain to break.
    var writesFail = false

    init(_ credentials: [SavedWiFiCredential] = []) {
        self.credentials = Dictionary(
            credentials.map { ($0.ssid, $0) }, uniquingKeysWith: { $1 })
    }

    var names: [String] {
        lock.withLock { WifiPresetSlotPlan.sortedSSIDs(Array(credentials.keys)) }
    }

    func credential(for ssid: String) -> SavedWiFiCredential? {
        lock.withLock { credentials[ssid] }
    }

    func save(_ credential: SavedWiFiCredential) -> Bool {
        lock.withLock {
            // The Keychain store's own rule, mirrored.
            guard !writesFail,
                  credential.isOpenNetwork == credential.password.isEmpty
            else { return false }
            credentials[credential.ssid] = credential
            return true
        }
    }

    func remove(_ ssid: String) -> Bool {
        lock.withLock {
            guard !writesFail else { return false }
            credentials[ssid] = nil
            return true
        }
    }
}

extension PanelManager {
    /// Point every saved-network read and write at `store` instead of the
    /// login Keychain.
    func useWifiCredentials(_ store: InMemoryWifiCredentials) {
        wifiCredentialLookup = { store.credential(for: $0) }
        wifiNetworkNamesReader = { store.names }
        wifiCredentialWriter = { store.save($0) }
        wifiCredentialRemover = { store.remove($0) }
    }
}
