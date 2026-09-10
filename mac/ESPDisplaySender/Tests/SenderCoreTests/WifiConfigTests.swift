import XCTest

@testable import SenderCore

/// Picking the right USB port is the step that decides whether a rename or a
/// WiFi change lands on the display the user selected or on some other board
/// sitting on the same desk. The rules used to be entangled with serial I/O and
/// modal alerts, so they could only be checked by plugging in hardware.
final class PortSelectionTests: XCTestCase {

    // MARK: helpers

    private typealias Failure = WifiConfigUI.ConfigFailure

    /// Records what was probed so timeout policy can be asserted too.
    private final class Recorder {
        var calls: [(port: String, timeout: TimeInterval)] = []
        var answers: [String: WifiConfigUI.PortProbe]

        init(answers: [String: WifiConfigUI.PortProbe]) {
            self.answers = answers
        }

        func probe(_ port: String, _ timeout: TimeInterval) -> WifiConfigUI.PortProbe {
            calls.append((port, timeout))
            return answers[port] ?? .unavailable("no response")
        }
    }

    private func select(
        expectedName: String? = nil,
        expectedHardwareID: String? = nil,
        preferredPort: String? = nil,
        availablePorts: [String] = [],
        answers: [String: WifiConfigUI.PortProbe] = [:],
        recorder: Recorder? = nil
    ) -> Result<String, Failure> {
        let recorder = recorder ?? Recorder(answers: answers)
        return WifiConfigUI.selectPort(
            expectedName: expectedName,
            expectedHardwareID: expectedHardwareID,
            preferredPort: preferredPort,
            availablePorts: availablePorts,
            probe: recorder.probe)
    }

