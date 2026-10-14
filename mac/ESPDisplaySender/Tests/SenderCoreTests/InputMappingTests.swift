import AppKit
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// The per-board assignment model: which inputs a board offers, what the
/// preset gives each, what the user changed, and the map the board is sent.
///
/// Like the preset tests, nothing here posts a real key or media key: the
/// dispatch test swaps in a recorder, and the mapping is otherwise pure.
final class InputMappingTests: XCTestCase {
    typealias G = DeviceProtocol.TouchGesture

    /// A board running firmware that stores a map, reporting today's
    /// defaults: touch, BOOT (with a boot menu) and a power key.
    private func reportingPanel(
        inputs: Set<G>? = nil,
        functions: Set<DeviceProtocol.BoardFunctionCode> = Set(
            DeviceProtocol.BoardFunctionCode.allCases),
        current: [UInt8]? = nil
    ) -> PanelSnapshot {
        let defaults: [UInt8] = [1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 3, 4, 5, 6, 0, 0]
        var panel = PanelSnapshot(serviceName: "panel", displayName: "Panel")
        panel.capabilitiesRaw = DeviceProtocol.Capabilities(
            [.touch, .touchLongPress, .inputMap]).rawValue
        panel.inputReport = DeviceProtocol.InputReport(
            inputs: inputs ?? [.tap, .swipeLeft, .swipeRight, .swipeUp, .swipeDown,
                               .longPress, .bootSinglePress, .bootDoublePress,
                               .bootTriplePress, .bootLongPress, .bootExtraLongPress,
                               .powerKeyPress, .powerKeyLongPress],
            functions: functions, current: current ?? defaults, defaults: defaults)
        return panel
    }

    // MARK: inputs per board

    /// Firmware that predates maps lists only what it forwards: its touch
    /// gestures, and the knob where it has one. No BOOT, no board functions.
    func testOlderFirmwareListsItsGesturesOnly() {
        var panel = PanelSnapshot(serviceName: "panel", displayName: "Panel")
        panel.capabilitiesRaw = DeviceProtocol.Capabilities.touch.rawValue
        XCTAssertEqual(
            panel.availableInputs, [.tap, .swipeUp, .swipeDown, .swipeRight, .swipeLeft])
        XCTAssertTrue(panel.availableBoardFunctions.isEmpty)
        panel.capabilitiesRaw = 0
        XCTAssertTrue(panel.availableInputs.isEmpty)
    }

    func testAReportingBoardListsWhatItReportsInGroups() {
        let panel = reportingPanel()
        XCTAssertEqual(
            panel.availableInputs,
            [.tap, .longPress, .swipeUp, .swipeDown, .swipeRight, .swipeLeft,
             .bootSinglePress, .bootDoublePress, .bootTriplePress, .bootLongPress,
             .bootExtraLongPress, .powerKeyPress, .powerKeyLongPress])
        XCTAssertEqual(
            Set(panel.availableInputs.map(InputGroup.of)),
            [.touch, .bootButton, .powerButton])
        XCTAssertEqual(panel.availableBoardFunctions, BoardFunction.allCases)
    }

    /// A board says which of its own functions it can run; only those are
    /// offered (a C6 has no boot menu).
    func testOnlyTheBoardsOwnFunctionsAreOffered() {
        let panel = reportingPanel(functions: [.nothing, .sender, .rotate180, .displayPower])
        XCTAssertEqual(panel.availableBoardFunctions, [.rotate180, .displayPower])
    }

    // MARK: the default preset is today's behaviour

    /// Untouched, every gesture does what the preset always did, BOOT keeps
    /// the board's own tiers, and the power key does nothing - so the board
    /// already runs the wanted map and nothing is ever sent to it.
    func testTheDefaultIsTodaysBehaviourAndNeedsNoMap() {
        let panel = reportingPanel()
        for gesture in G.allCases where gesture.isTouch {
            for landscape in [false, true] {
                XCTAssertEqual(
                    panel.function(for: gesture, landscape: landscape),
                    TouchAction.action(for: gesture, preset: .standard, landscape: landscape)
                        .map(InputFunction.mac) ?? .nothing)
            }
        }
        XCTAssertEqual(panel.function(for: .bootSinglePress, landscape: false), .board(.statusScreen))
        XCTAssertEqual(panel.function(for: .bootDoublePress, landscape: false), .board(.wifiSelector))
        XCTAssertEqual(panel.function(for: .bootTriplePress, landscape: false), .board(.bootMenu))
        XCTAssertEqual(panel.function(for: .bootLongPress, landscape: false), .board(.rotate180))
        XCTAssertEqual(panel.function(for: .bootExtraLongPress, landscape: false), .board(.displayPower))
        XCTAssertEqual(panel.function(for: .powerKeyPress, landscape: false), .nothing)
        XCTAssertFalse(panel.hasCustomAssignments)
        XCTAssertTrue(panel.boardMapIsCurrent)
    }

