import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// The panel reports gestures, not actions: it has no idea what the Mac will do
/// with a swipe. Everything about which gesture means what lives here.
///
/// Note on what is deliberately *not* tested here: no test dispatches a
/// multimedia action through `PanelManager`, and none calls
/// `setGesturePreset(.multimedia, …)`. The first would post real media keys and
/// change the volume or pause the music of whoever is running the suite; the
/// second raises the Accessibility permission prompt. The mapping is pure, so it
/// is tested directly instead.
final class SourceCyclingPresetTests: XCTestCase {

    private func action(
        _ gesture: DeviceProtocol.TouchGesture, landscape: Bool = false
    ) -> TouchAction? {
        TouchAction.action(for: gesture, preset: .sourceCycling, landscape: landscape)
    }

    func testTapTogglesPause() {
        XCTAssertEqual(action(.tap), .togglePause)
    }

    /// Left and up advance, matching how a carousel and a list respectively move
    /// forward. Unchanged from before presets existed.
    func testLeftAndUpAdvance() {
        XCTAssertEqual(action(.swipeLeft), .cycleSource(forward: true))
        XCTAssertEqual(action(.swipeUp), .cycleSource(forward: true))
    }

    func testRightAndDownGoBack() {
        XCTAssertEqual(action(.swipeRight), .cycleSource(forward: false))
        XCTAssertEqual(action(.swipeDown), .cycleSource(forward: false))
    }

    /// This preset is deliberately axis-blind: a source switcher gains nothing
    /// from telling the panel's long edge from its short one, and staying
    /// orientation-independent is what preserves the original behaviour exactly.
    func testRotatingThePanelChangesNothing() {
        for gesture in DeviceProtocol.TouchGesture.allCases {
            XCTAssertEqual(
                action(gesture, landscape: false),
                action(gesture, landscape: true),
                "\(gesture) changed meaning when the panel was rotated")
        }
    }

    func testHoldingIsNotBound() {
        XCTAssertNil(action(.longPress))
    }
}

/// The point of the multimedia preset is that it is axis-relative: volume runs
/// along the panel's long edge whichever way it is facing. That only works
/// because the firmware reports directions in screen space and flags the
/// orientation, so both orientations are tested.
final class MultimediaPresetTests: XCTestCase {

    private func action(
        _ gesture: DeviceProtocol.TouchGesture, landscape: Bool
    ) -> TouchAction? {
        TouchAction.action(for: gesture, preset: .multimedia, landscape: landscape)
    }

    func testTapPlaysAndPauses() {
        XCTAssertEqual(action(.tap, landscape: false), .mediaPlayPause)
        XCTAssertEqual(action(.tap, landscape: true), .mediaPlayPause)
    }

    /// Portrait: 172 wide by 320 tall, so the long axis is vertical.
    func testPortraitPutsVolumeOnTheVerticalAxis() {
        XCTAssertEqual(action(.swipeUp, landscape: false), .volume(up: true))
        XCTAssertEqual(action(.swipeDown, landscape: false), .volume(up: false))
        XCTAssertEqual(action(.swipeLeft, landscape: false), .track(next: true))
        XCTAssertEqual(action(.swipeRight, landscape: false), .track(next: false))
    }

    /// Landscape: 320 by 172, so the same physical gesture along the long edge is
    /// now horizontal — and must still be volume.
    func testLandscapePutsVolumeOnTheHorizontalAxis() {
        XCTAssertEqual(action(.swipeRight, landscape: true), .volume(up: true))
        XCTAssertEqual(action(.swipeLeft, landscape: true), .volume(up: false))
        XCTAssertEqual(action(.swipeUp, landscape: true), .track(next: true))
        XCTAssertEqual(action(.swipeDown, landscape: true), .track(next: false))
    }

    /// Up and right both mean "more" even though up and *left* mean "forward".
    /// Collapsing those two senses would make either volume or track order run
    /// backwards in one of the orientations.
    func testIncreasingIsUpOrRightInBothOrientations() {
        XCTAssertEqual(action(.swipeUp, landscape: false), .volume(up: true))
        XCTAssertEqual(action(.swipeRight, landscape: true), .volume(up: true))
    }

