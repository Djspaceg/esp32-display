import AppKit
import Combine
import SwiftUI
import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// The WiFi networks moved off the display pages and into the Settings window.
///
/// Each view is read as the value SwiftUI is handed - every string it carries
/// and every button, with the action that button runs (`ViewReading`) - so a
/// display page, the Add Display sheet and Settings can be checked for which
/// controls they offer, and those controls pressed, without a window, a
/// screen or a board. Serial I/O is off and the networks are in memory, never
/// the Keychain.
@MainActor
final class SettingsWindowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    // MARK: the display page

    /// The section reads, top down: the WiFi pop-up with its link to
    /// Settings, the address, the signal. The rows that explained presets and
    /// copies are gone, and the pop-up offers the saved networks by name.
    func testTheDisplayPageOffersTheSavedNetworksAboveAddressAndSignal() throws {
        let (manager, panel) = makeManager(saved: ["Studio WiFi", "Guest"])
        let page = ViewReading(PanelDetailView(panel: panel, manager: manager))

        let strings = page.strings
        let section = try XCTUnwrap(strings.firstIndex(of: "Network Connection"))
        let wifi = try XCTUnwrap(strings.firstIndex(of: "WiFi"))
        let address = try XCTUnwrap(strings.firstIndex(of: "Address"))
        let signal = try XCTUnwrap(strings.firstIndex(of: "Signal strength"))
        XCTAssertTrue(section < wifi && wifi < address && address < signal,
            "the rows are not WiFi, Address, Signal strength in that order")
        XCTAssertTrue(strings.contains("Studio WiFi") && strings.contains("Guest"),
            "the pop-up does not offer the saved networks")
        XCTAssertTrue(page.contains("SwiftUI.Picker"))
        XCTAssertNotNil(page.button("WiFi Settings…"), "the row keeps its link to Settings")
        for gone in ["WiFi preset", "Could not copy", "Connected WiFi", "WiFi signal"] {
            XCTAssertFalse(strings.contains(gone), "\"\(gone)\" is still on the display page")
        }
        for gone in ["Apply", "Manage…", "Copy Now", "Add Network…", "Edit…", "Remove"] {
            XCTAssertNil(page.button(gone), "\"\(gone)\" is still on the display page")
        }
        XCTAssertFalse(page.contains("SwiftUI.SecureField"))
    }

    /// Pressing the row's link asks for the Settings window at WiFi Networks.
    func testTheDisplayPageLinkOpensSettingsAtWifiNetworks() throws {
        let (manager, panel) = makeManager(saved: ["Studio WiFi"])
        let link = try XCTUnwrap(
            ViewReading(PanelDetailView(panel: panel, manager: manager))
                .button("WiFi Settings…"))
        XCTAssertEqual(opened { link.press() }, [.wifiNetworks])
    }

    /// Onboarding only chooses one of the saved networks. Nothing in it types
    /// a network or a password, and it links to Settings to add one.
    func testOnboardingChoosesASavedNetworkAndAddsNoneOfItsOwn() throws {
        for saved in [[], ["Studio WiFi"]] {
            let (manager, _) = makeManager(saved: saved)
            let sheet = ViewReading(AddDeviceSheet(manager: manager))
            XCTAssertTrue(sheet.strings.contains("WiFi"), "the reading missed the WiFi section")
            XCTAssertFalse(sheet.strings.contains("Network name (SSID)"))
            XCTAssertFalse(sheet.strings.contains("Type a network…"))
            XCTAssertFalse(sheet.strings.contains("Open network (no password)"))
            XCTAssertFalse(sheet.contains("SwiftUI.SecureField"))
            let title = saved.isEmpty ? "Add a Network in Settings…" : "WiFi Settings…"
            let link = try XCTUnwrap(sheet.button(title), "no \"\(title)\" link")
            XCTAssertEqual(opened { link.press() }, [.wifiNetworks])
        }
    }

    /// The pop-up selects the board's own network. A network this Mac has not
    /// saved, or none reported, is shown as an item of its own so the pop-up
    /// still says where the board is.
    func testThePopUpSelectsTheBoardsNetwork() {
        func model(_ current: String?, _ description: String) -> WifiNetworkRows.Model {
            WifiNetworkRows.model(
                current: current, currentDescription: description,
                savedNetworks: ["Home", "Guest"], report: nil, switchState: nil,
                unavailableReason: nil)
        }
        XCTAssertEqual(model("Guest", "Guest").selection, "Guest")
        XCTAssertNil(model("Guest", "Guest").unsavedItem)
        XCTAssertEqual(
            model("Neighbours", "Neighbours").unsavedItem,
            "Neighbours (not saved)")
        XCTAssertEqual(
            model("Home", "Not answering (set to \"Home\")").selection, "Home")
        XCTAssertEqual(
            model("Home", "Not answering (set to \"Home\")").statusNote,
            "Not answering (set to \"Home\")",
            "the pop-up shows only the name, so the rest is said under it")
        XCTAssertNil(model("Guest", "Guest").statusNote)
        XCTAssertNil(model("Guest", "Guest").disabledNote, "an enabled pop-up says nothing")
        XCTAssertNil(model(nil, "Unknown (not reported yet)").selection)
        XCTAssertEqual(
            model(nil, "Unknown (not reported yet)").unsavedItem,
            "Unknown (not reported yet)")
    }

    /// A switch in flight selects the network it is going to; a failed one is
    /// the row's error; with neither, the error is a network the last copy
    /// could not read, and an empty password is never one.
    func testTheRowShowsASwitchAndItsError() {
        let report = unreadableReport(unusable: ["Office"])
        func model(_ state: WifiSwitchState?) -> WifiNetworkRows.Model {
            WifiNetworkRows.model(
                current: "Home", currentDescription: "Home",
                savedNetworks: ["Home", "Office", "Guest"], report: report,
                switchState: state, unavailableReason: nil)
        }
        let unavailable = WifiNetworkRows.model(
            current: "Home", currentDescription: "Home",
            savedNetworks: ["Home"], report: nil, switchState: nil,
            unavailableReason: "Connect this device to the Mac by USB.")
        XCTAssertEqual(
            unavailable.disabledNote, "Connect this device to the Mac by USB.",
            "a disabled pop-up says why on the row, not only in a tooltip")
        XCTAssertEqual(
            WifiNetworkRows.model(
                current: nil, currentDescription: "Unknown", savedNetworks: [],
                report: nil, switchState: nil, unavailableReason: nil).disabledNote,
            "No networks are saved on this Mac yet.")
        XCTAssertNil(model(.switching("Guest", since: Date())).disabledNote)
        let switching = model(.switching("Guest", since: Date()))
        XCTAssertEqual(switching.selection, "Guest")
        XCTAssertNil(switching.problem)
        XCTAssertEqual(model(.failed("The device refused it.")).problem,
            "The device refused it.")
        XCTAssertEqual(
            model(nil).problem,
            "The password for \"Office\" could not be read from the Keychain, "
                + "so it is not on this device. Enter it again in Settings.")
        XCTAssertNil(WifiNetworkRows.model(
            current: "Home", currentDescription: "Home",
            savedNetworks: ["Home", "Guest"],
            report: unreadableReport(unusable: []), switchState: nil,
            unavailableReason: nil).problem,
            "an open network is not a copy problem")
    }

    private func unreadableReport(
        unusable: [String], omitted: [String] = [], onBoard: [Int: String] = [1: "Home"]
    ) -> WifiPresetSyncReport {
        WifiPresetSyncReport(
            snapshot: WifiPresetSnapshot(
                roster: ConfigCommands.WiFiPresetRoster(
                    capacity: 10, validSlots: Set(onBoard.keys),
                    activeSlot: onBoard.keys.min(), localSelectorAvailable: true),
                slots: Dictionary(uniqueKeysWithValues: onBoard.map { slot, ssid in
                    (slot, ConfigCommands.WiFiPresetSlot(
                        slot: slot, ssid: ssid, hasPassword: true,
                        active: slot == onBoard.keys.min()))
                })),
            omitted: omitted, unusable: unusable, commandCount: 0)
    }

    /// The error names the networks whose password could not be read. One
    /// merely past the tenth slot is not an error.
    func testTheErrorNamesNetworksWhosePasswordCouldNotBeRead() {
        let saved = ["Home", "Office", "Guest", "Lab", "Eleventh"]
        func row(_ report: WifiPresetSyncReport?) -> String? {
            WifiNetworkRows.unreadableDescription(report, savedNetworkNames: saved)
        }
        XCTAssertNil(row(nil))
        XCTAssertNil(row(unreadableReport(unusable: [])))
        XCTAssertNil(row(unreadableReport(unusable: [], omitted: ["Eleventh"])))
        XCTAssertEqual(
            row(unreadableReport(unusable: ["Office", "Guest", "Lab"])),
            "The passwords for \"Office\", \"Guest\" and \"Lab\" could not be "
                + "read from the Keychain, so they are not on this device. Enter "
                + "them again in Settings.")
    }

    /// The report is only replaced by the next USB copy, so the error checks
    /// it against now: a network no longer saved is not named, and neither is
    /// one the board still holds.
    func testTheErrorLeavesOutWhatNoLongerApplies() {
        let report = unreadableReport(
            unusable: ["Office", "Guest"], onBoard: [1: "Home", 3: "Guest"])
        XCTAssertEqual(
            WifiNetworkRows.unreadableDescription(
                report, savedNetworkNames: ["Home", "Office", "Guest"]),
            "The password for \"Office\" could not be read from the Keychain, "
                + "so it is not on this device. Enter it again in Settings.")
        XCTAssertNil(WifiNetworkRows.unreadableDescription(
            report, savedNetworkNames: ["Home", "Guest"]))
    }

    /// Entering the network again is what the error asks for, so saving it
    /// clears the error at once, with no board attached to copy to.
    func testSavingASkippedNetworkTakesItOffTheRow() {
        let (manager, panel) = makeManager(saved: ["Home", "Office", "Guest"])
        manager.wifiPresetSyncReports["020000123456"] =
            unreadableReport(unusable: ["Office", "Guest"])
        XCTAssertNil(manager.saveNetwork(
            ssid: "Office", password: "new password"))
        XCTAssertEqual(
            manager.wifiPresetSyncReport(for: panel.serviceName)?.unusable,
            ["Guest"])
    }

    // MARK: the Settings window

    /// The WiFi Networks pane is where a network is added, edited, removed and
    /// moved between slots.
    func testSettingsOwnsAddEditRemoveAndReorder() throws {
        let (manager, _) = makeManager(saved: ["Studio WiFi", "Guest", "Home"])
        let navigation = SettingsNavigation()
        navigation.show(.wifiNetworks)
        let pane = ViewReading(SettingsView(manager: manager, navigation: navigation))

        for control in ["Add Network…", "Remove"] {
            XCTAssertNotNil(pane.button(control), "Settings has no \"\(control)\"")
        }
        // The rows, their slots and their pencils are the table's; see
        // testEachRowHasOnlyAnEditButtonAndTheFooterAddsAndRemoves.
        XCTAssertTrue(pane.contains("SenderCore.WifiNetworkTable"))
        for section in SettingsPane.allCases {
            XCTAssertTrue(
                pane.strings.contains(section.title),
                "the sidebar does not list \(section.title)")
        }
        XCTAssertEqual(pane.networkTables.count, 1, "the rows are not draggable")
    }

    // MARK: the saved-network list

    /// A plus and a minus under the list, and no per-row arrows or remove
    /// buttons. Each row's only button is its pencil, drawn by the table.
    func testEachRowHasOnlyAnEditButtonAndTheFooterAddsAndRemoves() {
        let (manager, _) = makeManager(saved: ["Studio WiFi", "Guest", "Home"])
        let section = ViewReading(WifiNetworksSection(manager: manager))
        XCTAssertEqual(section.buttons.filter { $0.title == "Remove" }.count, 1)
        XCTAssertEqual(section.buttons.filter { $0.title == "Add Network…" }.count, 1)
        XCTAssertNil(section.button("Move Up"))
        XCTAssertNil(section.button("Move Down"))
        XCTAssertNil(section.button("Edit…"))
        XCTAssertTrue(section.contains("SenderCore.WifiNetworkTable"))

        let (table, coordinator) = makeTable(["Studio WiFi", "Guest", "Home"])
        XCTAssertEqual(table.numberOfRows, 3)
        var edited: [String] = []
        coordinator.onEdit = { edited.append($0) }
        for row in 0..<3 {
            let cell = try? XCTUnwrap(coordinator.tableView(
                table, viewFor: table.tableColumns.first, row: row) as? NetworkCell)
            let buttons = cell.map(Self.buttons(in:)) ?? []
            XCTAssertEqual(buttons.count, 1, "row \(row) has other buttons")
            XCTAssertEqual(cell?.slotLabel.stringValue, "Slot \(row + 1)")
            buttons.first?.performClick(nil)
        }
        XCTAssertEqual(edited, ["Studio WiFi", "Guest", "Home"])
    }

    // MARK: drag-and-drop reorder

    /// Every direction: down, up, the first row to the end, the last row to
    /// the top, and a drop where the row already is.
    func testTheReorderModelMovesUpDownFirstAndLast() {
        let names = ["a", "b", "c", "d"]
        func drop(_ row: Int, into gap: Int) -> [String] {
            WifiNetworkReorder.reordered(names, dragging: [row], to: gap)
        }
        XCTAssertEqual(drop(1, into: 3), ["a", "c", "b", "d"], "down one")
        XCTAssertEqual(drop(2, into: 1), ["a", "c", "b", "d"], "up one")
        XCTAssertEqual(drop(0, into: 4), ["b", "c", "d", "a"], "first to the end")
        XCTAssertEqual(drop(0, into: 2), ["b", "a", "c", "d"], "first down")
        XCTAssertEqual(drop(3, into: 0), ["d", "a", "b", "c"], "last to the top")
        XCTAssertEqual(drop(3, into: 2), ["a", "b", "d", "c"], "last up one")
        XCTAssertEqual(drop(1, into: 0), ["b", "a", "c", "d"], "to the top")
        for row in 0..<4 {
            XCTAssertEqual(drop(row, into: row), names, "onto its own gap above")
            XCTAssertEqual(drop(row, into: row + 1), names, "onto its own gap below")
        }
    }

    /// A drop "on" a row is turned into the gap above or below it, so the
    /// indicator shows a line at every pointer position rather than vanishing
    /// over each row's middle - the flicker - and every gap stays reachable.
    func testADropOnARowBecomesTheGapNearestThePointer() {
        func gap(_ row: Int, _ op: NSTableView.DropOperation, lower: Bool = false) -> Int {
            WifiNetworkReorder.retargeted(
                row: row, dropOperation: op, lowerHalf: lower, rowCount: 4)
        }
        XCTAssertEqual(gap(0, .on), 0, "upper half of the first row: the top")
        XCTAssertEqual(gap(0, .on, lower: true), 1)
        XCTAssertEqual(gap(3, .on), 3)
        XCTAssertEqual(gap(3, .on, lower: true), 4, "lower half of the last row: the end")
        XCTAssertEqual(gap(2, .above), 2)
        XCTAssertEqual(gap(4, .above), 4)
        XCTAssertEqual(gap(9, .above), 4, "clamped to the end")
        XCTAssertEqual(gap(-1, .above), 0, "clamped to the top")
    }

    /// What the table does on a drop, through to the shared order, in both
    /// directions and at both ends.
    func testADropReordersTheSavedNetworksUpAndDown() {
        let (manager, _) = makeManager(saved: ["a", "b", "c", "d"])
        let list = WifiNetworkList(manager: manager)
        let (_, coordinator) = makeTable(manager.savedNetworkNames)
        coordinator.onMove = { list.move(fromOffsets: $0, toOffset: $1) }

        coordinator.performDrop(rows: [3], to: 0)
        XCTAssertEqual(manager.savedNetworkNames, ["d", "a", "b", "c"], "last to the top")
        coordinator.performDrop(rows: [0], to: 4)
        XCTAssertEqual(manager.savedNetworkNames, ["a", "b", "c", "d"], "first to the end")
        coordinator.performDrop(rows: [2], to: 1)
        XCTAssertEqual(manager.savedNetworkNames, ["a", "c", "b", "d"], "up")
        coordinator.performDrop(rows: [1], to: 3)
        XCTAssertEqual(manager.savedNetworkNames, ["a", "b", "c", "d"], "down")
        XCTAssertEqual(manager.settings.wifiPresetOrder, ["a", "b", "c", "d"])
    }

    /// While a drag is under way the rows are not rebuilt, even when the list
    /// changes; the change is shown once the drag ends. Rebuilding the rows
    /// under the pointer is what made the drop indicator flicker.
    func testTheRowsAreNotRebuiltWhileADragIsUnderWay() {
        let (table, coordinator) = makeTable(["a", "b", "c"])
        let before = coordinator.reloadCount
        coordinator.beginDrag()
        coordinator.apply(.init(
            rows: ["c", "a", "b"].map { .init(ssid: $0, isOpen: false) },
            selection: nil, editingDisabled: false))
        XCTAssertEqual(coordinator.reloadCount, before)
        XCTAssertEqual(coordinator.state.rows.map(\.ssid), ["a", "b", "c"])
        coordinator.endDrag()
        XCTAssertEqual(coordinator.reloadCount, before + 1)
        XCTAssertEqual(coordinator.state.rows.map(\.ssid), ["c", "a", "b"])
        XCTAssertEqual(table.numberOfRows, 3)
        // An unchanged list does not rebuild either.
        coordinator.apply(coordinator.state)
        XCTAssertEqual(coordinator.reloadCount, before + 1)
    }

    /// Selecting a row reports it, and the Delete key asks to remove it.
    func testSelectingARowAndTheDeleteKey() throws {
        let (table, coordinator) = makeTable(["a", "b", "c"])
        var selected: [String?] = []
        var deletes = 0
        coordinator.onSelect = { selected.append($0) }
        coordinator.onDelete = { deletes += 1 }
        table.selectRowIndexes([1], byExtendingSelection: false)
        XCTAssertEqual(selected, ["b"])
        // Matching the table to a selection made elsewhere is not reported.
        coordinator.apply(.init(
            rows: coordinator.state.rows, selection: "c", editingDisabled: false))
        XCTAssertEqual(table.selectedRow, 2)
        XCTAssertEqual(selected, ["b"])

        let delete = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{7f}",
            charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
        table.keyDown(with: delete)
        XCTAssertEqual(deletes, 1)
    }

    // MARK: the network form

    /// The form is a section of its own below the list, with no "open
    /// network" switch: an empty password is an open network.
    func testTheFormIsItsOwnSectionWithNoOpenNetworkSwitch() {
        let (manager, _) = makeManager(saved: ["Studio WiFi", "Office"])
        let closed = ViewReading(WifiNetworksSection(manager: manager))
        XCTAssertFalse(closed.strings.contains("Network Details"))

        let editing = ViewReading(WifiNetworksSection(
            manager: manager,
            editing: .init(original: "Office", ssid: "Office", password: "pw")))
        XCTAssertTrue(editing.strings.contains("Network Details"))
        XCTAssertTrue(editing.strings.contains("Saved Networks"))
        XCTAssertGreaterThanOrEqual(
            editing.typeNames.filter { $0.hasPrefix("SwiftUI.Section<") }.count, 2,
            "the form is not a section of its own")
        XCTAssertFalse(editing.strings.contains("Open network (no password)"))
        XCTAssertFalse(editing.contains("SwiftUI.Toggle"))
        XCTAssertNotNil(editing.button("Save"))

        let adding = ViewReading(WifiNetworksSection(
            manager: manager, editing: .init(original: nil)))
        XCTAssertTrue(adding.strings.contains("New Network"))
        XCTAssertTrue(adding.strings.contains(
            "With no password, this is saved as an open network."))
        XCTAssertNotNil(adding.button("Add"))
    }

    /// A network whose saved password cannot be read is not shown as open:
    /// the form says it could not be read.
    func testEditingAnUnreadablePasswordSaysSo() {
        let (manager, _) = makeManager(saved: ["Office"])
        let reading = ViewReading(WifiNetworksSection(
            manager: manager,
            editing: .init(original: "Office", ssid: "Office", passwordUnreadable: true)))
        XCTAssertTrue(reading.strings.contains { $0.contains("could not be read") })
        XCTAssertFalse(reading.strings.contains(
            "With no password, this is saved as an open network."))
    }

    /// The edit form fills in a readable password, shows an open network's
    /// empty one, and marks one that could not be read - which an empty field
    /// can then never save as open.
    func testTheEditFormFromEachKindOfSavedCredential() {
        let secured = WifiNetworksSection.editor(
            for: "Home", saved: SavedWiFiCredential(ssid: "Home", password: "pw"))
        XCTAssertEqual(secured.password, "pw")
        XCTAssertFalse(secured.passwordUnreadable)
        XCTAssertTrue(WifiNetworksSection.canCommit(secured))

        let open = WifiNetworksSection.editor(
            for: "Guest", saved: SavedWiFiCredential(ssid: "Guest", password: ""))
        XCTAssertEqual(open.password, "")
        XCTAssertFalse(open.passwordUnreadable)
        XCTAssertTrue(WifiNetworksSection.canCommit(open), "an open network saves as open")

        var unreadable = WifiNetworksSection.editor(for: "Office", saved: nil)
        XCTAssertTrue(unreadable.passwordUnreadable)
        XCTAssertEqual(unreadable.password, "")
        XCTAssertFalse(
            WifiNetworksSection.canCommit(unreadable),
            "an unreadable password must not save as an open network")
        unreadable.password = "typed again"
        XCTAssertTrue(WifiNetworksSection.canCommit(unreadable))
    }

    /// The drop handler as the table calls it: the pasteboard names the
    /// dragged network, and the drop is refused when the list changed under
    /// the drag, so a stale row never moves a different network.
    func testTheTablesDropHandlerReadsNamesAndRefusesAStaleList() throws {
        let (table, coordinator) = makeTable(["a", "b", "c", "d"])
        var moves: [(IndexSet, Int)] = []
        coordinator.onMove = { moves.append(($0, $1)) }

        let item = try XCTUnwrap(coordinator.tableView(table, pasteboardWriterForRow: 3)
            as? NSPasteboardItem)
        XCTAssertEqual(item.string(forType: WifiNetworkTable.Coordinator.rowType), "d")
        let pasteboard = NSPasteboard(name: .init("wifi-table-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let info = FakeDraggingInfo(source: table, pasteboard: pasteboard)

        XCTAssertTrue(coordinator.tableView(
            table, acceptDrop: info, row: 0, dropOperation: .above))
        XCTAssertEqual(moves.map { Array($0.0) }, [[3]])
        XCTAssertEqual(moves.map(\.1), [0])

        // The list changes while a second drag is under way: refused.
        coordinator.beginDrag()
        coordinator.apply(.init(
            rows: ["d", "a", "b"].map { .init(ssid: $0, isOpen: false) },
            selection: nil, editingDisabled: false))
        XCTAssertFalse(coordinator.acceptDrop(of: ["a"], to: 0))
        XCTAssertEqual(moves.count, 1)
        coordinator.endDrag()
        XCTAssertTrue(coordinator.acceptDrop(of: ["b"], to: 0))
        XCTAssertEqual(moves.last.map { Array($0.0) }, [2])

        // Another table's drag is not this list's reorder.
        let stranger = FakeDraggingInfo(source: NSTableView(), pasteboard: pasteboard)
        XCTAssertEqual(coordinator.tableView(
            table, validateDrop: stranger, proposedRow: 0, proposedDropOperation: .above), [])
        XCTAssertEqual(coordinator.tableView(
            table, validateDrop: info, proposedRow: 1, proposedDropOperation: .above), .move)
    }

    private func makeTable(
        _ names: [String]
    ) -> (NSTableView, WifiNetworkTable.Coordinator) {
        let coordinator = WifiNetworkTable.Coordinator()
        let table = WifiNetworkTable.Coordinator.makeTable(coordinator)
        table.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        coordinator.apply(.init(
            rows: names.map { .init(ssid: $0, isOpen: false) },
            selection: nil, editingDisabled: false))
        return (table, coordinator)
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { sub -> [NSButton] in
            (sub as? NSButton).map { [$0] } ?? buttons(in: sub)
        }
    }

    /// Dragging a row is a move of the shared order: what the list's drop
    /// handler is given goes straight into every board's slot order.
    func testDraggingARowReordersTheSavedNetworks() throws {
        let (manager, _) = makeManager(saved: ["Studio WiFi", "Guest", "Home"])
        let section = ViewReading(WifiNetworksSection(
            manager: manager, list: WifiNetworkList(manager: manager)))
        let drop = try XCTUnwrap(
            section.networkTables.first?.onMove, "the rows are not draggable")

        // "Home" dragged to the top, then "Studio WiFi" dragged past the end.
        drop([2], 0)
        XCTAssertEqual(manager.savedNetworkNames, ["Home", "Studio WiFi", "Guest"])
        drop([1], 3)
        XCTAssertEqual(manager.savedNetworkNames, ["Home", "Guest", "Studio WiFi"])
        XCTAssertEqual(manager.settings.wifiPresetOrder, ["Home", "Guest", "Studio WiFi"])
        // A drop where the row already is changes nothing.
        drop([0], 0)
        drop([0], 1)
        XCTAssertEqual(manager.savedNetworkNames, ["Home", "Guest", "Studio WiFi"])
    }

    /// The manager's move means what SwiftUI's `onMove` means, for every
    /// selection of rows and every drop position in a five-row list.
    func testTheMoveMatchesSwiftUIsOnMoveEverywhere() {
        let names = ["a", "b", "c", "d", "e"]
        for mask in 1..<(1 << names.count) {
            let source = IndexSet((0..<names.count).filter { mask & (1 << $0) != 0 })
            for destination in 0...names.count {
                var expected = names
                expected.move(fromOffsets: source, toOffset: destination)
                XCTAssertEqual(
                    PanelManager.moving(names, fromOffsets: source, toOffset: destination),
                    expected, "moving \(Array(source)) to \(destination)")
            }
        }
    }

    /// The footer's minus removes the selected row, after asking. With no
    /// row selected it does nothing.
    func testMinusRemovesTheSelectedRowAfterAsking() throws {
        let (manager, _) = makeManager(saved: ["Studio WiFi", "Guest", "Home"])
        let list = WifiNetworkList(manager: manager)
        let minus = try XCTUnwrap(
            ViewReading(WifiNetworksSection(manager: manager, list: list)).button("Remove"))

        XCTAssertFalse(list.canRemove)
        minus.press()
        XCTAssertNil(list.pendingRemoval, "nothing selected, nothing to ask about")

        list.selection = "Guest"
        XCTAssertTrue(list.canRemove)
        minus.press()
        XCTAssertEqual(list.pendingRemoval, "Guest")
        XCTAssertEqual(manager.savedNetworkNames.count, 3, "removed before confirming")

        list.cancelRemoval()
        XCTAssertNil(list.pendingRemoval)
        XCTAssertEqual(manager.savedNetworkNames.count, 3)

        minus.press()
        list.confirmRemoval()
        XCTAssertEqual(manager.savedNetworkNames, ["Studio WiFi", "Home"])
        XCTAssertNil(list.selection, "the removed row stays selected")
        XCTAssertNil(manager.savedCredential(for: "Guest"))
        XCTAssertNil(list.failure)
    }

    /// Nothing is removed while the add or edit form is open - the minus is
    /// greyed out and the Delete key asks nothing - since saving the form
    /// afterwards would put the removed network back at the end.
    func testNothingIsRemovedWhileTheEditorIsOpen() {
        let (manager, _) = makeManager(saved: ["Studio WiFi", "Guest"])
        let list = WifiNetworkList(manager: manager)
        list.selection = "Guest"
        list.isEditing = true
        XCTAssertFalse(list.canRemove)
        list.requestRemoval()
        XCTAssertNil(list.pendingRemoval)
        list.isEditing = false
        list.requestRemoval()
        XCTAssertEqual(list.pendingRemoval, "Guest")
        // Confirmed for the network the dialog showed, even if the dialog
        // has already let go of it.
        list.cancelRemoval()
        list.confirmRemoval("Guest")
        XCTAssertEqual(manager.savedNetworkNames, ["Studio WiFi"])
    }

    /// A removal the Keychain refuses keeps the network and its selection, and
    /// says why.
    func testARefusedRemovalKeepsTheRowAndSaysWhy() {
        let (manager, _) = makeManager(saved: ["Studio WiFi", "Guest"])
        let store = InMemoryWifiCredentials([
            SavedWiFiCredential(ssid: "Studio WiFi", password: "pw"),
            SavedWiFiCredential(ssid: "Guest", password: "pw"),
        ])
        manager.useWifiCredentials(store)
        store.writesFail = true
        let list = WifiNetworkList(manager: manager)
        list.selection = "Guest"
        list.requestRemoval()
        list.confirmRemoval()
        XCTAssertEqual(list.failure?.title, "Keychain removal failed")
        XCTAssertEqual(list.selection, "Guest")
        XCTAssertEqual(manager.savedNetworkNames, ["Studio WiFi", "Guest"])
    }

    /// A selected network that goes away some other way is no longer what
    /// the minus would remove.
    func testASelectionThatDisappearsIsDropped() {
        let (manager, _) = makeManager(saved: ["Studio WiFi", "Guest"])
        let list = WifiNetworkList(manager: manager)
        list.selection = "Guest"
        XCTAssertNil(manager.removeSavedNetwork("Guest"))
        list.namesChanged(manager.savedNetworkNames)
        XCTAssertNil(list.selection)
        XCTAssertFalse(list.canRemove)
    }

    /// Settings apply as they are made. Restore Defaults puts back only what
    /// the Streaming pane shows: the display list's order and the saved
    /// networks' order are left alone.
    func testRestoreDefaultsResetsOnlyTheStreamingSettings() throws {
        let (manager, _) = makeManager(saved: ["Studio WiFi", "Guest"])
        manager.updateDeviceListSortOrder(.status)
        manager.moveSavedNetwork("Guest", by: -1)
        manager.updateSettings(SenderSettings(
            fps: 24, spacingMicros: 900, adaptivePacing: false,
            identifySeconds: 3, tileQuality: .aggressive,
            deviceListSortOrder: .status))
        let navigation = SettingsNavigation()
        navigation.show(.streaming)
        let restore = try XCTUnwrap(
            ViewReading(SettingsView(manager: manager, navigation: navigation))
                .button("Restore Defaults"))
        restore.press()

        let defaults = SenderSettings()
        XCTAssertEqual(manager.settings.fps, defaults.fps)
        XCTAssertEqual(manager.settings.spacingMicros, defaults.spacingMicros)
        XCTAssertEqual(manager.settings.adaptivePacing, defaults.adaptivePacing)
        XCTAssertEqual(manager.settings.tileQuality, defaults.tileQuality)
        XCTAssertEqual(manager.settings.identifySeconds, 3)
        XCTAssertEqual(manager.settings.deviceListSortOrder, .status)
        XCTAssertEqual(manager.savedNetworkNames, ["Guest", "Studio WiFi"])
    }

    /// A new password for a network already saved changes no name, and the
    /// Add Display sheet, which reads the credential itself, still redraws.
    func testANewPasswordForASavedNetworkRedrawsItsReaders() {
        let (manager, _) = makeManager(saved: ["Studio WiFi"])
        var redraws = 0
        let watch = manager.objectWillChange.sink { redraws += 1 }
        defer { watch.cancel() }
        XCTAssertNil(manager.saveNetwork(
            ssid: "Studio WiFi", password: "rotated"))
        XCTAssertGreaterThan(redraws, 0)
        XCTAssertEqual(manager.savedCredential(for: "Studio WiFi")?.password, "rotated")
    }

    /// Every AppKit control in each pane lies within the window's width, at
    /// the window's default size and at its minimum. The Identify stepper
    /// used to be laid out as a whole form row inside the value column, which
    /// put its arrows past the right edge, and at the old 640 pt minimum the
    /// tile-quality segments ran 12 pt past it. Only the horizontal is
    /// checked: the form scrolls, so a control below the fold is no defect.
    ///
    /// The WiFi pane carries a 32-byte open network. Its row buttons are drawn
    /// by SwiftUI rather than AppKit, so whether "Edit…" keeps its width is
    /// not measurable here; that one was checked in the live window.
    func testEveryPaneKeepsItsControlsInsideTheWindow() throws {
        let longName = "Workshop Upstairs Mesh Extender!"
        XCTAssertEqual(longName.utf8.count, 32)
        let (manager, _) = makeManager(saved: ["Studio WiFi"])
        let store = InMemoryWifiCredentials([
            SavedWiFiCredential(ssid: "Studio WiFi", password: "pw"),
            SavedWiFiCredential(ssid: longName, password: ""),
        ])
        manager.useWifiCredentials(store)
        manager.applySavedNetworkNames(store.names)
        XCTAssertTrue(manager.savedNetworkNames.contains(longName))

        let minimum = SettingsWindowController.minimumContentSize
        for size in [CGSize(width: 720, height: 620), minimum] {
            for pane in SettingsPane.allCases {
                let navigation = SettingsNavigation()
                navigation.show(pane)
                let rect = NSRect(origin: .zero, size: size)
                let host = NSHostingView(rootView: SettingsView(
                    manager: manager, navigation: navigation)
                    .frame(width: size.width, height: size.height))
                host.frame = rect
                let window = NSWindow(
                    contentRect: rect, styleMask: [.borderless],
                    backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
                host.layoutSubtreeIfNeeded()
                var controls: [NSView] = []
                var queue: [NSView] = [host]
                while let view = queue.popLast() {
                    // A hidden scroller has a zero-height frame at -9.
                    if view is NSControl, !(view is NSScroller) { controls.append(view) }
                    queue.append(contentsOf: view.subviews)
                }
                let label = "\(pane.title) at \(Int(size.width))x\(Int(size.height))"
                switch pane {
                case .general:
                    XCTAssertTrue(controls.contains { $0 is NSStepper }, "no stepper on \(label)")
                case .streaming:
                    XCTAssertEqual(
                        controls.filter { $0 is NSSlider }.count, 2, "no sliders on \(label)")
                case .wifiNetworks:
                    break
                case .permissions:
                    break
                }
                for control in controls where control.window != nil {
                    let frame = control.convert(control.bounds, to: host)
                    XCTAssertTrue(
                        frame.minX >= -0.5 && frame.maxX <= host.bounds.maxX + 0.5,
                        "\(type(of: control)) on \(label) lies at \(frame), "
                            + "outside the window's width \(host.bounds.width)")
                }
                window.close()
            }
        }
    }

    func testTheSidebarSearchFindsAPaneByTheSettingsOnIt() {
        let navigation = SettingsNavigation()
        XCTAssertEqual(navigation.visiblePanes, SettingsPane.allCases)
        navigation.query = "password"
        XCTAssertEqual(navigation.visiblePanes, [.wifiNetworks])
        navigation.query = "FPS"
        XCTAssertEqual(navigation.visiblePanes, [.streaming])
        navigation.query = "identify"
        XCTAssertEqual(navigation.visiblePanes, [.general])
        navigation.query = "bluetooth"
        XCTAssertEqual(navigation.visiblePanes, [])
    }

    func testBackAndForwardWalkTheVisitedPanes() {
        let navigation = SettingsNavigation()
        XCTAssertEqual(navigation.pane, .general)
        navigation.show(.streaming)
        navigation.show(.wifiNetworks)
        navigation.show(.wifiNetworks)
        navigation.goBack()
        XCTAssertEqual(navigation.pane, .streaming)
        navigation.goBack()
        XCTAssertEqual(navigation.pane, .general)
        navigation.goBack()
        XCTAssertEqual(navigation.pane, .general)
        navigation.goForward()
        XCTAssertEqual(navigation.pane, .streaming)
        navigation.show(.general)
        XCTAssertTrue(navigation.forwardStack.isEmpty, "a new visit drops the forward history")
    }

    /// The menu's Settings… and the links all go through one notification,
    /// which names the pane.
    func testOpeningSettingsNamesThePane() {
        var received: [[AnyHashable: Any]?] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .espDisplayShowSettings, object: nil, queue: nil
        ) { received.append($0.userInfo) }
        defer { NotificationCenter.default.removeObserver(observer) }
        SettingsPane.open(.wifiNetworks)
        SettingsPane.open()
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0]?["pane"] as? String, "wifiNetworks")
        XCTAssertNil(received[1])
    }

    // MARK: support

    private func makeManager(saved: [String]) -> (PanelManager, PanelSnapshot) {
        let now = Date()
        var panel = PanelSnapshot(serviceName: "desk-panel", displayName: "Desk Panel")
        panel.hardwareID = "020000123456"
        panel.address = "192.168.1.42"
        panel.discovered = true
        panel.lastSeen = now
        panel.lastHeartbeatAt = now
        panel.rssi = -52
        panel.firmwareVersion = "2.0.0"
        panel.controlProtocolVersion = Int(DeviceProtocol.controlProtocolVersion)
        panel.usbHardwareID = "020000123456"
        let store = InMemoryWifiCredentials(saved.map {
            SavedWiFiCredential(ssid: $0, password: "pw")
        })
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [],
            settings: SenderSettings(wifiPresetOrder: saved))
        manager.serialIODisabled = true
        manager.useWifiCredentials(store)
        manager.applySavedNetworkNames(store.names)
        manager.selectedServiceName = panel.serviceName
        return (manager, panel)
    }

    /// The panes the Settings window was asked to open while `body` ran.
    private func opened(_ body: () -> Void) -> [SettingsPane?] {
        var opened: [SettingsPane?] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .espDisplayShowSettings, object: nil, queue: nil
        ) { note in
            opened.append((note.userInfo?["pane"] as? String)
                .flatMap(SettingsPane.init(rawValue:)))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        body()
        return opened
    }
}

