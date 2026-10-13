import Foundation
import SenderProtocol
@testable import SenderCore
import XCTest

@MainActor
final class WifiPresetSyncTests: XCTestCase {

    // MARK: slot assignment - saved order, truncation, active slot

    /// The slots follow the order chosen in Settings, not the alphabet, and
    /// truncation drops the tail of that order.
    func testSavedNetworksKeepTheirOrderAndAreTruncatedToTenSlots() {
        let saved = [
            "Zeta", "Mango", "alpha", "Delta", "echo", "Foxtrot", "Golf",
            "hotel", "India", "Juliet", "Kilo", "Lima",
        ]
        let assignment = WifiPresetSlotPlan.assignment(
            savedSSIDs: saved, snapshot: directSnapshot())

        XCTAssertEqual(assignment.protectedSlot, nil)
        XCTAssertEqual(assignment.slots, [
            "Zeta", "Mango", "alpha", "Delta", "echo",
            "Foxtrot", "Golf", "hotel", "India", "Juliet",
        ])
        XCTAssertEqual(assignment.omitted, ["Kilo", "Lima"])
    }

    func testFewerSavedNetworksThanSlotsLeavesTheRestEmpty() {
        let assignment = WifiPresetSlotPlan.assignment(
            savedSSIDs: ["Beta", "alpha"], snapshot: directSnapshot())

        XCTAssertEqual(
            assignment.slots,
            ["Beta", "alpha"] + [String?](repeating: nil, count: 8))
        XCTAssertTrue(assignment.omitted.isEmpty)
    }

    /// A migrated order is the alphabetical one every earlier build synced in,
    /// so a board receives exactly the slots it did before the migration.
    func testAMigratedOrderPlacesTheSlotsTheAlphabeticalSyncDid() {
        let keychain = ["Zeta", "Mango", "alpha", "Delta", "echo"]
        let migrated = WifiPresetOrder.reconciled(
            stored: nil, keychainNames: keychain)

        XCTAssertEqual(
            WifiPresetSlotPlan.assignment(
                savedSSIDs: migrated, snapshot: directSnapshot()).slots,
            WifiPresetSlotPlan.assignment(
                savedSSIDs: WifiPresetSlotPlan.sortedSSIDs(keychain),
                snapshot: directSnapshot()).slots)
        XCTAssertEqual(migrated, ["alpha", "Delta", "echo", "Mango", "Zeta"])
    }

    /// The rule that outranks the saved order: the slot the display is
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

    /// An active SSID that the saved order would have placed in a different
    /// slot is not moved. Moving it means clearing the slot it is active in.
    func testActiveNetworkIsNotMovedIntoItsSavedSlot() {
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
                ssid: "Cafe", password: ""),
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

    /// The whole automatic path: read, lay out in the saved order, truncate,
    /// write, read back.
    func testAutomaticSyncCopiesTheSavedCollectionInItsSavedOrder() throws {
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
            ["Zeta", "alpha", "Bravo", "Charlie", "Delta",
             "echo", "Foxtrot", "Golf", "hotel", "India"])
        XCTAssertEqual(report.omitted, ["Juliet"])
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

    /// No password is an open network: it is copied as one and never named
    /// as a network the copy left out.
    func testAnEmptyPasswordIsCopiedAsAnOpenNetwork() throws {
        let device = FakePresetDevice(slots: [:])

        let report = try resultValue(WifiConfigUI.syncSavedWifiPresets(
            savedSSIDs: ["Guest"],
            credentials: [
                "Guest": SavedWiFiCredential(ssid: "Guest", password: "")
            ],
            port: "/dev/fake",
            send: { command, _, _ in device.send(command) }))

        XCTAssertTrue(report.unusable.isEmpty)
        XCTAssertEqual(device.mutations, ["CFGWIFISET 1 R3Vlc3Q= -"])
    }

    /// The 7663fc3 safety, kept: a password the Keychain could not read is
    /// an error, never an open network. `WifiCredentialStore.credential(for:)`
    /// is `read(_:).credential`, which is nil for an unreadable item, so the
    /// sync gets no credential for it, names it as unusable and writes nothing
    /// for it.
    func testAnUnreadablePasswordIsNeverCopiedAsAnOpenNetwork() throws {
        let device = FakePresetDevice(slots: [:])
        let lookups: [String: WifiCredentialStore.Read] = [
            "Office": WifiCredentialStore.decode(
                ssid: "Office", status: errSecInteractionNotAllowed, result: nil),
            "Guest": .saved(SavedWiFiCredential(ssid: "Guest", password: "")),
        ]
        XCTAssertEqual(lookups["Office"], .unreadable)

        let report = try resultValue(WifiConfigUI.syncSavedWifiPresets(
            savedSSIDs: ["Office", "Guest"],
            credentials: lookups.compactMapValues(\.credential),
            port: "/dev/fake",
            send: { command, _, _ in device.send(command) }))

        XCTAssertEqual(report.unusable, ["Office"])
        XCTAssertEqual(device.mutations, ["CFGWIFISET 1 R3Vlc3Q= -"],
            "only the readable open network is written")
    }

