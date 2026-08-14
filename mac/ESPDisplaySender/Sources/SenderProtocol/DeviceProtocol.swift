import Foundation

/// Versioned management protocol layered beside the existing frame and EHB1
/// packets. Keeping device information and controls separate lets old senders
/// and firmware continue streaming while newer peers negotiate capabilities.
public enum DeviceProtocol {
    public static let infoVersion: UInt8 = 1
    public static let frameProtocolVersion: UInt8 = 2
    public static let controlProtocolVersion: UInt8 = 1
    public static let touchVersion: UInt8 = 1
    public static let batteryVersion: UInt8 = 1

    public struct Capabilities: OptionSet, Hashable, Sendable {
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
        /// Classifies a held press as `longPress` rather than as nothing.
        /// Advertised apart from `touch` for the same reason `brightnessLevel`
        /// is advertised apart from `brightness`: a gesture preset bound to a
        /// long press would otherwise silently do nothing on a panel running
        /// firmware that never emits one, which is indistinguishable from the
        /// panel ignoring the finger.
        public static let touchLongPress = Capabilities(rawValue: 1 << 10)
        /// Emits EBAT, i.e. this board has a power-management IC with a battery
        /// gauge. Advertised because it is a per-board fact rather than a
        /// firmware one — only the 1.75C carries a PMU — so a sender must not
        /// show a battery row for a panel that will never report one. An empty
        /// or 0% reading would look like a flat battery rather than no battery.
        public static let battery = Capabilities(rawValue: 1 << 11)
        /// Accepts packed band packets: several RLE-compressed or raw band
        /// records per datagram (band_index bit 15; see `BandPacker`). The
        /// panel's receive path tops out at a datagram rate, not a byte rate,
        /// so fewer, denser packets is what raises the frame rate. The sender
        /// only packs for a panel advertising this; every other pairing stays
        /// byte-identical on the wire, which is why this is a capability bit
        /// and not a protocol version bump.
        public static let compressedBands = Capabilities(rawValue: 1 << 12)
        /// Accepts `rotate`, i.e. any quarter turn rather than only the 180
        /// flip. Only square panels advertise it: on rectangular glass a
        /// physical 90-degree turn is what the sender-driven landscape
        /// mechanism already expresses, and a MADCTL quarter turn would fight
        /// it. A new opcode plus this bit rather than widened `flip` values,
        /// because old firmware rejects a flip value above 1 SILENTLY — no
        /// acknowledgement at all — and this sender could not tell that from
        /// packet loss. The UI keeps the flip toggle for panels without the
        /// bit, so nothing regresses.
        public static let rotate = Capabilities(rawValue: 1 << 13)
        /// Accepts `power`, a standing on/off instruction independent of the
        /// Mac's own sleep sync (`sleepSync`'s ESLP/EWAK) and persisted across
        /// a reboot. Advertised unconditionally: unlike `battery` or `rotate`
        /// this is not a hardware fact — every board here already has a
        /// backlight or panel-command brightness sink, so every board can
        /// honour it.
        public static let power = Capabilities(rawValue: 1 << 14)
        /// Accepts tile-stream packets (see `TileProtocol`): a 16x16
        /// dirty-tile grid with per-run codec choice (raw / RLE565 / BC1)
        /// replacing full-width bands. Advertised only by the square CO5300
        /// AMOLED board — gated on the board variant, not on square
        /// dimensions, so a future square panel on other silicon does not
        /// inherit a draw path tuned for this board's QSPI and PSRAM. The
        /// sender only sends tile packets to a panel advertising this;
        /// every other pairing — including every C6 board — stays
        /// byte-identical on the wire, which is why this is a capability
        /// bit and not a protocol version bump.
        public static let tileStream = Capabilities(rawValue: 1 << 15)
        /// This panel's glass is round, so pixels outside the frame's
        /// inscribed circle are physically invisible and never need sending.
        /// A per-board hardware fact like `battery`, and the only way the
        /// sender can know the glass shape — the firmware acts on it not at
        /// all, since the tile receive path accepts whatever subset of tiles
        /// a frame declares. Ignoring it is correct, merely slower: on the
        /// 466x466 panel it is 181 of 900 tiles, a fifth of both the wire
        /// cost and the panel's paint time.
        public static let roundDisplay = Capabilities(rawValue: 1 << 16)
        /// This panel decodes half-resolution BC1 tile records
        /// (`TileProtocol.Codec.halfBc1`), pixel-doubling them on arrival.
        /// Separate from `tileStream` because tile firmware predating codec 3
        /// REJECTS such a record — and a rejected record drops the whole
        /// datagram — so guessing costs entire frames rather than degrading.
        public static let tileHalfRes = Capabilities(rawValue: 1 << 17)
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
        /// The panel's mounting rotation in clockwise quarter turns (0-3),
        /// from flags bits 5-6. Only meaningful on firmware advertising
        /// `Capabilities.rotate`: older firmware never sets those bits, so a
        /// flipped old panel reads `flipped == true` with `rotation == 0`,
        /// and `flipped` stays the authority there. On rotation-aware
        /// firmware the two are packed from one value and cannot disagree
        /// (`flipped` is exactly `rotation == 2`).
        public let rotation: Int
        public let sleeping: Bool
        public let idle: Bool
        public let wifiConnected: Bool
        /// The user's standing "display off" instruction (flags bit 7),
        /// independent of `sleeping`/`idle` — those clear on the next drawn
        /// frame, this persists until the user turns the panel back on. See
        /// `Capabilities.power`.
        public let manuallyOff: Bool
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
        /// Value 0-3: clockwise quarter turns. Supersedes `flip` (rotate 2 is
        /// flip 1); only sent to firmware advertising `Capabilities.rotate`,
        /// which is why `flip` stays for everything older.
        case rotate = 6
        /// Value 0 or 1: whether the display should be on. A standing
        /// instruction, persisted, and independent of `flip`/`rotate` and the
        /// idle timer — see `Capabilities.power`.
        case power = 7
    }

