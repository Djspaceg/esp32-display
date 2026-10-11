import Foundation

/// The game store: the directory, in the last 4 KiB sector of a board's game
/// data area, that names every Doom WAD and Quake pak the app has put there.
///
/// The firmware's reader is firmware/doom/src/platform/game_store_model.h, and
/// both are held to the shared fixture Tests/SenderProtocolTests/Fixtures/
/// game-store-v1.hex. The area is the flash Quake's data has always used (the
/// P4's quake_pak partition, the S3's raw region past its 8 MiB table), so the
/// partition table is unchanged. An area with no directory is the legacy
/// layout: Quake's pak0.pak, raw, at offset 0. The app keeps pak0.pak at
/// offset 0 whenever the store holds one, so firmware from before the store
/// still finds it.
///
/// The bundled doom1.wad is not here: every firmware flash writes it to the
/// doom_wad partition, and it stays required by every S3 and P4 bundle.
public enum GameStore {
    public static let magic = Array("ESPGAMES".utf8)
    public static let version: UInt16 = 1
    public static let sectorBytes = 4096
    public static let headerBytes = 32
    public static let entryBytes = 64
    public static let nameBytes = 20
    public static let maxEntries = 16
    public static let maxDoomWads = 8
    public static let maxQuakeSlot = 9
    public static let s3Offset = 0x800000
    public static let s3MaxBytes = 0x1200000
    public static let minAreaBytes = 0x100000

    public enum Kind: UInt8, Sendable, CaseIterable {
        case doomWad = 1
        case quakePak = 2
    }

    public struct Entry: Equatable, Sendable {
        public var kind: Kind
        /// Quake: N of id1/pakN.pak. Doom: 0.
        public var slot: Int
        public var offset: Int
        public var length: Int
        public var name: String
        /// Lowercase hex; empty when unknown (a legacy pak0.pak kept in
        /// place), which is written as zeros.
        public var sha256: String

        public init(
            kind: Kind, slot: Int = 0, offset: Int, length: Int, name: String,
            sha256: String
        ) {
            self.kind = kind
            self.slot = slot
            self.offset = offset
            self.length = length
            self.name = name
            self.sha256 = sha256
        }

        public var end: Int { offset + length }
    }

    public struct Directory: Equatable, Sendable {
        public var areaBytes: Int
        public var generation: UInt32
        public var entries: [Entry]

        public init(areaBytes: Int, generation: UInt32, entries: [Entry]) {
            self.areaBytes = areaBytes
            self.generation = generation
            self.entries = entries
        }
    }