    private func expectFailure(
        _ result: Result<String, Failure>,
        title: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> Failure? {
        switch result {
        case .success(let port):
            XCTFail("expected failure, selected \(port)", file: file, line: line)
            return nil
        case .failure(let failure):
            XCTAssertEqual(failure.title, title, file: file, line: line)
            return failure
        }
    }

    func testHardwareIDFindsDeviceAfterPortRenumbering() throws {
        let result = select(
            expectedName: "studio-display",
            expectedHardwareID: "02:00:00:12:34:56",
            preferredPort: "/dev/cu.usbmodem-old",
            availablePorts: ["/dev/cu.usbmodem-new"],
            answers: [
                "/dev/cu.usbmodem-old": .unavailable("port disappeared"),
                "/dev/cu.usbmodem-new": .identified(.init(
                    name: "studio-display", hardwareID: "020000123456")),
            ])

        XCTAssertEqual(try result.get(), "/dev/cu.usbmodem-new")
    }

    func testHardwareIDDistinguishesDuplicateDeviceNames() throws {
        let result = select(
            expectedName: "studio-display",
            expectedHardwareID: "020000123456",
            availablePorts: ["/dev/cu.usbmodem-1", "/dev/cu.usbmodem-2"],
            answers: [
                "/dev/cu.usbmodem-1": .identified(.init(
                    name: "studio-display", hardwareID: "020000abcdef")),
                "/dev/cu.usbmodem-2": .identified(.init(
                    name: "studio-display", hardwareID: "020000123456")),
            ])

        XCTAssertEqual(try result.get(), "/dev/cu.usbmodem-2")
    }

    // MARK: assigned port

    /// Assigning a port is the user's explicit identity override, so a name
    /// that disagrees is not an error. Answering CFGSHOW at all is the only
    /// requirement, which is what proves the path speaks our protocol.
    func testAssignedPortWinsOverReportedName() throws {
        let result = select(
            expectedName: "studio-display",
            preferredPort: "/dev/cu.usbmodem-1",
            availablePorts: ["/dev/cu.usbmodem-2"],
            answers: ["/dev/cu.usbmodem-1": .named("something-else")])

        XCTAssertEqual(try result.get(), "/dev/cu.usbmodem-1")
    }

    func testAssignedPortThatDoesNotAnswerFails() {
        let result = select(
            expectedName: "studio-display",
            preferredPort: "/dev/cu.usbmodem-1",
            answers: ["/dev/cu.usbmodem-1": .unavailable("could not open")])

        let failure = expectFailure(result, title: "Assigned USB device unavailable")
        XCTAssertEqual(
            failure?.message, "Could not verify /dev/cu.usbmodem-1: could not open")
    }

    /// A cleared assignment is stored as an empty or whitespace string in some
    /// paths; it must fall through to discovery rather than probing "".
    func testBlankAssignedPortFallsThroughToDiscovery() throws {
        for blank in ["", "   "] {
            let recorder = Recorder(answers: ["/dev/cu.usbmodem-2": .named("studio-display")])
            let result = select(
                expectedName: "studio-display",
                preferredPort: blank,
                availablePorts: ["/dev/cu.usbmodem-2"],
                recorder: recorder)

            XCTAssertEqual(try result.get(), "/dev/cu.usbmodem-2")
            XCTAssertEqual(recorder.calls.map(\.port), ["/dev/cu.usbmodem-2"])
        }
    }

    // MARK: no ports

    func testNoPortsFails() {
        let result = select(expectedName: "studio-display", availablePorts: [])

        let failure = expectFailure(result, title: "No device found")
        XCTAssertEqual(
            failure?.message,
            "Connect the display board to this Mac with a USB cable, then try again.")
    }

    // MARK: one port

    func testSinglePortWithMatchingNameIsSelected() throws {
        let result = select(
            expectedName: "studio-display",
            availablePorts: ["/dev/cu.usbmodem-1"],
            answers: ["/dev/cu.usbmodem-1": .named("studio-display")])

        XCTAssertEqual(try result.get(), "/dev/cu.usbmodem-1")
    }

    /// Without a name to check against there is nothing to disambiguate, so the
    /// single connected board is the answer.
    func testSinglePortIsSelectedWhenNoNameIsKnown() throws {
        for name in [nil, "", "  "] as [String?] {
            let result = select(
                expectedName: name,
                availablePorts: ["/dev/cu.usbmodem-1"],
                answers: ["/dev/cu.usbmodem-1": .named("whatever")])

            XCTAssertEqual(try result.get(), "/dev/cu.usbmodem-1")
        }
    }

    /// The case that protects against writing WiFi settings to the wrong board.
    func testSinglePortWithWrongNameFails() {
        let result = select(
            expectedName: "studio-display",
            availablePorts: ["/dev/cu.usbmodem-1"],
            answers: ["/dev/cu.usbmodem-1": .named("travel-display")])

        let failure = expectFailure(result, title: "USB device mismatch")
        XCTAssertEqual(
            failure?.message,
            "The connected USB device at /dev/cu.usbmodem-1 reports \"travel-display\", "
                + "not \"studio-display\". Assign the correct port under Connection "
                + "before changing the display.")
    }

    func testSinglePortThatDoesNotAnswerFails() {
        let result = select(
            expectedName: "studio-display",
            availablePorts: ["/dev/cu.usbmodem-1"],
            answers: ["/dev/cu.usbmodem-1": .unavailable("no response from the device")])

        let failure = expectFailure(result, title: "USB device unavailable")
        XCTAssertEqual(
            failure?.message,
            "Could not verify /dev/cu.usbmodem-1: no response from the device")
    }

    // MARK: several ports

    /// Any USB serial device counts as a candidate, including phones and other
    /// dev boards, so with several attached and no name we cannot guess.
    func testSeveralPortsWithoutANameFails() {
        let result = select(
            expectedName: nil,
            availablePorts: ["/dev/cu.usbmodem-1", "/dev/cu.usbserial-2"])

        let failure = expectFailure(result, title: "Select a USB device")
        XCTAssertEqual(
            failure?.message,
            "More than one USB serial device is connected. Select a display in the "
                + "manager and assign its USB device under Connection.")
    }

    func testSeveralPortsResolveByReportedName() throws {
        let result = select(
            expectedName: "studio-display",
            availablePorts: ["/dev/cu.usbmodem-1", "/dev/cu.usbserial-2"],
            answers: [
                "/dev/cu.usbmodem-1": .named("travel-display"),
                "/dev/cu.usbserial-2": .named("studio-display"),
            ])

        XCTAssertEqual(try result.get(), "/dev/cu.usbserial-2")
    }

    /// Devices that do not speak the protocol are skipped rather than being
    /// reported, so an unrelated board does not mask a clean match.
    func testUnrelatedPortsAreSkippedNotReported() throws {
        let result = select(
            expectedName: "studio-display",
            availablePorts: ["/dev/cu.usbmodem-phone", "/dev/cu.usbserial-2"],
            answers: [
                "/dev/cu.usbmodem-phone": .unavailable("no response"),
                "/dev/cu.usbserial-2": .named("studio-display"),
            ])

        XCTAssertEqual(try result.get(), "/dev/cu.usbserial-2")
    }

    /// Two boards flashed with the same name cannot be told apart, and guessing
    /// would silently reconfigure the wrong one.
    func testDuplicateNamesAreAmbiguous() {
        let result = select(
            expectedName: "studio-display",
            availablePorts: ["/dev/cu.usbmodem-1", "/dev/cu.usbserial-2"],
            answers: [
                "/dev/cu.usbmodem-1": .named("studio-display"),
                "/dev/cu.usbserial-2": .named("studio-display"),
            ])

        let failure = expectFailure(result, title: "USB device is ambiguous")
        XCTAssertEqual(
            failure?.message,
            "More than one USB device reports the name \"studio-display\". Assign the "
                + "correct port under Connection before changing the display.")
    }

    func testNoMatchingNameFails() {
        let result = select(
            expectedName: "studio-display",
            availablePorts: ["/dev/cu.usbmodem-1", "/dev/cu.usbserial-2"],
            answers: [
                "/dev/cu.usbmodem-1": .named("travel-display"),
                "/dev/cu.usbserial-2": .named("desk-display"),
            ])

        let failure = expectFailure(result, title: "Display not found")
        XCTAssertEqual(
            failure?.message,
            "No connected USB device reports the name \"studio-display\". Assign its "
                + "port under Connection, or reconnect the display and try again.")
    }

    // MARK: probe timeouts

    /// Scanning has to be quicker per port than checking one known port,
    /// otherwise a handful of attached devices stalls the UI for many seconds.
    func testScanUsesShorterTimeoutThanASingleKnownPort() {
        let single = Recorder(answers: ["/dev/cu.usbmodem-1": .named("studio-display")])
        _ = select(
            expectedName: "studio-display",
            availablePorts: ["/dev/cu.usbmodem-1"],
            recorder: single)
        XCTAssertEqual(single.calls.map(\.timeout), [3])

        let assigned = Recorder(answers: ["/dev/cu.usbmodem-9": .named("studio-display")])
        _ = select(
            expectedName: "studio-display",
            preferredPort: "/dev/cu.usbmodem-9",
            recorder: assigned)
        XCTAssertEqual(assigned.calls.map(\.timeout), [3])

        let scan = Recorder(answers: [
            "/dev/cu.usbmodem-1": .named("travel-display"),
            "/dev/cu.usbserial-2": .named("studio-display"),
        ])
        _ = select(
            expectedName: "studio-display",
            availablePorts: ["/dev/cu.usbmodem-1", "/dev/cu.usbserial-2"],
            recorder: scan)
        XCTAssertEqual(scan.calls.map(\.timeout), [2, 2])
    }
}

final class USBDeviceOptionTests: XCTestCase {
    func testCFGSHOWCarriesExactTargetAndPhysicalBoard() {
        let name = Data("round-panel".utf8).base64EncodedString()
        let identity = WifiConfigUI.usbIdentity(from:
            "CFGINFO name64=\(name) id=28:84:85:55:55:94 "
                + "target=s3-185 board=st77916")

        XCTAssertEqual(identity.name, "round-panel")
        XCTAssertEqual(identity.hardwareID, "288485555594")
        XCTAssertEqual(identity.target, "s3-185")
        XCTAssertEqual(identity.board, "st77916")
    }