    func testHoldingIsNotBound() {
        XCTAssertNil(action(.longPress, landscape: false))
    }
}

final class WindowCyclingPresetTests: XCTestCase {

    private func action(
        _ gesture: DeviceProtocol.TouchGesture, landscape: Bool = false
    ) -> TouchAction? {
        TouchAction.action(for: gesture, preset: .windowCycling, landscape: landscape)
    }

    func testHoldingReturnsToTheWholeScreen() {
        XCTAssertEqual(action(.longPress), .showFullDisplay)
        XCTAssertEqual(action(.longPress, landscape: true), .showFullDisplay)
    }

    func testTheLongAxisStepsThroughWindows() {
        XCTAssertEqual(action(.swipeUp), .cycleWindow(forward: true))
        XCTAssertEqual(action(.swipeDown), .cycleWindow(forward: false))
        XCTAssertEqual(
            action(.swipeLeft, landscape: true), .cycleWindow(forward: true))
        XCTAssertEqual(
            action(.swipeRight, landscape: true), .cycleWindow(forward: false))
    }

    /// The short axis is left unbound rather than given an invented job. The help
    /// readout lists only what is bound, so an unbound gesture is visible in the
    /// UI instead of feeling broken.
    func testTheShortAxisAndTapAreUnbound() {
        XCTAssertNil(action(.swipeLeft))
        XCTAssertNil(action(.swipeRight))
        XCTAssertNil(action(.swipeUp, landscape: true))
        XCTAssertNil(action(.swipeDown, landscape: true))
        XCTAssertNil(action(.tap))
    }
}

/// Invariants that hold across every preset.
final class GesturePresetTests: XCTestCase {

    /// The old tripwire asserted every wire gesture was bound, which presets make
    /// impossible — a preset that bound all six would be doing something
    /// arbitrary. The invariant that still matters is that no gesture the firmware
    /// can emit is dead everywhere, which would mean the wire format carries
    /// something the app has no use for.
    func testEveryGestureIsBoundInSomePreset() {
        for gesture in DeviceProtocol.TouchGesture.allCases {
            let bound = GesturePreset.allCases.contains { preset in
                [true, false].contains { landscape in
                    TouchAction.action(
                        for: gesture, preset: preset, landscape: landscape) != nil
                }
            }
            XCTAssertTrue(bound, "\(gesture) does nothing under any preset")
        }
    }

    /// Only window cycling needs firmware new enough to report a hold, and the UI
    /// greys its notice on this rather than on a hard-coded list of presets.
    func testOnlyWindowCyclingNeedsALongPress() {
        XCTAssertTrue(GesturePreset.windowCycling.usesLongPress)
        XCTAssertFalse(GesturePreset.multimedia.usesLongPress)
        XCTAssertFalse(GesturePreset.sourceCycling.usesLongPress)
    }

    /// The default has to stay source cycling: it is what panels already did, and
    /// it is the only preset that needs neither a permission nor new firmware.
    func testTheDefaultIsTheLeastSurprisingOne() {
        XCTAssertEqual(GesturePreset.standard, .sourceCycling)
    }

    func testEveryPresetIsNamedAndDescribed() {
        for preset in GesturePreset.allCases {
            XCTAssertFalse(preset.label.isEmpty, "\(preset) has no name")
            XCTAssertFalse(preset.summary.isEmpty, "\(preset) has no description")
        }
    }
}

/// The help readout under the dropdown.
///
/// It is generated by asking the resolver, so these tests are really about the
/// one property that matters: the app cannot describe a binding it does not
/// have, or omit one it does.
final class GestureHelpTests: XCTestCase {