/// A SwiftUI view read as a value: the strings it carries, the types it is
/// built from, and its buttons with their actions.
///
/// SwiftUI only builds its accessibility tree for an assistive client, so an
/// offscreen render cannot be asked what controls it shows. The view value
/// itself can: containers keep their content, a `Button` keeps its label and
/// action, and `ForEach` exposes its data and content. This app's own views
/// are expanded through `body`, which outside a window reads every `@State` as
/// its initial value. Classes - the manager above all - are not walked into,
/// so nothing it holds is mistaken for something the view shows; the one
/// exception is the storage behind a localized `Text`.
@MainActor
struct ViewReading {
    struct PressableButton {
        let title: String
        let press: @MainActor () -> Void
    }

    private(set) var strings: [String] = []
    private(set) var buttons: [PressableButton] = []
    /// Every saved-network table, with the drop handler it was given. Read
    /// as the typed value rather than cast out of a `Mirror` as a closure:
    /// the handler is main-actor isolated, and a closure cast loses that and
    /// calls it with the wrong arguments.
    private(set) var networkTables: [WifiNetworkTable] = []
    private(set) var typeNames: [String] = []

    init(_ root: Any) {
        visit(root, depth: 0)
    }

    func button(_ title: String) -> PressableButton? {
        buttons.first { $0.title == title }
    }