    // MARK: - CRC-32

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        return crc
    }

    /// zlib's CRC-32, the firmware's game_store_crc32.
    public static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return ~crc
    }

    // MARK: - encode / decode

    /// The directory sector for `directory`: 4096 bytes, erased (0xFF) past
    /// the entries, as the flash holds it once written.
    public static func encode(_ directory: Directory) -> Data {
        var bytes = [UInt8](repeating: 0xFF, count: sectorBytes)
        func put16(_ at: Int, _ value: Int) {
            bytes[at] = UInt8(value & 0xFF)
            bytes[at + 1] = UInt8((value >> 8) & 0xFF)
        }
        func put32(_ at: Int, _ value: UInt32) {
            for index in 0..<4 { bytes[at + index] = UInt8((value >> (8 * index)) & 0xFF) }
        }
        bytes.replaceSubrange(0..<8, with: magic)
        put16(8, Int(version))
        put16(10, entryBytes)
        put16(12, directory.entries.count)
        put16(14, 0)
        put32(16, UInt32(directory.areaBytes))
        put32(20, directory.generation)
        put32(24, 0)
        put32(28, 0)
        for (index, entry) in directory.entries.enumerated() {
            let at = headerBytes + index * entryBytes
            bytes[at] = entry.kind.rawValue
            bytes[at + 1] = UInt8(entry.slot)
            put16(at + 2, 0)
            put32(at + 4, UInt32(entry.offset))
            put32(at + 8, UInt32(entry.length))
            let name = Array(entry.name.utf8.prefix(nameBytes))
            bytes.replaceSubrange(
                (at + 12)..<(at + 32),
                with: name + [UInt8](repeating: 0, count: nameBytes - name.count))
            bytes.replaceSubrange((at + 32)..<(at + 64), with: shaBytes(entry.sha256))
        }
        let covered = headerBytes + directory.entries.count * entryBytes
        put32(24, crc32(bytes[0..<covered]))
        return Data(bytes)
    }

    public enum DecodeError: Error, LocalizedError, Equatable {
        case newerVersion(Int)
        case damaged(String)

        public var errorDescription: String? {
            switch self {
            case .newerVersion(let version):
                return "The board's game store is version \(version), newer than this "
                    + "app understands. Update the app before changing its game data."
            case .damaged(let why):
                return "The board's game store directory is damaged (\(why)). Writing "
                    + "game data again replaces it."
            }
        }
    }

    /// The directory a sector holds, nil for the legacy layout (no magic), or
    /// the firmware's own refusal.
    public static func decode(sector: Data, areaBytes: Int) throws -> Directory? {
        let bytes = [UInt8](sector)
        guard bytes.count >= sectorBytes else { throw DecodeError.damaged("short read") }
        guard Array(bytes[0..<8]) == magic else { return nil }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | (Int(bytes[at + 1]) << 8) }
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) | (Int(bytes[at + 1]) << 8) | (Int(bytes[at + 2]) << 16)
                | (Int(bytes[at + 3]) << 24)
        }
        let version = u16(8)
        if version > Int(Self.version) { throw DecodeError.newerVersion(version) }
        guard version == Int(Self.version), u16(10) == entryBytes, u16(14) == 0, u32(28) == 0
        else { throw DecodeError.damaged("bad header") }
        let count = u16(12)
        guard count <= maxEntries else { throw DecodeError.damaged("too many files") }
        guard u32(16) == areaBytes else {
            throw DecodeError.damaged("written for a different area size")
        }
        var sealed = Array(bytes[0..<(headerBytes + count * entryBytes)])
        sealed.replaceSubrange(24..<28, with: [0, 0, 0, 0])
        guard crc32(sealed) == UInt32(u32(24)) else { throw DecodeError.damaged("bad checksum") }
        var entries: [Entry] = []
        for index in 0..<count {
            let at = headerBytes + index * entryBytes
            guard let kind = Kind(rawValue: bytes[at]) else {
                throw DecodeError.damaged("a file this app does not know")
            }
            let nameBytes = bytes[(at + 12)..<(at + 32)].prefix { $0 != 0 }
            let sha = bytes[(at + 32)..<(at + 64)]
            entries.append(Entry(
                kind: kind, slot: Int(bytes[at + 1]), offset: u32(at + 4),
                length: u32(at + 8), name: String(decoding: nameBytes, as: UTF8.self),
                sha256: sha.allSatisfy { $0 == 0 }
                    ? "" : sha.map { String(format: "%02x", $0) }.joined()))
        }
        let directory = Directory(
            areaBytes: areaBytes, generation: UInt32(u32(20)), entries: entries)
        if let problem = problem(in: directory) { throw DecodeError.damaged(problem) }
        return directory
    }

    /// What the firmware would refuse in this directory, or nil. The encoder
    /// never writes one that fails this.
    public static func problem(in directory: Directory) -> String? {
        guard directory.areaBytes >= minAreaBytes, directory.areaBytes % sectorBytes == 0
        else { return "game data area too small" }
        guard directory.entries.count <= maxEntries else { return "too many files" }
        let dataEnd = directory.areaBytes - sectorBytes
        let doom = directory.entries.filter { $0.kind == .doomWad }
        if doom.count > maxDoomWads { return "too many Doom WADs" }
        for (index, entry) in directory.entries.enumerated() {
            switch entry.kind {
            case .doomWad:
                guard entry.slot == 0, entry.name.hasSuffix(".wad") else {
                    return "\(entry.name) is not a stored WAD name"
                }
            case .quakePak:
                guard (0...maxQuakeSlot).contains(entry.slot),
                      entry.name == "pak\(entry.slot).pak"
                else { return "\(entry.name) is not a stored pak name" }
            }
            guard isStorableName(entry.name) else { return "\(entry.name) is not storable" }
            guard entry.offset % sectorBytes == 0, entry.length >= 12,
                  entry.offset <= dataEnd, entry.length <= dataEnd - entry.offset
            else { return "\(entry.name) lies outside the area" }
            for other in directory.entries[..<index] {
                if entry.offset < other.end && other.offset < entry.end {
                    return "\(entry.name) overlaps \(other.name)"
                }
                if other.kind == entry.kind
                    && (entry.kind == .quakePak
                        ? other.slot == entry.slot : other.name == entry.name) {
                    return "\(entry.name) is named twice"
                }
            }
        }
        return nil
    }

    /// 5 to 20 of [a-z0-9._-].
    public static func isStorableName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        return (5...nameBytes).contains(bytes.count) && bytes.allSatisfy {
            ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39)
                || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
        }
    }

    private static func shaBytes(_ hex: String) -> [UInt8] {
        let digits = Array(hex.utf8)
        guard digits.count == 64 else { return [UInt8](repeating: 0, count: 32) }
        return (0..<32).map { index in
            UInt8(String(decoding: digits[(index * 2)..<(index * 2 + 2)], as: UTF8.self),
                  radix: 16) ?? 0
        }
    }

    // MARK: - the area

    /// Where a board's game data area is, from the partition table it boots
    /// with and (on an S3) its flash size.
    public struct Area: Equatable, Sendable {
        /// Absolute flash address of the area's first byte.
        public let address: Int
        public let byteCount: Int
        public let description: String

        public init(address: Int, byteCount: Int, description: String) {
            self.address = address
            self.byteCount = byteCount
            self.description = description
        }

        public var directoryAddress: Int { address + byteCount - GameStore.sectorBytes }
        /// What files may use: the area less its directory sector.
        public var usableBytes: Int { byteCount - GameStore.sectorBytes }
    }

    public enum AreaResult: Equatable, Sendable {
        case area(Area)
        case refuse(title: String, message: String)
    }

    /// The S3 area on a chip of `flashBytes`: past the 8 MiB table, up to
    /// 18 MiB; 0 below 9 MiB. The firmware's game_store_s3_area_bytes.
    public static func s3AreaBytes(flashBytes: Int) -> Int {
        guard flashBytes >= s3Offset + minAreaBytes else { return 0 }
        return min(flashBytes - s3Offset, s3MaxBytes)
    }

    public static func area(chip: String, partitionTable: Data, flashBytes: Int?) -> AreaResult {
        let entries = FirmwareBundle.partitionEntries(partitionTable)
        switch chip {
        case QuakePak.p4Chip:
            guard let entries,
                  FirmwareBundle.matchesDoomPartitionLayout(entries, targets: ["p4"])
            else { return staleLayout(family: "P4") }
            guard let entry = entries[QuakePak.flashRole],
                  entry.type == QuakePak.partitionType,
                  entry.subtype == QuakePak.partitionSubtype,
                  entry.byteCount >= minAreaBytes
            else {
                return .refuse(
                    title: "No game data partition",
                    message: "The board's partition table has no usable \(QuakePak.flashRole) "
                        + "partition. Update its firmware over USB first.")
            }
            return .area(Area(
                address: entry.address, byteCount: entry.byteCount,
                description: "the \(QuakePak.flashRole) partition"))
        case QuakePak.s3Chip:
            guard let entries,
                  FirmwareBundle.matchesDoomPartitionLayout(entries, targets: ["s3"])
            else { return staleLayout(family: "S3") }
            guard let flashBytes else {
                return .refuse(
                    title: "Flash size unknown",
                    message: "esptool did not report this board's flash size, so the app "
                        + "cannot tell where its game data area ends. Nothing was written.")
            }
            let bytes = s3AreaBytes(flashBytes: flashBytes)
            guard bytes > 0 else {
                return .refuse(
                    title: "No room for game data",
                    message: "This board has \(flashBytes / 0x100000) MiB of flash, all of it "
                        + "used by the firmware; extra game data needs 16 MiB. Nothing was "
                        + "written.")
            }
            return .area(Area(
                address: s3Offset, byteCount: bytes,
                description: "the flash past the firmware's 8 MiB"))
        default:
            return .refuse(
                title: "No games on this board",
                message: "Doom and Quake run only on ESP32-S3 and ESP32-P4 boards; this one "
                    + "is \(chip.isEmpty ? "an unknown chip" : chip). Nothing was written.")
        }
    }

    private static func staleLayout(family: String) -> AreaResult {
        .refuse(
            title: "Partition layout not current",
            message: "The board's partition table is not this app's \(family) layout. "
                + "Update its firmware over USB first, then write its game data. "
                + "Nothing was written.")
    }

    // MARK: - what the board holds

    /// The area's contents as read from a board.
    public enum Contents: Equatable, Sendable {
        /// No directory. `legacyPak0Bytes` is the raw pak0.pak's length when
        /// offset 0 holds one (its directory's end), else nil.
        case legacy(legacyPak0Bytes: Int?)
        case directory(Directory)

        public var entries: [Entry] {
            switch self {
            case .legacy(let bytes?):
                return [Entry(
                    kind: .quakePak, slot: 0, offset: 0, length: bytes,
                    name: "pak0.pak", sha256: "")]
            case .legacy(nil):
                return []
            case .directory(let directory):
                return directory.entries
            }
        }

        public var generation: UInt32 {
            if case .directory(let directory) = self { return directory.generation }
            return 0
        }
    }

    /// The legacy pak0.pak's length from the area's first bytes: where its
    /// directory ends, which is where id's own tools end the file. Nil when
    /// offset 0 is not a pack.
    public static func legacyPakBytes(firstBytes: Data, areaBytes: Int) -> Int? {
        let bytes = [UInt8](firstBytes.prefix(12))
        guard bytes.count == 12, Array(bytes[0..<4]) == Array("PACK".utf8) else { return nil }
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) | (Int(bytes[at + 1]) << 8) | (Int(bytes[at + 2]) << 16)
                | (Int(bytes[at + 3]) << 24)
        }
        let end = u32(4) + u32(8)
        guard end > 12, end <= areaBytes - sectorBytes else { return nil }
        return end
    }

    // MARK: - planning a write

    /// A file the store should hold after the write.
    public struct File: Equatable, Sendable {
        public var kind: Kind
        public var slot: Int
        public var name: String
        public var sha256: String
        public var byteCount: Int
        /// The app has no bytes for it: it can stay where it is, never move.
        public var boardOnly: Bool

        public init(
            kind: Kind, slot: Int = 0, name: String, sha256: String, byteCount: Int,
            boardOnly: Bool = false
        ) {
            self.kind = kind
            self.slot = slot
            self.name = name
            self.sha256 = sha256
            self.byteCount = byteCount
            self.boardOnly = boardOnly
        }

        func matches(_ entry: Entry) -> Bool {
            entry.kind == kind && entry.slot == slot && entry.name == name
                && entry.length == byteCount
                && (boardOnly || (!sha256.isEmpty && entry.sha256 == sha256))
        }
    }

    public struct Plan: Equatable, Sendable {
        /// Written first when a file is dropped or moved over: only what stays
        /// in place, so a write cut short never leaves the board naming bytes
        /// that are half overwritten.
        public var interim: Directory?
        public var final: Directory
        /// The entries whose bytes must be written, in address order.
        public var writes: [Entry]

        public var usedBytes: Int { final.entries.reduce(0) { $0 + GameStore.aligned($1.length) } }
    }

    public enum PlanError: Error, LocalizedError, Equatable {
        case doesNotFit(needed: Int, usable: Int)
        case fragmented(name: String)
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .doesNotFit(let needed, let usable):
                return "The selection needs \(GameStore.byteText(needed)) but the board's game "
                    + "data area holds \(GameStore.byteText(usable)). Uncheck something."
            case .fragmented(let name):
                return "\(name) does not fit between the files that stay on the board. "
                    + "Check every file on the board so the app can rewrite them all."
            case .invalid(let why):
                return why
            }
        }
    }

    public static func aligned(_ bytes: Int) -> Int {
        (bytes + sectorBytes - 1) / sectorBytes * sectorBytes
    }

    public static func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Bytes `files` take on the board, each rounded up to a flash sector.
    public static func neededBytes(_ files: [File]) -> Int {
        files.reduce(0) { $0 + aligned($1.byteCount) }
    }

    /// Lay `desired` out in `area` given what the board holds now. A file
    /// already on the board, byte for byte, stays where it is; pak0.pak goes at
    /// offset 0 when it can (firmware from before the store reads it there);
    /// the rest go first-fit, largest first. When files that could move are in
    /// the way, everything the app has bytes for is laid out afresh.
    public static func plan(current: Contents, desired: [File], area: Area) -> Result<Plan, PlanError> {
        let needed = neededBytes(desired)
        guard needed <= area.usableBytes else {
            return .failure(.doesNotFit(needed: needed, usable: area.usableBytes))
        }
        if let problem = selectionProblem(desired) { return .failure(.invalid(problem)) }
        let onBoard = current.entries
        var stayingSets: [[Int: Entry]] = []
        // First try: everything already on the board stays put.
        var inPlace: [Int: Entry] = [:]
        for (index, file) in desired.enumerated() {
            if let entry = onBoard.first(where: { file.matches($0) }) {
                inPlace[index] = renamed(entry, as: file)
            } else if file.boardOnly {
                return .failure(.invalid("\(file.name) is not on the board to keep."))
            }
        }
        stayingSets.append(inPlace)
        // Second: only what the app cannot rewrite stays put.
        stayingSets.append(inPlace.filter { desired[$0.key].boardOnly })

        var lastFailure: PlanError = .doesNotFit(needed: needed, usable: area.usableBytes)
        for staying in stayingSets {
            switch place(desired, staying: staying, usable: area.usableBytes) {
            case .success(let entries):
                let writes = entries.enumerated()
                    .filter { staying[$0.offset] == nil }
                    .map(\.element)
                    .sorted { $0.offset < $1.offset }
                let kept = entries.enumerated()
                    .filter { staying[$0.offset] != nil }.map(\.element)
                // A file on the board that does not stay where it is leaves the
                // directory before any byte moves.
                let disturbed = onBoard.contains { old in
                    !kept.contains {
                        $0.kind == old.kind && $0.name == old.name
                            && $0.offset == old.offset && $0.length == old.length
                    }
                }
                let generation = current.generation &+ 1
                let interim: Directory? = disturbed && !writes.isEmpty
                    ? Directory(areaBytes: area.byteCount, generation: generation,
                                entries: kept.sorted { $0.offset < $1.offset })
                    : nil
                let final = Directory(
                    areaBytes: area.byteCount,
                    generation: interim == nil ? generation : generation &+ 1,
                    entries: entries.sorted { $0.offset < $1.offset })
                if let problem = problem(in: final) { return .failure(.invalid(problem)) }
                return .success(Plan(interim: interim, final: final, writes: writes))
            case .failure(let failure):
                lastFailure = failure
            }
        }
        return .failure(lastFailure)
    }

    /// Why the selection itself cannot be stored, whatever the space.
    public static func selectionProblem(_ files: [File]) -> String? {
        let doom = files.filter { $0.kind == .doomWad }
        if doom.count > maxDoomWads {
            return "The board's menu lists at most \(maxDoomWads) extra WADs; \(doom.count) "
                + "are checked."
        }
        if Set(doom.map(\.name)).count != doom.count {
            return "Two checked WADs share a name; the board tells them apart by name."
        }
        let slots = files.filter { $0.kind == .quakePak }.map(\.slot)
        if Set(slots).count != slots.count {
            return "Two checked Quake paks are the same pak; keep one of each."
        }
        if !slots.isEmpty {
            let missing = (0...(slots.max() ?? 0)).first { !slots.contains($0) }
            if let missing {
                return "Quake loads pak0.pak, pak1.pak and on in turn and stops at the "
                    + "first one missing, so pak\(missing).pak is needed too."
            }
        }
        if files.count > maxEntries {
            return "The board's game store holds at most \(maxEntries) files."
        }
        return nil
    }

    private static func renamed(_ entry: Entry, as file: File) -> Entry {
        var entry = entry
        // A legacy pak0.pak has no digest on the board; keep the one the app
        // knows when it matched by bytes it already had.
        if entry.sha256.isEmpty { entry.sha256 = file.sha256 }
        return entry
    }

    private static func place(
        _ desired: [File], staying: [Int: Entry], usable: Int
    ) -> Result<[Entry], PlanError> {
        var placed: [Int: Entry] = staying
        func free(_ offset: Int, _ length: Int) -> Bool {
            offset + length <= usable && placed.values.allSatisfy {
                offset + length <= $0.offset || $0.end <= offset
            }
        }
        let order = desired.indices
            .filter { placed[$0] == nil }
            .sorted { lhs, rhs in
                let l = desired[lhs], r = desired[rhs]
                let lPak0 = l.kind == .quakePak && l.slot == 0
                let rPak0 = r.kind == .quakePak && r.slot == 0
                if lPak0 != rPak0 { return lPak0 }
                return l.byteCount > r.byteCount
            }
        for index in order {
            let file = desired[index]
            // Candidate starts: 0 and the end of every placed file.
            let starts = ([0] + placed.values.map { aligned($0.end) }).sorted()
            guard let start = starts.first(where: { free($0, file.byteCount) }) else {
                return .failure(.fragmented(name: file.name))
            }
            placed[index] = Entry(
                kind: file.kind, slot: file.slot, offset: start, length: file.byteCount,
                name: file.name, sha256: file.sha256)
        }
        return .success(desired.indices.compactMap { placed[$0] })
    }
}