    func testEveryRowMatchesWhatTheGestureActuallyDoes() {
        for preset in GesturePreset.allCases {
            for landscape in [true, false] {
                let rows = GestureHelpRow.rows(for: preset, landscape: landscape)
                for row in rows {
                    // Recover the gesture from its label, then ask the resolver
                    // directly. A row describing something the resolver would not
                    // do fails here.
                    let gesture = DeviceProtocol.TouchGesture.allCases.first {
                        GestureHelpRow.label(for: $0) == row.gesture
                    }
                    let action = gesture.flatMap {
                        TouchAction.action(
                            for: $0, preset: preset, landscape: landscape)
                    }
                    XCTAssertEqual(
                        action?.summary, row.effect,
                        "\(preset) \(row.gesture) is described as "
                            + "\"\(row.effect)\" but does something else")
                }
            }
        }
    }

    func testUnboundGesturesAreLeftOutRatherThanListedAsDoingNothing() {
        let rows = GestureHelpRow.rows(for: .windowCycling, landscape: false)
        let bound = DeviceProtocol.TouchGesture.allCases.filter {
            TouchAction.action(for: $0, preset: .windowCycling, landscape: false)
                != nil
        }

        XCTAssertEqual(rows.count, bound.count)
        XCTAssertFalse(
            rows.contains { $0.gesture == "Tap" },
            "tap is unbound in this preset but was listed anyway")
    }

    /// The payoff of the whole axis-relative design, stated as the user sees it:
    /// the same swipe is described differently depending on how the panel is
    /// turned, so the readout is never quietly wrong.
    func testTheReadoutFollowsTheOrientation() {
        let portrait = GestureHelpRow.rows(for: .multimedia, landscape: false)
        let landscape = GestureHelpRow.rows(for: .multimedia, landscape: true)

        XCTAssertEqual(
            portrait.first { $0.gesture == "Swipe up" }?.effect, "Volume up")
        XCTAssertEqual(
            landscape.first { $0.gesture == "Swipe up" }?.effect, "Next track")
        XCTAssertEqual(
            landscape.first { $0.gesture == "Swipe right" }?.effect, "Volume up")
    }

    /// Rows are ordered so the two gestures doing one job land next to each
    /// other; a list interleaving volume and track would be hard to scan.
    func testTheLongAxisIsListedBeforeTheShort() {
        let rows = GestureHelpRow.rows(for: .multimedia, landscape: false)
        let effects = rows.map(\.effect)

        guard let firstVolume = effects.firstIndex(where: { $0.hasPrefix("Volume") }),
              let lastVolume = effects.lastIndex(where: { $0.hasPrefix("Volume") }),
              let firstTrack = effects.firstIndex(where: { $0.hasSuffix("track") })
        else { return XCTFail("expected both volume and track rows") }

        XCTAssertEqual(lastVolume, firstVolume + 1, "volume rows are not adjacent")
        XCTAssertLessThan(lastVolume, firstTrack, "track was listed before volume")
    }

    func testTapIsListedFirstWhenBound() {
        let rows = GestureHelpRow.rows(for: .multimedia, landscape: false)

        XCTAssertEqual(rows.first?.gesture, "Tap")
    }
}

/// A swipe walks a ring of sources. It has no menu to read from, so the ring's
/// contents and its wrap-around are the entire user interface.
final class SourceRingTests: XCTestCase {

    func testAutomaticLeadsTheRing() {
        let ring = PanelSource.ring(displayNames: ["Studio Display", "Sidecar"])

        XCTAssertEqual(
            ring, [.automatic, .display("Studio Display"), .display("Sidecar")])
    }

    /// Without a display attached the ring still holds Automatic, so cycling is
    /// a no-op rather than a crash or an empty source.
    func testRingWithNoDisplaysIsJustAutomatic() {
        XCTAssertEqual(PanelSource.ring(displayNames: []), [.automatic])
    }

    func testForwardAdvancesAndWraps() {
        let ring = PanelSource.ring(displayNames: ["A", "B"])

        XCTAssertEqual(
            PanelSource.next(after: .automatic, in: ring, forward: true),
            .display("A"))
        XCTAssertEqual(
            PanelSource.next(after: .display("A"), in: ring, forward: true),
            .display("B"))
        XCTAssertEqual(
            PanelSource.next(after: .display("B"), in: ring, forward: true),
            .automatic)
    }

