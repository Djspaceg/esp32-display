import XCTest

@testable import SenderProtocol

final class BandProtocolTests: XCTestCase {

    // Bands must tile the frame exactly in both orientations, MTU-safe.
    func testGeometryTilesTheFrame() {
        let p = BandProtocol.bandGeometry(landscape: false)
        let l = BandProtocol.bandGeometry(landscape: true)
        XCTAssertEqual(p.bands * p.bandBytes, BandProtocol.frameBytes)
        XCTAssertEqual(l.bands * l.bandBytes, BandProtocol.frameBytes)
        XCTAssertLessThanOrEqual(6 + p.bandBytes, 1400)
        XCTAssertLessThanOrEqual(6 + l.bandBytes, 1400)
        // Portrait bands are whole 172px rows; landscape whole 320px rows.
        XCTAssertEqual(p.bandBytes % (172 * 2), 0)
        XCTAssertEqual(l.bandBytes % (320 * 2), 0)
    }

    // Same test vector as the firmware's parseHeader test - this is the
    // cross-language agreement check.
    func testPacketHeaderMatchesFirmwareVector() {
        let h = BandProtocol.packetHeader(
            frameId: 0x1234, band: 5, dirtyCount: 0x50, landscape: true)
        XCTAssertEqual([UInt8](h), [0x34, 0x12, 0x05, 0x00, 0x50, 0x80])

        let portrait = BandProtocol.packetHeader(
            frameId: 0, band: 0, dirtyCount: 80, landscape: false)
        XCTAssertEqual([UInt8](portrait), [0x00, 0x00, 0x00, 0x00, 0x50, 0x00])
    }

    func testDirtyBandsIdenticalFramesAreClean() {
        let frame = [UInt8](repeating: 0xAB, count: BandProtocol.frameBytes)
        XCTAssertEqual(BandProtocol.dirtyBands(new: frame, previous: frame, landscape: false), [])
        XCTAssertEqual(BandProtocol.dirtyBands(new: frame, previous: frame, landscape: true), [])
    }

    func testDirtyBandsDetectsSingleByteChange() {
        let prev = [UInt8](repeating: 0, count: BandProtocol.frameBytes)
        let (_, bandBytes) = BandProtocol.bandGeometry(landscape: false)

        var new = prev
        new[42 * bandBytes] = 1  // first byte of band 42
        XCTAssertEqual(BandProtocol.dirtyBands(new: new, previous: prev, landscape: false), [42])

        var lastByte = prev
        lastByte[BandProtocol.frameBytes - 1] = 1  // last byte of last band
        XCTAssertEqual(
            BandProtocol.dirtyBands(new: lastByte, previous: prev, landscape: false), [79])
    }

    func testDirtyBandsChangeSpanningBoundaryMarksBothBands() {
        let prev = [UInt8](repeating: 0, count: BandProtocol.frameBytes)
        let (_, bandBytes) = BandProtocol.bandGeometry(landscape: false)
        var new = prev
        new[5 * bandBytes - 1] = 1  // last byte of band 4
        new[5 * bandBytes] = 1      // first byte of band 5
        XCTAssertEqual(BandProtocol.dirtyBands(new: new, previous: prev, landscape: false), [4, 5])
    }

    func testDirtyBandsLandscapeGeometry() {
        let prev = [UInt8](repeating: 0, count: BandProtocol.frameBytes)
        let (bands, bandBytes) = BandProtocol.bandGeometry(landscape: true)
        var new = prev
        new[(bands - 1) * bandBytes] = 1  // first byte of band 85
        XCTAssertEqual(
            BandProtocol.dirtyBands(new: new, previous: prev, landscape: true), [bands - 1])
    }

