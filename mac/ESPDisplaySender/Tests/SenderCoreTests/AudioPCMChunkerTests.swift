import XCTest

@testable import SenderCore

final class AudioPCMChunkerTests: XCTestCase {
    func testSplitsCaptureCallbacksIntoDescriptorSizedPackets() {
        var chunker = AudioPCMChunker(packetFrames: 4, channels: 2)

        XCTAssertEqual(chunker.append(Data(repeating: 1, count: 10)), [])
        XCTAssertEqual(chunker.pending.count, 10)
        XCTAssertEqual(
            chunker.append(Data(repeating: 2, count: 30)),
            [
                Data(repeating: 1, count: 10)
                    + Data(repeating: 2, count: 6),
                Data(repeating: 2, count: 16),
            ])
        XCTAssertEqual(chunker.pending, Data(repeating: 2, count: 8))
    }

    func testMonoUsesTwoBytesPerFrame() {
        var chunker = AudioPCMChunker(packetFrames: 3, channels: 1)
        XCTAssertEqual(
            chunker.append(Data((0..<12).map { UInt8($0) })),
            [
                Data((0..<6).map { UInt8($0) }),
                Data((6..<12).map { UInt8($0) }),
            ])
        XCTAssertTrue(chunker.pending.isEmpty)
    }
}
