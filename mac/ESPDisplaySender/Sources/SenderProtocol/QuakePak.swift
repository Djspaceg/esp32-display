import Foundation

/// Quake's data file, id1/pak0.pak, and where it may be written on a board.
///
/// The pak is the user's own file, never part of a bundle or the catalog, so it
/// reaches a board by a separate USB write. These are the rules
/// `tools/espdisp.py write-data quake_pak` applies (`validate_quake_pak`,
/// `data_partition_target`, `quake_pak_s3_target`), kept here as pure functions
/// so the app and the CLI refuse the same boards for the same reasons.
///
/// On the P4 it is a partition in the table. The S3's universal table covers
/// only its common 8 MiB, so there it is a raw region just past that layout,
/// which the firmware registers at runtime (firmware/quake/src/platform/
/// quake_pak_vfs.c, QUAKE_PAK_S3_*), and only a 32 MiB chip holds it.
public enum QuakePak {
    /// The `FirmwareBundle.FlashWrite` role, and the P4 table's label.
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
    /// The S3's raw region, which starts where the universal table's last
    /// partition ends.
    public static let s3Address = 0x800000
    public static let s3RegionBytes = 0x1200000
    /// 26 MiB is the region's end; in practice that means a 32 MiB chip.
    public static var s3RequiredFlashBytes: Int { s3Address + s3RegionBytes }
    /// Where a board keeps its partition table, and how much of it is read.
    public static let partitionTableAddress = 0x8000
    public static let partitionTableBytes = 0xC00

    public static let p4Chip = "esp32p4"
    public static let s3Chip = "esp32s3"

    /// The S3 profiles whose panel holds Quake's frame (firmware/quake/src/
    /// quake_mode.h quakeSupportsBoard): the AMOLED 1.75C and the LCD 1.85C.
    public static let s3Profiles: Set<String> = ["co5300", "st77916"]

    /// Whether Quake runs on this chip at all.
    public static func supports(chip: String?) -> Bool {
        chip == p4Chip || chip == s3Chip
    }

    /// Whether Quake can run on this board: any P4, and an S3 whose profile
    /// is one of `s3Profiles` (or not reported yet; the write itself then
    /// decides). Flash size is the write's to check.
    public static func supports(chip: String?, profile: String?) -> Bool {
        guard supports(chip: chip) else { return false }
        guard chip == s3Chip, let profile else { return true }
        return s3Profiles.contains(profile)
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

    // MARK: - where it goes

    /// Where the pak may be written, or why it may not.
    public enum Plan: Equatable, Sendable {
        case write(address: Int)
        case refuse(title: String, message: String)
    }

    /// Decide where `payloadBytes` of pak go on this board.
    ///
    /// `partitionTable` is what the board itself boots with, read from 0x8000:
    /// the board's table, not this repo's, decides where bytes land, so a board
    /// on an older layout (where that address belongs to an app slot or the
    /// Doom WAD) is refused rather than overwritten. `flashBytes` is the chip's
    /// detected flash size and is only consulted on an S3.
    public static func plan(
        chip: String,
        partitionTable: Data,
        flashBytes: Int?,
        payloadBytes: Int
    ) -> Plan {
        let entries = FirmwareBundle.partitionEntries(partitionTable)
        switch chip {
        case p4Chip:
            guard let entries,
                  FirmwareBundle.matchesDoomPartitionLayout(entries, targets: ["p4"])
            else { return staleLayout(family: "P4") }
            guard let entry = entries[flashRole] else {
                return .refuse(
                    title: "No Quake partition",
                    message: "The board's partition table has no \(flashRole) partition.")
            }
            guard entry.type == partitionType, entry.subtype == partitionSubtype else {
                return .refuse(
                    title: "No Quake partition",
                    message: "The board's \(flashRole) partition has type/subtype "
                        + "\(hexByte(entry.type))/\(hexByte(entry.subtype)), expected "
                        + "\(hexByte(partitionType))/\(hexByte(partitionSubtype)).")
            }
            guard payloadBytes <= entry.byteCount else {
                return tooLarge(payloadBytes: payloadBytes, holds: entry.byteCount)
            }
            return .write(address: entry.address)
        case s3Chip:
            guard let entries,
                  FirmwareBundle.matchesDoomPartitionLayout(entries, targets: ["s3"])
            else { return staleLayout(family: "S3") }
            guard let flashBytes else {
                return .refuse(
                    title: "Flash size unknown",
                    message: "esptool did not report this board's flash size, so the "
                        + "app cannot tell whether Quake's data fits. Nothing was written.")
            }
            guard flashBytes >= s3RequiredFlashBytes else {
                return .refuse(
                    title: "Not enough flash for Quake",
                    message: "This board has \(flashBytes / 0x100000) MiB of flash; "
                        + "Quake's data needs 32 MiB. Nothing was written.")
            }
            guard payloadBytes <= s3RegionBytes else {
                return tooLarge(payloadBytes: payloadBytes, holds: s3RegionBytes)
            }
            return .write(address: s3Address)
        default:
            return chipRefusal(chip)
                ?? .refuse(title: "Quake is not available on this board", message: chip)
        }
    }

    /// The refusal for a chip Quake does not run on, or nil when it does - so
    /// a caller can stop before reading anything off such a board.
    public static func chipRefusal(_ chip: String) -> Plan? {
        guard !supports(chip: chip) else { return nil }
        return .refuse(
            title: "Quake is not available on this board",
            message: "Quake runs only on ESP32-P4 and ESP32-S3 boards; this one is "
                + "\(chip.isEmpty ? "an unknown chip" : chip). Nothing was written.")
    }

    /// The single write the planner allowed, for `UsbOnboarder.flash`.
    public static func flashWrite(
        payload: Data, address: Int, filename: String, sha256: String
    ) -> FirmwareBundle.FlashWrite {
        FirmwareBundle.FlashWrite(
            role: flashRole, address: address, filename: filename,
            sha256: sha256, payload: payload)
    }

    private static func staleLayout(family: String) -> Plan {
        .refuse(
            title: "Partition layout not current",
            message: "The board's partition table is not this app's \(family) layout. "
                + "Update its firmware over USB first, then write Quake's data. "
                + "Nothing was written.")
    }

    private static func tooLarge(payloadBytes: Int, holds: Int) -> Plan {
        .refuse(
            title: "The file is too large",
            message: "The file is \(payloadBytes) bytes, but the board's Quake area "
                + "holds \(holds). Nothing was written.")
    }

    private static func hexByte(_ value: UInt8) -> String {
        String(format: "0x%02X", value)
    }
}