    func testParseHeartbeat() {
        var packet = Data("EHB1".utf8)
        // shown=0x01020304, dropped=5, skipped=6, packets=0x00010000, heap=81920
        let values: [UInt32] = [0x0102_0304, 5, 6, 0x0001_0000, 81920]
        for v in values {
            packet.append(UInt8(v & 0xFF))
            packet.append(UInt8((v >> 8) & 0xFF))
            packet.append(UInt8((v >> 16) & 0xFF))
            packet.append(UInt8((v >> 24) & 0xFF))
        }
        let stats = BandProtocol.parseHeartbeat(packet)
        XCTAssertEqual(
            stats,
            BandProtocol.DeviceStats(
                shown: 0x0102_0304, dropped: 5, skipped: 6, packets: 0x0001_0000, heap: 81920))
    }

    func testParseHeartbeatRejectsGarbage() {
        XCTAssertNil(BandProtocol.parseHeartbeat(Data("EHB1".utf8)))       // too short
        XCTAssertNil(BandProtocol.parseHeartbeat(Data(repeating: 0, count: 24)))  // bad magic
        var long = Data("EHB1".utf8)
        long.append(Data(repeating: 0, count: 24))
        XCTAssertNil(BandProtocol.parseHeartbeat(long))                    // too long
        XCTAssertNil(BandProtocol.parseHeartbeat(Data("EPNG".utf8)))       // wrong type
    }
}

// MARK: - PanelGeometry tests

final class PanelGeometryTests: XCTestCase {

    // The parametric formula must reproduce the legacy hardcoded values
    // for the original 172x320 panel exactly.
    func testPanel172x320MatchesLegacyGeometry() {
        let geo = PanelGeometry.panel172x320

        // Portrait
        let legacyP = BandProtocol.bandGeometry(landscape: false)
        let paramP = BandProtocol.bandGeometry(for: geo, landscape: false)
        XCTAssertEqual(paramP.bands, legacyP.bands)
        XCTAssertEqual(paramP.bandBytes, legacyP.bandBytes)
        XCTAssertEqual(geo.bandCount(landscape: false), 80)
        XCTAssertEqual(geo.rowsPerBand(landscape: false), 4)
        XCTAssertEqual(geo.bandPayloadBytes(index: 0, landscape: false), 1376)

        // Landscape
        let legacyL = BandProtocol.bandGeometry(landscape: true)
        let paramL = BandProtocol.bandGeometry(for: geo, landscape: true)
        XCTAssertEqual(paramL.bands, legacyL.bands)
        XCTAssertEqual(paramL.bandBytes, legacyL.bandBytes)
        XCTAssertEqual(geo.bandCount(landscape: true), 86)
        XCTAssertEqual(geo.rowsPerBand(landscape: true), 2)
        XCTAssertEqual(geo.bandPayloadBytes(index: 0, landscape: true), 1280)

        // frameBytes
        XCTAssertEqual(geo.frameBytes, BandProtocol.frameBytes)
        XCTAssertEqual(geo.frameBytes, 110_080)
    }

    // 466x466 square panel (ESP32-S3-Touch-AMOLED-1.75C).
    // rowBytes = 466*2 = 932; fit = (1400-6)/932 = 1; bands = 466; all uniform.
    func testPanel466x466Geometry() {
        let geo = PanelGeometry(width: 466, height: 466)

        XCTAssertEqual(geo.frameBytes, 466 * 466 * 2)  // 434_312
        XCTAssertEqual(geo.rowsPerBand(landscape: false), 1)
        XCTAssertEqual(geo.bandCount(landscape: false), 466)
        XCTAssertEqual(geo.bandPayloadBytes(index: 0, landscape: false), 932)
        // All bands uniform
        XCTAssertEqual(geo.bandPayloadBytes(index: 465, landscape: false), 932)
        // Square: landscape and portrait are identical
        XCTAssertEqual(geo.bandCount(landscape: true), 466)
        XCTAssertEqual(geo.bandPayloadBytes(index: 0, landscape: true), 932)
        XCTAssertEqual(geo.rowsPerBand(landscape: true), 1)
        // MTU safe
        XCTAssertLessThanOrEqual(PanelGeometry.headerBytes + 932, PanelGeometry.maxPacketBytes)
    }