    func testCFGSHOWParsesLiveSerialFactsIncludingAppendedFields() {
        let identity = WifiConfigUI.usbIdentity(from:
            "CFGINFO ssid64=U3R1ZGlv name64=cm91bmQtcGFuZWw= "
                + "id=288485555594 connected=1 ip=192.168.1.44 rssi=-61 "
                + "flip=1 rot=2 auto=1 effective=3 motion=1 bl=low pwr=off "
                + "board=st77916 profile=st77916 target=s3-185 chip=esp32s3 "
                + "partition=8MB bat=72 ota=on ssid=Studio fw=spoof "
                + "bllevel=37 fw=1.5.0")

        XCTAssertEqual(identity.status?.firmwareVersion, "1.5.0")
        XCTAssertEqual(identity.status?.currentSSID, "Studio")
        XCTAssertEqual(identity.status?.networkConnected, true)
        XCTAssertEqual(identity.status?.ipAddress, "192.168.1.44")
        XCTAssertEqual(identity.status?.rssi, -61)
        XCTAssertEqual(identity.status?.rotation, 2)
        XCTAssertEqual(identity.status?.brightnessHigh, false)
        XCTAssertEqual(identity.status?.brightnessLevel, 37)
        XCTAssertEqual(identity.status?.manuallyOff, true)
        XCTAssertEqual(identity.status?.batteryPercent, 72)
        XCTAssertEqual(identity.status?.otaStatus, "on")
    }

