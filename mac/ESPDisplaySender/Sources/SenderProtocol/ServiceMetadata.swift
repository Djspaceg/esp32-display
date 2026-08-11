import Foundation

/// What a panel says about itself in its mDNS TXT records, parsed.
///
/// The firmware has advertised these all along (display_stream.ino,
/// `addMdnsService`) and until now the app read none of them - discovery kept
/// the service instance name and the endpoint and dropped the rest, so every
/// panel was streamed as if it were the original 172x320 one and the app could
/// not tell a C6 from an S3. The producer writes, in this order:
///
/// | Key | Format in the firmware | What it is |
/// | --- | --- | --- |
/// | `name` | the configured name verbatim | user-settable panel name |
/// | `res` | `%ux%u` | native (portrait) panel size in pixels |
/// | `fw` | `FW_VERSION` verbatim | firmware version, e.g. `1.2.0` |
/// | `proto` | `%u` | `deviceproto::FRAME_PROTOCOL_VERSION` |
/// | `caps` | `%08lx` | capability bits, lowercase hex |
/// | `chip` | `CONFIG_IDF_TARGET` | `esp32c6`, `esp32s3`, or `unknown` |
///
/// TOLERANT BY CONSTRUCTION. Nothing here throws and nothing here is required:
/// a record that is missing, empty, misspelled, out of range, or written by a
/// firmware this app has never seen leaves its own field nil and leaves every
/// other field alone. That is not politeness, it is the only safe stance - these
/// records arrive unauthenticated over multicast from a device that may be
/// running firmware older or newer than this build, and the app's job when it
/// cannot understand one is to behave exactly as it did before the record
/// existed. A panel that advertises nothing must still appear in the list and
/// still stream, which is what `ServiceMetadata.empty` is for.
///
/// Deliberately NOT the authority on the firmware version even though `fw` is
/// here: EINF carries the same number over a live session, which is
/// authoritative and cannot be a stale mDNS cache entry. `fw` is kept because it
/// is the only version available before a session exists (a panel in the list
/// that has not connected yet), and because omitting a field the producer sends
/// invites someone to re-derive it later from something worse.
public struct ServiceMetadata: Hashable, Sendable {
    /// `name`. The panel's own idea of its name, which can differ from the
    /// service instance name if a rename has not re-announced yet.
    public let name: String?
    /// `res`, once it has been believed - see `PanelGeometry.isStreamable` for
    /// what "believed" means and why an implausible size becomes nil here.
    public let geometry: PanelGeometry?
    /// `fw`. See the note above about EINF being the authority.
    public let firmwareVersion: String?
    /// `chip`. The IDF target token, one vocabulary with
    /// `tools/espdisp.py BOARDS[*].chip` and with a `.espdispfw` manifest's
    /// `chip` field. `unknownChip` is a value the firmware really sends and
    /// means "this build could not name its chip", which is not the same as
    /// this key being absent - see that constant.
    public let chip: String?
    /// `caps`. The same bits EINF reports, available before a session exists.
    public let capabilities: DeviceProtocol.Capabilities?
    /// `proto`. Which frame-protocol generation this panel speaks.
    public let frameProtocolVersion: Int?

    public init(
        name: String? = nil,
        geometry: PanelGeometry? = nil,
        firmwareVersion: String? = nil,
        chip: String? = nil,
        capabilities: DeviceProtocol.Capabilities? = nil,
        frameProtocolVersion: Int? = nil
    ) {
        self.name = name
        self.geometry = geometry
        self.firmwareVersion = firmwareVersion
        self.chip = chip
        self.capabilities = capabilities
        self.frameProtocolVersion = frameProtocolVersion
    }

    /// A panel that told us nothing: no TXT records at all, or none we could
    /// read. Every caller must treat this as "carry on as before".
    public static let empty = ServiceMetadata()

    /// The token a firmware sends when it cannot name its own chip
    /// (`chipidentity::TOKEN_UNKNOWN`, firmware/display_stream/chip_identity.h).
    ///
    /// It means "I could not tell", never "some other chip". Kept distinct from
    /// `chip == nil` on purpose: nil is a panel whose firmware predates the
    /// record, this is a panel whose firmware has the record and could not fill
    /// it in. Both end up as the same refusal, but only one of them is a reason
    /// to suggest reflashing over USB, so the distinction is worth keeping until
    /// something acts on it.
    public static let unknownChip = "unknown"