    /// The knob stays the Mac's volume and mute under every preset.
    func testTheKnobIsVolumeUnderEveryPreset() {
        var panel = reportingPanel(inputs: [.knobClockwise, .knobCounterclockwise, .knobPress])
        for preset in GesturePreset.allCases {
            panel.gesturePreset = preset
            XCTAssertEqual(panel.function(for: .knobClockwise, landscape: false), .mac(.volume(up: true)))
            XCTAssertEqual(panel.function(for: .knobPress, landscape: false), .mac(.mute))
            XCTAssertEqual(panel.boardCodes[.knobPress], .sender)
        }
    }

    /// Window cycling binds the long axis, which turns with the panel. The
    /// board is told to report every swipe either way up, so it never needs
    /// to know its orientation; the Mac resolves the axis as before.
    func testOrientationDependentPresetsStillReportBothAxes() {
        var panel = reportingPanel()
        panel.gesturePreset = .windowCycling
        for swipe in [G.swipeUp, .swipeDown, .swipeLeft, .swipeRight] {
            XCTAssertEqual(panel.boardCodes[swipe], .sender, "\(swipe)")
        }
        XCTAssertEqual(panel.boardCodes[.longPress], .sender)
        // Unbound by the preset, the tap is still reported (and still shows
        // the board's info bar); an assignment of Nothing drops it.
        XCTAssertEqual(panel.boardCodes[.tap], .sender)
        panel.inputAssignments[.tap] = .nothing
        XCTAssertEqual(panel.boardCodes[.tap], .nothing)
    }

    // MARK: editing

    func testAnAssignmentOverridesThePresetAndChangesTheBoardsMap() {
        var panel = reportingPanel()
        panel.inputAssignments[.bootSinglePress] = .mac(.mediaPlayPause)
        panel.inputAssignments[.tap] = .board(.rotate180)
        panel.inputAssignments[.powerKeyPress] = .board(.displayPower)
        XCTAssertTrue(panel.hasCustomAssignments)
        XCTAssertEqual(panel.boardCodes[.bootSinglePress], .sender)
        XCTAssertEqual(panel.boardCodes[.tap], .rotate180)
        XCTAssertEqual(panel.boardCodes[.powerKeyPress], .displayPower)
        XCTAssertFalse(panel.boardMapIsCurrent)
        XCTAssertEqual(
            [UInt8](DeviceProtocol.inputMapPacket(panel.boardCodes)),
            [0x45, 0x4d, 0x41, 0x50, 0x01, 0x10, 0x00, 0x00,
             0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
             0x01, 0x03, 0x04, 0x05, 0x06, 0x06, 0x00])
        // Once the board reports that map, it is current and nothing is sent.
        let applied = DeviceProtocol.inputMapPacket(panel.boardCodes).dropFirst(8)
        panel.inputReport = DeviceProtocol.InputReport(
            inputs: panel.inputReport!.inputs, functions: panel.inputReport!.functions,
            current: Array(applied), defaults: [1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 3, 4, 5, 6, 0, 0])
        XCTAssertTrue(panel.boardMapIsCurrent)
    }

    /// Inputs the board does not have keep its own defaults in the map, so
    /// an edit never changes something the user cannot see.
    func testInputsTheBoardLacksKeepItsDefaults() {
        var panel = reportingPanel(inputs: [.tap])
        panel.inputAssignments[.tap] = .board(.displayPower)
        XCTAssertEqual(panel.boardCodes[.bootLongPress], .rotate180)
        XCTAssertEqual(panel.boardCodes[.knobPress], .sender)
    }

    @MainActor
    func testAPresetFillsInEveryAssignmentAndAMatchingEditIsNoEdit() throws {
        let subject = PanelManager(
            previewPanels: [reportingPanel()], savedNetworkNames: [], usbSerialPorts: [])
        subject.mediaKeysAuthorized = { true }
        subject.setInputFunction(.board(.displayPower), for: .bootSinglePress, on: "panel")
        subject.setInputFunction(.mac(.togglePause), for: .bootLongPress, on: "panel")
        XCTAssertEqual(try XCTUnwrap(subject.panels.first).inputAssignments.count, 2)
        // Choosing what the preset already gives removes the assignment.
        subject.setInputFunction(.board(.statusScreen), for: .bootSinglePress, on: "panel")
        XCTAssertEqual(
            try XCTUnwrap(subject.panels.first).inputAssignments,
            [.bootLongPress: .mac(.togglePause)])
        // A preset replaces every assignment.
        subject.setGesturePreset(.windowCycling, for: "panel")
        let panel = try XCTUnwrap(subject.panels.first)
        XCTAssertEqual(panel.gesturePreset, .windowCycling)
        XCTAssertTrue(panel.inputAssignments.isEmpty)
    }

    // MARK: dispatch