    // 412x412 panel.
    // rowBytes = 412*2 = 824; fit = (1400-6)/824 = 1; bands = 412.
    func testPanel412x412Geometry() {
        let geo = PanelGeometry(width: 412, height: 412)

        XCTAssertEqual(geo.frameBytes, 412 * 412 * 2)
        XCTAssertEqual(geo.rowsPerBand(landscape: false), 1)
        XCTAssertEqual(geo.bandCount(landscape: false), 412)
        XCTAssertEqual(geo.bandPayloadBytes(index: 0, landscape: false), 824)
        XCTAssertEqual(geo.bandPayloadBytes(index: 411, landscape: false), 824)
        XCTAssertLessThanOrEqual(PanelGeometry.headerBytes + 824, PanelGeometry.maxPacketBytes)
    }

    // 480x480 panel.
    // rowBytes = 480*2 = 960; fit = (1400-6)/960 = 1; bands = 480.
    func testPanel480x480Geometry() {
        let geo = PanelGeometry(width: 480, height: 480)

        XCTAssertEqual(geo.frameBytes, 480 * 480 * 2)
        XCTAssertEqual(geo.rowsPerBand(landscape: false), 1)
        XCTAssertEqual(geo.bandCount(landscape: false), 480)
        XCTAssertEqual(geo.bandPayloadBytes(index: 0, landscape: false), 960)
        XCTAssertEqual(geo.bandPayloadBytes(index: 479, landscape: false), 960)
        XCTAssertLessThanOrEqual(PanelGeometry.headerBytes + 960, PanelGeometry.maxPacketBytes)
    }

    // bandOffset must tile the frame without gaps or overlaps.
    func testBandOffsetsAndPayloadsTileTheFrame() {
        let panels = [
            PanelGeometry.panel172x320,
            PanelGeometry(width: 466, height: 466),
            PanelGeometry(width: 412, height: 412),
            PanelGeometry(width: 480, height: 480),
        ]
        for geo in panels {
            for landscape in [false, true] {
                let bands = geo.bandCount(landscape: landscape)
                var covered = 0
                for i in 0..<bands {
                    XCTAssertEqual(geo.bandOffset(index: i, landscape: landscape), covered,
                                   "\(geo.width)x\(geo.height) landscape=\(landscape) band \(i)")
                    covered += geo.bandPayloadBytes(index: i, landscape: landscape)
                }
                XCTAssertEqual(covered, geo.frameBytes,
                               "\(geo.width)x\(geo.height) landscape=\(landscape) total mismatch")
            }
        }
    }

    // Geometry-aware dirtyBands: identical frames produce no dirty bands.
    func testGeometryDirtyBandsCleanOnIdentical() {
        let geo = PanelGeometry(width: 466, height: 466)
        let frame = [UInt8](repeating: 0xCD, count: geo.frameBytes)
        XCTAssertEqual(
            BandProtocol.dirtyBands(new: frame, previous: frame, geometry: geo, landscape: false), [])
    }

    // Geometry-aware dirtyBands: detect a change in the last band.
    func testGeometryDirtyBandsDetectsLastBand() {
        let geo = PanelGeometry(width: 466, height: 466)
        let prev = [UInt8](repeating: 0, count: geo.frameBytes)
        var new = prev
        new[geo.frameBytes - 1] = 1  // last byte of last band
        let dirty = BandProtocol.dirtyBands(new: new, previous: prev, geometry: geo, landscape: false)
        XCTAssertEqual(dirty, [465])
    }

    // Geometry-aware dirtyBands on 172x320 produces same results as legacy.
    func testGeometryDirtyBandsMatchesLegacyFor172x320() {
        let geo = PanelGeometry.panel172x320
        let prev = [UInt8](repeating: 0, count: geo.frameBytes)
        var new = prev
        let (_, bandBytes) = BandProtocol.bandGeometry(landscape: false)
        new[10 * bandBytes] = 0xFF
        new[10 * bandBytes + 1] = 0xAB

        let legacy = BandProtocol.dirtyBands(new: new, previous: prev, landscape: false)
        let parametric = BandProtocol.dirtyBands(new: new, previous: prev, geometry: geo, landscape: false)
        XCTAssertEqual(legacy, parametric)
    }
}

