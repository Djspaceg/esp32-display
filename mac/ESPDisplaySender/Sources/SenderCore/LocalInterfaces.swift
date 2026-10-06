import Darwin
import Foundation
import SenderProtocol
import SystemConfiguration

/// This Mac's IPv4 interfaces, as `OTASourceAddress` needs them.
enum LocalInterfaces {
    /// The address an OTA push to `panel` should send from, or nil for the
    /// kernel's default. Read fresh on every push: interfaces come and go.
    static func otaSourceAddress(toward panel: String) -> String? {
        OTASourceAddress.choose(toward: panel, among: current())
    }

    /// Every up, non-loopback IPv4 address, marked WiFi by SystemConfiguration's
    /// interface type rather than by BSD name, since `en0` is not WiFi on every
    /// Mac.
    static func current() -> [OTASourceAddress.Interface] {
        let wifiNames = wifiBSDNames()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [OTASourceAddress.Interface] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.pointee.ifa_netmask
            else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            result.append(OTASourceAddress.Interface(
                name: name, address: dotted(addr), netmask: dotted(mask),
                isWiFi: wifiNames.contains(name)))
        }
        return result
    }

    private static func wifiBSDNames() -> Set<String> {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        return Set(all.compactMap { interface in
            guard SCNetworkInterfaceGetInterfaceType(interface)
                    == kSCNetworkInterfaceTypeIEEE80211
            else { return nil }
            return SCNetworkInterfaceGetBSDName(interface) as String?
        })
    }

    /// The IPv4 address in a sockaddr, as a dotted quad.
    ///
    /// Copies at most `sa_len` bytes into a zeroed `sockaddr_in` rather than
    /// reading one in place, because BSD trims netmask sockaddrs: 255.255.255.0
    /// can arrive with `sa_len` 7 and `sa_family` 0, its zero byte simply absent.
    /// The caller has already checked that the entry itself is AF_INET.
    private static func dotted(_ addr: UnsafeMutablePointer<sockaddr>) -> String {
        var full = sockaddr_in()
        let length = min(Int(addr.pointee.sa_len), MemoryLayout<sockaddr_in>.size)
        withUnsafeMutableBytes(of: &full) { target in
            target.copyMemory(from: UnsafeRawBufferPointer(start: addr, count: length))
        }
        var raw = full.sin_addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &raw, &text, socklen_t(text.count)) != nil else { return "" }
        return String(cString: text)
    }
}