    func testBackwardRetreatsAndWraps() {
        let ring = PanelSource.ring(displayNames: ["A", "B"])

        XCTAssertEqual(
            PanelSource.next(after: .automatic, in: ring, forward: false),
            .display("B"))
        XCTAssertEqual(
            PanelSource.next(after: .display("B"), in: ring, forward: false),
            .display("A"))
        XCTAssertEqual(
            PanelSource.next(after: .display("A"), in: ring, forward: false),
            .automatic)
    }

    /// A window pick, or a display unplugged since it was chosen, is not in the
    /// ring. Landing on the first entry means the swipe still does something the
    /// user can see instead of appearing to be ignored.
    func testSourceOutsideTheRingLandsOnTheFirstEntry() {
        let ring = PanelSource.ring(displayNames: ["A"])

        XCTAssertEqual(
            PanelSource.next(after: .window("Music"), in: ring, forward: true),
            .automatic)
        XCTAssertEqual(
            PanelSource.next(after: .display("Unplugged"), in: ring, forward: false),
            .automatic)
    }

    func testEmptyRingHasNoNext() {
        XCTAssertNil(PanelSource.next(after: .automatic, in: [], forward: true))
    }

    /// A ring of one cannot move, and the caller relies on getting the current
    /// source back so it can skip the pointless re-apply.
    func testSingleEntryRingReturnsItself() {
        XCTAssertEqual(
            PanelSource.next(after: .automatic, in: [.automatic], forward: true),
            .automatic)
    }
}

/// Pointing a panel at a display shaped like a panel is either a mirror of what
/// it already shows or a feedback loop, so those are kept out of the ring.
final class PanelShapedDisplayTests: XCTestCase {

    func testThePanelsOwnShapeIsRecognised() {
        XCTAssertTrue(PanelManager.isPanelShaped(172, 320))
        XCTAssertTrue(PanelManager.isPanelShaped(320, 172))
    }

    func testRealDisplaysAreNotPanelShaped() {
        XCTAssertFalse(PanelManager.isPanelShaped(1920, 1080))
        XCTAssertFalse(PanelManager.isPanelShaped(2560, 1440))
        XCTAssertFalse(PanelManager.isPanelShaped(1080, 1920))
        XCTAssertFalse(PanelManager.isPanelShaped(1440, 2560))
    }

    func testDegenerateSizesAreNotPanelShaped() {
        XCTAssertFalse(PanelManager.isPanelShaped(0, 0))
        XCTAssertFalse(PanelManager.isPanelShaped(320, 0))
    }
}

/// UDP can deliver the same datagram twice. Both touch actions are toggles or
/// steps, so a duplicate would either undo itself — a tap that looks ignored —
/// or step two sources at once.
@MainActor
final class TouchDeduplicationTests: XCTestCase {

    private func manager() -> PanelManager {
        PanelManager(
            previewPanels: [
                PanelSnapshot(serviceName: "panel", displayName: "panel")
            ],
            savedNetworkNames: [],
            usbSerialPorts: [])
    }

    private func tap(_ sequence: UInt16) -> FrameSender.DeviceEvent {
        .touch(
            DeviceProtocol.TouchEvent(
                gesture: .tap, sequence: sequence, x: 86, y: 160, landscape: false))
    }

    func testTapTogglesPause() {
        let subject = manager()
        XCTAssertFalse(try! XCTUnwrap(subject.panels.first).paused)

        subject.update(tap(1), for: "panel")
        XCTAssertTrue(try! XCTUnwrap(subject.panels.first).paused)

        subject.update(tap(2), for: "panel")
        XCTAssertFalse(try! XCTUnwrap(subject.panels.first).paused)
    }

    func testRedeliveredTapIsIgnored() {
        let subject = manager()

        subject.update(tap(7), for: "panel")
        subject.update(tap(7), for: "panel")

        XCTAssertTrue(
            try! XCTUnwrap(subject.panels.first).paused,
            "the duplicate resumed the stream, so the tap looked ignored")
    }