final class DeviceProtocolTests: XCTestCase {
    func testControlPacketMatchesFirmwareVector() {
        let packet = DeviceProtocol.controlPacket(
            opcode: .flip, sequence: 0x1234, value: 1)
        XCTAssertEqual(
            [UInt8](packet),
            [0x45, 0x43, 0x54, 0x4C, 0x01, 0x02, 0x34, 0x12,
             0x01, 0x00, 0x00, 0x00])
    }

    func testParseDeviceInfoMatchesFirmwareVector() {
        var packet = Data("EINF".utf8)
        packet.append(contentsOf: [
            0x01, 0x02, 0x01, 0x13,             // versions + flags
            0x3F, 0x00, 0x00, 0x00,             // capabilities
            0x04, 0x03, 0x02, 0x01,             // uptime
            0xCD, 0xFF, 0x80,                    // RSSI -51, brightness 128
            0x05, 0x05,                          // string lengths
            0x02, 0x00, 0x00, 0x12, 0x34, 0x56, // device ID
        ])
        packet.append(contentsOf: "panel".utf8)
        packet.append(contentsOf: "1.2.3".utf8)

        let info = DeviceProtocol.parseInfo(packet)
        XCTAssertEqual(info?.deviceID, "020000123456")
        XCTAssertEqual(info?.name, "panel")
        XCTAssertEqual(info?.firmwareVersion, "1.2.3")
        XCTAssertEqual(info?.rssi, -51)
        XCTAssertEqual(info?.uptimeSeconds, 0x0102_0304)
        XCTAssertEqual(info?.brightness, 128)
        XCTAssertEqual(info?.capabilities.rawValue, 0x3F)
        XCTAssertEqual(info?.frameProtocolVersion, 2)
        XCTAssertTrue(info?.brightnessHigh == true)
        XCTAssertTrue(info?.flipped == true)
        XCTAssertTrue(info?.wifiConnected == true)
        XCTAssertTrue(info?.sleeping == false)
    }

    func testParseAck() {
        let packet = Data([
            0x45, 0x41, 0x43, 0x4B, 0x01, 0x02, 0x34, 0x12,
            0x00, 0x03, 0x80, 0x00,
        ])
        let ack = DeviceProtocol.parseAck(packet)
        XCTAssertEqual(ack?.opcode, .flip)
        XCTAssertEqual(ack?.sequence, 0x1234)
        XCTAssertTrue(ack?.succeeded == true)
        XCTAssertTrue(ack?.brightnessHigh == true)
        XCTAssertTrue(ack?.flipped == true)
        XCTAssertEqual(ack?.brightness, 128)
    }

    func testRejectsMalformedManagementPackets() {
        XCTAssertNil(DeviceProtocol.parseInfo(Data("EINF".utf8)))
        XCTAssertNil(DeviceProtocol.parseInfo(Data(repeating: 0, count: 27)))
        XCTAssertNil(DeviceProtocol.parseAck(Data("EACK".utf8)))

        var badVersion = Data(repeating: 0, count: 12)
        badVersion.replaceSubrange(0..<4, with: "EACK".utf8)
        badVersion[4] = 99
        XCTAssertNil(DeviceProtocol.parseAck(badVersion))
    }

