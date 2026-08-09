import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// The panel reports gestures, not actions: it has no idea what the Mac will do
/// with a swipe. Everything about which gesture means what lives here.
final class TouchActionTests: XCTestCase {

    func testTapTogglesPause() {
        XCTAssertEqual(TouchAction.for(.tap), .togglePause)
    }

    /// Both axes cycle, because the panel can be flipped to landscape and the
    /// user should not have to remember which way it is facing before swiping.
    func testLeftAndUpAdvance() {
        XCTAssertEqual(TouchAction.for(.swipeLeft), .cycleSource(forward: true))
        XCTAssertEqual(TouchAction.for(.swipeUp), .cycleSource(forward: true))
    }

    func testRightAndDownGoBack() {
        XCTAssertEqual(TouchAction.for(.swipeRight), .cycleSource(forward: false))
        XCTAssertEqual(TouchAction.for(.swipeDown), .cycleSource(forward: false))
    }

    /// A gesture the firmware can emit but the sender ignores would be a dead
    /// spot on the screen, so every one the wire format defines is bound.
    func testEveryGestureOnTheWireIsBound() {
        for gesture in DeviceProtocol.TouchGesture.allCases {
            XCTAssertNotNil(TouchAction.for(gesture), "\(gesture) does nothing")
        }
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
