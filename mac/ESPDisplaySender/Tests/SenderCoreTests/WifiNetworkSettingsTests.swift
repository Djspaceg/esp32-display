import Foundation
@testable import SenderCore
import XCTest

/// The saved WiFi networks and their preset order as one app-wide setting:
/// the first-launch migration, its idempotence, and the Settings edits.
@MainActor
final class WifiNetworkSettingsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WifiNetworkSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: migration

    /// The migration as a launch sees it, through nothing but the settings
    /// file and the Keychain's names - the APIs a build before the setting
    /// already had, so this compiles against the old code and fails there at
    /// runtime: the old build neither ordered the list nor recorded it.
    ///
    /// A settings.json from before the setting holds no order. The first launch
    /// seeds it from the Keychain in the alphabetical order the old sync used,
    /// writes it next to every other setting it kept, and every later launch
    /// leaves the file byte-for-byte alone. A user's order survives a relaunch,
    /// and a network saved since is appended rather than sorted into it.
    func testFirstLaunchMigratesThePresetOrderOnceAndKeepsIt() throws {
        let url = directory.appendingPathComponent("settings.json")
        try Data(#"{"fps": 30, "identifySeconds": 5, "tileQuality": "aggressive"}"#.utf8)
            .write(to: url)
        let keychain = ["Zeta", "alpha", "Bravo"]

        let first = PanelManager(
            previewPanels: [], savedNetworkNames: keychain, usbSerialPorts: [],
            settings: SettingsStore.load(from: url).settings,
            settingsPersistenceURL: url)

        XCTAssertEqual(first.savedNetworkNames, ["alpha", "Bravo", "Zeta"])
        let written = try settingsObject(at: url)
        XCTAssertEqual(
            written["wifiPresetOrder"] as? [String], ["alpha", "Bravo", "Zeta"],
            "the migrated order must be written to settings.json")
        XCTAssertEqual(written["fps"] as? Int, 30)
        XCTAssertEqual(written["identifySeconds"] as? Int, 5)
        XCTAssertEqual(written["tileQuality"] as? String, "aggressive")

        // Idempotent: a second launch over the migrated file changes nothing.
        let migratedBytes = try Data(contentsOf: url)
        let second = PanelManager(
            previewPanels: [], savedNetworkNames: keychain, usbSerialPorts: [],
            settings: SettingsStore.load(from: url).settings,
            settingsPersistenceURL: url)
        XCTAssertEqual(second.savedNetworkNames, ["alpha", "Bravo", "Zeta"])
        XCTAssertEqual(try Data(contentsOf: url), migratedBytes)

        // A chosen order is kept, and a network saved since joins the end.
        var reordered = try settingsObject(at: url)
        reordered["wifiPresetOrder"] = ["Zeta", "alpha", "Bravo"]
        try JSONSerialization.data(withJSONObject: reordered).write(to: url)
        let third = PanelManager(
            previewPanels: [], savedNetworkNames: keychain + ["Charlie"],
            usbSerialPorts: [],
            settings: SettingsStore.load(from: url).settings,
            settingsPersistenceURL: url)
        XCTAssertEqual(third.savedNetworkNames, ["Zeta", "alpha", "Bravo", "Charlie"])
        XCTAssertEqual(
            try settingsObject(at: url)["wifiPresetOrder"] as? [String],
            ["Zeta", "alpha", "Bravo", "Charlie"])
    }

    /// A settings.json that exists but will not decode is left exactly as it
    /// is: the launch reports it, and the migration does not write defaults
    /// over it.
    func testAnUnreadableSettingsFileIsNotOverwrittenByTheMigration() throws {
        let url = directory.appendingPathComponent("settings.json")
        let corrupt = Data(#"{"fps": 30, "identifySec"#.utf8)
        try corrupt.write(to: url)

        let manager = PanelManager(
            previewPanels: [], savedNetworkNames: ["alpha"], usbSerialPorts: [],
            settings: SettingsStore.load(from: url).settings,
            settingsPersistenceURL: url)

        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertEqual(manager.savedNetworkNames, ["alpha"])
        XCTAssertTrue(
            manager.issues.contains { $0.issue == .persistence },
            "the unsaved order is reported")
    }

    /// `--fps` and the other overrides apply for one run without being written
    /// back. The migration writes the order into the file as it is on disk.
    func testTheMigrationDoesNotPersistCommandLineOverrides() throws {
        let url = directory.appendingPathComponent("settings.json")
        try Data(#"{"fps": 60, "spacingMicros": 200}"#.utf8).write(to: url)
        var overrides = SettingsStore.load(from: url).settings
        overrides.fps = 12
        overrides.spacingMicros = 900

        let manager = PanelManager(
            previewPanels: [], savedNetworkNames: ["alpha"], usbSerialPorts: [],
            settings: overrides, settingsPersistenceURL: url)

        XCTAssertEqual(manager.settings.fps, 12)
        let written = try settingsObject(at: url)
        XCTAssertEqual(written["fps"] as? Int, 60)
        XCTAssertEqual(written["spacingMicros"] as? Int, 200)
        XCTAssertEqual(written["wifiPresetOrder"] as? [String], ["alpha"])
    }

    func testReconcilingIsIdempotentAndNeverDropsAStoredName() {
        let seeded = WifiPresetOrder.reconciled(
            stored: nil, keychainNames: ["b", "A", "c"])
        XCTAssertEqual(seeded, ["A", "b", "c"])
        XCTAssertEqual(
            WifiPresetOrder.reconciled(stored: seeded, keychainNames: ["b", "A", "c"]),
            seeded)

        // A Keychain that read as empty - locked, or the read failed - must not
        // cost the user their order.
        XCTAssertEqual(
            WifiPresetOrder.reconciled(stored: ["c", "A"], keychainNames: []),
            ["c", "A"])
        XCTAssertEqual(
            WifiPresetOrder.present(["c", "A", "b"], keychainNames: ["b", "c"]),
            ["c", "b"])
    }

    /// A Keychain that reads as empty at launch writes nothing, and the order
    /// it would have seeded arrives intact once the names can be read.
    func testALockedKeychainAtLaunchMigratesOnTheNextRead() throws {
        let url = directory.appendingPathComponent("settings.json")
        try Data(#"{"fps": 30}"#.utf8).write(to: url)
        let manager = PanelManager(
            previewPanels: [], savedNetworkNames: [], usbSerialPorts: [],
            settings: SettingsStore.load(from: url).settings,
            settingsPersistenceURL: url)
        XCTAssertNil(manager.settings.wifiPresetOrder)
        XCTAssertNil(try settingsObject(at: url)["wifiPresetOrder"])

        XCTAssertTrue(manager.applySavedNetworkNames(["Zeta", "alpha"]))
        XCTAssertEqual(manager.savedNetworkNames, ["alpha", "Zeta"])
        XCTAssertEqual(
            try settingsObject(at: url)["wifiPresetOrder"] as? [String],
            ["alpha", "Zeta"])
    }

    /// The migration writes the order and nothing else: the passwords and the
    /// open-network marker are Keychain items it never touches.
    func testMigrationLeavesEveryCredentialAsItWas() {
        let store = InMemoryWifiCredentials([
            SavedWiFiCredential(ssid: "Office", password: "secret"),
            SavedWiFiCredential(ssid: "Guest", password: ""),
        ])
        let before = store.names.map { store.credential(for: $0) }
        let manager = PanelManager(
            previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])
        manager.useWifiCredentials(store)
        manager.wifiCredentialWriter = { _ in
            XCTFail("the migration wrote a credential"); return "unexpected write"
        }
        manager.wifiCredentialRemover = { _ in
            XCTFail("the migration removed a credential"); return "unexpected removal"
        }

        manager.applySavedNetworkNames(store.names)

        XCTAssertEqual(manager.savedNetworkNames, ["Guest", "Office"])
        XCTAssertEqual(store.names.map { store.credential(for: $0) }, before)
        XCTAssertEqual(store.credential(for: "Guest")?.isOpenNetwork, true)
    }

    // MARK: the setting itself

    func testTheOrderRoundTripsAndAMalformedOneReadsAsUnmigrated() throws {
        let settings = SenderSettings(fps: 30, wifiPresetOrder: ["b", "", "a", "b"])
        XCTAssertEqual(settings.wifiPresetOrder, ["b", "a"])
        let decoded = try JSONDecoder.espDisplay.decode(
            SenderSettings.self, from: JSONEncoder.espDisplay.encode(settings))
        XCTAssertEqual(decoded, settings)

        let malformed = try JSONDecoder.espDisplay.decode(
            SenderSettings.self,
            from: Data(#"{"fps": 25, "wifiPresetOrder": 7}"#.utf8))
        XCTAssertEqual(malformed.fps, 25)
        XCTAssertNil(malformed.wifiPresetOrder)
    }

    /// The Settings sheet applies a draft on Done. A draft taken before a WiFi
    /// edit, or Restore Defaults, must not put the old order back.
    func testApplyingTheSettingsDraftKeepsTheLiveOrder() {
        let manager = PanelManager(
            previewPanels: [], savedNetworkNames: ["a", "b"], usbSerialPorts: [])
        let draft = manager.settings
        manager.moveSavedNetwork("b", by: -1)
        XCTAssertEqual(manager.savedNetworkNames, ["b", "a"])

        var edited = draft
        edited.fps = 30
        manager.updateSettings(edited)
        XCTAssertEqual(manager.settings.fps, 30)
        XCTAssertEqual(manager.settings.wifiPresetOrder, ["b", "a"])

        manager.updateSettings(SenderSettings())
        XCTAssertEqual(manager.settings.wifiPresetOrder, ["b", "a"])
        XCTAssertEqual(manager.savedNetworkNames, ["b", "a"])
    }

    // MARK: editing from Settings

    func testAddingANetworkAppendsItAndAnEditKeepsItsPlace() {
        let (manager, store) = managerWithStore(["Office", "Home"])
        XCTAssertEqual(manager.savedNetworkNames, ["Home", "Office"])

        XCTAssertNil(manager.saveNetwork(
            ssid: "  Cafe ", password: "latte"))
        XCTAssertEqual(manager.savedNetworkNames, ["Home", "Office", "Cafe"])
        XCTAssertEqual(
            store.credential(for: "Cafe"),
            SavedWiFiCredential(ssid: "Cafe", password: "latte"))

        XCTAssertNil(manager.saveNetwork(
            ssid: "Home", password: "new-password"))
        XCTAssertEqual(manager.savedNetworkNames, ["Home", "Office", "Cafe"])
        XCTAssertEqual(store.credential(for: "Home")?.password, "new-password")
    }

    /// An empty password is an open network: Settings saves it as one, with
    /// nothing to tick, and a typed password is a secured network.
    func testAnEmptyPasswordSavesAnOpenNetwork() {
        let (manager, store) = managerWithStore([])

        XCTAssertNil(manager.saveNetwork(ssid: "Guest", password: ""))
        let guest = store.credential(for: "Guest")
        XCTAssertEqual(guest?.isOpenNetwork, true)
        XCTAssertEqual(guest?.password, "")
        XCTAssertEqual(manager.savedNetworkNames, ["Guest"])

        // Editing it with a password secures it; clearing the password opens
        // it again.
        XCTAssertNil(manager.saveNetwork(ssid: "Guest", password: "lobby"))
        XCTAssertEqual(store.credential(for: "Guest")?.isOpenNetwork, false)
        XCTAssertNil(manager.saveNetwork(ssid: "Guest", password: ""))
        XCTAssertEqual(store.credential(for: "Guest")?.isOpenNetwork, true)
    }

    func testInvalidNetworksAreRefusedBeforeTheKeychain() {
        let (manager, store) = managerWithStore([])
        XCTAssertEqual(
            manager.saveNetwork(ssid: "   ", password: "x")?.title,
            "Invalid network name")
        XCTAssertEqual(
            manager.saveNetwork(
                ssid: String(repeating: "s", count: 33), password: "x")?.title,
            "Invalid network name")
        XCTAssertEqual(
            manager.saveNetwork(
                ssid: "Long", password: String(repeating: "p", count: 65))?.title,
            "Invalid WiFi credential")
        XCTAssertTrue(store.names.isEmpty)
    }

    func testAKeychainFailureChangesNothingAndSaysSo() {
        let (manager, store) = managerWithStore(["Home"])
        store.writesFail = true

        let failure = manager.saveNetwork(
            ssid: "Cafe", password: "latte")
        XCTAssertEqual(failure?.title, "Keychain storage failed")
        XCTAssertEqual(manager.savedNetworkNames, ["Home"])

        XCTAssertEqual(manager.removeSavedNetwork("Home")?.title, "Keychain removal failed")
        XCTAssertEqual(manager.savedNetworkNames, ["Home"])
        XCTAssertNotNil(store.credential(for: "Home"))

        // Resolved: the retry goes through and reports nothing.
        store.writesFail = false
        XCTAssertNil(manager.saveNetwork(
            ssid: "Cafe", password: "latte"))
        XCTAssertEqual(manager.savedNetworkNames, ["Home", "Cafe"])
    }

    func testRemovingANetworkDeletesItAndTakesItOutOfTheOrder() {
        let (manager, store) = managerWithStore(["a", "b", "c"])
        XCTAssertNil(manager.removeSavedNetwork("b"))
        XCTAssertEqual(manager.savedNetworkNames, ["a", "c"])
        XCTAssertNil(store.credential(for: "b"))
        XCTAssertEqual(manager.settings.wifiPresetOrder, ["a", "c"])
    }

    func testMovingANetworkReordersAndStopsAtTheEnds() {
        let (manager, _) = managerWithStore(["a", "b", "c"])
        manager.moveSavedNetwork("c", by: -1)
        XCTAssertEqual(manager.savedNetworkNames, ["a", "c", "b"])
        manager.moveSavedNetwork("a", by: -1)
        XCTAssertEqual(manager.savedNetworkNames, ["a", "c", "b"])
        manager.moveSavedNetwork("a", by: 5)
        XCTAssertEqual(manager.savedNetworkNames, ["c", "b", "a"])
        XCTAssertEqual(manager.settings.wifiPresetOrder, ["c", "b", "a"])
    }

    /// A name whose Keychain item went missing keeps its stored place, so it
    /// gets it back if the item returns, and a move does not lose it.
    func testAMissingKeychainItemKeepsItsStoredPlace() {
        let manager = PanelManager(
            previewPanels: [], savedNetworkNames: [], usbSerialPorts: [],
            settings: SenderSettings(wifiPresetOrder: ["Gone", "a", "b"]))
        let store = InMemoryWifiCredentials(["a", "b"].map {
            SavedWiFiCredential(ssid: $0, password: "pw")
        })
        manager.useWifiCredentials(store)
        manager.applySavedNetworkNames(store.names)
        XCTAssertEqual(manager.savedNetworkNames, ["a", "b"])

        manager.moveSavedNetwork("b", by: -1)
        XCTAssertEqual(manager.savedNetworkNames, ["b", "a"])
        XCTAssertEqual(manager.settings.wifiPresetOrder, ["b", "a", "Gone"])
    }

    // MARK: helpers

    private func managerWithStore(
        _ names: [String]
    ) -> (PanelManager, InMemoryWifiCredentials) {
        let store = InMemoryWifiCredentials(names.map {
            SavedWiFiCredential(ssid: $0, password: "pw-\($0)")
        })
        let manager = PanelManager(
            previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])
        manager.useWifiCredentials(store)
        manager.applySavedNetworkNames(store.names)
        return (manager, store)
    }

    private func settingsObject(at url: URL) throws -> [String: Any] {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "settings.json was not written")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }
}
