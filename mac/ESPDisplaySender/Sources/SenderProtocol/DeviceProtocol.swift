import Foundation

/// Versioned management protocol layered beside the existing frame and EHB1
/// packets. Keeping device information and controls separate lets old senders
/// and firmware continue streaming while newer peers negotiate capabilities.
public enum DeviceProtocol {
    public static let infoVersion: UInt8 = 1
    public static let frameProtocolVersion: UInt8 = 2
    public static let controlProtocolVersion: UInt8 = 1
    public static let touchVersion: UInt8 = 1

    public struct Capabilities: OptionSet, Equatable, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let brightness = Capabilities(rawValue: 1 << 0)
        public static let flip = Capabilities(rawValue: 1 << 1)
        public static let identify = Capabilities(rawValue: 1 << 2)
        public static let restart = Capabilities(rawValue: 1 << 3)
        public static let ota = Capabilities(rawValue: 1 << 4)
        public static let sleepSync = Capabilities(rawValue: 1 << 5)
        public static let telemetry = Capabilities(rawValue: 1 << 6)
        /// Accepts any backlight level, not only high or low. Advertised apart
        /// from `brightness` so a sender can offer a slider to firmware that
        /// supports it and the old toggle to firmware that does not, with no
        /// protocol version bump and so no forced reflash.
        public static let brightnessLevel = Capabilities(rawValue: 1 << 7)
        /// Accepts pushed idle text, so the panel can show something the user
        /// chose while no sender is driving it.
        public static let idleText = Capabilities(rawValue: 1 << 8)
        /// Emits ETCH, i.e. this panel has a touch screen and reports gestures.
        /// Advertised so a sender can offer touch settings only on a panel that
        /// can actually produce them, rather than showing a control that could
        /// never fire.
        public static let touch = Capabilities(rawValue: 1 << 9)
    }

    public struct DeviceInfo: Equatable, Sendable {
        public let infoVersion: UInt8
        public let frameProtocolVersion: UInt8
        public let controlProtocolVersion: UInt8
        public let capabilities: Capabilities
        public let uptimeSeconds: UInt32
        public let rssi: Int16
        public let brightness: UInt8
        public let brightnessHigh: Bool
        public let flipped: Bool
        public let sleeping: Bool
        public let idle: Bool
        public let wifiConnected: Bool
        public let deviceID: String
        public let name: String
        public let firmwareVersion: String
    }

    public enum ControlOpcode: UInt8, CaseIterable, Sendable {
        case brightness = 1
        case flip = 2
        case identify = 3
        case restart = 4
        case brightnessLevel = 5
    }

    /// Range a `brightnessLevel` command may request. Zero is excluded: a black
    /// backlight is indistinguishable from a broken panel, and switching the
    /// display off already has its own command.
    public static let brightnessLevelRange: ClosedRange<Int> = 1...255

    /// Range an `identify` command may request, in seconds. Mirrors the
    /// firmware's own check, which rejects anything outside it.
    public static let identifySecondsRange: ClosedRange<Int> = 1...30

    public struct ControlAck: Equatable, Sendable {
        public let opcode: ControlOpcode
        public let sequence: UInt16
        public let status: UInt8
        public let brightnessHigh: Bool
        public let flipped: Bool
        public let sleeping: Bool
        public let brightness: UInt8

        public var succeeded: Bool { status == 0 }
    }

    /// Parse an EINF packet. The fixed 27-byte prefix is followed by UTF-8
    /// device-name and firmware-version strings whose lengths are in bytes.
    public static func parseInfo(_ data: Data) -> DeviceInfo? {
        let bytes = [UInt8](data)
        guard bytes.count >= 27,
              Array(bytes[0..<4]) == Array("EINF".utf8),
              bytes[4] == infoVersion
        else { return nil }

        func u16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }

        let nameLength = Int(bytes[19])
        let firmwareLength = Int(bytes[20])
        guard nameLength <= 32, firmwareLength <= 24,
              bytes.count == 27 + nameLength + firmwareLength
        else { return nil }

        let nameStart = 27
        let firmwareStart = nameStart + nameLength
        guard let name = String(bytes: bytes[nameStart..<firmwareStart], encoding: .utf8),
              let firmware = String(
                bytes: bytes[firmwareStart..<(firmwareStart + firmwareLength)],
                encoding: .utf8)
        else { return nil }

        let flags = bytes[7]
        let deviceID = bytes[21..<27].map { String(format: "%02x", $0) }.joined()
        return DeviceInfo(
            infoVersion: bytes[4],
            frameProtocolVersion: bytes[5],
            controlProtocolVersion: bytes[6],
            capabilities: Capabilities(rawValue: u32(8)),
            uptimeSeconds: u32(12),
            rssi: Int16(bitPattern: u16(16)),
            brightness: bytes[18],
            brightnessHigh: flags & 0x01 != 0,
            flipped: flags & 0x02 != 0,
            sleeping: flags & 0x04 != 0,
            idle: flags & 0x08 != 0,
            wifiConnected: flags & 0x10 != 0,
            deviceID: deviceID,
            name: name,
            firmwareVersion: firmware)
    }

    /// Encode a fixed-size ECTL packet. Values are intentionally explicit:
    /// brightness/flip use 0 or 1, brightnessLevel uses 1-255, identify uses
    /// seconds, and restart uses 1.
    public static func controlPacket(
        opcode: ControlOpcode, sequence: UInt16, value: Int32
    ) -> Data {
        var packet = Data("ECTL".utf8)
        packet.append(controlProtocolVersion)
        packet.append(opcode.rawValue)
        appendLE(sequence, to: &packet)
        appendLE(UInt32(bitPattern: value), to: &packet)
        return packet
    }

    /// Parse the device's fixed-size EACK response.
    public static func parseAck(_ data: Data) -> ControlAck? {
        let bytes = [UInt8](data)
        guard bytes.count == 12,
              Array(bytes[0..<4]) == Array("EACK".utf8),
              bytes[4] == controlProtocolVersion,
              let opcode = ControlOpcode(rawValue: bytes[5])
        else { return nil }
        let sequence = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
        let flags = bytes[9]
        return ControlAck(
            opcode: opcode,
            sequence: sequence,
            status: bytes[8],
            brightnessHigh: flags & 0x01 != 0,
            flipped: flags & 0x02 != 0,
            sleeping: flags & 0x04 != 0,
            brightness: bytes[10])
    }

    /// A gesture the panel observed. Semantic, not raw coordinates: these
    /// datagrams are unauthenticated, so the set of things a panel can ask for
    /// has to stay small enough that a forged one is recoverable.
    public enum TouchGesture: UInt8, CaseIterable, Sendable {
        case tap = 1
        case swipeLeft = 2
        case swipeRight = 3
        case swipeUp = 4
        case swipeDown = 5
    }

    public struct TouchEvent: Equatable, Sendable {
        public let gesture: TouchGesture
        /// Increments per gesture on the device. Its only job is to let the
        /// receiver drop a duplicate datagram; it carries no ordering meaning
        /// because it wraps.
        public let sequence: UInt16
        /// Where the gesture happened, in the frame that was on screen at the
        /// time — so `landscape` is needed to interpret it.
        public let x: UInt16
        public let y: UInt16
        public let landscape: Bool

        public init(
            gesture: TouchGesture, sequence: UInt16, x: UInt16, y: UInt16,
            landscape: Bool
        ) {
            self.gesture = gesture
            self.sequence = sequence
            self.x = x
            self.y = y
            self.landscape = landscape
        }
    }

    public static let touchPacketBytes = 14
    /// Bit 0 of the flags byte: the panel was in landscape for this gesture.
    public static let touchFlagLandscape: UInt8 = 0x01

    /// Parse the device's fixed-size ETCH touch event.
    public static func parseTouch(_ data: Data) -> TouchEvent? {
        let bytes = [UInt8](data)
        guard bytes.count == touchPacketBytes,
              Array(bytes[0..<4]) == Array("ETCH".utf8),
              bytes[4] == touchVersion,
              let gesture = TouchGesture(rawValue: bytes[5])
        else { return nil }
        return TouchEvent(
            gesture: gesture,
            sequence: UInt16(bytes[6]) | (UInt16(bytes[7]) << 8),
            x: UInt16(bytes[8]) | (UInt16(bytes[9]) << 8),
            y: UInt16(bytes[10]) | (UInt16(bytes[11]) << 8),
            landscape: bytes[12] & touchFlagLandscape != 0)
    }

    private static func appendLE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private static func appendLE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
