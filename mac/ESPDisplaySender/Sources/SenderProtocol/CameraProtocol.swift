import Foundation

/// ECAM v1: camera start/stop requests and fragmented JPEG frames. It is
/// separate from the fixed EINF/EHB1 records so older peers continue parsing
/// their existing messages byte-for-byte.
public enum CameraProtocol {
    public static let version: UInt8 = 1
    public static let commandBytes = 8
    public static let authBytes = 136
    public static let challengeBytes = 72
    public static let frameHeaderBytes = 14
    public static let maximumFragmentPayload = 1_200
    public static let maximumFragments = 256

    public enum Resolution: UInt8, CaseIterable, Sendable {
        case qvga = 1
        case vga = 2

        public var title: String {
            switch self {
            case .qvga: return "320 x 240"
            case .vga: return "640 x 480"
            }
        }
    }

    public enum Command: UInt8 {
        case challenge = 1
        case authenticateStart = 2
        case stop = 3
    }

    public enum Status: UInt8, Sendable {
        case authenticationRefused = 0x82
        case authenticationUnavailable = 0x83
    }

    public struct Challenge: Equatable, Sendable {
        public let resolution: Resolution
        public let nonce: String
    }

    public struct Fragment: Equatable, Sendable {
        public let resolution: Resolution
        public let frameID: UInt16
        public let index: UInt16
        public let count: UInt16
        public let payload: Data
    }

    public static func commandPacket(_ command: Command, resolution: Resolution) -> Data {
        Data([
            0x45, 0x43, 0x41, 0x4d, version, command.rawValue,
            resolution.rawValue, 0,
        ])
    }

    public static func authenticationPacket(
        resolution: Resolution, cnonce: String, response: String
    ) -> Data? {
        guard cnonce.utf8.count == 64, response.utf8.count == 64,
              cnonce.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) }),
              response.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) })
        else { return nil }
        var packet = commandPacket(.authenticateStart, resolution: resolution)
        packet.append(Data(cnonce.utf8))
        packet.append(Data(response.utf8))
        return packet
    }

    public static func parseChallenge(_ data: Data) -> Challenge? {
        let bytes = [UInt8](data)
        guard bytes.count == challengeBytes,
              Array(bytes[0..<4]) == Array("ECAM".utf8),
              bytes[4] == version, bytes[5] == 0x81,
              let resolution = Resolution(rawValue: bytes[6]), bytes[7] == 0,
              let nonce = String(bytes: bytes[8...], encoding: .utf8),
              nonce.count == 64, nonce.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) })
        else { return nil }
        return Challenge(resolution: resolution, nonce: nonce)
    }

    public static func parseStatus(_ data: Data) -> (Status, Resolution)? {
        let bytes = [UInt8](data)
        guard bytes.count == commandBytes,
              Array(bytes[0..<4]) == Array("ECAM".utf8),
              bytes[4] == version, let status = Status(rawValue: bytes[5]),
              let resolution = Resolution(rawValue: bytes[6]), bytes[7] == 0
        else { return nil }
        return (status, resolution)
    }

    public static func parseFragment(_ data: Data) -> Fragment? {
        let bytes = [UInt8](data)
        guard bytes.count >= frameHeaderBytes,
              Array(bytes[0..<4]) == Array("ECAM".utf8),
              bytes[4] == version,
              bytes[5] == 0x80,
              let resolution = Resolution(rawValue: bytes[6]),
              bytes[7] == 0
        else { return nil }
        func u16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        let index = u16(10)
        let count = u16(12)
        guard count > 0, count <= maximumFragments, index < count,
              bytes.count - frameHeaderBytes <= maximumFragmentPayload
        else { return nil }
        return Fragment(
            resolution: resolution, frameID: u16(8), index: index, count: count,
            payload: Data(bytes[frameHeaderBytes...]))
    }

    public static func fragments(
        for jpeg: Data, resolution: Resolution, frameID: UInt16
    ) -> [Data] {
        guard !jpeg.isEmpty else { return [] }
        let count = Int(ceil(Double(jpeg.count) / Double(maximumFragmentPayload)))
        guard count <= maximumFragments else { return [] }
        return (0..<count).map { index in
            let start = index * maximumFragmentPayload
            let end = min(jpeg.count, start + maximumFragmentPayload)
            var packet = Data([
                0x45, 0x43, 0x41, 0x4d, version, 0x80, resolution.rawValue, 0,
                UInt8(frameID & 0xFF), UInt8(frameID >> 8),
                UInt8(index & 0xFF), UInt8(index >> 8),
                UInt8(count & 0xFF), UInt8(count >> 8),
            ])
            packet.append(jpeg[start..<end])
            return packet
        }
    }
}
