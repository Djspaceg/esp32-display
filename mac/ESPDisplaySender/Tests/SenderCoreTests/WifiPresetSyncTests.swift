import Foundation
import SenderProtocol
@testable import SenderCore
import XCTest

@MainActor
final class WifiPresetSyncTests: XCTestCase {

    // MARK: slot assignment - alphabetical order, truncation, active slot

    func testSavedNetworksAreSortedAlphabeticallyAndTruncatedToTenSlots() {
        let saved = [
            "Zeta", "Mango", "alpha", "Delta", "echo", "Foxtrot", "Golf",
            "hotel", "India", "Juliet", "Kilo", "Lima",
        ]
        let assignment = WifiPresetSlotPlan.assignment(
            savedSSIDs: saved, snapshot: directSnapshot())

        XCTAssertEqual(assignment.protectedSlot, nil)
        XCTAssertEqual(assignment.slots, [
            "alpha", "Delta", "echo", "Foxtrot", "Golf",
            "hotel", "India", "Juliet", "Kilo", "Lima",
        ])
        // Truncation drops the alphabetical tail, not an arbitrary ten.
        XCTAssertEqual(assignment.omitted, ["Mango", "Zeta"])
    }

    func testFewerSavedNetworksThanSlotsLeavesTheRestEmpty() {
        let assignment = WifiPresetSlotPlan.assignment(
            savedSSIDs: ["Beta", "alpha"], snapshot: directSnapshot())

        XCTAssertEqual(
            assignment.slots,
            ["alpha", "Beta"] + [String?](repeating: nil, count: 8))
        XCTAssertTrue(assignment.omitted.isEmpty)
    }

    /// The rule that outranks alphabetical order: the slot the display is
    /// joined through keeps its content, in place. Everything else sorts around
    /// it, so no reactivation is needed and the board cannot reboot as a side
    /// effect of a sync.
    func testActiveSlotKeepsItsContentAndTheRestSortAroundIt() {
        let saved = [
            "alpha", "Bravo", "Charlie", "Delta", "echo",
            "Foxtrot", "Golf", "hotel", "India", "Juliet", "Kilo",
        ]
        let snapshot = snapshot(
            slots: [7: "Golf"], activeSlot: 7)

        let assignment = WifiPresetSlotPlan.assignment(
            savedSSIDs: saved, snapshot: snapshot)

        XCTAssertEqual(assignment.protectedSlot, 7)
        // "Golf" would have sorted into slot 7 by coincidence here? No: with
        // "Golf" removed from the run, slot 7 would otherwise have held
        // "hotel". It stays put and the others fill 1-6 and 8-10 in order.
        XCTAssertEqual(assignment.slots, [
            "alpha", "Bravo", "Charlie", "Delta", "echo",
            "Foxtrot", "Golf", "hotel", "India", "Juliet",
        ])
        XCTAssertEqual(assignment.omitted, ["Kilo"])
    }

    /// An active network the app does not have saved is still retained. Losing
    /// it is the reboot loop this rule exists to prevent, so it costs a slot.
    func testActiveNetworkAbsentFromTheSavedListIsStillRetained() {
        let saved = [
            "alpha", "Bravo", "Charlie", "Delta", "echo",
            "Foxtrot", "Golf", "hotel", "India", "Juliet",
        ]
        let assignment = WifiPresetSlotPlan.assignment(
            savedSSIDs: saved,
            snapshot: snapshot(slots: [3: "Only On Device"], activeSlot: 3))

        XCTAssertEqual(assignment.protectedSlot, 3)
        XCTAssertEqual(assignment.slots[2], "Only On Device")
        XCTAssertEqual(assignment.slots, [
            "alpha", "Bravo", "Only On Device", "Charlie", "Delta",
            "echo", "Foxtrot", "Golf", "hotel", "India",
        ])
        XCTAssertEqual(assignment.omitted, ["Juliet"])
    }

