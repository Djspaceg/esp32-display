import Foundation

/// The game files a person can put in a board's game store, and how each is
/// recognised: what `GameStore` stores, read and refused the way the firmware
/// would refuse it.
public enum GameData {
    /// The bundled doom1.wad (FirmwareBundle's doomWad constants): every S3
    /// and P4 bundle writes it to the doom_wad partition, so a copy in the
    /// store would only take space.
    public static let bundledDoomBytes = 4_196_020
    public static let bundledDoomSHA256 =
        "1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771"
    /// The doom_wad partition the bundled WAD lives in, on both families.
    public static let doomWadPartitionBytes = 0x401000

    /// A file that passed `identify`, ready to be a `GameStore.File`.
    public struct Identified: Equatable, Sendable {
        public let kind: GameStore.Kind
        public let slot: Int
        /// The name the board stores it under, which is the name the engine
        /// opens it by.
        public let storedName: String
        public let byteCount: Int
        public let sha256: String
        /// "Quake shareware pak0.pak", "IWAD, 2,919 lumps, Doom II maps".
        public let summary: String

        public init(
            kind: GameStore.Kind, slot: Int, storedName: String, byteCount: Int,
            sha256: String, summary: String
        ) {
            self.kind = kind
            self.slot = slot
            self.storedName = storedName
            self.byteCount = byteCount
            self.sha256 = sha256
            self.summary = summary
        }

        public func file(boardOnly: Bool = false) -> GameStore.File {
            GameStore.File(
                kind: kind, slot: slot, name: storedName, sha256: sha256,
                byteCount: byteCount, boardOnly: boardOnly)
        }
    }

    public enum IdentifyError: Error, LocalizedError, Equatable {
        case notAWad(magicHex: String)
        case pwad
        case wadDirectory
        case wadLumpOutside(index: Int)
        case wadHasNoMaps
        case bundledWad
        case wadName(String)
        case notDoom(String)
        case notAPak(String)
        case pakName(String)

        public var errorDescription: String? {
            switch self {
            case .notAWad(let magic):
                return "This is not a Doom WAD: it starts with "
                    + "\(magic.isEmpty ? "nothing" : magic) rather than IWAD."
            case .pwad:
                return "This is a PWAD, an add-on that needs a full WAD loaded under it. "
                    + "The board plays one complete WAD (an IWAD) at a time, so choose an "
                    + "IWAD such as doom2.wad or freedoom1.wad."
            case .wadDirectory:
                return "This WAD's directory does not fit inside the file, so Doom would "
                    + "refuse it."
            case .wadLumpOutside(let index):
                return "Lump \(index) of this WAD points past the end of the file, so Doom "
                    + "would refuse it."
            case .wadHasNoMaps:
                return "This WAD has neither E1M1 nor MAP01, so Doom cannot tell which game "
                    + "it is and would not start it."
            case .bundledWad:
                return "This is the shareware doom1.wad that every firmware update already "
                    + "puts on the board; it is in its boot menu as DOOM."
            case .wadName(let name):
                return "\(name) cannot be stored under its own name: the board needs a name "
                    + "ending in .wad, up to 20 letters, digits, dots, dashes or underscores. "
                    + "Rename the file and choose it again."
            case .notDoom(let name):
                return "\(name) is not a Doom WAD: the board runs Doom and Doom II WADs, not "
                    + "Heretic, Hexen or Strife."
            case .notAPak(let why):
                return why
            case .pakName(let name):
                return "Quake opens its paks by name, id1/pak0.pak then pak1.pak and on, so "
                    + "\(name) must be named for the pak it is. Rename it pak0.pak or "
                    + "pak1.pak and choose it again."
            }
        }
    }

    /// Recognise `data`, chosen as a `kind` file named `filename`.
    public static func identify(
        _ data: Data, filename: String, kind: GameStore.Kind
    ) throws -> Identified {
        switch kind {
        case .doomWad:
            return try identifyWad(data, filename: filename)
        case .quakePak:
            return try identifyPak(data, filename: filename)
        }
    }

    // MARK: - Doom