    /// How a Keychain answer is read: zero bytes of password data is an open
    /// network; any lookup that did not return data is unreadable.
    func testKeychainAnswersAreReadAsOpenOrUnreadableNeverBoth() {
        func item(_ data: Data?) -> CFTypeRef {
            var item: [String: Any] = [kSecAttrAccount as String: "Guest"]
            item[kSecValueData as String] = data
            return item as CFDictionary
        }
        XCTAssertEqual(
            WifiCredentialStore.decode(
                ssid: "Guest", status: errSecSuccess, result: item(Data())),
            .saved(SavedWiFiCredential(ssid: "Guest", password: "")))
        XCTAssertEqual(
            WifiCredentialStore.decode(
                ssid: "Home", status: errSecSuccess, result: item(Data("pw".utf8))),
            .saved(SavedWiFiCredential(ssid: "Home", password: "pw")))
        XCTAssertEqual(
            WifiCredentialStore.decode(ssid: "Gone", status: errSecItemNotFound, result: nil),
            .notSaved)
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled] {
            XCTAssertEqual(
                WifiCredentialStore.decode(ssid: "Guest", status: status, result: item(Data())),
                .unreadable, "status \(status)")
        }
        XCTAssertEqual(
            WifiCredentialStore.decode(ssid: "Guest", status: errSecSuccess, result: item(nil)),
            .unreadable, "attributes without password data")
        XCTAssertEqual(
            WifiCredentialStore.decode(
                ssid: "Guest", status: errSecSuccess, result: item(Data([0xFF, 0xFE]))),
            .unreadable, "data that is not UTF-8")
        XCTAssertEqual(
            WifiCredentialStore.decode(ssid: "Guest", status: errSecSuccess, result: nil),
            .unreadable)
    }

    // MARK: switching from the display page

    /// Choosing a network copies the saved collection first, so it is in a
    /// slot, and only then chooses that slot - the one CFGWIFIUSE, last.
    func testSwitchingCopiesFirstThenChoosesTheNetworksSlot() throws {
        let device = FakePresetDevice(slots: [1: ("Home", true)], activeSlot: 1)

        let outcome = try resultValue(WifiConfigUI.switchSavedWifiPreset(
            to: "Guest",
            savedSSIDs: ["Home", "Office", "Guest"],
            credentials: [
                "Home": SavedWiFiCredential(ssid: "Home", password: "h"),
                "Office": SavedWiFiCredential(ssid: "Office", password: "o"),
                "Guest": SavedWiFiCredential(ssid: "Guest", password: ""),
            ],
            port: "/dev/fake",
            send: { command, _, _ in device.send(command) }))

        XCTAssertTrue(outcome.restarted)
        XCTAssertEqual(outcome.report.snapshot.slots[3]?.ssid, "Guest")
        let uses = device.commands.filter { $0.hasPrefix("CFGWIFIUSE") }
        XCTAssertEqual(uses, ["CFGWIFIUSE 3"])
        XCTAssertEqual(device.commands.last, "CFGWIFIUSE 3")
        XCTAssertTrue(device.mutations.contains("CFGWIFISET 3 R3Vlc3Q= -"),
            "the open network went in as open: \(device.mutations)")
    }

    /// A board already joined through the chosen network's slot is not
    /// restarted for nothing.
    func testSwitchingToTheActiveNetworkSendsNoChoice() throws {
        let device = FakePresetDevice(slots: [1: ("Home", true)], activeSlot: 1)

        let outcome = try resultValue(WifiConfigUI.switchSavedWifiPreset(
            to: "Home", savedSSIDs: ["Home"],
            credentials: ["Home": SavedWiFiCredential(ssid: "Home", password: "h")],
            port: "/dev/fake",
            send: { command, _, _ in device.send(command) }))

        XCTAssertFalse(outcome.restarted)
        XCTAssertFalse(device.commands.contains { $0.hasPrefix("CFGWIFIUSE") })
    }

    /// A network that could not be copied is not chosen, and the row says why
    /// in words: an unreadable password, or one past the ten slots.
    func testANetworkTheCopyCouldNotPlaceIsNotChosen() throws {
        let device = FakePresetDevice(slots: [:])
        let unreadable = WifiConfigUI.switchSavedWifiPreset(
            to: "Office", savedSSIDs: ["Home", "Office"],
            credentials: ["Home": SavedWiFiCredential(ssid: "Home", password: "h")],
            port: "/dev/fake",
            send: { command, _, _ in device.send(command) })
        guard case .failure(let failure) = unreadable else {
            return XCTFail("an unreadable network was switched to")
        }
        XCTAssertEqual(
            failure.message,
            "The password for \"Office\" could not be read from the Keychain. "
                + "Enter it again in Settings.")

        let eleven = (1...11).map { "net\($0)" }
        let pastTheSlots = WifiConfigUI.switchSavedWifiPreset(
            to: "net11", savedSSIDs: eleven,
            credentials: Dictionary(uniqueKeysWithValues: eleven.map {
                ($0, SavedWiFiCredential(ssid: $0, password: "pw"))
            }),
            port: "/dev/fake",
            send: { command, _, _ in device.send(command) })
        guard case .failure(let failure) = pastTheSlots else {
            return XCTFail("a network past the slots was switched to")
        }
        XCTAssertEqual(
            failure.message,
            "\"net11\" did not fit in this display's slots. "
                + "Drag it higher in Settings.")
        XCTAssertFalse(device.commands.contains { $0.hasPrefix("CFGWIFIUSE") })
    }

    /// The manager's switch: over USB it copies and chooses, and the board is
    /// marked as restarting; the row shows the switch until the board
    /// reports the network.
    func testTheManagerSwitchesAVerifiedBoardAndShowsItRestarting() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        let manager = manager(path: path, saved: ["Home", "Guest"], device: device)
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)
        XCTAssertNil(manager.wifiSwitchUnavailableReason(for: "studio-display"))

        manager.switchWifi(to: "Guest", for: "studio-display")
        guard case .switching("Guest", _)? =
            manager.wifiSwitchState(for: "studio-display", asOf: Date())
        else { return XCTFail("the switch did not show as in progress") }
        try await waitForSyncToSettle(manager)

        let slot = try XCTUnwrap(manager.wifiPresetSyncReport(for: "studio-display")?
            .snapshot.slots.values.first { $0.ssid == "Guest" }?.slot)
        XCTAssertEqual(
            device.commands.filter { $0.hasPrefix("CFGWIFIUSE") }, ["CFGWIFIUSE \(slot)"])
        XCTAssertTrue(manager.usbRestartingServices.contains("studio-display"))
        guard case .switching("Guest", _)? =
            manager.wifiSwitchState(for: "studio-display", asOf: Date())
        else { return XCTFail("the switch stopped showing before the board reported") }
        XCTAssertEqual(
            manager.wifiSwitchUnavailableReason(for: "studio-display"),
            "This display is restarting.")
        // A board that never reports the network stops showing as switching
        // once the wait is over.
        XCTAssertNil(manager.wifiSwitchState(
            for: "studio-display",
            asOf: Date().addingTimeInterval(PanelManager.wifiSwitchPatience + 1)))

        manager.updatePanel("studio-display") { $0.currentSSID = "Guest" }
        XCTAssertNil(manager.wifiSwitchState(for: "studio-display", asOf: Date()))
    }

    /// While a copy holds the board the pop-up is disabled, rather than
    /// taking a choice and leaving an error behind.
    func testThePopUpIsDisabledWhileACopyHoldsTheBoard() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        let manager = manager(path: path, saved: ["Home"], device: device)
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)

        let held = Task<Void, Never> { try? await Task.sleep(nanoseconds: 5_000_000_000) }
        manager.wifiPresetSyncTasks["020000123456"] = held
        XCTAssertEqual(
            manager.wifiSwitchUnavailableReason(for: "studio-display"),
            "Copying the saved networks to this display.")
        held.cancel()
        manager.wifiPresetSyncTasks["020000123456"] = nil
        XCTAssertNil(manager.wifiSwitchUnavailableReason(for: "studio-display"))
    }

    /// A refresh that lets go of the board mid-switch does not hide a choice
    /// that already went out: the board is still shown restarting onto it.
    func testACancelledSwitchWhoseChoiceWentOutStillShowsTheRestart() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        let manager = manager(path: path, saved: ["Home", "Guest"], device: device)
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)

        manager.switchWifi(to: "Guest", for: "studio-display")
        manager.forgetWifiPresetSync(hardwareID: "020000123456")
        try await waitUntil {
            device.commands.contains { $0.hasPrefix("CFGWIFIUSE") }
                && manager.usbRestartingServices.contains("studio-display")
        }
        guard case .switching("Guest", _)? =
            manager.wifiSwitchState(for: "studio-display", asOf: Date())
        else { return XCTFail("the restart the choice caused is not shown") }
    }

    /// Without USB there is no command to send: the network protocol has
    /// none for WiFi. The pop-up says so, and a choice sends nothing.
    func testWithoutUSBTheSwitchIsUnavailableAndSendsNothing() async throws {
        let device = FakePresetDevice(slots: [:])
        let manager = manager(
            path: "/dev/cu.usbmodem-preset-test", saved: ["Home"], device: device)

        XCTAssertEqual(
            manager.wifiSwitchUnavailableReason(for: "studio-display"),
            "Connect this display to the Mac by USB to switch its network. "
                + "Over WiFi the display has no command for it.")
        manager.switchWifi(to: "Home", for: "studio-display")
        try await waitForSyncToSettle(manager)

        XCTAssertTrue(device.commands.isEmpty, device.commands.description)
        XCTAssertEqual(
            manager.wifiSwitchState(for: "studio-display", asOf: Date()),
            .failed(manager.wifiSwitchUnavailableReason(for: "studio-display")!))
    }

    /// A refused choice is shown on the row, and the next choice clears it.
    func testARefusedSwitchIsShownUntilTheNextChoice() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        device.sabotage = .refuseSets
        let manager = manager(path: path, saved: ["Home"], device: device)
        manager.wifiPresetSyncRetryDelays = []
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)

        manager.switchWifi(to: "Home", for: "studio-display")
        try await waitForSyncToSettle(manager)
        guard case .failed(let reason)? =
            manager.wifiSwitchState(for: "studio-display", asOf: Date())
        else { return XCTFail("a refused switch was not shown") }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertFalse(device.commands.contains { $0.hasPrefix("CFGWIFIUSE") })

        device.sabotage = nil
        manager.switchWifi(to: "Home", for: "studio-display")
        if case .failed? = manager.wifiSwitchState(for: "studio-display", asOf: Date()) {
            XCTFail("the next choice left the old error up")
        }
        try await waitForSyncToSettle(manager)
    }

    /// A failed switch's error clears itself once a later copy to the board
    /// goes through - the user does not have to choose again to clear it.
    func testASwitchErrorClearsWhenACopyLaterSucceeds() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        device.sabotage = .refuseSets
        let manager = manager(path: path, saved: ["Home"], device: device)
        manager.wifiPresetSyncRetryDelays = []
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)
        manager.switchWifi(to: "Home", for: "studio-display")
        try await waitForSyncToSettle(manager)
        guard case .failed? = manager.wifiSwitchState(for: "studio-display", asOf: Date())
        else { return XCTFail("the refused switch was not shown") }

        device.sabotage = nil
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)

        XCTAssertNil(manager.wifiSwitchState(for: "studio-display", asOf: Date()))
        XCTAssertFalse(device.commands.contains { $0.hasPrefix("CFGWIFIUSE") })
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

    /// Reordering in Settings moves networks between slots, so every attached
    /// board receives the new order - through the same SET and CLEAR commands.
    func testReorderingInSettingsRecopiesInTheNewOrder() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        let manager = manager(
            path: path, saved: ["alpha", "Bravo"], device: device)
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)

        manager.moveSavedNetwork("Bravo", by: -1)
        try await waitForSyncToSettle(manager)

        let report = try XCTUnwrap(manager.wifiPresetSyncReport(for: "studio-display"))
        XCTAssertEqual(
            (1...2).map { report.snapshot.slots[$0]?.ssid }, ["Bravo", "alpha"])
        XCTAssertTrue(device.mutations.allSatisfy {
            $0.hasPrefix("CFGWIFISET ") || $0.hasPrefix("CFGWIFICLEAR ")
        }, device.mutations.description)
        XCTAssertFalse(device.commands.contains { $0.hasPrefix("CFGWIFIUSE") })
    }

    /// A drag in the Settings list is the same move: the attached board gets
    /// the new order through the same set-before-clear copy, and nothing
    /// activates a preset.
    func testDraggingInSettingsRecopiesInTheNewOrder() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        let manager = manager(
            path: path, saved: ["alpha", "Bravo", "Charlie"], device: device)
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)

        manager.moveSavedNetworks(fromOffsets: [2], toOffset: 0)
        try await waitForSyncToSettle(manager)

        let report = try XCTUnwrap(manager.wifiPresetSyncReport(for: "studio-display"))
        XCTAssertEqual(
            (1...3).map { report.snapshot.slots[$0]?.ssid }, ["Charlie", "alpha", "Bravo"])
        XCTAssertTrue(device.mutations.allSatisfy {
            $0.hasPrefix("CFGWIFISET ") || $0.hasPrefix("CFGWIFICLEAR ")
        }, device.mutations.description)
        XCTAssertFalse(device.commands.contains { $0.hasPrefix("CFGWIFIUSE") })
    }

    /// A new password under the same name is still a change the boards need,
    /// and it is the new password that arrives.
    func testAPasswordChangeInSettingsRecopiesAnUnchangedList() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        let manager = manager(path: path, saved: ["alpha"], device: device)
        manager.useWifiCredentials(InMemoryWifiCredentials([
            SavedWiFiCredential(ssid: "alpha", password: "original"),
        ]))
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)
        XCTAssertEqual(device.mutations.count, 1)

        XCTAssertNil(manager.saveNetwork(
            ssid: "alpha", password: "rotated"))
        try await waitForSyncToSettle(manager)

        XCTAssertEqual(device.mutations.count, 2, device.mutations.description)
        XCTAssertEqual(
            device.mutations.last,
            "CFGWIFISET 1 \(Data("alpha".utf8).base64EncodedString()) "
                + Data("rotated".utf8).base64EncodedString())
    }

    /// An edit that lands while a copy is already running is not lost: the
    /// copy that finishes sees the list moved on and copies again.
    func testAnEditDuringACopyIsCopiedWhenItFinishes() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        let manager = manager(
            path: path, saved: ["alpha", "Bravo"], device: device)
        let gate = DispatchSemaphore(value: 0)
        let first = LockedCounter(0)
        manager.usbControlSender = { command, _, _ in
            first.count()
            if first.total == 1 { gate.wait() }
            return device.send(command)
        }
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitUntil { first.total == 1 }

        manager.moveSavedNetwork("Bravo", by: -1)
        gate.signal()
        try await waitUntil {
            manager.wifiPresetSyncReport(for: "studio-display")?
                .snapshot.slots[1]?.ssid == "Bravo"
        }
        try await waitForSyncToSettle(manager)
        XCTAssertEqual(
            manager.wifiPresetSyncReport(for: "studio-display")?
                .snapshot.slots[2]?.ssid, "alpha")
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

    /// The banner reports a board whose presets could not be copied. Once a
    /// later copy to that board succeeds, it has nothing left to report.
    func testASuccessfulSyncClearsTheEarlierFailureBanner() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        device.sabotage = .refuseSets
        let manager = manager(path: path, saved: ["alpha"], device: device)

        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)
        XCTAssertEqual(manager.issues.map(\.issue), [.wifiPresetSync])

        device.sabotage = nil
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)

        XCTAssertNotNil(manager.wifiPresetSyncReport(for: "studio-display"))
        XCTAssertTrue(manager.issues.isEmpty, manager.issues.description)
    }

    /// A board that answers CFGSHOW and then goes quiet for a few seconds -
    /// still booting after the port opened, or restarted once early on - is
    /// waited for. The copy lands once it answers, with no banner on the way.
    func testABoardThatIsSlowToAnswerAtFirstIsNotReported() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        let manager = manager(path: path, saved: ["alpha"], device: device)
        let silent = LockedCounter(2)
        manager.usbControlSender = { command, _, _ in
            if silent.takeOne() {
                return .failure("no response from the device (is display_stream flashed?)")
            }
            return device.send(command)
        }

        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)

        XCTAssertTrue(manager.issues.isEmpty, manager.issues.description)
        XCTAssertEqual(device.mutations.count, 1, device.commands.description)
        XCTAssertNotNil(manager.wifiPresetSyncReport(for: "studio-display"))
    }

    /// What the banner under "WiFi presets could not be copied" says: which
    /// board, which command and slot, and what the board replied.
    func testAFailedSyncSaysWhichCommandSlotAndReply() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        device.sabotage = .refuseSets
        let manager = manager(path: path, saved: ["alpha"], device: device)

        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)

        let issue = try XCTUnwrap(manager.issues.first)
        XCTAssertEqual(issue.title, "WiFi presets could not be copied")
        XCTAssertTrue(issue.detail.hasPrefix("studio-display: WiFi preset sync stopped."),
                      issue.detail)
        XCTAssertTrue(issue.detail.contains("(CFGWIFISET slot 1) failed: CFGERR device refused the write"),
                      issue.detail)
        XCTAssertFalse(issue.detail.contains(Data("pw-alpha".utf8).base64EncodedString()))
    }

    func testATimedOutReadSaysWhichCommandTimedOut() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let manager = manager(path: path, saved: ["alpha"], device: FakePresetDevice(slots: [:]))
        manager.usbControlSender = { _, _, _ in
            .failure("no response from the device (is display_stream flashed?)")
        }
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)

        let detail = try XCTUnwrap(manager.issues.first?.detail)
        XCTAssertEqual(
            detail,
            "studio-display: Could not read WiFi presets. CFGWIFISHOW on \(path): "
                + "no response from the device (is display_stream flashed?)")
    }

    /// A board that never answers is still reported, once every retry has
    /// been made and failed.
    func testABoardThatNeverAnswersIsReportedAfterEveryRetry() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let manager = manager(path: path, saved: ["alpha"], device: FakePresetDevice(slots: [:]))
        let asked = LockedCounter(0)
        manager.usbControlSender = { _, _, _ in
            asked.count()
            return .failure("no response from the device (is display_stream flashed?)")
        }
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)

        XCTAssertEqual(manager.issues.map(\.issue), [.wifiPresetSync])
        XCTAssertEqual(asked.total, manager.wifiPresetSyncRetryDelays.count + 1)
    }

    /// A board unplugged while it waits for a retry is not reported: nothing
    /// is known about it until it answers again.
    func testABoardUnpluggedDuringItsRetryWaitIsNotReported() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let manager = manager(path: path, saved: ["alpha"], device: FakePresetDevice(slots: [:]))
        manager.wifiPresetSyncRetryDelays = [0.3]
        let asked = LockedCounter(0)
        manager.usbControlSender = { _, _, _ in
            asked.count()
            return .failure("no response from the device (is display_stream flashed?)")
        }
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        // The first attempt is over and the retry is waiting.
        try await waitUntil { asked.total == 1 }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNotNil(manager.wifiPresetSyncTasks["020000123456"])

        manager.updateUSBPorts([])
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(asked.total, 1)
        XCTAssertTrue(manager.wifiPresetSyncTasks.isEmpty)
        XCTAssertTrue(manager.issues.isEmpty, manager.issues.description)
    }

    /// A refused write is the board's answer, not silence: it is reported at
    /// once, without the retries a booting board gets.
    func testARefusalIsReportedWithoutRetrying() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        device.sabotage = .refuseSets
        let manager = manager(path: path, saved: ["alpha"], device: device)
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)

        XCTAssertEqual(manager.issues.map(\.issue), [.wifiPresetSync])
        XCTAssertEqual(device.mutations.count, 1, device.mutations.description)
        XCTAssertTrue(manager.wifiPresetSyncRechecks.isEmpty)
    }

    /// Deleting every saved network while a copy is still running leaves the
    /// board with nothing it should hold, so that copy failing afterwards is
    /// no failure to report; nothing would ever clear the banner otherwise.
    func testACopyFailingAfterEveryNetworkIsDeletedIsNotReported() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        device.sabotage = .refuseSets
        let manager = manager(path: path, saved: ["alpha"], device: device)
        let writing = LockedCounter(0)
        manager.usbControlSender = { command, _, _ in
            if command.hasPrefix("CFGWIFISET ") {
                writing.count()
                Thread.sleep(forTimeInterval: 0.2)
            }
            return device.send(command)
        }
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitUntil { writing.total == 1 }

        manager.savedNetworkNames = []
        manager.syncWifiPresetsToAttachedDevices()
        try await waitForSyncToSettle(manager)

        XCTAssertEqual(device.mutations.count, 1, device.mutations.description)
        XCTAssertTrue(manager.issues.isEmpty, manager.issues.description)
    }

    /// A board still attached after its silence was reported is tried again
    /// later, and the banner clears once it answers - no replug needed.
    func testABoardThatComesGoodAfterTheReportClearsItsBanner() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        let manager = manager(path: path, saved: ["alpha"], device: device)
        manager.wifiPresetSyncRecheckInterval = 0.05
        let silent = LockedCounter(3)
        manager.usbControlSender = { command, _, _ in
            if silent.takeOne() {
                return .failure("no response from the device (is display_stream flashed?)")
            }
            return device.send(command)
        }
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)
        XCTAssertEqual(manager.issues.map(\.issue), [.wifiPresetSync])

        try await waitUntil { manager.issues.isEmpty }
        XCTAssertNotNil(manager.wifiPresetSyncReport(for: "studio-display"))
        XCTAssertTrue(manager.wifiPresetSyncRechecks.isEmpty)
    }

    /// Removing a display's record withdraws its part of the banner; nothing
    /// could ever clear it otherwise.
    func testForgettingTheRecordWithdrawsItsBanner() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        device.sabotage = .refuseSets
        let manager = manager(path: path, saved: ["alpha"], device: device)
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)
        XCTAssertEqual(manager.issues.map(\.issue), [.wifiPresetSync])

        manager.forget("studio-display")

        XCTAssertTrue(manager.issues.isEmpty, manager.issues.description)
    }

    /// While a repair holds USB probes off, a retry waits instead of talking
    /// over it, and goes ahead once the repair is done.
    func testARetryWaitsWhileARepairHasTheBoard() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        let manager = manager(path: path, saved: ["alpha"], device: device)
        manager.wifiPresetSyncRetryDelays = [0.2]
        let asked = LockedCounter(0)
        manager.usbControlSender = { command, _, _ in
            asked.count()
            if asked.total == 1 {
                return .failure("no response from the device (is display_stream flashed?)")
            }
            return device.send(command)
        }
        manager.usbProbeHolds = 1
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(asked.total, 0, "a new sync is held off while the repair has the board")

        // Released: the next CFGSHOW answer syncs, and the board is silent.
        // The repair takes the board again before the retry comes.
        manager.usbProbeHolds = 0
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitUntil { asked.total == 1 }
        manager.usbProbeHolds = 1
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(asked.total, 1, "the retry waits while the repair has the board")
        XCTAssertNotNil(manager.wifiPresetSyncTasks["020000123456"])

        manager.usbProbeHolds = 0
        try await waitUntil { manager.wifiPresetSyncReport(for: "studio-display") != nil }
        XCTAssertEqual(device.mutations.count, 1, device.commands.description)
        XCTAssertTrue(manager.issues.isEmpty, manager.issues.description)
    }

    /// The rescue image answers CFGSHOW with an identity and nothing else. It is
    /// waited out - no command, no banner - and the stream firmware's first
    /// CFGSHOW brings the sync.
    func testTheRescueImageIsWaitedForNotReported() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        let manager = manager(path: path, saved: ["alpha"], device: device)

        manager.noteUSBIdentity(
            path: path, identity: Self.rescueIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)
        XCTAssertTrue(device.commands.isEmpty, device.commands.description)
        XCTAssertTrue(manager.issues.isEmpty, manager.issues.description)

        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)
        XCTAssertEqual(device.mutations.count, 1)
        XCTAssertNotNil(manager.wifiPresetSyncReport(for: "studio-display"))
    }

    /// While a USB flash owns the board, a CFGSHOW answer does not start a
    /// sync; the run's end re-probes, and the fresh answer does.
    func testAFlashInFlightHoldsTheSyncUntilItEnds() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        let manager = manager(path: path, saved: ["alpha"], device: device)
        answerReprobes(manager, with: Self.verifiedIdentity)

        manager.beginUSBFlash(hardwareID: "02:00:00:12:34:56")
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)
        XCTAssertTrue(device.commands.isEmpty, device.commands.description)

        manager.finishUSBFlash(hardwareID: "020000123456", wroteFlash: true)
        try await waitForSyncToSettle(manager)
        XCTAssertEqual(device.mutations.count, 1)
        XCTAssertTrue(manager.issues.isEmpty, manager.issues.description)
    }

    /// The run's own settle never updates the device list, so what it said
    /// before the flash is not trusted after it: a board that does not answer
    /// the re-probe gets no sync and no banner.
    func testTheRunsEndDoesNotSyncOnPreFlashVerification() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        let manager = manager(path: path, saved: ["alpha"], device: device)
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)
        let before = device.commands.count

        manager.beginUSBFlash(hardwareID: "020000123456")
        manager.finishUSBFlash(hardwareID: "020000123456", wroteFlash: true)
        try await waitForSyncToSettle(manager)
        XCTAssertEqual(device.commands.count, before, device.commands.description)
        XCTAssertTrue(manager.issues.isEmpty, manager.issues.description)
        XCTAssertNil(manager.verifiedUSBDevice(for: "studio-display"))
    }

    /// A sync already running when a run starts fails against a board being
    /// reset. It is not reported, and when the run is over before it is, the
    /// sync is tried again rather than lost.
    func testASyncOverlappingAWholeRunIsDiscardedAndRetried() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        let manager = manager(path: path, saved: ["alpha"], device: device)
        answerReprobes(manager, with: Self.verifiedIdentity)
        let gate = DispatchSemaphore(value: 0)
        let first = LockedFlag()
        manager.usbControlSender = { command, _, _ in
            if first.takeFirst() {
                gate.wait()
                return .failure("no response from the device (is display_stream flashed?)")
            }
            return device.send(command)
        }
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        XCTAssertFalse(manager.wifiPresetSyncTasks.isEmpty)

        manager.beginUSBFlash(hardwareID: "020000123456")
        manager.finishUSBFlash(hardwareID: "020000123456", wroteFlash: true)
        // Let the re-probe land while the stale sync is still registered.
        try await Task.sleep(nanoseconds: 30_000_000)
        gate.signal()
        try await waitForSyncToSettle(manager)
        try await waitForSyncToSettle(manager)

        XCTAssertTrue(manager.issues.isEmpty, manager.issues.description)
        XCTAssertEqual(device.mutations.count, 1)
        XCTAssertNotNil(manager.wifiPresetSyncReport(for: "studio-display"))
    }

    /// Two runs on one board: the first one ending does not release the second.
    func testASecondRunKeepsItsHoldWhenTheFirstEnds() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        let manager = manager(path: path, saved: ["alpha"], device: device)
        answerReprobes(manager, with: Self.verifiedIdentity)

        manager.beginUSBFlash(hardwareID: "020000123456")
        manager.beginUSBFlash(hardwareID: "020000123456")
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        manager.finishUSBFlash(hardwareID: "020000123456", wroteFlash: true)
        try await waitForSyncToSettle(manager)
        XCTAssertTrue(device.commands.isEmpty, device.commands.description)

        manager.finishUSBFlash(hardwareID: "020000123456", wroteFlash: true)
        try await waitForSyncToSettle(manager)
        XCTAssertEqual(device.mutations.count, 1)
    }

    /// A run that stopped at a check wrote nothing; the collection is not
    /// rewritten for it. One that wrote flash gets it again.
    func testOnlyARunThatWroteFlashRewritesTheCollection() async throws {
        let path = "/dev/cu.usbmodem-preset-test"
        let device = FakePresetDevice(slots: [:])
        let manager = manager(path: path, saved: ["alpha"], device: device)
        answerReprobes(manager, with: Self.verifiedIdentity)
        manager.noteUSBIdentity(
            path: path, identity: Self.verifiedIdentity,
            generation: manager.usbPathGeneration(path))
        try await waitForSyncToSettle(manager)
        XCTAssertEqual(device.mutations.count, 1)

        manager.beginUSBFlash(hardwareID: "020000123456")
        manager.finishUSBFlash(hardwareID: "020000123456", wroteFlash: false)
        try await waitForSyncToSettle(manager)
        XCTAssertEqual(device.mutations.count, 1)

        manager.beginUSBFlash(hardwareID: "020000123456")
        manager.finishUSBFlash(hardwareID: "020000123456", wroteFlash: true)
        try await waitForSyncToSettle(manager)
        XCTAssertEqual(device.mutations.count, 2)
    }

    /// A 1.5.0 build from before the serial fix can lose `fw=` - its last token -
    /// to a 256-byte cut. `ssid64=` is its first and still marks the stream
    /// firmware; the rescue image sends neither.
    func testStreamFirmwareIsRecognisedWithoutItsTruncatedVersion() {
        let truncated = WifiConfigUI.usbIdentity(from:
            "CFGINFO ssid64= name64=c3R1ZGlvLWRpc3BsYXk= id=020000123456 connected=0")
        XCTAssertTrue(PanelManager.runsStreamFirmware(truncated.status))
        XCTAssertTrue(PanelManager.runsStreamFirmware(Self.verifiedIdentity.status))
        XCTAssertFalse(PanelManager.runsStreamFirmware(Self.rescueIdentity.status))
        XCTAssertFalse(PanelManager.runsStreamFirmware(nil))
    }

    // MARK: helpers

    /// Verbatim shape of firmware/rescue/rescue.ino's reportIdentity().
    private static let rescueIdentity = WifiConfigUI.usbIdentity(from:
        "CFGINFO id=020000123456 board=st77916 profile=st77916 target=s3-185 "
            + "chip=esp32s3 partition=8MB")

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
        panel.usbHardwareID = "020000123456"
        let manager = PanelManager(
            previewPanels: [panel],
            savedNetworkNames: saved,
            usbSerialPorts: [path])
        manager.usbControlSender = { command, port, timeout in
            device.send(command)
        }
        manager.usbControlReprobe = { _, _ in }
        // Two quick retries, so a failure is still reported within a settle.
        manager.wifiPresetSyncRetryDelays = [0.01, 0.01]
        manager.wifiCredentialLookup = { ssid in
            SavedWiFiCredential(ssid: ssid, password: "pw-\(ssid)")
        }
        return manager
    }

    /// What the run's-end re-probe hears: a fresh CFGSHOW from this identity.
    @MainActor
    private func answerReprobes(
        _ manager: PanelManager, with identity: WifiConfigUI.USBIdentity
    ) {
        manager.usbControlReprobe = { [weak manager] path, _ in
            guard let manager else { return }
            manager.noteUSBIdentity(
                path: path, identity: identity,
                generation: manager.usbPathGeneration(path))
        }
    }

    @MainActor
    private func waitForSyncToSettle(
        _ manager: PanelManager, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        // A hop first, so a re-probe Task scheduled just before has run.
        try await Task.sleep(nanoseconds: 10_000_000)
        var settled = false
        for _ in 0..<400 {
            if manager.wifiPresetSyncTasks.isEmpty { settled = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(settled, "a preset sync never finished", file: file, line: line)
        // One more hop so the completion handler's main-actor work is applied.
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    @MainActor
    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition never became true", file: file, line: line)
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
                // What `sendCommand` returns for a refusal: the CFGERR line.
                return .failure("CFGERR device refused the write")
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
        if command.hasPrefix("CFGWIFIUSE "),
           let slot = Int(command.dropFirst("CFGWIFIUSE ".count)) {
            guard storage[slot] != nil else {
                return .failure("CFGERR wifi slot=\(slot) unavailable")
            }
            active = slot
            return .success("CFGOK wifi slot=\(slot) selected")
        }
        return .failure("unexpected command")
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    /// True exactly once.
    func takeFirst() -> Bool {
        lock.withLock {
            defer { taken = true }
            return !taken
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var counted = 0
    init(_ count: Int) { remaining = count }
    /// True for the first `count` calls, then false.
    func takeOne() -> Bool {
        lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }
    func count() { lock.withLock { counted += 1 } }
    var total: Int { lock.withLock { counted } }
}
