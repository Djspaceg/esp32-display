import XCTest

@testable import SenderProtocol

/// EMAP and EINP, byte for byte as the firmware's host tests write them
/// (firmware/test/test_band_protocol.cpp, "Input map").
final class InputMapProtocolTests: XCTestCase {

    func testInputsAreTheirGestureValues() {
        XCTAssertEqual(DeviceProtocol.TouchGesture.bootSinglePress.rawValue, 10)
        XCTAssertEqual(DeviceProtocol.TouchGesture.bootDoublePress.rawValue, 11)
        XCTAssertEqual(DeviceProtocol.TouchGesture.bootTriplePress.rawValue, 12)
        XCTAssertEqual(DeviceProtocol.TouchGesture.bootLongPress.rawValue, 13)
        XCTAssertEqual(DeviceProtocol.TouchGesture.bootExtraLongPress.rawValue, 14)
        XCTAssertEqual(DeviceProtocol.TouchGesture.powerKeyPress.rawValue, 15)
        XCTAssertEqual(DeviceProtocol.TouchGesture.powerKeyLongPress.rawValue, 16)
        XCTAssertEqual(DeviceProtocol.inputCount, 16)
        XCTAssertEqual(DeviceProtocol.Capabilities.inputMap.rawValue, 1 << 23)
        XCTAssertEqual(DeviceProtocol.BoardFunctionCode.displayPower.rawValue, 6)
    }

    func testMapPacketMatchesTheFirmware() {
        typealias G = DeviceProtocol.TouchGesture
        var codes: [G: DeviceProtocol.BoardFunctionCode] = [:]
        for gesture in G.allCases where gesture.rawValue <= 9 { codes[gesture] = .sender }
        codes[.tap] = .statusScreen
        codes[.bootSinglePress] = .statusScreen
        codes[.bootDoublePress] = .wifiSelector
        codes[.bootLongPress] = .rotate180
        codes[.bootExtraLongPress] = .displayPower
        codes[.powerKeyPress] = .displayPower
        let expected: [UInt8] = [
            0x45, 0x4d, 0x41, 0x50, 0x01, 0x10, 0x00, 0x00,
            0x02, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
            0x02, 0x03, 0x00, 0x05, 0x06, 0x06, 0x00,
        ]
        XCTAssertEqual([UInt8](DeviceProtocol.inputMapPacket(codes)), expected)
    }

    private func report(
        count: UInt8 = 16, inputs: UInt32 = 0x0001_FC7E, functions: UInt32 = 0x7F,
        current: [UInt8]? = nil, defaults: [UInt8]? = nil, magic: String = "EINP",
        version: UInt8 = 1, flags: UInt8 = 0, status: UInt8 = 1
    ) -> Data {
        var bytes = Array(magic.utf8) + [version, count, flags, status]
        for value in [inputs, functions] {
            bytes += [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                      UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
        }
        let plain: [UInt8] = [1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 3, 0, 5, 6, 0, 0]
        bytes += current ?? Array(plain.prefix(Int(count)))
        bytes += defaults ?? Array(plain.prefix(Int(count)))
        return Data(bytes)
    }

    func testReportNamesInputsFunctionsAndBothMaps() throws {
        var current: [UInt8] = [1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 3, 0, 5, 6, 0, 0]
        current[0] = 5
        let parsed = try XCTUnwrap(DeviceProtocol.parseInputReport(report(current: current)))
        XCTAssertEqual(
            parsed.inputs,
            [.tap, .swipeLeft, .swipeRight, .swipeUp, .swipeDown, .longPress,
             .bootSinglePress, .bootDoublePress, .bootTriplePress, .bootLongPress,
             .bootExtraLongPress, .powerKeyPress, .powerKeyLongPress])
        XCTAssertEqual(parsed.functions, Set(DeviceProtocol.BoardFunctionCode.allCases))
        XCTAssertEqual(parsed.current(.tap), 5)
        XCTAssertEqual(parsed.defaultCode(.tap), 1)
        XCTAssertEqual(parsed.defaultCode(.bootDoublePress), 3)
        XCTAssertEqual(parsed.defaultCode(.powerKeyLongPress), 0)
    }

    /// Byte 6 is the stored map's flags, byte 7 whether it is in force for
    /// this app; EMAP carries the flags in its byte 6 too.
    func testFlagsAndInForceStatus() throws {
        let inForce = try XCTUnwrap(DeviceProtocol.parseInputReport(report(flags: 1, status: 1)))
        XCTAssertEqual(inForce.flags, DeviceProtocol.inputMapFlagCountPresses)
        XCTAssertTrue(inForce.mapInForce)
        let notYet = try XCTUnwrap(DeviceProtocol.parseInputReport(report(status: 0)))
        XCTAssertFalse(notYet.mapInForce)
        XCTAssertEqual(
            [UInt8](DeviceProtocol.inputMapPacket([:], flags: 1))[6], 0x01)
    }

    func testKnobBoardReportsTheKnobAndNoSinglePress() throws {
        let parsed = try XCTUnwrap(DeviceProtocol.parseInputReport(
            report(inputs: 0x0000_7B80, functions: 0x63)))
        XCTAssertEqual(
            parsed.inputs,
            [.knobClockwise, .knobCounterclockwise, .knobPress, .bootDoublePress,
             .bootTriplePress, .bootLongPress, .bootExtraLongPress])
        XCTAssertEqual(parsed.functions, [.nothing, .sender, .rotate180, .displayPower])
    }

    /// A newer board may carry more inputs than this app names; they are
    /// read past, and the ones it does name still compare.
    func testLongerReportIsReadForTheInputsThisAppKnows() throws {
        let plain: [UInt8] = [1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 3, 0, 5, 6, 0, 0]
        let parsed = try XCTUnwrap(DeviceProtocol.parseInputReport(report(
            count: 18, inputs: 0x0006_0002, current: plain + [9, 9],
            defaults: plain + [9, 9])))
        XCTAssertEqual(parsed.inputs, [.tap])
        XCTAssertEqual(parsed.current(.bootLongPress), 5)
    }

    func testMalformedReportsAreRefused() {
        XCTAssertNotNil(DeviceProtocol.parseInputReport(report()))
        XCTAssertNil(DeviceProtocol.parseInputReport(report(magic: "EINX")))
        XCTAssertNil(DeviceProtocol.parseInputReport(report(version: 2)))
        XCTAssertNil(DeviceProtocol.parseInputReport(report().dropLast()))
        XCTAssertNil(DeviceProtocol.parseInputReport(report(count: 0, current: [], defaults: [])))
        XCTAssertNil(DeviceProtocol.parseInputReport(report() + Data([0])))
        // Not mistaken for any other inbound packet, nor they for it.
        XCTAssertNil(DeviceProtocol.parseTouch(report()))
        XCTAssertNil(DeviceProtocol.parseBattery(report()))
    }
}
