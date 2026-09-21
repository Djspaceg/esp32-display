import Network
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// Discovery's own logic: which geometry a discovered panel gets streamed with,
/// and what reaches the panel list.
///
/// `NWBrowser.Result` has no public initialiser and a live browse needs a real
/// panel on the network, so `DeviceBrowser.devices(from:)` takes an
/// `Advertisement` - the two things the browser reads out of a result - and this
/// exercises that. What is NOT covered here, and cannot be without hardware: that
/// a real panel's TXT record arrives at all. That rests on the browser being
/// created with `.bonjourWithTXTRecord`, which is read from the framework's own
/// header and marked in DeviceBrowser rather than measured.
@MainActor
final class DiscoveryMetadataTests: XCTestCase {

    private func service(_ name: String) -> NWEndpoint {
        .service(name: name, type: "_espdisp._udp", domain: "local.", interface: nil)
    }

    // MARK: - geometry

    func testAPanelThatAdvertisesNothingHasNoGeometry() {
        // Absence is not evidence that this panel is the original 172x320
        // hardware. A concrete geometry drives frame allocation and the capture
        // aspect ratio, so discovery must leave it unknown until a source names
        // the panel's actual size.
        let devices = DeviceBrowser.devices(from: [
            DeviceBrowser.Advertisement(endpoint: service("espdisplay-9050"))
        ])
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].metadata, .empty)
        XCTAssertNil(devices[0].geometry)

        // And an empty record set, which is a different thing from no record set
        // and must land in the same place.
        let empty = DeviceBrowser.devices(from: [
            DeviceBrowser.Advertisement(endpoint: service("espdisplay-9050"), txtRecords: [:])
        ])
        XCTAssertNil(empty[0].geometry)
    }

    func testAPanelThatAdvertisesItsResolutionGetsIt() throws {
        let devices = DeviceBrowser.devices(from: [
            DeviceBrowser.Advertisement(
                endpoint: service("espdisplay-amoled"),
                txtRecords: ["res": "466x466", "chip": "esp32s3",
                             "target": "s3-175", "fw": "1.2.0"])
        ])
        XCTAssertEqual(devices[0].geometry, PanelGeometry(width: 466, height: 466))
        XCTAssertEqual(devices[0].metadata.geometry, PanelGeometry(width: 466, height: 466))
        XCTAssertEqual(devices[0].metadata.chip, "esp32s3")
        XCTAssertEqual(devices[0].metadata.target, "s3-175")
        XCTAssertEqual(devices[0].metadata.firmwareVersion, "1.2.0")
        // The band layout that follows, which is the thing that was wrong before:
        // this panel was being sent 80 bands of 172-pixel rows.
        let geometry = try XCTUnwrap(devices[0].geometry)
        XCTAssertEqual(geometry.bandCount(landscape: false), 466)
        XCTAssertEqual(geometry.frameBytes, 466 * 466 * 2)
    }

    func testAdvertisedGeometryRealignsAStoredFallbackRegion() throws {
        let stale = RegionSpec(
            display: "Studio", x: 493, y: 817, width: 172, height: 320)
        var panel = PanelSnapshot(
            serviceName: "white-cube", displayName: "white-cube")
        panel.source = .region(stale)
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [])

        manager.noteDiscovery([
            DeviceBrowser.Device(
                name: "white-cube",
                endpoint: service("white-cube"),
                metadata: ServiceMetadata(txtRecords: ["res": "240x240"]))
        ])

        let corrected = try XCTUnwrap(manager.panels[0].source.region)
        XCTAssertEqual(corrected.width, 240, accuracy: 0.001)
        XCTAssertEqual(corrected.height, 240, accuracy: 0.001)
        XCTAssertEqual(
            corrected.x + corrected.width / 2,
            stale.x + stale.width / 2,
            accuracy: 0.001)
        XCTAssertEqual(
            corrected.y + corrected.height / 2,
            stale.y + stale.height / 2,
            accuracy: 0.001)
    }

    func testAnImplausibleResolutionIsUnknown() {
        // Do not propagate an invalid geometry: it drives band arithmetic and
        // frame allocation. Do not replace it with a legacy concrete geometry
        // either: this panel's size is unknown.
        for value in ["0x0", "60000x60000", "800x480", "junk", ""] {
            let devices = DeviceBrowser.devices(from: [
                DeviceBrowser.Advertisement(
                    endpoint: service("espdisplay-9050"), txtRecords: ["res": value])
            ])
            XCTAssertNil(devices[0].geometry, "res=\(value)")
            XCTAssertNil(devices[0].metadata.geometry, "res=\(value)")
        }
    }

    // MARK: - the mapping itself

    func testKeepsTheServiceNameAndEndpointAsBefore() {
        let endpoint = service("espdisplay-9050")
        let devices = DeviceBrowser.devices(from: [
            DeviceBrowser.Advertisement(endpoint: endpoint, txtRecords: ["name": "Kitchen"])
        ])
        XCTAssertEqual(devices[0].name, "espdisplay-9050", "the instance name, not the TXT name")
        XCTAssertEqual(devices[0].endpoint, endpoint)
        XCTAssertEqual(devices[0].metadata.name, "Kitchen")
    }

    func testDropsAnythingThatIsNotABonjourService() {
        // The browse is for a Bonjour type, so this should not happen; it is a
        // guard the original code had and losing it would put an endpoint with no
        // instance name into the panel list.
        let devices = DeviceBrowser.devices(from: [
            DeviceBrowser.Advertisement(endpoint: .hostPort(host: "192.168.1.7", port: 5568)),
            DeviceBrowser.Advertisement(endpoint: service("espdisplay-9050")),
        ])
        XCTAssertEqual(devices.map(\.name), ["espdisplay-9050"])
    }

    func testSortsByName() {
        // The panel list's order comes from here, so the sort is part of the
        // mapping rather than a detail of the old closure.
        let devices = DeviceBrowser.devices(from: [
            DeviceBrowser.Advertisement(endpoint: service("espdisplay-zulu")),
            DeviceBrowser.Advertisement(endpoint: service("espdisplay-alpha")),
            DeviceBrowser.Advertisement(endpoint: service("espdisplay-mike")),
        ])
        XCTAssertEqual(
            devices.map(\.name), ["espdisplay-alpha", "espdisplay-mike", "espdisplay-zulu"])
    }

    func testEachDeviceGetsItsOwnMetadata() {
        // Two panels of different resolutions in one browse result, which is the
        // configuration this whole feature exists for.
        let devices = DeviceBrowser.devices(from: [
            DeviceBrowser.Advertisement(
                endpoint: service("espdisplay-amoled"),
                txtRecords: ["res": "466x466", "chip": "esp32s3"]),
            DeviceBrowser.Advertisement(
                endpoint: service("espdisplay-9050"),
                txtRecords: ["res": "172x320", "chip": "esp32c6"]),
        ])
        XCTAssertEqual(devices[0].name, "espdisplay-9050")
        XCTAssertEqual(devices[0].geometry, .panel172x320)
        XCTAssertEqual(devices[0].metadata.chip, "esp32c6")
        XCTAssertEqual(devices[1].name, "espdisplay-amoled")
        XCTAssertEqual(devices[1].geometry, PanelGeometry(width: 466, height: 466))
        XCTAssertEqual(devices[1].metadata.chip, "esp32s3")
    }

    func testReadsTXTRecordsOffABrowseResultMetadata() {
        // The one step between a browse result and the pure mapping.
        // NWBrowser.Result cannot be built here, but its Metadata can.
        let record = NWTXTRecord(["res": "466x466", "chip": "esp32s3"])
        XCTAssertEqual(
            DeviceBrowser.txtRecords(from: .bonjour(record)),
            ["res": "466x466", "chip": "esp32s3"])
        // `.none` is what a result carries when no TXT record was retrieved, and
        // it must be nil rather than an empty dictionary so the two stay
        // distinguishable at the boundary.
        XCTAssertNil(DeviceBrowser.txtRecords(from: .none))
    }

    func testUSBIdentitySuppliesGeometryForAKnownBoard() {
        let hardwareID = "80456b350450"
        let port = "/dev/cu.example"
        var panel = PanelSnapshot(serviceName: "round", displayName: "round")
        panel.hardwareID = hardwareID
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [port])

        let identity = WifiConfigUI.usbIdentity(from:
            "CFGINFO id=80456b350450 connected=0 ip=0.0.0.0 rot=3 autorot=1 "
                + "board=co5300 profile=co5300 target=s3 chip=esp32s3 fw=1.5.0")
        manager.noteUSBIdentity(path: port, identity: identity, generation: 0)

        XCTAssertEqual(
            manager.panels[0].geometry, PanelGeometry(width: 466, height: 466))
    }

    func testUSBIdentityDoesNotGuessAnUnrecognizedBoardGeometry() {
        let hardwareID = "80456b350450"
        let port = "/dev/cu.example"
        var panel = PanelSnapshot(serviceName: "future", displayName: "future")
        panel.hardwareID = hardwareID
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [port])

        manager.noteUSBIdentity(
            path: port,
            name: "future",
            hardwareID: hardwareID,
            target: "s3",
            board: "future-panel",
            chip: "esp32s3")

        XCTAssertNil(manager.panels[0].geometry)
    }

    // MARK: - what the panel list keeps

    func testDiscoveryRecordsTheChipOnOwnedPanelRows() {
        let manager = PanelManager(
            previewPanels: [
                PanelSnapshot(
                    serviceName: "espdisplay-9050", displayName: "espdisplay-9050"),
                PanelSnapshot(
                    serviceName: "espdisplay-amoled", displayName: "espdisplay-amoled"),
            ],
            savedNetworkNames: [], usbSerialPorts: [])
        manager.noteDiscovery([
            DeviceBrowser.Device(
                name: "espdisplay-9050",
                endpoint: service("espdisplay-9050"),
                metadata: ServiceMetadata(txtRecords: [
                    "chip": "esp32c6", "target": "c6", "res": "172x320",
                ])),
            DeviceBrowser.Device(
                name: "espdisplay-amoled",
                endpoint: service("espdisplay-amoled"),
                metadata: ServiceMetadata(txtRecords: [
                    "chip": "esp32s3", "target": "s3-185", "res": "466x466",
                ])),
        ])
        XCTAssertEqual(manager.panels.count, 2)
        XCTAssertEqual(manager.panels.first { $0.serviceName == "espdisplay-9050" }?.chip,
                       "esp32c6")
        XCTAssertEqual(manager.panels.first { $0.serviceName == "espdisplay-9050" }?.target,
                       "c6")
        XCTAssertEqual(manager.panels.first { $0.serviceName == "espdisplay-amoled" }?.chip,
                       "esp32s3")
        XCTAssertEqual(manager.panels.first { $0.serviceName == "espdisplay-amoled" }?.target,
                       "s3-185")
    }

    func testAPanelThatAdvertisesNoChipHasNoneRecorded() {
        let manager = PanelManager(
            previewPanels: [PanelSnapshot(
                serviceName: "espdisplay-9050", displayName: "espdisplay-9050")],
            savedNetworkNames: [], usbSerialPorts: [])
        manager.noteDiscovery([
            DeviceBrowser.Device(
                name: "espdisplay-9050", endpoint: service("espdisplay-9050"))
        ])
        XCTAssertNil(manager.panels[0].chip, "firmware older than the record says nothing")
        XCTAssertNil(manager.panels[0].target)
    }

    func testALaterResultWithoutAChipDoesNotEraseOne() {
        // NWBrowser can report a service and then report it again with metadata
        // attached, so the arrival order is not guaranteed. Overwriting
        // unconditionally would let a metadata-less result erase a chip that had
        // already arrived, and there is no such thing as a panel that stops
        // knowing which chip it is.
        let manager = PanelManager(
            previewPanels: [PanelSnapshot(
                serviceName: "espdisplay-9050", displayName: "espdisplay-9050")],
            savedNetworkNames: [], usbSerialPorts: [])
        let endpoint = service("espdisplay-9050")
        manager.noteDiscovery([
            DeviceBrowser.Device(name: "espdisplay-9050", endpoint: endpoint,
                                 metadata: ServiceMetadata(txtRecords: ["chip": "esp32c6"]))
        ])
        XCTAssertEqual(manager.panels[0].chip, "esp32c6")

        manager.noteDiscovery([
            DeviceBrowser.Device(name: "espdisplay-9050", endpoint: endpoint)
        ])
        XCTAssertEqual(manager.panels[0].chip, "esp32c6", "still known")

        // A panel that reports a different chip is believed, though: that is a
        // renamed service reaching different hardware, not missing information.
        manager.noteDiscovery([
            DeviceBrowser.Device(name: "espdisplay-9050", endpoint: endpoint,
                                 metadata: ServiceMetadata(txtRecords: ["chip": "esp32s3"]))
        ])
        XCTAssertEqual(manager.panels[0].chip, "esp32s3")
    }

    func testALaterResultWithoutATargetDoesNotEraseOne() {
        let manager = PanelManager(
            previewPanels: [PanelSnapshot(
                serviceName: "espdisplay-amoled", displayName: "espdisplay-amoled")],
            savedNetworkNames: [], usbSerialPorts: [])
        let endpoint = service("espdisplay-amoled")
        manager.noteDiscovery([
            DeviceBrowser.Device(
                name: "espdisplay-amoled", endpoint: endpoint,
                metadata: ServiceMetadata(txtRecords: [
                    "chip": "esp32s3", "target": "s3-185",
                ])),
        ])
        XCTAssertEqual(manager.panels[0].target, "s3-185")

        manager.noteDiscovery([
            DeviceBrowser.Device(name: "espdisplay-amoled", endpoint: endpoint),
        ])
        XCTAssertEqual(manager.panels[0].target, "s3-185")
    }

    func testDisappearanceStartsANewMetadataGeneration() {
        let manager = PanelManager(
            previewPanels: [PanelSnapshot(
                serviceName: "espdisplay-amoled", displayName: "espdisplay-amoled")],
            savedNetworkNames: [], usbSerialPorts: [])
        let endpoint = service("espdisplay-amoled")
        manager.noteDiscovery([
            DeviceBrowser.Device(
                name: "espdisplay-amoled", endpoint: endpoint,
                metadata: ServiceMetadata(txtRecords: [
                    "chip": "esp32s3", "target": "s3-185", "res": "360x360",
                ])),
        ])
        XCTAssertEqual(manager.panels[0].target, "s3-185")
        XCTAssertEqual(manager.panels[0].geometry, PanelGeometry(width: 360, height: 360))

        manager.noteDiscovery([])
        XCTAssertNil(manager.panels[0].chip)
        XCTAssertNil(manager.panels[0].target)
        XCTAssertNil(manager.panels[0].geometry)

        // Reappearing on target-less firmware is a new answer, not permission
        // to reuse the previous same-chip S3 target.
        manager.noteDiscovery([
            DeviceBrowser.Device(
                name: "espdisplay-amoled", endpoint: endpoint,
                metadata: ServiceMetadata(txtRecords: ["chip": "esp32s3"])),
        ])
        XCTAssertEqual(manager.panels[0].chip, "esp32s3")
        XCTAssertNil(manager.panels[0].target)
    }

    func testChipArrivesOnAPanelThatWasAlreadyInTheList() {
        // A panel restored from disk, or one whose first browse result arrived
        // before its TXT query answered. Recording the chip only while creating
        // the row would leave both of those with no chip forever.
        let existing = PanelSnapshot(
            serviceName: "espdisplay-9050", displayName: "Kitchen")
        let manager = PanelManager(
            previewPanels: [existing], savedNetworkNames: [], usbSerialPorts: [])
        XCTAssertNil(manager.panels[0].chip)

        manager.noteDiscovery([
            DeviceBrowser.Device(name: "espdisplay-9050",
                                 endpoint: service("espdisplay-9050"),
                                 metadata: ServiceMetadata(txtRecords: ["chip": "esp32c6"]))
        ])
        XCTAssertEqual(manager.panels.count, 1, "no second row for the same panel")
        XCTAssertEqual(manager.panels[0].chip, "esp32c6")
        XCTAssertEqual(manager.panels[0].displayName, "Kitchen", "the row is otherwise intact")
    }

    // MARK: - the geometry reaching the streaming path

    func testASenderCarriesTheGeometryItWasBuiltWith() {
        // Constructing a sender opens nothing: FrameSender.init only stores its
        // arguments, and nothing connects until start().
        let discovered = DeviceBrowser.devices(from: [
            DeviceBrowser.Advertisement(
                endpoint: service("espdisplay-amoled"), txtRecords: ["res": "466x466"])
        ])[0]
        guard let geometry = discovered.geometry else {
            return XCTFail("the advertised resolution must be available")
        }
        let sender = FrameSender(endpoint: discovered.endpoint, geometry: geometry)
        XCTAssertEqual(sender.geometry, PanelGeometry(width: 466, height: 466))

        // Both inits default to the original panel, which is what an explicit
        // --host still gets: it skips discovery, so there is no TXT record to
        // take a resolution from.
        XCTAssertEqual(FrameSender(host: "192.168.1.7", port: 5568).geometry, .panel172x320)
        XCTAssertEqual(
            FrameSender(endpoint: discovered.endpoint).geometry, .panel172x320)
    }

    func testTheTestPatternFollowsTheGeometryToo() {
        // Test mode sizes its buffer from the sender's geometry, so the pattern
        // has to fill the same buffer: send(frame:) preconditions on
        // geometry.frameBytes and would trap on a mismatch rather than send a
        // squashed picture.
        let square = PanelGeometry(width: 466, height: 466)
        var frame = [UInt8](repeating: 0, count: square.frameBytes)
        TestPattern.frame(tick: 3, landscape: false, geometry: square, into: &frame)
        XCTAssertEqual(frame.count, square.frameBytes)
        XCTAssertTrue(frame.contains { $0 != 0 }, "something was drawn")
        // The moving bar is white, and at tick 3 it crosses the top of the frame.
        XCTAssertEqual(Array(frame.prefix(4)), [0xFF, 0xFF, 0xFF, 0xFF])
        // The LAST pixel matters more than the first: a pattern still drawing at
        // 172x320 would fill the front of this buffer and leave the tail black,
        // which every "something was drawn" check would sail past. At x=465 the
        // red channel is full scale and green and blue are zero, so 0xF800.
        XCTAssertEqual(Array(frame.suffix(2)), [0xF8, 0x00])

        // And the default argument is the historical 172x320 pattern, byte for
        // byte, so the panels that already work are untouched by the new
        // parameter.
        var defaulted = [UInt8](repeating: 0, count: PanelGeometry.panel172x320.frameBytes)
        var explicit = defaulted
        TestPattern.frame(tick: 7, landscape: true, into: &defaulted)
        TestPattern.frame(
            tick: 7, landscape: true, geometry: .panel172x320, into: &explicit)
        XCTAssertEqual(defaulted, explicit)
    }

    // MARK: - what a bundle would make of a discovered panel

    func testADiscoveredChipIsTheVocabularyABundleUses() {
        // The end of the thread this feature lays: a chip token off the wire has
        // to be the same string a manifest keys its images by. Checked here
        // rather than only in SenderProtocolTests because this is where the wire
        // value actually comes from.
        let device = DeviceBrowser.devices(from: [
            DeviceBrowser.Advertisement(
                endpoint: service("espdisplay-9050"),
                txtRecords: [
                    "chip": "esp32c6", "target": "c6", "res": "172x320",
                    "fw": "1.2.0",
                ])
        ])[0]
        XCTAssertEqual(device.metadata.chip, "esp32c6")
        XCTAssertEqual(device.metadata.target, "c6")
        XCTAssertTrue(device.metadata.namesAChip)
        // And the token a firmware that cannot tell sends, which must not read as
        // a chip.
        let vague = DeviceBrowser.devices(from: [
            DeviceBrowser.Advertisement(
                endpoint: service("espdisplay-9050"), txtRecords: ["chip": "unknown"])
        ])[0]
        XCTAssertEqual(vague.metadata.chip, ServiceMetadata.unknownChip)
        XCTAssertFalse(vague.metadata.namesAChip)
    }
}