    // Byte-for-byte the vector firmware/test/test_band_protocol.cpp asserts
    // writeTouch produces, copied by hand rather than shared: the point is that
    // two independent implementations agree, which a shared fixture could not
    // show.
    func testParseTouchMatchesFirmwareVector() {
        let packet = Data([
            0x45, 0x54, 0x43, 0x48, 0x01, 0x02, 0x34, 0x12,
            0x2C, 0x01, 0x96, 0x00, 0x01, 0x00,
        ])
        let touch = DeviceProtocol.parseTouch(packet)
        XCTAssertEqual(touch?.gesture, .swipeLeft)
        XCTAssertEqual(touch?.sequence, 0x1234)
        XCTAssertEqual(touch?.x, 300)
        XCTAssertEqual(touch?.y, 150)
        XCTAssertTrue(touch?.landscape == true)
    }

    func testParseTouchAcceptsEveryGesture() {
        for gesture in DeviceProtocol.TouchGesture.allCases {
            var packet = Data("ETCH".utf8)
            packet.append(contentsOf: [
                DeviceProtocol.touchVersion, gesture.rawValue,
                0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            ])
            XCTAssertEqual(DeviceProtocol.parseTouch(packet)?.gesture, gesture)
            XCTAssertTrue(DeviceProtocol.parseTouch(packet)?.landscape == false)
        }
    }

    func testRejectsMalformedTouchPackets() {
        func packet(magic: String = "ETCH", version: UInt8 = 1, gesture: UInt8 = 1,
                    length: Int = 14) -> Data {
            var data = Data(magic.utf8)
            data.append(contentsOf: [version, gesture])
            data.append(Data(repeating: 0, count: max(0, length - data.count)))
            return data.prefix(length)
        }

        XCTAssertNotNil(DeviceProtocol.parseTouch(packet()))
        XCTAssertNil(DeviceProtocol.parseTouch(packet(magic: "ETCX")))
        XCTAssertNil(DeviceProtocol.parseTouch(packet(version: 99)))
        // Gesture 0 and 7 sit either side of the defined range, which now runs to
        // 6 (long press). An unknown gesture is refused rather than ignored:
        // acting on a byte this parser does not understand is how a future
        // firmware's new gesture would get silently mapped onto the wrong action.
        //
        // That refusal is also what makes adding a gesture safe in both
        // directions without a version bump — an older sender drops the datagram
        // it cannot name, rather than guessing.
        XCTAssertNil(DeviceProtocol.parseTouch(packet(gesture: 0)))
        XCTAssertNotNil(DeviceProtocol.parseTouch(packet(gesture: 6)))
        XCTAssertNil(DeviceProtocol.parseTouch(packet(gesture: 7)))
        XCTAssertNil(DeviceProtocol.parseTouch(packet(length: 13)))
        XCTAssertNil(DeviceProtocol.parseTouch(packet(length: 15)))
    }

    // Inbound messages are told apart by trial-parsing in FrameSender, so no
    // parser may claim another's packet. If one ever did, whichever ran first
    // would silently swallow the other kind.
    func testTouchPacketIsNotClaimedByOtherParsers() {
        let touch = Data([
            0x45, 0x54, 0x43, 0x48, 0x01, 0x02, 0x34, 0x12,
            0x2C, 0x01, 0x96, 0x00, 0x01, 0x00,
        ])
        XCTAssertNotNil(DeviceProtocol.parseTouch(touch))
        XCTAssertNil(DeviceProtocol.parseInfo(touch))
        XCTAssertNil(DeviceProtocol.parseAck(touch))
        XCTAssertNil(BandProtocol.parseHeartbeat(touch))
    }

    func testTouchParserRejectsOtherMessageKinds() {
        var info = Data("EINF".utf8)
        info.append(contentsOf: [
            0x01, 0x02, 0x01, 0x13,
            0x3F, 0x00, 0x00, 0x00,
            0x04, 0x03, 0x02, 0x01,
            0xCD, 0xFF, 0x80,
            0x00, 0x00,
            0x02, 0x00, 0x00, 0x12, 0x34, 0x56,
        ])
        XCTAssertNotNil(DeviceProtocol.parseInfo(info))
        XCTAssertNil(DeviceProtocol.parseTouch(info))

        let ack = Data([
            0x45, 0x41, 0x43, 0x4B, 0x01, 0x02, 0x34, 0x12,
            0x00, 0x03, 0x80, 0x00,
        ])
        XCTAssertNotNil(DeviceProtocol.parseAck(ack))
        XCTAssertNil(DeviceProtocol.parseTouch(ack))
    }

