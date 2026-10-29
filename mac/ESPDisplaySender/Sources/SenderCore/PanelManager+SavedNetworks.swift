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
    /// Settings list accepts is one every board accepts too. An empty
    /// password is an open network (`SavedWiFiCredential.isOpenNetwork`), not
    /// a missing one.
    nonisolated static func savedNetworkProblem(
        ssid: String, password: String
    ) -> WifiConfigUI.ConfigFailure? {
        guard !ssid.isEmpty, ssid.utf8.count <= 32 else {
            return WifiConfigUI.ConfigFailure(
                title: "Invalid network name",
                message: "The network name (SSID) must be 1 to 32 bytes.")
        }
        guard ConfigCommands.setWifiPreset(
            slot: ConfigCommands.wifiPresetSlotRange.lowerBound,
            ssid: ssid, password: password) != nil
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
    /// Returns nil on success. An empty password saves an open network.
    func saveNetwork(
        ssid rawSSID: String, password: String
    ) -> WifiConfigUI.ConfigFailure? {
        let ssid = rawSSID.trimmingCharacters(in: .whitespaces)
        if let problem = Self.savedNetworkProblem(ssid: ssid, password: password) {
            return problem
        }
        let credential = SavedWiFiCredential(ssid: ssid, password: password)
        if let failure = wifiCredentialWriter(credential) {
            return WifiConfigUI.ConfigFailure(
                title: "Keychain storage failed",
                message: "\"\(ssid)\" could not be saved to the app's protected Keychain, "
                    + "so nothing changed. " + failure + " Retry the save.")
        }
        var order = settings.wifiPresetOrder ?? savedNetworkNames
        if !order.contains(ssid) { order.append(ssid) }
        // The same name may carry a new password, so the boards are told even
        // when the list of names did not change.
        wifiCredentialRevision += 1
        // Views that read the credential itself - the Add Display sheet -
        // redraw even when the list of names is the same.
        objectWillChange.send()
        // Entering it again is what a display page asks for when the last copy
        // could not use it, so it leaves that row now, not at the next copy.
        for hardwareID in wifiPresetSyncReports.keys {
            wifiPresetSyncReports[hardwareID]?.unusable.removeAll { $0 == ssid }
        }
        setWifiPresetOrder(order, keychainNames: wifiNetworkNamesReader())
        syncWifiPresetsToAttachedDevices()
        return nil
    }

    /// Delete a saved network from the Keychain and the order. The next sync
    /// clears it from every attached board's slots, except a slot a board is
    /// joined through, which the sync never touches.
    func removeSavedNetwork(_ ssid: String) -> WifiConfigUI.ConfigFailure? {
        if let failure = wifiCredentialRemover(ssid) {
            return WifiConfigUI.ConfigFailure(
                title: "Keychain removal failed",
                message: "\"\(ssid)\" could not be removed from the app's protected "
                    + "Keychain, so it is still saved. " + failure + " Retry "
                    + "the removal.")
        }
        let order = (settings.wifiPresetOrder ?? savedNetworkNames)
            .filter { $0 != ssid }
        setWifiPresetOrder(order, keychainNames: wifiNetworkNamesReader())
        return nil
    }

    /// Move one network up (negative) or down (positive) in the order, which
    /// moves it between the slots every board receives. The Settings list
    /// drags instead (`moveSavedNetworks`); this stays as the step form the
    /// order's tests are written in.
    func moveSavedNetwork(_ ssid: String, by offset: Int) {
        guard let from = savedNetworkNames.firstIndex(of: ssid) else { return }
        let to = min(max(from + offset, 0), savedNetworkNames.count - 1)
        guard to != from else { return }
        // `toOffset` counts positions before the move, as a drag does.
        moveSavedNetworks(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
    }

    /// Move the networks at `source` to before position `destination` - the
    /// list's drag-and-drop reorder, with SwiftUI's `onMove` meaning of both
    /// offsets: positions in the order as it stands before the move, where
    /// `destination` may be one past the end.
    func moveSavedNetworks(fromOffsets source: IndexSet, toOffset destination: Int) {
        let order = Self.moving(savedNetworkNames, fromOffsets: source, toOffset: destination)
        guard order != savedNetworkNames else { return }
        // Names the stored order keeps for a missing Keychain item stay at the
        // end, so they regain a place if the item comes back.
        let hidden = (settings.wifiPresetOrder ?? []).filter { !order.contains($0) }
        setWifiPresetOrder(order + hidden, keychainNames: wifiNetworkNamesReader())
    }

    /// `Array.move(fromOffsets:toOffset:)`, without needing SwiftUI here.
    nonisolated static func moving(
        _ names: [String], fromOffsets source: IndexSet, toOffset destination: Int
    ) -> [String] {
        let valid = source.filter { names.indices.contains($0) }
        guard !valid.isEmpty else { return names }
        let moved = valid.map { names[$0] }
        var rest = names.enumerated().filter { !valid.contains($0.offset) }.map(\.element)
        let insertAt = destination - valid.filter { $0 < destination }.count
        rest.insert(contentsOf: moved, at: min(max(insertAt, 0), rest.count))
        return rest
    }

    /// The saved credential behind a network, for the Settings editor.
    func savedCredential(for ssid: String) -> SavedWiFiCredential? {
        wifiCredentialLookup(ssid)
    }
}

/// Saved networks held in memory, for previews and tests, which run unsigned
/// and must never write the protected Keychain. An empty password is an open
/// network here too.
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
            guard !writesFail else { return false }
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
    /// app's protected Keychain.
    func useWifiCredentials(_ store: InMemoryWifiCredentials) {
        wifiCredentialLookup = { store.credential(for: $0) }
        wifiNetworkNamesReader = { store.names }
        wifiCredentialWriter = {
            store.save($0) ? nil : "The temporary credential store refused the save."
        }
        wifiCredentialRemover = {
            store.remove($0) ? nil : "The temporary credential store refused the removal."
        }
    }
}
