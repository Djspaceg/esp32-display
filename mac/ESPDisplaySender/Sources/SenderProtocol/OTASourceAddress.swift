import Foundation

/// Which of this Mac's addresses an OTA push should send its datagrams from.
///
/// ArduinoOTA dials the image transfer BACK to the source address of the
/// authentication datagram (`_ota_ip = _udp_ota.remoteIP()`, ArduinoOTA.cpp:306,
/// then `client.connect(_ota_ip, ...)` at :364). Left to the kernel, that source
/// is whatever the default route's interface owns - on the bench Mac a USB
/// Ethernet adapter on the same /24 as its WiFi - so the panel is told to come
/// back to an address on a path it never spoke to. Panels are WiFi devices, so
/// when this Mac's WiFi is on the panel's own subnet, that is the address to
/// send from. In every other shape the kernel's choice stands, exactly as before.
public enum OTASourceAddress {
    public struct Interface: Equatable, Sendable {
        public let name: String
        public let address: String
        public let netmask: String
        public let isWiFi: Bool

        public init(name: String, address: String, netmask: String, isWiFi: Bool) {
            self.name = name
            self.address = address
            self.netmask = netmask
            self.isWiFi = isWiFi
        }
    }

    /// The WiFi address on `panel`'s subnet, or nil to leave it to the kernel.
    ///
    /// Nil for a panel that is not a dotted IPv4 address: the push only ever
    /// targets the live session's resolved IPv4 address, and anything else is
    /// not something a netmask comparison can say anything about. Nil for
    /// link-local 169.254/16, which every interface carries, so a match there
    /// says nothing. And nil when a non-WiFi interface matches on a longer
    /// prefix: that is the route the kernel would take, and it is more specific.
    public static func choose(toward panel: String, among interfaces: [Interface]) -> String? {
        guard let target = ipv4(panel), target & 0xFFFF_0000 != 0xA9FE_0000 else { return nil }
        func matchingPrefix(_ candidate: Interface) -> Int? {
            guard let address = ipv4(candidate.address),
                  let mask = ipv4(candidate.netmask), mask != 0,
                  address & mask == target & mask
            else { return nil }
            return mask.nonzeroBitCount
        }
        let wired = interfaces.filter { !$0.isWiFi }.compactMap(matchingPrefix).max() ?? 0
        return interfaces.first { candidate in
            guard candidate.isWiFi, let prefix = matchingPrefix(candidate) else { return false }
            return prefix >= wired
        }?.address
    }

    /// A dotted-quad IPv4 address as a host-order integer, or nil.
    private static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let octet = UInt8(part)
            else { return nil }
            value = value << 8 | UInt32(octet)
        }
        return value
    }
}