    /// An active SSID that alphabetical order would have placed in a different
    /// slot is not moved. Moving it means clearing the slot it is active in.
    func testActiveNetworkIsNotMovedIntoItsAlphabeticalSlot() {
        let assignment = WifiPresetSlotPlan.assignment(
            savedSSIDs: ["alpha", "Bravo", "Charlie"],
            snapshot: snapshot(slots: [9: "alpha"], activeSlot: 9))

        XCTAssertEqual(assignment.protectedSlot, 9)
        XCTAssertEqual(assignment.slots[8], "alpha")
        XCTAssertEqual(assignment.slots[0], "Bravo")
        XCTAssertEqual(assignment.slots[1], "Charlie")
    }

    /// A roster naming an active slot whose contents would not read is the
    /// worst case for a rewrite: reserve it and leave it alone.
    func testUnreadableActiveSlotIsStillReservedAndUntouched() {
        let roster = ConfigCommands.WiFiPresetRoster(
            capacity: 10, validSlots: [4], activeSlot: 4,
            localSelectorAvailable: true)
        let opaque = WifiPresetSnapshot(roster: roster, slots: [:])

        let assignment = WifiPresetSlotPlan.assignment(
            savedSSIDs: ["alpha", "Bravo"], snapshot: opaque)

        XCTAssertEqual(assignment.protectedSlot, 4)
        XCTAssertNil(assignment.slots[3])
        XCTAssertEqual(assignment.slots[0], "alpha")
        XCTAssertEqual(assignment.slots[1], "Bravo")

        let commands = try? resultValue(WifiPresetSyncPlanner.commands(
            desired: assignment.slots, existing: [:],
            credentials: [
                "alpha": SavedWiFiCredential(ssid: "alpha", password: "a"),
                "Bravo": SavedWiFiCredential(ssid: "Bravo", password: "b"),
            ],
            protectedSlot: assignment.protectedSlot))
        XCTAssertEqual(commands, [
            "CFGWIFISET 1 YWxwaGE= YQ==",
            "CFGWIFISET 2 QnJhdm8= Yg==",
        ])
    }

    // MARK: planner

    func testPlannerWritesCredentialsBeforeClearingOldSlots() throws {
        let existing = [
            1: ConfigCommands.WiFiPresetSlot(
                slot: 1, ssid: "Old", hasPassword: true, active: false),
            2: ConfigCommands.WiFiPresetSlot(
                slot: 2, ssid: "Stale", hasPassword: false, active: false),
        ]
        let desired: [String?] = ["New"] + Array(repeating: nil, count: 9)
        let credentials = [
            "New": SavedWiFiCredential(ssid: "New", password: "synthetic")
        ]

        let commands = try resultValue(WifiPresetSyncPlanner.commands(
            desired: desired, existing: existing, credentials: credentials))
        XCTAssertEqual(commands, [
            "CFGWIFISET 1 TmV3 c3ludGhldGlj",
            "CFGWIFICLEAR 2",
        ])
    }

    /// Every replacement is accepted by the device before any old credential is
    /// destroyed. The device has no transaction, so this ordering is what keeps
    /// a partial write survivable.
    func testEverySetPrecedesEveryClearAcrossAFullReplacement() throws {
        var existing: [Int: ConfigCommands.WiFiPresetSlot] = [:]
        for slot in 1...10 {
            existing[slot] = ConfigCommands.WiFiPresetSlot(
                slot: slot, ssid: "Old \(slot)", hasPassword: true, active: false)
        }
        let desired: [String?] = ["Replacement", nil, "Second"]
            + Array(repeating: nil, count: 7)
        let credentials = [
            "Replacement": SavedWiFiCredential(
                ssid: "Replacement", password: "one"),
            "Second": SavedWiFiCredential(ssid: "Second", password: "two"),
        ]

        let commands = try resultValue(WifiPresetSyncPlanner.commands(
            desired: desired, existing: existing, credentials: credentials))
        let lastSet = try XCTUnwrap(
            commands.lastIndex { $0.hasPrefix("CFGWIFISET ") })
        let firstClear = try XCTUnwrap(
            commands.firstIndex { $0.hasPrefix("CFGWIFICLEAR ") })
        XCTAssertEqual(commands.count, 10)
        XCTAssertEqual(lastSet, 1)
        XCTAssertEqual(firstClear, 2)
        XCTAssertTrue(lastSet < firstClear)
    }