    /// The firmware's doom_wad_check_file over the file's own length, plus
    /// what the engine needs to start it: an IWAD with E1M1 or MAP01.
    static func identifyWad(_ data: Data, filename: String) throws -> Identified {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else {
            throw IdentifyError.notAWad(magicHex: hex(bytes.prefix(4)))
        }
        let magic = String(decoding: bytes[0..<4], as: UTF8.self)
        if magic == "PWAD" { throw IdentifyError.pwad }
        guard magic == "IWAD" else { throw IdentifyError.notAWad(magicHex: hex(bytes[0..<4])) }
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) | (Int(bytes[at + 1]) << 8) | (Int(bytes[at + 2]) << 16)
                | (Int(bytes[at + 3]) << 24)
        }
        func s32(_ at: Int) -> Int { Int(Int32(bitPattern: UInt32(u32(at)))) }
        let count = u32(4)
        let directory = u32(8)
        guard count > 0, directory <= bytes.count, count <= (bytes.count - directory) / 16
        else { throw IdentifyError.wadDirectory }
        var maps: Set<String> = []
        var otherGame = false
        for index in 0..<count {
            let at = directory + index * 16
            let offset = s32(at)
            let size = s32(at + 4)
            guard offset >= 0, size >= 0, offset <= bytes.count, size <= bytes.count - offset
            else { throw IdentifyError.wadLumpOutside(index: index) }
            let name = String(
                decoding: bytes[(at + 8)..<(at + 16)].prefix { $0 != 0 }, as: UTF8.self
            ).uppercased()
            if name == "E1M1" || name == "MAP01" { maps.insert(name) }
            // The lumps the engine's W_CheckCorrectIWAD refuses a Doom boot on:
            // Heretic's, Hexen's and Strife's.
            if ["IMPXA1", "ETTNA1", "AGRDA1"].contains(name) { otherGame = true }
        }
        guard !maps.isEmpty else { throw IdentifyError.wadHasNoMaps }
        // Heretic, Hexen and Strife IWADs have E1M1 or MAP01 too, but this
        // engine is Doom's and refuses them at boot: by their lumps, whatever
        // the file is called, and by their names.
        if otherGame || ["heretic.wad", "heretic1.wad", "hexen.wad", "strife1.wad",
                         "strife0.wad"].contains(filename.lowercased()) {
            throw IdentifyError.notDoom(filename)
        }
        let sha = FirmwareBundle.sha256Hex(data)
        if bytes.count == bundledDoomBytes && sha == bundledDoomSHA256 {
            throw IdentifyError.bundledWad
        }
        let name = filename.lowercased()
        guard name.hasSuffix(".wad"), GameStore.isStorableName(name) else {
            throw IdentifyError.wadName(filename)
        }
        return Identified(
            kind: .doomWad, slot: 0, storedName: name, byteCount: bytes.count,
            sha256: sha,
            summary: "IWAD, \(count) lumps, "
                + (maps.contains("MAP01") ? "Doom II maps" : "Doom maps"))
    }

    // MARK: - Quake

    static func identifyPak(_ data: Data, filename: String) throws -> Identified {
        let validated: QuakePak.Validated
        do {
            validated = try QuakePak.validate(data)
        } catch {
            throw IdentifyError.notAPak(error.localizedDescription)
        }
        guard let slot = pakSlot(filename) else { throw IdentifyError.pakName(filename) }
        return Identified(
            kind: .quakePak, slot: slot, storedName: "pak\(slot).pak",
            byteCount: validated.byteCount, sha256: validated.sha256,
            summary: validated.isShareware
                ? "Quake shareware pak0.pak"
                : "Quake pack, \(validated.entryCount) files")
    }

    /// N for a file named pakN.pak (any case), N from 0 to 9.
    public static func pakSlot(_ filename: String) -> Int? {
        let name = Array(filename.lowercased().utf8)
        guard name.count == 8, Array(name[0..<3]) == Array("pak".utf8),
              Array(name[4..<8]) == Array(".pak".utf8),
              name[3] >= 0x30, name[3] <= 0x39
        else { return nil }
        return Int(name[3] - 0x30)
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - the free data

    /// How a download becomes the file.
    public enum Unpack: String, Sendable {
        /// The download is the file.
        case raw
        /// quake106.zip: resource.1 is an LHA holding ID1/PAK0.PAK.
        case quake106
        /// quakesw-1.0.6.tar.gz holding id1/pak0.pak.
        case sdlTarGz
    }

    public struct Mirror: Equatable, Sendable {
        public let name: String
        public let url: URL
        public let unpack: Unpack
    }

    /// A free file the app can fetch, pinned by size and SHA-256.
    public struct Download: Equatable, Sendable {
        public let kind: GameStore.Kind
        public let filename: String
        public let byteCount: Int
        public let sha256: String
        public let mirrors: [Mirror]
    }

    /// Quake's shareware pak0.pak, from the mirrors tools/fetch_game_data.sh
    /// uses, in its order. Doom's shareware WAD has no download here: it is
    /// the bundled doom1.wad, already on every board.
    public static let quakeShareware = Download(
        kind: .quakePak, filename: "pak0.pak",
        byteCount: QuakePak.sharewareBytes, sha256: QuakePak.sharewareSHA256,
        mirrors: [
            Mirror(
                name: "ftp.gwdg.de, id Software's original quake106.zip",
                url: URL(string:
                    "https://ftp.gwdg.de/pub/misc/ftp.idsoftware.com/idstuff/quake/quake106.zip")!,
                unpack: .quake106),
            Mirror(
                name: "gamers.org idgames, id Software's original quake106.zip",
                url: URL(string:
                    "https://www.gamers.org/pub/idgames/idstuff/quake/quake106.zip")!,
                unpack: .quake106),
            Mirror(
                name: "libsdl.org, quakesw-1.0.6.tar.gz",
                url: URL(string:
                    "https://www.libsdl.org/projects/quake/data/quakesw-1.0.6.tar.gz")!,
                unpack: .sdlTarGz),
        ])
}