    func testUSBDeviceOptionCarriesExactTargetAndPhysicalBoard() {
        let device = WifiConfigUI.USBDeviceOption(
            path: "/dev/cu.usbmodem1101",
            target: "s3-185",
            board: "st77916")
        XCTAssertEqual(device.target, "s3-185")
        XCTAssertEqual(device.board, "st77916")
    }

    func testReportedNameIsThePickerLabelInsteadOfThePort() {
        let device = WifiConfigUI.USBDeviceOption(
            path: "/dev/cu.usbmodem1101",
            name: "espdisplay-5594",
            hardwareID: "288485555594")

        XCTAssertEqual(device.displayName, "espdisplay-5594")
        XCTAssertEqual(device.path, "/dev/cu.usbmodem1101")
    }

    func testMacSuffixLabelsAnUnconfiguredBoard() {
        let device = WifiConfigUI.USBDeviceOption(
            path: "/dev/cu.usbmodem1101",
            hardwareID: "28:84:85:55:55:94")

        XCTAssertEqual(device.displayName, "ESP32-5594")
        XCTAssertEqual(device.hardwareID, "288485555594")
    }

    func testPortNameIsOnlyTheLastResort() {
        let device = WifiConfigUI.USBDeviceOption(path: "/dev/cu.usbserial-unknown")
        XCTAssertEqual(device.displayName, "cu.usbserial-unknown")
    }
}

/// Device names travel over the serial protocol and become the Bonjour service
/// name, so the firmware only accepts a restricted character set.
final class DeviceNameNormalizationTests: XCTestCase {

    func testLowercasesAndReplacesSeparators() {
        XCTAssertEqual(
            WifiConfigUI.normalizedDeviceName("My Display Name"), "my-display-name")
        XCTAssertEqual(
            WifiConfigUI.normalizedDeviceName("ESP32_C6 Panel"), "esp32-c6-panel")
    }

    func testKeepsDigitsAndDashes() {
        XCTAssertEqual(WifiConfigUI.normalizedDeviceName("panel-9050"), "panel-9050")
    }

    /// Punctuation and non-ASCII are dropped rather than substituted, so they
    /// cannot smuggle an unexpected byte into the name field.
    func testDropsPunctuationAndNonASCII() {
        XCTAssertEqual(WifiConfigUI.normalizedDeviceName("Panel!?.,"), "panel")
        XCTAssertEqual(WifiConfigUI.normalizedDeviceName("café"), "caf")
        XCTAssertEqual(WifiConfigUI.normalizedDeviceName("显示器"), "")
    }

    func testEmptyForInputWithNothingUsable() {
        XCTAssertEqual(WifiConfigUI.normalizedDeviceName(""), "")
        XCTAssertEqual(WifiConfigUI.normalizedDeviceName("!!!"), "")
    }

    /// The firmware name field is 32 bytes.
    func testTruncatesToThirtyTwoBytes() {
        let long = String(repeating: "a", count: 40)
        let normalized = WifiConfigUI.normalizedDeviceName(long)

        XCTAssertEqual(normalized.utf8.count, 32)
        XCTAssertEqual(normalized, String(repeating: "a", count: 32))
    }
}