    func testPlannerPreservesDeviceOnlyCredentialInItsExistingSlot() throws {
        let existing = [
            3: ConfigCommands.WiFiPresetSlot(
                slot: 3, ssid: "Device Only", hasPassword: true, active: true)
        ]
        let desired = [String?](repeating: nil, count: 2)
            + ["Device Only"]
            + [String?](repeating: nil, count: 7)
        let commands = try resultValue(WifiPresetSyncPlanner.commands(
            desired: desired, existing: existing, credentials: [:]))
        XCTAssertEqual(commands, [])
    }

    /// Not even an identical rewrite of the active slot. A SET is a serial
    /// write to the credential the display is joined through; there is no
    /// upside to issuing it.
    func testPlannerIssuesNoCommandForTheActiveSlotEvenWithACredential() throws {
        let existing = [
            5: ConfigCommands.WiFiPresetSlot(
                slot: 5, ssid: "Studio", hasPassword: true, active: true)
        ]
        let desired = [String?](repeating: nil, count: 4)
            + ["Studio"]
            + [String?](repeating: nil, count: 5)
        let commands = try resultValue(WifiPresetSyncPlanner.commands(
            desired: desired, existing: existing,
            credentials: [
                "Studio": SavedWiFiCredential(ssid: "Studio", password: "rotated")
            ],
            protectedSlot: 5))
        XCTAssertEqual(commands, [])
    }

    /// Refused, not reordered. A plan that replaces the active credential would
    /// leave the display holding an active slot whose network is gone.
    func testPlannerRefusesToRewriteOrClearTheActiveSlot() {
        let existing = [
            5: ConfigCommands.WiFiPresetSlot(
                slot: 5, ssid: "Studio", hasPassword: true, active: true)
        ]
        let replaced = [String?](repeating: nil, count: 4)
            + ["Cafe"]
            + [String?](repeating: nil, count: 5)
        XCTAssertEqual(
            failureValue(WifiPresetSyncPlanner.commands(
                desired: replaced, existing: existing,
                credentials: [
                    "Cafe": SavedWiFiCredential(ssid: "Cafe", password: "x")
                ],
                protectedSlot: 5)),
            .activeSlotRewrite(slot: 5))

        let cleared = [String?](repeating: nil, count: 10)
        XCTAssertEqual(
            failureValue(WifiPresetSyncPlanner.commands(
                desired: cleared, existing: existing, credentials: [:],
                protectedSlot: 5)),
            .activeSlotRewrite(slot: 5))
    }

    func testPlannerRejectsDuplicateAndMissingCredentials() {
        let duplicate: [String?] = ["Cafe", "Cafe"]
            + Array(repeating: nil, count: 8)
        XCTAssertEqual(
            failureValue(WifiPresetSyncPlanner.commands(
                desired: duplicate, existing: [:], credentials: [:])),
            .duplicateSSID("Cafe"))

        let missing: [String?] = ["Unknown"] + Array(repeating: nil, count: 9)
        XCTAssertEqual(
            failureValue(WifiPresetSyncPlanner.commands(
                desired: missing, existing: [:], credentials: [:])),
            .missingCredential(slot: 1, ssid: "Unknown"))
    }

    // MARK: the sync as it reaches the device

    func testSyncUsesDeviceProtocolAndVerifiesFinalRoster() throws {
        let device = FakePresetDevice(slots: [
            1: ("Old", true),
            2: ("Stale", false),
        ])
        let desired: [String?] = ["New", nil, "Cafe"]
            + Array(repeating: nil, count: 7)
        let credentials = [
            "New": SavedWiFiCredential(ssid: "New", password: "synthetic"),
            "Cafe": SavedWiFiCredential(
                ssid: "Cafe", password: "", isOpenNetwork: true),
        ]

        let result = WifiConfigUI.syncWifiPresets(
            desired,
            credentials: credentials,
            port: "/dev/fake",
            send: { command, _, _ in device.send(command) })
        let snapshot = try resultValue(result)

        XCTAssertEqual(snapshot.slots[1]?.ssid, "New")
        XCTAssertNil(snapshot.slots[2])
        XCTAssertEqual(snapshot.slots[3]?.ssid, "Cafe")
        XCTAssertEqual(device.mutations, [
            "CFGWIFISET 1 TmV3 c3ludGhldGlj",
            "CFGWIFISET 3 Q2FmZQ== -",
            "CFGWIFICLEAR 2",
        ])
        XCTAssertEqual(device.commands.last, "CFGWIFISHOW 3")
    }