    /// True when this metadata names a chip that is a real, specific chip.
    public var namesAChip: Bool {
        guard let chip else { return false }
        return chip != Self.unknownChip
    }

    /// Parse a set of TXT records. Never fails; unreadable fields are nil.
    public init(txtRecords: [String: String]) {
        let records = Self.caseFolded(txtRecords)
        self.name = Self.nonEmpty(records["name"])
        self.firmwareVersion = Self.nonEmpty(records["fw"])
        self.chip = Self.nonEmpty(records["chip"])
        self.geometry = Self.parseResolution(records["res"])
        self.capabilities = Self.parseCapabilities(records["caps"])
        self.frameProtocolVersion = Self.parseUnsignedDecimal(records["proto"])
    }

    // MARK: - field parsing

    /// TXT keys, lowercased, because RFC 6763 6.4 says a key is compared
    /// without regard to case. The producer writes them lowercase already, so
    /// this only matters for a record that reached us through something that
    /// rewrote it.
    ///
    /// Two keys that differ only in case are dropped rather than arbitrated:
    /// `[String: String]` has no defined iteration order, so picking one would
    /// pick differently on different runs, and there is no reading of an
    /// ambiguous record that is better than not having it.
    static func caseFolded(_ txtRecords: [String: String]) -> [String: String] {
        var folded = [String: String]()
        var ambiguous = Set<String>()
        for (key, value) in txtRecords {
            let lower = key.lowercased()
            if folded.updateValue(value, forKey: lower) != nil {
                ambiguous.insert(lower)
            }
        }
        for key in ambiguous { folded[key] = nil }
        return folded
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// `res=WxH` -> a geometry, or nil if it is not a size this app can stream.
    ///
    /// Strict about the shape (exactly two all-digit fields around one `x`) and
    /// then strict about the result, because a geometry taken from here drives
    /// band arithmetic and frame allocation on every frame. See
    /// `PanelGeometry.isStreamable` for the bounds and where they come from.
    static func parseResolution(_ value: String?) -> PanelGeometry? {
        guard let value else { return nil }
        let parts = value.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = parseUnsignedDecimal(String(parts[0])),
              let height = parseUnsignedDecimal(String(parts[1]))
        else { return nil }
        let geometry = PanelGeometry(width: width, height: height)
        return geometry.isStreamable ? geometry : nil
    }

    /// `caps=%08lx` -> capability bits.
    ///
    /// One to eight hex digits, which is the field `%08lx` produces, in either
    /// case. The width limit does more than reject a number too big to hold:
    /// `UInt32(_:radix:)` already refuses a value that would not fit, so the
    /// interesting case is a WIDE field carrying a SMALL value, like a
    /// zero-padded twelve digits. That parses perfectly well, and accepting it
    /// would mean this app quietly disagreeing with the producer about how wide
    /// the field is. If capabilities ever outgrow 32 bits the field has to grow,
    /// and that should be a deliberate change here rather than something this
    /// parser absorbs by accident and then truncates.
    static func parseCapabilities(_ value: String?) -> DeviceProtocol.Capabilities? {
        guard let value, !value.isEmpty, value.count <= 8,
              value.allSatisfy(\.isHexDigit),
              let bits = UInt32(value, radix: 16)
        else { return nil }
        return DeviceProtocol.Capabilities(rawValue: bits)
    }

    /// A `%u` field: all digits, no sign, no spaces, no overflow.
    ///
    /// `Int(_:)` alone would accept "+7" and " 7" is rejected by it but "-0" is
    /// not, so the digit check is what makes this mirror `%u` rather than
    /// approximate it. An oversized number leaves `Int(_:)` nil, which becomes
    /// an absent field - the same answer as any other unreadable value.
    static func parseUnsignedDecimal(_ value: String?) -> Int? {
        guard let value, !value.isEmpty,
              value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let parsed = Int(value)
        else { return nil }
        return parsed
    }
}
