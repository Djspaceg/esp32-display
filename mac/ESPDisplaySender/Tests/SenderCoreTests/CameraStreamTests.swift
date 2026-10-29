import XCTest

@testable import SenderCore
@testable import SenderProtocol

final class CameraStreamTests: XCTestCase {
    func testCameraIdentityDoesNotMistakeTheLegacyExtensionForTheNewOne() {
        XCTAssertFalse(CameraExtensionBridge.isOurCamera(
            localizedName: CameraExtensionBridge.deviceName, modelID: "XIAOML Kit"))
        XCTAssertTrue(CameraExtensionBridge.isOurCamera(
            localizedName: CameraExtensionBridge.deviceName,
            modelID: CameraExtensionBridge.deviceModelID))
    }

    func testAssemblerWaitsForAllFragmentsAndReassemblesInOrder() throws {
        let jpeg = Data((0..<1_400).map { UInt8($0 & 0xff) })
        let packets = CameraProtocol.fragments(for: jpeg, resolution: .vga, frameID: 9)
        let first = try XCTUnwrap(CameraProtocol.parseFragment(packets[0]))
        let second = try XCTUnwrap(CameraProtocol.parseFragment(packets[1]))
        var assembler = CameraFrameAssembler()

        XCTAssertNil(assembler.append(second))
        let completed = try XCTUnwrap(assembler.append(first))
        XCTAssertEqual(completed.0, jpeg)
        XCTAssertEqual(completed.1, .vga)
    }

    func testNewFrameReplacesAnIncompleteOlderFrame() throws {
        let old = CameraProtocol.fragments(
            for: Data(repeating: 1, count: 1_300), resolution: .qvga, frameID: 1)
        let current = CameraProtocol.fragments(
            for: Data(repeating: 2, count: 12), resolution: .qvga, frameID: 2)
        var assembler = CameraFrameAssembler()

        XCTAssertNil(assembler.append(try XCTUnwrap(CameraProtocol.parseFragment(old[0]))))
        let completed = try XCTUnwrap(
            assembler.append(try XCTUnwrap(CameraProtocol.parseFragment(current[0]))))
        XCTAssertEqual(completed.0, Data(repeating: 2, count: 12))
    }
}