    /// The whole automatic path: read, sort, truncate, write, read back.
    func testAutomaticSyncCopiesTheSavedCollectionInAlphabeticalOrder() throws {
        let device = FakePresetDevice(slots: [1: ("Leftover", true)])
        let saved = [
            "Zeta", "alpha", "Bravo", "Charlie", "Delta", "echo",
            "Foxtrot", "Golf", "hotel", "India", "Juliet",
        ]

        let report = try resultValue(WifiConfigUI.syncSavedWifiPresets(
            savedSSIDs: saved,
            credentials: credentials(for: saved),
            port: "/dev/fake",
            send: { command, _, _ in device.send(command) }))

        XCTAssertEqual(
            (1...10).map { report.snapshot.slots[$0]?.ssid },
            ["alpha", "Bravo", "Charlie", "Delta", "echo",
             "Foxtrot", "Golf", "hotel", "India", "Juliet"])
        XCTAssertEqual(report.omitted, ["Zeta"])
        XCTAssertTrue(report.unusable.isEmpty)
    }

    /// The safety rule, end to end at the device: the active slot's credential
    /// is never written and never cleared, and the rest sort around it.
    func testAutomaticSyncNeverWritesTheActiveSlot() throws {
        let device = FakePresetDevice(
            slots: [4: ("Studio", true)], activeSlot: 4)
        let saved = [
            "alpha", "Bravo", "Charlie", "Delta", "echo",
            "Foxtrot", "Golf", "hotel", "India", "Studio", "Zeta",
        ]

        let report = try resultValue(WifiConfigUI.syncSavedWifiPresets(
            savedSSIDs: saved,
            credentials: credentials(for: saved),
            port: "/dev/fake",
            send: { command, _, _ in device.send(command) }))

        XCTAssertEqual(report.snapshot.activeSlot, 4)
        XCTAssertEqual(report.snapshot.slots[4]?.ssid, "Studio")
        XCTAssertEqual(report.snapshot.slots[4]?.active, true)
        XCTAssertEqual(
            (1...10).map { report.snapshot.slots[$0]?.ssid },
            ["alpha", "Bravo", "Charlie", "Studio", "Delta",
             "echo", "Foxtrot", "Golf", "hotel", "India"])
        XCTAssertEqual(report.omitted, ["Zeta"])
        XCTAssertFalse(
            device.mutations.contains { $0.hasSuffix(" 4") || $0.contains("SET 4 ") },
            "no command may address the active slot: \(device.mutations)")
    }

    /// The failure this feature is designed against. A bench run left a preset
    /// active whose credential the sync had replaced, and the panel rebooted
    /// every 75 to 160 seconds. The readback is what catches it.
    func testSyncFailsWhenTheActiveNetworkChangedDuringTheWrite() {
        let device = FakePresetDevice(
            slots: [2: ("Studio", true)], activeSlot: 2)
        // A device that quietly moves which slot is active mid-sync. Every
        // slot's contents are exactly what was asked for, so this is only
        // catchable by checking the active slot itself.
        device.sabotage = .moveActiveSlot(to: 1)

        let result = WifiConfigUI.syncSavedWifiPresets(
            savedSSIDs: ["alpha", "Studio"],
            credentials: credentials(for: ["alpha", "Studio"]),
            port: "/dev/fake",
            send: { command, _, _ in device.send(command) })

        guard case .failure(let failure) = result else {
            return XCTFail("a moved active network must not verify")
        }
        XCTAssertEqual(failure.title, "WiFi preset verification failed")
        XCTAssertTrue(
            failure.message.contains("active network changed"),
            failure.message)
    }