    // Byte-for-byte the vector firmware/test/test_band_protocol.cpp asserts
    // writeBattery produces, copied by hand for the same reason the touch vector
    // is: two independent implementations agreeing is the whole point, and a
    // shared fixture would only show that one implementation agrees with itself.
    func testParseBatteryMatchesFirmwareVector() {
        let packet = Data([
            0x45, 0x42, 0x41, 0x54, 0x01, 0x03,
            0x57, 0x01, 0xAC, 0x0F, 0x00, 0x00,
        ])
        let battery = DeviceProtocol.parseBattery(packet)
        XCTAssertTrue(battery?.present == true)
        XCTAssertTrue(battery?.externalPower == true)
        XCTAssertEqual(battery?.percent, 87)
        XCTAssertEqual(battery?.state, .charging)
        XCTAssertEqual(battery?.millivolts, 4012)
    }

    // The unknown sentinels arrive as nil rather than as numbers: 0xFF percent
    // would read as a full battery and 0mV as a dead one.
    func testParseBatteryUnknownValuesBecomeNil() {
        let packet = Data([
            0x45, 0x42, 0x41, 0x54, 0x01, 0x00,
            0xFF, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        let battery = DeviceProtocol.parseBattery(packet)
        XCTAssertNotNil(battery)
        XCTAssertTrue(battery?.present == false)
        XCTAssertTrue(battery?.externalPower == false)
        XCTAssertNil(battery?.percent)
        XCTAssertNil(battery?.millivolts)
        XCTAssertEqual(battery?.state, .unknown)
    }

    func testParseBatteryAcceptsEveryChargeState() {
        for state in DeviceProtocol.ChargeState.allCases {
            var packet = Data("EBAT".utf8)
            packet.append(contentsOf: [
                DeviceProtocol.batteryVersion, DeviceProtocol.batteryFlagPresent,
                state.rawValue, state.rawValue, 0x74, 0x0E, 0x00, 0x00,
            ])
            let battery = DeviceProtocol.parseBattery(packet)
            XCTAssertEqual(battery?.state, state)
            XCTAssertEqual(battery?.percent, state.rawValue)
            XCTAssertEqual(battery?.millivolts, 3700)
            XCTAssertTrue(battery?.present == true)
            XCTAssertTrue(battery?.externalPower == false)
        }
    }

    func testRejectsMalformedBatteryPackets() {
        func packet(magic: String = "EBAT", version: UInt8 = 1, flags: UInt8 = 0x03,
                    percent: UInt8 = 87, state: UInt8 = 1, reserved: UInt8 = 0,
                    length: Int = 12) -> Data {
            var data = Data(magic.utf8)
            data.append(contentsOf: [version, flags, percent, state, 0xAC, 0x0F,
                                     reserved, reserved])
            data.append(Data(repeating: 0, count: max(0, length - data.count)))
            return data.prefix(length)
        }

        XCTAssertNotNil(DeviceProtocol.parseBattery(packet()))
        XCTAssertNil(DeviceProtocol.parseBattery(packet(magic: "EBAX")))
        XCTAssertNil(DeviceProtocol.parseBattery(packet(version: 99)))
        // 100 is full; 101 and up are not percentages at all. Only 0xFF has a
        // meaning above 100, and it means "no reading", not "very full".
        XCTAssertNotNil(DeviceProtocol.parseBattery(packet(percent: 100)))
        XCTAssertNil(DeviceProtocol.parseBattery(packet(percent: 101)))
        XCTAssertNil(DeviceProtocol.parseBattery(packet(percent: 254)))
        XCTAssertNotNil(DeviceProtocol.parseBattery(packet(percent: 0xFF)))
        // State 4 does not exist. Refused rather than treated as unknown, so a
        // future firmware's new state cannot be silently misread as a current one.
        XCTAssertNil(DeviceProtocol.parseBattery(packet(state: 4)))
        // Fixed length, so a short or over-long packet is the trailing-byte test.
        XCTAssertNil(DeviceProtocol.parseBattery(packet(length: 11)))
        XCTAssertNil(DeviceProtocol.parseBattery(packet(length: 13)))
        // The reserved bytes are ignored on purpose: a later firmware must be
        // able to use them without this parser rejecting every packet.
        XCTAssertNotNil(DeviceProtocol.parseBattery(packet(reserved: 0x5A)))
    }

    func testBatteryPacketIsNotClaimedByOtherParsers() {
        let battery = Data([
            0x45, 0x42, 0x41, 0x54, 0x01, 0x03,
            0x57, 0x01, 0xAC, 0x0F, 0x00, 0x00,
        ])
        XCTAssertNotNil(DeviceProtocol.parseBattery(battery))
        XCTAssertNil(DeviceProtocol.parseInfo(battery))
        XCTAssertNil(DeviceProtocol.parseAck(battery))
        XCTAssertNil(DeviceProtocol.parseTouch(battery))
        XCTAssertNil(BandProtocol.parseHeartbeat(battery))
    }

    func testBatteryParserRejectsOtherMessageKinds() {
        // EACK is the other 12-byte device packet, so it is the one this parser
        // could plausibly steal.
        let ack = Data([
            0x45, 0x41, 0x43, 0x4B, 0x01, 0x02, 0x34, 0x12,
            0x00, 0x03, 0x80, 0x00,
        ])
        XCTAssertNotNil(DeviceProtocol.parseAck(ack))
        XCTAssertNil(DeviceProtocol.parseBattery(ack))

        let control = DeviceProtocol.controlPacket(
            opcode: .brightness, sequence: 1, value: 1)
        XCTAssertEqual(control.count, 12)
        XCTAssertNil(DeviceProtocol.parseBattery(control))
    }

    // The capability bit is what gates the manager's battery row, so it has to
    // sit where the firmware puts it and must not overlap a neighbour.
    func testBatteryCapabilityBit() {
        XCTAssertEqual(DeviceProtocol.Capabilities.battery.rawValue, 1 << 11)
        XCTAssertTrue(
            DeviceProtocol.Capabilities.battery
                .isDisjoint(with: [.touch, .touchLongPress, .telemetry]))
    }

    // CAP_OTA was reserved from the start and unused until the firmware learned
    // to accept a push over WiFi. It is a runtime bit - a panel with no OTA
    // password does not set it - so what matters here is that this side reads it
    // out of the same place the firmware writes it.
    func testOtaCapabilityBit() {
        XCTAssertEqual(DeviceProtocol.Capabilities.ota.rawValue, 1 << 4)
        XCTAssertTrue(
            DeviceProtocol.Capabilities.ota
                .isDisjoint(with: [.restart, .sleepSync, .battery]))
    }

    // The exact capability bytes an OTA-capable panel sends: 0x000001FF is
    // everything every board always has, plus OTA. Typed out by hand here and in
    // firmware/test/test_band_protocol.cpp, deliberately not shared.
    func testParseDeviceInfoWithOtaCapability() {
        var packet = Data("EINF".utf8)
        packet.append(contentsOf: [
            0x01, 0x02, 0x01, 0x13,             // versions + flags
            0xFF, 0x01, 0x00, 0x00,             // capabilities incl. OTA
            0x04, 0x03, 0x02, 0x01,             // uptime
            0xCD, 0xFF, 0x80,                    // RSSI -51, brightness 128
            0x05, 0x05,                          // string lengths
            0x02, 0x00, 0x00, 0x12, 0x34, 0x56, // device ID
        ])
        packet.append(contentsOf: "panel".utf8)
        packet.append(contentsOf: "1.2.3".utf8)

        let info = DeviceProtocol.parseInfo(packet)
        XCTAssertEqual(info?.capabilities.rawValue, 0x1FF)
        XCTAssertTrue(info?.capabilities.contains(.ota) == true)
        // Still runtime-gated on the panel: the same packet with the bit clear
        // must not read as OTA-capable.
        XCTAssertFalse(
            DeviceProtocol.Capabilities(rawValue: 0x1EF).contains(.ota))
    }
}

final class DeviceSourceConfigTests: XCTestCase {
    func testParseValidConfig() throws {
        let json = """
            {
              "espdisplay-9050": { "display": "Tiny Monitor" },
              "espdisplay-abcd": { "window": "Music" }
            }
            """
        let config = try DeviceSourceConfig.parse(Data(json.utf8))
        XCTAssertEqual(config["espdisplay-9050"], SourceSpec(display: "Tiny Monitor"))
        XCTAssertEqual(config["espdisplay-abcd"], SourceSpec(window: "Music"))
        XCTAssertNil(config["espdisplay-none"])
    }

    func testParseEmptyAndMalformed() throws {
        XCTAssertEqual(try DeviceSourceConfig.parse(Data("{}".utf8)), [:])
        XCTAssertThrowsError(try DeviceSourceConfig.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try DeviceSourceConfig.parse(Data("[1,2]".utf8)))
    }
}

final class ConfigCommandsTests: XCTestCase {
    // A blank password field must NOT wipe the device's saved password: the
    // command omits the argument entirely, which the firmware reads as
    // "keep what's in use".
    func testKeepCurrentPasswordOmitsArgument() {
        let cmd = ConfigCommands.setWifi(ssid: "Stephens Manor", password: .keepCurrent)
        XCTAssertEqual(cmd, "CFGWIFI U3RlcGhlbnMgTWFub3I=")
        XCTAssertEqual(cmd.split(separator: " ").count, 2)  // no password arg
    }

    // An open network is a deliberate, distinct case: the argument is
    // present but empty.
    func testOpenNetworkSendsEmptyArgument() {
        let cmd = ConfigCommands.setWifi(ssid: "Cafe", password: .openNetwork)
        XCTAssertEqual(cmd, "CFGWIFI Q2FmZQ== ")
        XCTAssertTrue(cmd.hasSuffix(" "))
    }

    func testSetPasswordEncodesBoth() {
        let cmd = ConfigCommands.setWifi(ssid: "Net", password: .set("p ss"))
        XCTAssertEqual(cmd, "CFGWIFI TmV0 cCBzcw==")
        // Round-trip the password through base64 to prove the space survives.
        let arg = cmd.split(separator: " ")[2]
        XCTAssertEqual(
            String(data: Data(base64Encoded: String(arg))!, encoding: .utf8), "p ss")
    }

    // Unicode and emoji survive because everything is bytes.
    func testUnicodeSsidRoundTrips() {
        let ssid = "café 📺"
        let cmd = ConfigCommands.setWifi(ssid: ssid, password: .keepCurrent)
        let arg = String(cmd.split(separator: " ")[1])
        XCTAssertEqual(
            String(data: Data(base64Encoded: arg)!, encoding: .utf8), ssid)
    }

    func testDecodeFieldHandlesSpacesAndMissingKeys() {
        let line = "CFGINFO ssid64=U3RlcGhlbnMgTWFub3I= name64=ZXNwZGlzcGxheS05MDUw "
            + "connected=1 ip=192.168.1.120 rssi=-67 ssid=Stephens Manor"
        XCTAssertEqual(ConfigCommands.decodeField("ssid64=", from: line), "Stephens Manor")
        XCTAssertEqual(ConfigCommands.decodeField("name64=", from: line), "espdisplay-9050")
        XCTAssertNil(ConfigCommands.decodeField("nope64=", from: line))
    }

    func testSetName() {
        XCTAssertEqual(ConfigCommands.setName("panel-2"), "CFGNAME cGFuZWwtMg==")
    }
}
