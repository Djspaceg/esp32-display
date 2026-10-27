import CoreGraphics
import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// A Mac screen used as a device: what is listed, which screen a saved device
/// is, where the picture goes, and what capture leaves out.
final class ScreenDeviceTests: XCTestCase {
    static func screen(
        _ name: String, id: CGDirectDisplayID, vendor: UInt32 = 0x9e3, model: UInt32 = 0x39,
        serial: UInt32 = 0, uuid: String, pixels: (Int, Int) = (1920, 1080),
        frame: CGRect = CGRect(x: 1512, y: 0, width: 1920, height: 1080),
        menuBar: Bool = false
    ) -> AttachedScreen {
        AttachedScreen(
            displayID: id,
            identity: ScreenIdentity(vendor: vendor, model: model, serial: serial, uuid: uuid),
            name: name, pixelWidth: pixels.0, pixelHeight: pixels.1, frame: frame,
            maximumFPS: 60, hasMenuBar: menuBar)
    }

    static let builtIn = screen(
        "Built-in Retina Display", id: 1, vendor: 0x610, model: 0xa050, uuid: "BUILTIN",
        pixels: (3024, 1964), frame: CGRect(x: 0, y: 0, width: 1512, height: 982), menuBar: true)
    static let oled = screen("BOE VX039", id: 7, uuid: "OLED-PORT-A")
    static let studio = screen(
        "Studio Display", id: 3, vendor: 0x610, model: 0xae2e, serial: 0x1234, uuid: "STUDIO",
        pixels: (5120, 2880), frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440))

    // MARK: listing and filtering

    func testListsEveryScreenExceptTheMenuBarScreenAndTheOnesCapturedFrom() {
        let entries = ScreenDeviceListing.entries(
            attached: [Self.builtIn, Self.oled, Self.studio], records: [],
            capturingFrom: ["Studio Display"])
        XCTAssertEqual(entries.map(\.name), ["BOE VX039"])
        XCTAssertEqual(entries.first?.label, "BOE VX039 (1920×1080)")
        XCTAssertEqual(entries.first?.inUse, false)
        XCTAssertEqual(entries.first?.screen?.displayID, 7)
    }

    func testAScreenADeviceRegionIsDrawnOnIsNotOffered() {
        var record = ScreenDeviceRecord(
            screen: Self.oled,
            region: RegionSpec(display: "Studio Display", x: 0, y: 0, width: 960, height: 540))
        record.rotation = 0
        let entries = ScreenDeviceListing.entries(
            attached: [Self.builtIn, Self.oled, Self.studio], records: [record],
            capturingFrom: [])
        XCTAssertEqual(entries.map(\.name), ["BOE VX039"])
        XCTAssertEqual(entries.first?.inUse, true)
    }

    func testADeviceStaysListedWhileUnpluggedAndWhateverItHosts() {
        let record = ScreenDeviceRecord(screen: Self.oled, region: nil)
        let unplugged = ScreenDeviceListing.entries(
            attached: [Self.builtIn], records: [record], capturingFrom: [])
        XCTAssertEqual(unplugged.map(\.name), ["BOE VX039"])
        XCTAssertNil(unplugged.first?.screen)
        XCTAssertEqual(unplugged.first?.label, "BOE VX039 (1920×1080)")

        let captured = ScreenDeviceListing.entries(
            attached: [Self.builtIn, Self.oled], records: [record],
            capturingFrom: ["BOE VX039"])
        XCTAssertEqual(captured.map(\.name), ["BOE VX039"])
        XCTAssertNotNil(captured.first?.screen)
    }

    func testTheSidebarTagCannotCollideWithABoard() {
        let tag = ScreenDeviceEntry.tag(for: Self.oled.identity.key)
        XCTAssertEqual(ScreenDeviceEntry.key(fromTag: tag), Self.oled.identity.key)
        XCTAssertNil(ScreenDeviceEntry.key(fromTag: "desk-panel"))
        XCTAssertNil(ScreenDeviceEntry.key(fromTag: nil))
    }

    // MARK: identity pairing

    func testASerialPairsTheScreenWhereverAndWhicheverIndexItComesBackAt() {
        let first = Self.screen(
            "VX039", id: 7, serial: 0xabc, uuid: "U1",
            frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080))
        let record = ScreenDeviceRecord(screen: first, region: nil)
        // Back on another port: new display ID, new UUID, new position, and a
        // different screen now sits first in the list.
        let other = Self.screen("VX039", id: 9, serial: 0xdef, uuid: "U9")
        let back = Self.screen(
            "VX039", id: 12, serial: 0xabc, uuid: "U2",
            frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        let paired = ScreenDeviceListing.pair([record], with: [other, back])
        XCTAssertEqual(paired[record.key]?.displayID, 12)
    }

    func testDifferentSerialsNeverPairEvenWithTheSameUUID() {
        let a = ScreenIdentity(vendor: 1, model: 2, serial: 3, uuid: "SAME")
        let b = ScreenIdentity(vendor: 1, model: 2, serial: 4, uuid: "SAME")
        XCTAssertFalse(a.matches(b))
        XCTAssertNotEqual(a.key, b.key)
    }

    func testWithoutASerialTheUUIDPairs() {
        let record = ScreenDeviceRecord(screen: Self.oled, region: nil)
        var back = Self.oled
        back.displayID = 44
        let paired = ScreenDeviceListing.pair([record], with: [Self.builtIn, back])
        XCTAssertEqual(paired[record.key]?.displayID, 44)
        XCTAssertTrue(
            ScreenIdentity(vendor: 1, model: 2, serial: 0, uuid: "abc")
                .matches(ScreenIdentity(vendor: 1, model: 2, serial: 0, uuid: "ABC")))
    }

    func testTwoIdenticalSerialLessScreensAreNeverGuessedBetween() {
        let a = Self.screen("VX039", id: 7, uuid: "A")
        let b = Self.screen("VX039", id: 8, uuid: "B")
        let recordA = ScreenDeviceRecord(screen: a, region: nil)
        let recordB = ScreenDeviceRecord(screen: b, region: nil)
        // Only B is attached: B pairs, A stays unplugged.
        let one = ScreenDeviceListing.pair([recordA, recordB], with: [b])
        XCTAssertEqual(one[recordB.key]?.displayID, 8)
        XCTAssertNil(one[recordA.key])
        // A serial-less screen whose UUID moved with its port pairs by vendor
        // and model only while that is unambiguous.
        let moved = Self.screen("VX039", id: 20, uuid: "C")
        XCTAssertEqual(ScreenDeviceListing.pair([recordA], with: [moved])[recordA.key]?.displayID, 20)
        let twin = Self.screen("VX039", id: 21, uuid: "D")
        XCTAssertNil(ScreenDeviceListing.pair([recordA], with: [moved, twin])[recordA.key])
        XCTAssertNil(ScreenDeviceListing.pair([recordA, recordB], with: [moved])[recordA.key])
        // Unknown vendor and model say nothing.
        let blankRecord = ScreenDeviceRecord(
            screen: Self.screen("Adapter", id: 3, vendor: 0, model: 0, uuid: "E"), region: nil)
        let blank = Self.screen("Adapter", id: 4, vendor: 0, model: 0, uuid: "F")
        XCTAssertNil(ScreenDeviceListing.pair([blankRecord], with: [blank])[blankRecord.key])
    }

    func testAScreenAlreadyClaimedIsNotPairedTwice() {
        let record = ScreenDeviceRecord(screen: Self.oled, region: nil)
        let moved = Self.screen("VX039", id: 20, uuid: "C")
        var exact = Self.oled
        exact.displayID = 30
        let paired = ScreenDeviceListing.pair([record], with: [moved, exact])
        XCTAssertEqual(paired[record.key]?.displayID, 30)
        XCTAssertEqual(paired.count, 1)
    }

    func testTheMenuBarScreenIsNeverCovered() {
        XCTAssertEqual(ScreenDeviceListing.coverDecision(for: nil), .unplugged)
        XCTAssertEqual(ScreenDeviceListing.coverDecision(for: Self.builtIn), .menuBarScreen)
        XCTAssertEqual(ScreenDeviceListing.coverDecision(for: Self.oled), .cover(Self.oled))
    }

    // MARK: fit and rotation geometry

    func testTheFrameIsTheScreensShapeAndTurnsAtAQuarterTurn() {
        let g = PanelGeometry(width: 1920, height: 1080)
        XCTAssertTrue(ScreenDeviceGeometry.frameSize(of: g, rotation: 0) == (1920, 1080))
        XCTAssertTrue(ScreenDeviceGeometry.frameSize(of: g, rotation: 1) == (1080, 1920))
        XCTAssertTrue(ScreenDeviceGeometry.frameSize(of: g, rotation: 2) == (1920, 1080))
        XCTAssertTrue(ScreenDeviceGeometry.frameSize(of: g, rotation: 3) == (1080, 1920))
        let square = PanelGeometry(width: 1080, height: 1080)
        XCTAssertTrue(ScreenDeviceGeometry.frameSize(of: square, rotation: 1) == (1080, 1080))
        XCTAssertEqual(ScreenDeviceGeometry.normalized(5), 1)
        XCTAssertEqual(ScreenDeviceGeometry.normalized(-1), 3)
    }

    func testThePictureTurnsClockwiseAndCoversTheWholeScreen() {
        let points = CGSize(width: 1920, height: 1080)
        let upright = ScreenDeviceGeometry.pictureLayout(screenPoints: points, rotation: 0)
        XCTAssertEqual(upright.bounds, points)
        XCTAssertEqual(upright.angle, 0)
        let quarter = ScreenDeviceGeometry.pictureLayout(screenPoints: points, rotation: 1)
        XCTAssertEqual(quarter.bounds, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(quarter.angle, -.pi / 2, accuracy: 1e-9)
        let half = ScreenDeviceGeometry.pictureLayout(screenPoints: points, rotation: 2)
        XCTAssertEqual(half.bounds, points)
        XCTAssertEqual(half.angle, -.pi, accuracy: 1e-9)
        let three = ScreenDeviceGeometry.pictureLayout(screenPoints: points, rotation: 7)
        XCTAssertEqual(three.bounds, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(three.angle, -3 * .pi / 2, accuracy: 1e-9)
        // Turned bounds rotated by the angle fill the screen exactly.
        let turned = CGRect(origin: .zero, size: quarter.bounds)
            .applying(CGAffineTransform(rotationAngle: quarter.angle))
        XCTAssertEqual(turned.width, points.width, accuracy: 1e-6)
        XCTAssertEqual(turned.height, points.height, accuracy: 1e-6)
    }

    func testTheRegionIsFittedWithItsAspectKeptAndBlackElsewhere() {
        XCTAssertEqual(
            ScreenDeviceGeometry.fittedRect(
                region: CGSize(width: 800, height: 800), frame: (1920, 1080)),
            CGRect(x: 420, y: 0, width: 1080, height: 1080))
        XCTAssertEqual(
            ScreenDeviceGeometry.fittedRect(
                region: CGSize(width: 1600, height: 400), frame: (1920, 1080)),
            CGRect(x: 0, y: 300, width: 1920, height: 480))
        XCTAssertEqual(
            ScreenDeviceGeometry.fittedRect(
                region: CGSize(width: 960, height: 540), frame: (1920, 1080)),
            CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertNil(ScreenDeviceGeometry.fittedRect(region: .zero, frame: (1920, 1080)))
    }

    func testAQuarterTurnTurnsTheRegionOnItsSideOnARectangularScreen() {
        let g = PanelGeometry(width: 1920, height: 1080)
        let host = CGSize(width: 1512, height: 982)
        let wide = RegionSpec(display: "Built-in", x: 276, y: 221, width: 960, height: 540)
        let turned = ScreenDeviceGeometry.region(wide, for: 1, geometry: g, hostSize: host)
        XCTAssertEqual(turned.width, 540)
        XCTAssertEqual(turned.height, 960)
        XCTAssertEqual(turned.x + turned.width / 2, wide.x + wide.width / 2, accuracy: 0.5)
        // Already on its side for 270, and upright for 180: nothing to do.
        XCTAssertEqual(ScreenDeviceGeometry.region(turned, for: 3, geometry: g, hostSize: host), turned)
        XCTAssertEqual(ScreenDeviceGeometry.region(wide, for: 2, geometry: g, hostSize: host), wide)
        XCTAssertEqual(
            ScreenDeviceGeometry.region(turned, for: 0, geometry: g, hostSize: host).width, 960)
        // A square screen turns its picture alone.
        let square = PanelGeometry(width: 1080, height: 1080)
        XCTAssertEqual(
            ScreenDeviceGeometry.region(wide, for: 1, geometry: square, hostSize: host), wide)
    }

    func testAFirstRegionHasTheScreensShapeForItsRotation() {
        let g = PanelGeometry(width: 1920, height: 1080)
        let upright = ScreenDeviceGeometry.startingRegion(on: Self.builtIn, geometry: g, rotation: 0)
        XCTAssertEqual(upright.display, "Built-in Retina Display")
        XCTAssertEqual(upright.width / upright.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(upright.width, 1512)
        XCTAssertLessThanOrEqual(upright.height, 982)
        XCTAssertGreaterThanOrEqual(upright.x, 0)
        let onSide = ScreenDeviceGeometry.startingRegion(on: Self.builtIn, geometry: g, rotation: 1)
        XCTAssertEqual(onSide.height / onSide.width, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(onSide.height, 982)
    }

    // MARK: feedback exclusion

    func testCoverWindowsAreLeftOutOfEveryCapture() {
        let windows: [CGWindowID] = [11, 12, 13, 14]
        XCTAssertEqual(
            ScreenDeviceFeedback.windowsToExclude(windows, id: { $0 }, covers: [12, 14, 99]),
            [12, 14])
        XCTAssertEqual(ScreenDeviceFeedback.windowsToExclude(windows, id: { $0 }, covers: []), [])
    }

    func testARegionCannotBeDrawnOnACoveredScreen() {
        XCTAssertEqual(
            ScreenDeviceFeedback.regionHost(
                proposed: "BOE VX039", current: "Built-in Retina Display",
                covered: ["BOE VX039"]),
            "Built-in Retina Display")
        XCTAssertNil(
            ScreenDeviceFeedback.regionHost(
                proposed: "BOE VX039", current: nil, covered: ["BOE VX039"]))
        XCTAssertEqual(
            ScreenDeviceFeedback.regionHost(
                proposed: "Studio Display", current: "Built-in Retina Display",
                covered: ["BOE VX039"]),
            "Studio Display")
    }

    func testANewRegionStartsOnTheMenuBarScreenAndNeverOnACoveredOne() {
        XCTAssertEqual(
            ScreenDeviceFeedback.startingHost(
                attached: [Self.oled, Self.builtIn, Self.studio], covered: ["BOE VX039"])?.name,
            "Built-in Retina Display")
        XCTAssertEqual(
            ScreenDeviceFeedback.startingHost(
                attached: [Self.oled, Self.studio], covered: ["BOE VX039"])?.name,
            "Studio Display")
        XCTAssertNil(
            ScreenDeviceFeedback.startingHost(attached: [Self.oled], covered: ["BOE VX039"]))
    }
}