    /// A serial write that reports success but does not land is caught by the
    /// readback rather than being reported as a synchronized display.
    func testReadbackCatchesAWriteThatDidNotLand() {
        let device = FakePresetDevice(slots: [:])
        device.sabotage = .dropSet(slot: 2)

        let result = WifiConfigUI.syncSavedWifiPresets(
            savedSSIDs: ["alpha", "Bravo", "Charlie"],
            credentials: credentials(for: ["alpha", "Bravo", "Charlie"]),
            port: "/dev/fake",
            send: { command, _, _ in device.send(command) })

        guard case .failure(let failure) = result else {
            return XCTFail("an unlanded write must not verify")
        }
        XCTAssertEqual(failure.title, "WiFi preset verification failed")
        XCTAssertTrue(failure.message.contains("Slot 2"), failure.message)
    }

    /// A sync stores credentials. It never chooses one, because choosing one
    /// restarts the board.
    func testSyncNeverIssuesAnActivationCommand() throws {
        let device = FakePresetDevice(
            slots: [3: ("Studio", true), 8: ("Stale", false)], activeSlot: 3)
        let saved = ["alpha", "Bravo", "Studio", "Zeta"]

        _ = try resultValue(WifiConfigUI.syncSavedWifiPresets(
            savedSSIDs: saved,
            credentials: credentials(for: saved),
            port: "/dev/fake",
            send: { command, _, _ in device.send(command) }))

        XCTAssertFalse(
            device.commands.contains { $0.hasPrefix("CFGWIFIUSE") },
            "the sync must never activate a preset: \(device.commands)")
        XCTAssertTrue(device.commands.allSatisfy {
            $0.hasPrefix("CFGWIFISHOW") || $0.hasPrefix("CFGWIFISET ")
                || $0.hasPrefix("CFGWIFICLEAR ")
        }, device.commands.description)
    }

    /// A saved network whose credential the app cannot produce, or that the
    /// device would refuse, is dropped from this sync rather than failing all
    /// ten of them.
    func testUnusableSavedNetworksAreSkippedRatherThanFailingTheSync() throws {
        let device = FakePresetDevice(slots: [:])
        let tooLong = String(repeating: "s", count: 33)

        let report = try resultValue(WifiConfigUI.syncSavedWifiPresets(
            savedSSIDs: ["alpha", "No Credential", tooLong],
            credentials: [
                "alpha": SavedWiFiCredential(ssid: "alpha", password: "a"),
                tooLong: SavedWiFiCredential(ssid: tooLong, password: "b"),
            ],
            port: "/dev/fake",
            send: { command, _, _ in device.send(command) }))

        XCTAssertEqual(report.snapshot.slots[1]?.ssid, "alpha")
        XCTAssertEqual(report.unusable.sorted(), ["No Credential", tooLong].sorted())
    }

    func testAutomaticSyncDoesNotWriteAnEmptyPasswordAsAnOpenPreset() throws {
        let device = FakePresetDevice(slots: [:])

        let report = try resultValue(WifiConfigUI.syncSavedWifiPresets(
            savedSSIDs: ["Office"],
            credentials: [
                "Office": SavedWiFiCredential(ssid: "Office", password: "")
            ],
            port: "/dev/fake",
            send: { command, _, _ in device.send(command) }))

        XCTAssertEqual(report.unusable, ["Office"])
        XCTAssertFalse(
            device.mutations.contains("CFGWIFISET 1 T2ZmaWNl -"),
            "an empty password must not become an open-network command: "
                + "\(device.mutations)")
    }

    func testAutomaticSyncWritesAnExplicitOpenNetwork() throws {
        let device = FakePresetDevice(slots: [:])

        let report = try resultValue(WifiConfigUI.syncSavedWifiPresets(
            savedSSIDs: ["Guest"],
            credentials: [
                "Guest": SavedWiFiCredential(
                    ssid: "Guest", password: "", isOpenNetwork: true)
            ],
            port: "/dev/fake",
            send: { command, _, _ in device.send(command) }))

        XCTAssertTrue(report.unusable.isEmpty)
        XCTAssertEqual(device.mutations, ["CFGWIFISET 1 R3Vlc3Q= -"])
    }

    // MARK: the manager's automatic trigger

