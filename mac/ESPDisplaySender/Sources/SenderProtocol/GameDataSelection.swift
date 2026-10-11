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

        /// A board row has its own id, so a local file of the same name sits
        /// beside it rather than replacing it.
        public var id: String {
            (source == .board ? "board/" : "")
                + "\(identified.kind.rawValue)/\(identified.storedName)"
        }
        public var kind: GameStore.Kind { identified.kind }

        public var url: URL? {
            switch source {
            case .cache(let url), .chosen(let url): return url
            case .board: return nil
            }
        }

        func sameStoredFile(as other: Item) -> Bool {
            kind == other.kind && identified.storedName == other.identified.storedName
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
        // A board row after the local file of its name.
        items.filter { $0.kind == kind }.sorted {
            ($0.identified.slot, $0.identified.storedName, $0.source == .board ? 1 : 0)
                < ($1.identified.slot, $1.identified.storedName, $1.source == .board ? 1 : 0)
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

    /// Adds a file and, when it is checked, its game. It replaces a local file
    /// stored under the same name (for Quake, the same pak), so choosing another
    /// pak0.pak swaps it in; a board file of that name stays listed, unchecked,
    /// since the new one would replace it.
    public mutating func add(
        _ identified: GameData.Identified, source: Source, checked: Bool = true
    ) {
        if identified.kind == .quakePak && !quakeOffered { return }
        let item = Item(identified: identified, source: source, isChecked: checked)
        items.removeAll { $0.id == item.id }
        if checked {
            for index in items.indices where items[index].source == .board
                && items[index].sameStoredFile(as: item) {
                items[index].isChecked = false
            }
            setGameChecked(identified.kind, true)
        }
        items.append(item)
    }

    public mutating func setChecked(_ id: Item.ID, _ checked: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isChecked = checked
    }

    /// Takes away a chosen file; the cache and the board keep theirs, and a
    /// board file it had displaced is checked again.
    public mutating func remove(_ id: Item.ID) {
        guard let removed = items.first(where: { $0.id == id && $0.source != .board })
        else { return }
        items.removeAll { $0.id == id }
        if removed.isChecked {
            for index in items.indices where items[index].source == .board
                && items[index].sameStoredFile(as: removed) {
                items[index].isChecked = true
            }
        }
    }

    /// Lists what the board holds. A file this Mac has the same bytes of is
    /// marked on the board through `isOnBoard`; anything else is a board row
    /// of its own: checked (it stays) unless someone unchecked it before or a
    /// checked local file of the same name is to replace it.
    public mutating func noteBoard(_ contents: GameStore.Contents) {
        let previous = Dictionary(
            items.filter { $0.source == .board }.map { ($0.id, $0.isChecked) },
            uniquingKeysWith: { first, _ in first })
        items.removeAll { $0.source == .board }
        for entry in contents.entries {
            if entry.kind == .quakePak && !quakeOffered { continue }
            let row = Item(
                identified: GameData.Identified(
                    kind: entry.kind, slot: entry.slot, storedName: entry.name,
                    byteCount: entry.length, sha256: entry.sha256,
                    summary: entry.sha256.isEmpty
                        ? "Written before the game store; contents not identified"
                        : "On the board; no copy on this Mac"),
                source: .board, isChecked: true)
            let local = items.filter { $0.sameStoredFile(as: row) }
            if local.contains(where: {
                !entry.sha256.isEmpty && $0.identified.sha256 == entry.sha256
            }) { continue }
            var kept = row
            kept.isChecked = previous[row.id] ?? !local.contains(where: \.isChecked)
            items.append(kept)
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
    ///
    /// Removal is only ever explicit. A file the board holds stays unless its
    /// row is unchecked, a checked local file of its name replaces it, or the
    /// local file that stands for it (same bytes) is unchecked. So a file with
    /// no row at all - the board changed since it was listed, or it was never
    /// listed - is kept, never dropped unseen.
    public func desiredFiles(board contents: GameStore.Contents) -> [GameStore.File] {
        var files: [GameStore.File] = []
        for kind in GameStore.Kind.allCases {
            let onBoard = contents.entries.filter { $0.kind == kind }
            guard isGameChecked(kind) else {
                files += onBoard.map(Self.kept)
                continue
            }
            let local = items(of: kind).filter { $0.source != .board }
            files += local.filter(\.isChecked).map { $0.identified.file() }
            for entry in onBoard {
                let named = local.filter { $0.identified.storedName == entry.name }
                if named.contains(where: \.isChecked) { continue }  // replaced
                if named.contains(where: {
                    !entry.sha256.isEmpty && $0.identified.sha256 == entry.sha256
                }) { continue }  // its stand-in is unchecked
                let row = items.first {
                    $0.source == .board && $0.kind == kind && $0.identified.storedName == entry.name
                }
                if row?.isChecked == false { continue }
                files.append(Self.kept(entry))
            }
        }
        return files
    }

    private static func kept(_ entry: GameStore.Entry) -> GameStore.File {
        GameStore.File(
            kind: entry.kind, slot: entry.slot, name: entry.name, sha256: entry.sha256,
            byteCount: entry.length, boardOnly: true)
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
