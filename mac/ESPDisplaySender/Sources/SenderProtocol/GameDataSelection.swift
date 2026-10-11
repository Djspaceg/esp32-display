import Foundation

/// What the Game data section has checked, and what that asks of the board.
///
/// Each game has a checkbox and a list of files. A checked game's checked files
/// are exactly what its part of the store holds after the write: a file
/// unchecked there is removed. An unchecked game is left as the board has it.
/// Files the board holds that this Mac has no copy of are listed too, as
/// "on the board", and stay unless unchecked.
public struct GameDataSelection: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Fetched into this Mac's cache.
        case cache(URL)
        /// A file the person chose.
        case chosen(URL)
        /// On the board, with no copy here: it can stay, never move.
        case board
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public var identified: GameData.Identified
        public var source: Source
        public var isChecked: Bool

        public var id: String { "\(identified.kind.rawValue)/\(identified.storedName)" }
        public var kind: GameStore.Kind { identified.kind }

        public var url: URL? {
            switch source {
            case .cache(let url), .chosen(let url): return url
            case .board: return nil
            }
        }
    }

    public var doomChecked: Bool
    public var quakeChecked: Bool
    /// Whether this board runs Quake at all; when not, its files are ignored
    /// and whatever the board holds for it is left alone.
    public let quakeOffered: Bool
    public private(set) var items: [Item] = []

    public init(quakeOffered: Bool, doomChecked: Bool = false, quakeChecked: Bool = false) {
        self.quakeOffered = quakeOffered
        self.doomChecked = doomChecked
        self.quakeChecked = quakeOffered && quakeChecked
    }

    public func items(of kind: GameStore.Kind) -> [Item] {
        items.filter { $0.kind == kind }.sorted {
            ($0.identified.slot, $0.identified.storedName)
                < ($1.identified.slot, $1.identified.storedName)
        }
    }

    public func isGameChecked(_ kind: GameStore.Kind) -> Bool {
        switch kind {
        case .doomWad: return doomChecked
        case .quakePak: return quakeOffered && quakeChecked
        }
    }

    public mutating func setGameChecked(_ kind: GameStore.Kind, _ checked: Bool) {
        switch kind {
        case .doomWad: doomChecked = checked
        case .quakePak: quakeChecked = quakeOffered && checked
        }
    }

    /// Adds a file, checked, and checks its game. It replaces the file the
    /// board would store under the same name (for Quake, the same pak), so
    /// choosing another pak0.pak swaps it in.
    public mutating func add(_ identified: GameData.Identified, source: Source) {
        if identified.kind == .quakePak && !quakeOffered { return }
        items.removeAll { $0.id == "\(identified.kind.rawValue)/\(identified.storedName)" }
        items.append(Item(identified: identified, source: source, isChecked: true))
        setGameChecked(identified.kind, true)
    }

    public mutating func setChecked(_ id: Item.ID, _ checked: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isChecked = checked
    }

    /// Takes away a chosen file; the cache and the board keep theirs.
    public mutating func remove(_ id: Item.ID) {
        items.removeAll { $0.id == id && $0.source != .board }
    }

    /// Lists what the board holds: a file this Mac has the same bytes of is
    /// marked on the board through `isOnBoard`; anything else becomes a
    /// board-only row, checked, so it stays unless someone unchecks it.
    public mutating func noteBoard(_ contents: GameStore.Contents) {
        items.removeAll { $0.source == .board }
        for entry in contents.entries {
            if entry.kind == .quakePak && !quakeOffered { continue }
            let held = items.contains {
                $0.kind == entry.kind && $0.identified.storedName == entry.name
                    && $0.identified.sha256 == entry.sha256 && !entry.sha256.isEmpty
            }
            if held { continue }
            // The same name with different bytes: the local file replaces it
            // when written; the board's copy is not listed as well.
            if items.contains(where: {
                $0.kind == entry.kind && $0.identified.storedName == entry.name
            }) { continue }
            items.append(Item(
                identified: GameData.Identified(
                    kind: entry.kind, slot: entry.slot, storedName: entry.name,
                    byteCount: entry.length, sha256: entry.sha256,
                    summary: entry.sha256.isEmpty
                        ? "Written before the game store; contents not identified"
                        : "On the board; no copy on this Mac"),
                source: .board, isChecked: true))
        }
    }

    public static func isOnBoard(_ item: Item, contents: GameStore.Contents?) -> Bool {
        if item.source == .board { return true }
        return contents?.entries.contains {
            $0.kind == item.kind && $0.name == item.identified.storedName
                && !$0.sha256.isEmpty && $0.sha256 == item.identified.sha256
        } ?? false
    }

    /// The files the store should hold after a write to a board holding
    /// `contents`.
    public func desiredFiles(board contents: GameStore.Contents) -> [GameStore.File] {
        var files: [GameStore.File] = []
        for kind in GameStore.Kind.allCases {
            if isGameChecked(kind) {
                files += items(of: kind).filter(\.isChecked).map {
                    $0.identified.file(boardOnly: $0.source == .board)
                }
            } else {
                files += contents.entries.filter { $0.kind == kind }.map {
                    GameStore.File(
                        kind: $0.kind, slot: $0.slot, name: $0.name, sha256: $0.sha256,
                        byteCount: $0.length, boardOnly: true)
                }
            }
        }
        return files
    }

    /// What the checked selection alone needs, before the board is read: the
    /// checked files of the checked games.
    public var checkedFiles: [GameStore.File] {
        GameStore.Kind.allCases.filter(isGameChecked).flatMap { kind in
            items(of: kind).filter(\.isChecked).map {
                $0.identified.file(boardOnly: $0.source == .board)
            }
        }
    }

    /// Whether any checked game has anything to put on the board.
    public var hasCheckedGame: Bool {
        GameStore.Kind.allCases.contains(where: isGameChecked)
    }
}

extension GameDataSelection {
    /// The space the selection needs against what the board's game data area
    /// can hold, and why a write would be refused, if it would.
    public struct Space: Equatable, Sendable {
        public let neededBytes: Int
        /// Nil until the board is read on an S3, whose area depends on its
        /// flash size.
        public let usableBytes: Int?
        public let problem: String?

        public var fits: Bool { problem == nil }
    }

    /// The area a family's current layout gives before the board is read: the
    /// P4's quake_pak partition, less the directory sector. An S3's depends on
    /// its flash, so it is nil until read.
    public static func expectedUsableBytes(chip: String?) -> Int? {
        chip == QuakePak.p4Chip ? 0x1200000 - GameStore.sectorBytes : nil
    }

    /// Before the board is read, what the checked files need; after, what the
    /// whole store would hold (unchecked games stay as they are).
    public func space(usableBytes: Int?, contents: GameStore.Contents?) -> Space {
        let files = contents.map { desiredFiles(board: $0) } ?? checkedFiles
        let needed = GameStore.neededBytes(files)
        if let problem = GameStore.selectionProblem(files) {
            return Space(neededBytes: needed, usableBytes: usableBytes, problem: problem)
        }
        if let usableBytes, needed > usableBytes {
            return Space(
                neededBytes: needed, usableBytes: usableBytes,
                problem: GameStore.PlanError.doesNotFit(needed: needed, usable: usableBytes)
                    .localizedDescription)
        }
        return Space(neededBytes: needed, usableBytes: usableBytes, problem: nil)
    }
}