    /// Range a `rotate` command may request: clockwise quarter turns.
    public static let rotationRange: ClosedRange<Int> = 0...3

    /// Values a `power` command may request: 0 (off) or 1 (on).
    public static let powerRange: ClosedRange<Int> = 0...1

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
        /// Clockwise quarter turns from flags bits 5-6; see
        /// `DeviceInfo.rotation` for when it is meaningful.
        public let rotation: Int
        public let sleeping: Bool
        /// See `DeviceInfo.manuallyOff`.
        public let manuallyOff: Bool
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
            rotation: Int((flags >> 5) & 0x03),
            sleeping: flags & 0x04 != 0,
            idle: flags & 0x08 != 0,
            wifiConnected: flags & 0x10 != 0,
            manuallyOff: flags & 0x80 != 0,
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
            rotation: Int((flags >> 5) & 0x03),
            sleeping: flags & 0x04 != 0,
            manuallyOff: flags & 0x80 != 0,
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
        /// A press held past the long-press threshold, reported while the finger
        /// is still down. Only emitted by firmware advertising
        /// `Capabilities.touchLongPress`; older firmware classifies a hold as
        /// nothing, and `parseTouch` rejects the value it never sends, so both
        /// directions fail closed with no version bump.
        case longPress = 6
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

    /// What the panel's power-management IC is doing with its battery. One enum
    /// rather than independent charging/discharging flags, so the wire format
    /// cannot express a contradictory state a receiver would have to arbitrate.
    public enum ChargeState: UInt8, CaseIterable, Sendable {
        case unknown = 0
        case charging = 1
        case discharging = 2
        case standby = 3
    }

    /// A battery reading from a panel advertising `Capabilities.battery`.
    ///
    /// Unknowns are `nil` rather than sentinel numbers: the wire uses 0xFF for
    /// an unsettled gauge and 0 for an unread voltage, and both would read as
    /// real, alarming values if they reached the UI as numbers.
    public struct BatteryStatus: Equatable, Sendable {
        public let present: Bool
        public let externalPower: Bool
        public let percent: UInt8?
        public let state: ChargeState
        public let millivolts: UInt16?

        public init(
            present: Bool, externalPower: Bool, percent: UInt8?,
            state: ChargeState, millivolts: UInt16?
        ) {
            self.present = present
            self.externalPower = externalPower
            self.percent = percent
            self.state = state
            self.millivolts = millivolts
        }
    }

    public static let batteryPacketBytes = 12
    /// Bit 0 of the flags byte: a battery is physically attached.
    public static let batteryFlagPresent: UInt8 = 0x01
    /// Bit 1: external (VBUS) power is present.
    public static let batteryFlagExternalPower: UInt8 = 0x02
    /// Percent value meaning the gauge has no opinion yet.
    public static let batteryPercentUnknown: UInt8 = 0xFF
    /// How long a received reading may be shown as current.
    ///
    /// EBAT arrives unprompted on the panel's own 10s timer, and only when a
    /// sample succeeded — so a panel whose PMU dies simply stops sending, and
    /// without an expiry the last percentage would stand for as long as the app
    /// ran. Nothing else clears it: the panel keeps heartbeating perfectly well
    /// while saying nothing about its battery.
    ///
    /// 45s is four missed samples, matching the firmware's
    /// `deviceproto::BATTERY_MAX_AGE_MS` so both sides call the same reading
    /// stale at the same moment. One dropped datagram therefore never blanks the
    /// row, and a PMU that has stopped is reported inside a minute.
    public static let batteryMaxAge: TimeInterval = 45

    /// Parse the device's fixed-size EBAT battery report.
    ///
    /// Validation mirrors the firmware's parser: version, a percent that is
    /// either 0-100 or the unknown sentinel, and a charge state this build can
    /// name. The two reserved bytes are deliberately not checked, so a later
    /// firmware can carry one more small field there without this parser
    /// rejecting every packet.
    ///
    /// What that costs: a field placed in bytes 10-11 later must define 0 as
    /// "absent". Every firmware built before it writes zeros there, and since
    /// nothing checks them this parser cannot tell those zeros from a real
    /// reading — so a field where 0 means something (a temperature, a current at
    /// rest) would be silently misread on every panel running older firmware.
    /// Anything that needs 0 to be meaningful needs a version bump instead.
    public static func parseBattery(_ data: Data) -> BatteryStatus? {
        let bytes = [UInt8](data)
        guard bytes.count == batteryPacketBytes,
              Array(bytes[0..<4]) == Array("EBAT".utf8),
              bytes[4] == batteryVersion,
              bytes[6] <= 100 || bytes[6] == batteryPercentUnknown,
              let state = ChargeState(rawValue: bytes[7])
        else { return nil }
        let millivolts = UInt16(bytes[8]) | (UInt16(bytes[9]) << 8)
        return BatteryStatus(
            present: bytes[5] & batteryFlagPresent != 0,
            externalPower: bytes[5] & batteryFlagExternalPower != 0,
            percent: bytes[6] == batteryPercentUnknown ? nil : bytes[6],
            state: state,
            millivolts: millivolts == 0 ? nil : millivolts)
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
