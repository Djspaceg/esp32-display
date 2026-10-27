import XCTest

@testable import SenderProtocol

final class CameraProtocolTests: XCTestCase {
    func testCapabilityBitMatchesFirmware() {
        XCTAssertEqual(DeviceProtocol.Capabilities.camera.rawValue, 1 << 24)
    }

    func testStartCommandLayout() {
        XCTAssertEqual(
            CameraProtocol.commandPacket(.start, resolution: .vga),
            Data([0x45, 0x43, 0x41, 0x4d, 1, 1, 2, 0]))
    }

    func testFragmentationRoundTripsEveryByte() throws {
        let jpeg = Data((0..<2_501).map { UInt8($0 & 0xff) })
        let packets = CameraProtocol.fragments(for: jpeg, resolution: .qvga, frameID: 0x1234)
        XCTAssertEqual(packets.count, 3)
        let fragments = try packets.map { try XCTUnwrap(CameraProtocol.parseFragment($0)) }
        XCTAssertEqual(fragments.map(\.index), [0, 1, 2])
        XCTAssertEqual(fragments.map(\.count), [3, 3, 3])
        XCTAssertEqual(fragments.map(\.frameID), [0x1234, 0x1234, 0x1234])
        XCTAssertEqual(fragments.reduce(into: Data()) { $0.append($1.payload) }, jpeg)
    }

    func testMalformedFragmentIsRefused() {
        var packet = CameraProtocol.commandPacket(.start, resolution: .qvga)
        packet.append(Data(repeating: 0, count: CameraProtocol.frameHeaderBytes))
        XCTAssertNil(CameraProtocol.parseFragment(packet))
        XCTAssertTrue(CameraProtocol.fragments(
            for: Data(repeating: 0, count: CameraProtocol.maximumFragmentPayload
                * (CameraProtocol.maximumFragments + 1)),
            resolution: .vga,
            frameID: 1).isEmpty)
    }
}