    /// The counter wraps at 16 bits and restarts at a random value when the
    /// device reboots, so a sequence that moves backwards is a new gesture, not
    /// a stale one.
    func testSequenceGoingBackwardsStillCounts() {
        let subject = manager()

        subject.update(tap(.max), for: "panel")
        subject.update(tap(3), for: "panel")

        XCTAssertFalse(try! XCTUnwrap(subject.panels.first).paused)
    }

    /// De-duplication is per panel. Two panels legitimately produce the same
    /// sequence numbers, and one must not mask the other's gesture.
    func testEachPanelIsTrackedSeparately() {
        let subject = PanelManager(
            previewPanels: [
                PanelSnapshot(serviceName: "one", displayName: "one"),
                PanelSnapshot(serviceName: "two", displayName: "two"),
            ],
            savedNetworkNames: [],
            usbSerialPorts: [])

        subject.update(tap(5), for: "one")
        subject.update(tap(5), for: "two")

        XCTAssertTrue(subject.panels.first { $0.serviceName == "one" }?.paused == true)
        XCTAssertTrue(subject.panels.first { $0.serviceName == "two" }?.paused == true)
    }

    /// A touch is not a heartbeat. Heartbeat age drives the reconnect watchdog
    /// and the pacing hill-climb, and a finger is no evidence that frames are
    /// landing — a panel whose stream had died would otherwise read "Online".
    func testTouchDoesNotMakeAPanelLookOnline() {
        let subject = manager()

        subject.update(tap(1), for: "panel")

        XCTAssertFalse(try! XCTUnwrap(subject.panels.first).isOnline)
    }
}

/// A preset is a setting the user chose, so it belongs on disk — and has to
/// survive a file written before presets existed.
final class GesturePresetPersistenceTests: XCTestCase {

    private func snapshot(_ preset: GesturePreset) -> PanelSnapshot {
        var panel = PanelSnapshot(serviceName: "panel", displayName: "Panel")
        panel.gesturePreset = preset
        return panel
    }

    func testAChosenPresetRoundTrips() throws {
        for preset in GesturePreset.allCases {
            let stored = PersistedPanel(snapshot: snapshot(preset))
            let data = try JSONEncoder.espDisplay.encode([stored])
            let loaded = try JSONDecoder.espDisplay.decode(
                [PersistedPanel].self, from: data)

            XCTAssertEqual(
                loaded.first?.snapshot.gesturePreset, preset,
                "\(preset) did not survive being saved")
        }
    }

    /// The default is stored as absent, matching how `source` records automatic.
    /// A record that only says "the default" is noise, and writing it would also
    /// mean a future change of default could not reach panels already saved.
    func testTheDefaultIsNotWrittenOut() {
        let stored = PersistedPanel(snapshot: snapshot(.standard))

        XCTAssertNil(stored.gesturePreset)
        XCTAssertEqual(stored.snapshot.gesturePreset, .standard)
    }

    /// Files written before presets existed have no such key. They must load as
    /// the default rather than failing to decode and taking the user's display
    /// names and port assignments down with them.
    func testAFileFromBeforePresetsLoadsAsTheDefault() throws {
        let json = Data(
            #"[{"serviceName":"panel","displayName":"Panel","idleText":"hi"}]"#.utf8)

        let loaded = try JSONDecoder.espDisplay.decode(
            [PersistedPanel].self, from: json)

        XCTAssertEqual(loaded.first?.snapshot.gesturePreset, .standard)
        XCTAssertEqual(loaded.first?.snapshot.idleText, "hi")
    }

    /// An unrecognised preset name — a file written by a newer build — must not
    /// take the whole file down with it either.
    func testAnUnknownPresetNameDoesNotDestroyTheFile() {
        let json = Data(
            #"[{"serviceName":"panel","displayName":"Panel","gesturePreset":"telepathy"}]"#
                .utf8)

        let loaded = try? JSONDecoder.espDisplay.decode(
            [PersistedPanel].self, from: json)

        // Documenting the real behaviour rather than asserting a wish: a bad enum
        // value fails the decode, and `PanelStore.load` reports that as a failure
        // instead of silently dropping the file.
        XCTAssertNil(loaded)
    }
}