    /// A BOOT press the map gave this Mac arrives like a gesture and runs its
    /// assignment; a recorded key press goes through the key sender.
    @MainActor
    func testForwardedButtonsRunTheirAssignment() throws {
        var preview = reportingPanel()
        let combo = KeyCombo(keyCode: 40, modifiers: NSEvent.ModifierFlags.command.rawValue,
                             label: "\u{2318}K")
        preview.inputAssignments[.bootSinglePress] = .mac(.togglePause)
        preview.inputAssignments[.powerKeyPress] = .mac(.keyPress(combo))
        let subject = PanelManager(
            previewPanels: [preview], savedNetworkNames: [], usbSerialPorts: [])
        subject.mediaKeysAuthorized = { true }
        var pressed: [KeyCombo] = []
        subject.keyPressSender = { pressed.append($0); return nil }

        func event(_ gesture: G, _ sequence: UInt16) -> FrameSender.DeviceEvent {
            .touch(DeviceProtocol.TouchEvent(
                gesture: gesture, sequence: sequence, x: 0, y: 0, landscape: false))
        }
        subject.update(event(.bootSinglePress, 1), for: "panel")
        XCTAssertTrue(try XCTUnwrap(subject.panels.first).paused)
        subject.update(event(.powerKeyPress, 2), for: "panel")
        XCTAssertEqual(pressed, [combo])
        // A board function reaching the Mac (a board behind on its map) is
        // not run here.
        subject.update(event(.bootLongPress, 3), for: "panel")
        XCTAssertTrue(try XCTUnwrap(subject.panels.first).paused)
    }

    @MainActor
    func testARefusedKeyPressIsReported() throws {
        var preview = reportingPanel()
        let combo = KeyCombo(keyCode: 0, modifiers: 0, label: "A")
        preview.inputAssignments[.tap] = .mac(.keyPress(combo))
        let subject = PanelManager(
            previewPanels: [preview], savedNetworkNames: [], usbSerialPorts: [])
        subject.mediaKeysAuthorized = { true }
        subject.keyPressSender = { _ in "refused" }
        subject.update(.touch(DeviceProtocol.TouchEvent(
            gesture: .tap, sequence: 1, x: 0, y: 0, landscape: false)), for: "panel")
        let outcome = try XCTUnwrap(subject.operationOutcome)
        XCTAssertEqual(outcome.kind, .failure)
        XCTAssertTrue(outcome.title.contains("press A"))
        XCTAssertEqual(outcome.message, "refused")
    }

    // MARK: key capture

    func testRecordedCombinationsAreLabelledAndModifiersAloneAreNot() {
        let combo = KeyCombo.recorded(
            keyCode: 40, modifiers: [.command, .shift, .capsLock],
            charactersIgnoringModifiers: "k")
        XCTAssertEqual(combo?.label, "\u{21E7}\u{2318}K")
        XCTAssertEqual(combo?.modifierFlags, [.command, .shift])
        XCTAssertEqual(
            KeyCombo.recorded(keyCode: 49, modifiers: [.control], charactersIgnoringModifiers: " ")?
                .label,
            "\u{2303}Space")
        XCTAssertEqual(
            KeyCombo.recorded(keyCode: 122, modifiers: [], charactersIgnoringModifiers: nil)?.label,
            "F1")
        XCTAssertNil(KeyCombo.recorded(
            keyCode: 56, modifiers: [.shift], charactersIgnoringModifiers: ""))
    }

    // MARK: persistence

    func testAssignmentsRoundTripAndUnknownOnesAreDropped() throws {
        var panel = PanelSnapshot(serviceName: "panel", displayName: "Panel")
        let combo = KeyCombo(keyCode: 40, modifiers: NSEvent.ModifierFlags.command.rawValue,
                             label: "\u{2318}:K")
        panel.inputAssignments = [
            .tap: .mac(.keyPress(combo)), .bootLongPress: .board(.displayPower),
            .swipeUp: .nothing, .powerKeyPress: .mac(.track(next: false)),
        ]
        let data = try JSONEncoder.espDisplay.encode([PersistedPanel(snapshot: panel)])
        let loaded = try JSONDecoder.espDisplay.decode([PersistedPanel].self, from: data)
        XCTAssertEqual(loaded.first?.snapshot.inputAssignments, panel.inputAssignments)

        XCTAssertNil(PersistedPanel(
            snapshot: PanelSnapshot(serviceName: "p", displayName: "P")).inputAssignments)
        let json = Data(
            #"[{"serviceName":"panel","displayName":"Panel","inputAssignments":{"1":"telepathy","13":"board.rotate180","99":"mute"}}]"#
                .utf8)
        let tolerant = try JSONDecoder.espDisplay.decode([PersistedPanel].self, from: json)
        XCTAssertEqual(tolerant.first?.snapshot.inputAssignments, [.bootLongPress: .board(.rotate180)])
    }

    /// Every catalog entry, board function and nothing has a token that reads
    /// back as itself.
    func testEveryFunctionHasAStableToken() {
        let all: [InputFunction] = [.nothing]
            + TouchAction.catalog.map(InputFunction.mac)
            + BoardFunction.allCases.map(InputFunction.board)
        XCTAssertEqual(Set(all.map(\.token)).count, all.count)
        for function in all {
            XCTAssertEqual(InputFunction(token: function.token), function)
        }
    }
}
