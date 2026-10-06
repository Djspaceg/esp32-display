import XCTest

@testable import SenderProtocol

/// The panel dials the update back to whatever address the invitation came
/// from, so that address has to be the Mac's WiFi one even when the default
/// route is a wired adapter on the same subnet - the bench Mac's own shape.
final class OTASourceAddressTests: XCTestCase {
    private let usbEthernet = OTASourceAddress.Interface(
        name: "en8", address: "192.168.1.139", netmask: "255.255.255.0", isWiFi: false)
    private let wifi = OTASourceAddress.Interface(
        name: "en0", address: "192.168.1.148", netmask: "255.255.255.0", isWiFi: true)
    private let vpn = OTASourceAddress.Interface(
        name: "utun1000", address: "11.113.0.76", netmask: "255.255.255.128", isWiFi: false)

    func testWiFiOnThePanelsSubnetWinsOverTheDefaultRouteAdapter() {
        XCTAssertEqual(
            OTASourceAddress.choose(
                toward: "192.168.1.83", among: [usbEthernet, wifi, vpn]),
            "192.168.1.148")
    }

    func testOrderOfInterfacesDoesNotMatter() {
        XCTAssertEqual(
            OTASourceAddress.choose(
                toward: "192.168.1.83", among: [wifi, usbEthernet]),
            "192.168.1.148")
    }

    /// WiFi on another subnet cannot reach the panel directly, so the kernel's
    /// own choice stands.
    func testWiFiOnAnotherSubnetIsNotForced() {
        let elsewhere = OTASourceAddress.Interface(
            name: "en0", address: "10.0.0.5", netmask: "255.255.255.0", isWiFi: true)
        XCTAssertNil(OTASourceAddress.choose(
            toward: "192.168.1.83", among: [usbEthernet, elsewhere]))
    }

    /// No WiFi at all, or a wired-only Mac: nothing to prefer, default route.
    func testWiredOnlyKeepsTheDefaultRoute() {
        XCTAssertNil(OTASourceAddress.choose(
            toward: "192.168.1.83", among: [usbEthernet, vpn]))
    }

    /// A name or an IPv6 address is not something this compares; the kernel
    /// decides, as it always did.
    func testNonIPv4PanelAddressKeepsTheDefaultRoute() {
        XCTAssertNil(OTASourceAddress.choose(toward: "panel.local", among: [wifi]))
        XCTAssertNil(OTASourceAddress.choose(toward: "fe80::1", among: [wifi]))
    }

    /// A wired interface on a narrower subnet is the route the kernel would
    /// take for this panel, and WiFi's broader match does not override it.
    func testAMoreSpecificWiredRouteIsNotOverridden() {
        let narrowWired = OTASourceAddress.Interface(
            name: "en8", address: "192.168.1.20", netmask: "255.255.255.128", isWiFi: false)
        XCTAssertNil(OTASourceAddress.choose(
            toward: "192.168.1.83", among: [narrowWired, wifi]))
    }

    /// Link-local 169.254/16 is configured on every interface, so matching it
    /// says nothing about which one reaches the panel.
    func testLinkLocalIsNeverForced() {
        let linkLocalWiFi = OTASourceAddress.Interface(
            name: "en0", address: "169.254.10.1", netmask: "255.255.0.0", isWiFi: true)
        XCTAssertNil(OTASourceAddress.choose(
            toward: "169.254.20.2", among: [linkLocalWiFi]))
    }

    func testOnlyPlainDecimalOctetsParse() {
        XCTAssertNil(OTASourceAddress.choose(toward: "192.168.1.+83", among: [wifi]))
        XCTAssertNil(OTASourceAddress.choose(toward: "192.168.1.256", among: [wifi]))
    }
}