    /// A board that answers CFGSHOW on a serial port is a board that gets the
    /// saved collection, with nothing for the user to press.
    func testVerifiedUSBDeviceIsSyncedOnConnect() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [1: ("Leftover", true)])
        let saved = ["Zeta", "alpha", "Bravo"]
        let manager = manager(path: path, saved: saved, device: device)

        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)

        let report = try XCTUnwrap(manager.wifiPresetSyncReport(for: "studio-display"))
        XCTAssertEqual(
            (1...3).map { report.snapshot.slots[$0]?.ssid },
            ["alpha", "Bravo", "Zeta"])
        XCTAssertTrue(manager.issues.isEmpty, manager.issues.description)
        XCTAssertFalse(device.commands.contains { $0.hasPrefix("CFGWIFIUSE") })
    }

    /// A repeat probe - which happens after every USB control and on every
    /// explicit refresh - must not rewrite ten slots.
    func testRepeatVerificationDoesNotRewriteAnUnchangedCollection() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        let manager = manager(
            path: path, saved: ["alpha", "Bravo"], device: device)

        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)
        let afterFirst = device.mutations

        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)

        XCTAssertEqual(device.mutations, afterFirst)
        XCTAssertEqual(afterFirst.count, 2)
    }

    /// Nothing saved means nothing to copy. It must never be read as an
    /// instruction to erase the display's presets.
    func testNoSavedNetworksLeavesTheDisplayAlone() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [1: ("Studio", true)], activeSlot: 1)
        let manager = manager(path: path, saved: [], device: device)

        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)

        XCTAssertTrue(device.commands.isEmpty, device.commands.description)
        XCTAssertNil(manager.wifiPresetSyncReport(for: "studio-display"))
    }

    /// A failed sync is reported and not remembered as done, so the next
    /// verified probe tries again.
    func testFailedSyncIsReportedAndRetriedLater() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        device.sabotage = .refuseSets
        let manager = manager(path: path, saved: ["alpha"], device: device)

        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)

        XCTAssertEqual(manager.issues.map(\.issue), [.wifiPresetSync])
        XCTAssertNil(manager.wifiPresetSyncReport(for: "studio-display"))
        XCTAssertTrue(manager.syncedWifiPresetSignatures.isEmpty)

        device.sabotage = nil
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)

        XCTAssertNotNil(manager.wifiPresetSyncReport(for: "studio-display"))
    }

    // MARK: helpers

    private static let verifiedIdentity = WifiConfigUI.usbIdentity(from:
        "CFGINFO name64=c3R1ZGlvLWRpc3BsYXk= id=020000123456 "
            + "rot=0 bl=high bllevel=64 pwr=on board=st77916 "
            + "target=s3-185 chip=esp32s3 partition=8MB fw=1.5.0")

    @MainActor
    private func manager(
        path: String, saved: [String], device: FakePresetDevice
    ) -> PanelManager {
        var panel = PanelSnapshot(
            serviceName: "studio-display",
            displayName: "studio-display",
            hardwareID: "020000123456")
        panel.usbPort = path
        panel.usbHardwareID = "020000123456"
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: saved,
            usbSerialPorts: [path])
        manager.usbControlSender = { command, port, timeout in
            device.send(command)
        }
        manager.usbControlReprobe = { _, _ in }
        manager.wifiCredentialLookup = { ssid in
            SavedWiFiCredential(ssid: ssid, password: "pw-\(ssid)")
        }
        return manager
    }

    @MainActor
    private func waitForSyncToSettle(_ manager: PanelManager) async throws {
        for _ in 0..<200 {
            if manager.wifiPresetSyncTasks.isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        // One more hop so the completion handler's main-actor work is applied.
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    private func directSnapshot() -> WifiPresetSnapshot {
        snapshot(slots: [:], activeSlot: nil)
    }

    private func snapshot(
        slots: [Int: String], activeSlot: Int?
    ) -> WifiPresetSnapshot {
        var parsed: [Int: ConfigCommands.WiFiPresetSlot] = [:]
        for (slot, ssid) in slots {
            parsed[slot] = ConfigCommands.WiFiPresetSlot(
                slot: slot, ssid: ssid, hasPassword: true,
                active: slot == activeSlot)
        }
        return WifiPresetSnapshot(
            roster: ConfigCommands.WiFiPresetRoster(
                capacity: 10,
                validSlots: Set(slots.keys),
                activeSlot: activeSlot,
                localSelectorAvailable: true),
            slots: parsed)
    }

    private func credentials(
        for ssids: [String]
    ) -> [String: SavedWiFiCredential] {
        var result: [String: SavedWiFiCredential] = [:]
        for ssid in ssids {
            result[ssid] = SavedWiFiCredential(ssid: ssid, password: "pw-\(ssid)")
        }
        return result
    }

    private func resultValue<T, E: Error>(_ result: Result<T, E>) throws -> T {
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    private func failureValue<T>(
        _ result: Result<T, WifiPresetSyncPlanner.PlanFailure>
    ) -> WifiPresetSyncPlanner.PlanFailure? {
        guard case .failure(let error) = result else { return nil }
        return error
    }
}

/// A device that stores ten preset slots, so a sync can be driven end to end
/// without hardware. `sabotage` reproduces the specific ways a real board has
/// diverged from what the app believed it wrote.
private final class FakePresetDevice: @unchecked Sendable {
    enum Sabotage {
        /// Report success for a SET that does not land.
        case dropSet(slot: Int)
        /// Refuse every SET.
        case refuseSets
        /// Move which slot is active behind the app's back, leaving every
        /// slot's contents exactly as the sync left them.
        case moveActiveSlot(to: Int)
    }

    private let lock = NSLock()
    private var storage: [Int: (ssid: String, hasPassword: Bool)]
    private var active: Int?
    private var recorded: [String] = []
    private var appliedMove = false
    var sabotage: Sabotage?

    init(slots: [Int: (String, Bool)], activeSlot: Int? = nil) {
        storage = slots.mapValues { (ssid: $0.0, hasPassword: $0.1) }
        active = activeSlot
    }

    var commands: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var mutations: [String] {
        commands.filter {
            $0.hasPrefix("CFGWIFISET") || $0.hasPrefix("CFGWIFICLEAR")
        }
    }

    func send(_ command: String) -> WifiConfigUI.CommandResult {
        lock.lock(); defer { lock.unlock() }
        recorded.append(command)

        if command == ConfigCommands.showWifiPresets {
            // The relocation lands between the writes and the readback, which
            // is exactly where a real board's own reconnection would put it.
            if case .moveActiveSlot(let slot) = sabotage,
               !recorded.filter({ $0.hasPrefix("CFGWIFISET ") }).isEmpty,
               !appliedMove {
                appliedMove = true
                active = slot
            }
            let mask = storage.keys.reduce(0) { $0 | (1 << ($1 - 1)) }
            let activeText = active.map(String.init) ?? "direct"
            return .success(String(
                format: "CFGINFO wifi capacity=10 valid=0x%03x "
                    + "active=\(activeText) mode=direct local=1",
                mask))
        }
        if command.hasPrefix("CFGWIFISHOW "),
           let slot = Int(command.dropFirst("CFGWIFISHOW ".count)),
           let stored = storage[slot] {
            let ssid64 = Data(stored.ssid.utf8).base64EncodedString()
            return .success(
                "CFGINFO wifi slot=\(slot) valid=1 active=\(active == slot ? 1 : 0) "
                    + "ssid64=\(ssid64) pass=\(stored.hasPassword ? "set" : "open")")
        }
        if command.hasPrefix("CFGWIFISET ") {
            let fields = command.split(separator: " ")
            guard fields.count == 4,
                  let slot = Int(fields[1]),
                  let ssidData = Data(base64Encoded: String(fields[2])),
                  let ssid = String(data: ssidData, encoding: .utf8)
            else { return .failure("bad fake set command") }
            if case .refuseSets = sabotage {
                return .failure("device refused the write")
            }
            // A serial write the device acknowledges without applying.
            if case .dropSet(let dropped) = sabotage, dropped == slot {
                return .success("CFGOK wifi slot=\(slot) saved")
            }
            storage[slot] = (ssid, fields[3] != "-")
            return .success("CFGOK wifi slot=\(slot) saved")
        }
        if command.hasPrefix("CFGWIFICLEAR "),
           let slot = Int(command.dropFirst("CFGWIFICLEAR ".count)) {
            storage[slot] = nil
            if active == slot { active = nil }
            return .success("CFGOK wifi slot=\(slot) cleared")
        }
        return .failure("unexpected command")
    }
}
