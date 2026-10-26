import Foundation

/// Quake's data files, id1/pak0.pak and on: the user's own, or the shareware
/// pak0.pak the app fetches, never part of a bundle or the catalog.
///
/// `validate` is the structural rule `tools/espdisp.py write-data quake_pak`
/// applies (`validate_quake_pak`) and the firmware's quake_pak_check. Where a
/// pak goes on a board is `GameStore`'s: the game data area this partition
/// (the P4's) or the S3's raw region past its table provides.
public enum QuakePak {
    /// The P4 table's label for the game data area.
    public static let flashRole = "quake_pak"
    public static let partitionType: UInt8 = 0x42
    public static let partitionSubtype: UInt8 = 0x07
    /// The shareware id1/pak0.pak from quake106.zip. Reported, not required:
    /// any well-formed pack that fits may be written.
    public static let sharewareBytes = 18_689_235
    public static let sharewareSHA256 =
        "35a9c55e5e5a284a159ad2a62e0e8def23d829561fe2f54eb402dbc0a9a946af"
    /// Each pack directory entry: 56-byte name, u32 offset, u32 length.
    static let directoryEntryBytes = 64
    static let headerBytes = 12
    /// The engine's MAX_FILES_IN_PACK, which the firmware's quake_pak_check
    /// also holds a pack to.
    public static let maxEntries = 2048
    /// Where a board keeps its partition table, and how much of it is read.
    public static let partitionTableAddress = 0x8000
    public static let partitionTableBytes = 0xC00

    public static let p4Chip = "esp32p4"
    public static let s3Chip = "esp32s3"

    /// The engine's base frame. Quake renders it unscaled or at a whole-pixel
    /// scale and never shrinks it, so a panel must hold it in its own
    /// orientation (firmware/quake/src/quake_mode.h QUAKE_MIN_PANEL_WIDTH,
    /// HEIGHT; quake_input_model.h frameLayout).
    public static let minPanelWidth = 320
    public static let minPanelHeight = 240
    /// The release families whose image carries the Quake runtime.
    public static let families: Set<String> = ["s3", "p4"]

    /// Whether Quake runs on this chip at all.
    public static func supports(chip: String?) -> Bool {
        chip == p4Chip || chip == s3Chip
    }

    /// The renderer's one limit: the panel holds the 320x240 frame.
    public static func panelHoldsFrame(_ geometry: PanelGeometry) -> Bool {
        geometry.width >= minPanelWidth && geometry.height >= minPanelHeight
    }

    /// Whether Quake can run on this board, from what the board is and never
    /// from a list of boards: a chip whose family image carries Quake, and a
    /// panel that holds its frame. A profile not reported yet, or one this app
    /// does not know (newer firmware), is offered; the board's own boot menu
    /// and the write then decide. Whether the pak fits the board's game data
    /// area is the write's to check (GameStore.area).
    public static func supports(chip: String?, profile: String?) -> Bool {
        guard supports(chip: chip) else { return false }
        guard let profile else { return true }
        let family = GeneratedBoardCatalog.requiredFamilies.first {
            GeneratedBoardCatalog.profilesByTarget[$0]?.contains(profile) == true
        }
        guard let family else { return true }
        guard families.contains(family),
              let geometry = GeneratedBoardCatalog.geometryByProfile[profile]
        else { return false }
        return panelHoldsFrame(geometry)
    }

    // MARK: - the file

    /// A file that passed `validate`.
    public struct Validated: Equatable, Sendable {
        public let byteCount: Int
        /// Lowercase hex, the spelling `sharewareSHA256` uses.
        public let sha256: String
        public let entryCount: Int

        /// Whether this is the shareware pak0.pak, byte for byte.
        public var isShareware: Bool {
            byteCount == QuakePak.sharewareBytes && sha256 == QuakePak.sharewareSHA256
        }
    }

    public enum ValidationError: Error, LocalizedError, Equatable {
        case notAPack(magicHex: String)
        case directoryOutsideFile(offset: Int, length: Int, fileBytes: Int)
        case entryPastEnd(entryOffset: Int)

        public var errorDescription: String? {
            switch self {
            case .notAPack(let magic):
                return "This is not a Quake pack: it starts with \(magic.isEmpty ? "nothing" : magic) "
                    + "rather than PACK."
            case .directoryOutsideFile(let offset, let length, let fileBytes):
                return "The Quake pack's directory (0x\(String(offset, radix: 16, uppercase: true))"
                    + "+0x\(String(length, radix: 16, uppercase: true))) does not fit the "
                    + "\(fileBytes)-byte file."
            case .entryPastEnd(let entryOffset):
                return "The Quake pack's directory entry at byte \(entryOffset) points past "
                    + "the end of the file."
            }
        }
    }

    /// Refuse anything that is not a structurally sound Quake pack: the PACK
    /// magic, a directory that is a whole number of entries after the header
    /// and inside the file, and every entry inside the file.
    public static func validate(_ data: Data) throws -> Validated {
        let count = data.count
        let checked = try data.withUnsafeBytes { raw -> Int in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard count >= headerBytes,
                  bytes[0] == 0x50, bytes[1] == 0x41, bytes[2] == 0x43, bytes[3] == 0x4B
            else {
                let magic = bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
                throw ValidationError.notAPack(magicHex: magic)
            }
            func u32(_ offset: Int) -> Int {
                Int(bytes[offset])
                    | (Int(bytes[offset + 1]) << 8)
                    | (Int(bytes[offset + 2]) << 16)
                    | (Int(bytes[offset + 3]) << 24)
            }
            let directory = u32(4)
            let length = u32(8)
            guard length != 0, length % directoryEntryBytes == 0,
                  length / directoryEntryBytes <= maxEntries,
                  directory >= headerBytes, directory <= count,
                  length <= count - directory
            else {
                throw ValidationError.directoryOutsideFile(
                    offset: directory, length: length, fileBytes: count)
            }
            for entry in stride(
                from: directory, to: directory + length, by: directoryEntryBytes
            ) {
                let offset = u32(entry + 56)
                let size = u32(entry + 60)
                guard offset <= count, size <= count - offset else {
                    throw ValidationError.entryPastEnd(entryOffset: entry)
                }
            }
            return length / directoryEntryBytes
        }
        return Validated(
            byteCount: count, sha256: FirmwareBundle.sha256Hex(data), entryCount: checked)
    }
}