    func contains(_ typePrefix: String) -> Bool {
        typeNames.contains { $0.hasPrefix(typePrefix) }
    }

    private mutating func visit(_ value: Any, depth: Int) {
        guard depth < 400 else { return }
        if let string = value as? String {
            strings.append(string)
            return
        }
        let mirror = Mirror(reflecting: value)
        let typeName = String(reflecting: type(of: value))
        // A localized `Text` keeps its key in a class of its own; that one
        // class is the exception.
        if mirror.displayStyle == .class, !typeName.contains("TextStorage") { return }
        typeNames.append(typeName)
        if typeName.hasPrefix("SwiftUI.Button<"), let pressable = Self.pressable(mirror) {
            buttons.append(pressable)
        }
        if let table = value as? WifiNetworkTable {
            networkTables.append(table)
            return
        }
        if let each = value as? ReadableForEach {
            for element in each.readContents { visit(element, depth: depth + 1) }
        }
        // An app view is read through what it draws. Its stored properties
        // are what it was handed, which its body shows already.
        if typeName.hasPrefix("SenderCore."), let view = value as? any View,
           let body = Self.body(of: view) {
            visit(body, depth: depth + 1)
            return
        }
        for child in mirror.children { visit(child.value, depth: depth + 1) }
    }

    private static func body<V: View>(of view: V) -> Any? {
        V.Body.self == Never.self ? nil : view.body
    }

    private static func pressable(_ button: Mirror) -> PressableButton? {
        guard let label = button.children.first(where: { $0.label == "label" })?.value,
              let action = button.children.first(where: { $0.label == "action" })?.value,
              let closure = Mirror(reflecting: action).children.first?.value
                as? @MainActor () -> Void,
              let title = ViewReading(label).strings.first
        else { return nil }
        return PressableButton(title: title, press: closure)
    }
}

private protocol ReadableForEach {
    var readContents: [Any] { get }
}

extension ForEach: ReadableForEach {
    fileprivate var readContents: [Any] { data.map { content($0) } }
}

/// Just enough of a drag for the table's drop handlers.
private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let source: AnyObject
    let pasteboard: NSPasteboard

    init(source: AnyObject, pasteboard: NSPasteboard) {
        self.source = source
        self.pasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { source }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation {
        get { .default }
        set {}
    }
    var animatesToDestination: Bool {
        get { false }
        set {}
    }
    var numberOfValidItemsForDrop: Int {
        get { 1 }
        set {}
    }
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
