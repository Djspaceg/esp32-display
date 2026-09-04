import XCTest
@testable import SenderProtocol

final class LargeTileProtocolTests: XCTestCase {
    func testGeometryCarriesThe720Square() {
        let geometry = LargeTileGeometry(width: 720, height: 720)
        XCTAssertTrue(geometry.isStreamable)
        XCTAssertEqual(geometry.tileCols, 45)
        XCTAssertEqual(geometry.tileRows, 45)
        XCTAssertEqual(geometry.tileCount, 2025)
        XCTAssertTrue(PanelGeometry(width: 720, height: 720).isStreamable)
        XCTAssertFalse(PanelGeometry(width: 720, height: 720).isBandStreamable)
    }

    func testHandAuthoredETL1Bytes() {
        var packet = LargeTileProtocol.header(
            frameId: 0x1234, dirtyCount: 3, landscape: true)
        packet.append(LargeTileProtocol.record(
            startTile: 2000, runLength: 3, codec: .raw,
            payload: [0xDE, 0xAD, 0xBE, 0xEF]))
        XCTAssertEqual([UInt8](packet), [
            0x45,0x54,0x4C,0x31, 0x34,0x12, 0x03,0x00, 0x01,0x00,
            0xD0,0x07, 0x03,0x00, 0x04,0x00, 0xDE,0xAD,0xBE,0xEF,
        ])
    }

    func testPackerStaysInsideDatagramBudget() {
        let geometry = LargeTileGeometry(width: 720, height: 720)
        var pixels = [UInt8](repeating: 0, count: geometry.frameBytes)
        for index in pixels.indices { pixels[index] = UInt8(truncatingIfNeeded: index) }
        let packets = LargeTilePacker.packets(
            frameId: 7, dirtyTiles: Array(0..<geometry.tileCount),
            pixels: pixels, geometry: geometry, landscape: false,
            policy: .aggressive)
        XCTAssertFalse(packets.isEmpty)
        XCTAssertTrue(packets.allSatisfy {
            $0.count <= LargeTileProtocol.maxPacketBytes
                && $0.prefix(4) == LargeTileProtocol.magic
        })
    }

    func testCapabilityBitIsIndependent() {
        XCTAssertEqual(DeviceProtocol.Capabilities.largeTileStream.rawValue,
                       1 << 19)
        XCTAssertTrue(DeviceProtocol.Capabilities.largeTileStream
            .intersection(.tileStream).isEmpty)
        XCTAssertTrue(DeviceProtocol.Capabilities.largeTileStream
            .intersection(.compressedBands).isEmpty)
    }
}
