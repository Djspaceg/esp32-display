import AppKit
import SenderProtocol
import SwiftUI

/// The Firmware section's "Games data" row: the button that opens
/// `GameDataSheet`, and the reason under it when it cannot proceed.
///
/// Its own view, holding its own sheet state, so the manager window gains one
/// line rather than another `@State` and `.sheet` of its own.
struct GamesDataRow: View {
    let panel: PanelSnapshot
    @ObservedObject var manager: PanelManager
    @State private var target: PanelManager.FirmwareUpdateTarget?

    /// Doom runs on every S3 and P4 board, Quake on some; boards with neither
    /// get no row. The chip is the panel's, else its matched USB device's, as
    /// the firmware sheet's target takes it.
    @MainActor
    static func isOffered(for panel: PanelSnapshot, manager: PanelManager) -> Bool {
        let chip = panel.chip ?? manager.usbUpdateDevice(for: panel.serviceName)?.chip
        return chip == QuakePak.p4Chip || chip == QuakePak.s3Chip
    }

    var body: some View {
        let unavailable = manager.gameDataUnavailableReason(panel.serviceName)
        LabeledContent("Games data") {
            VStack(alignment: .leading, spacing: 4) {
                // Not disabled when it cannot proceed, for the reason the Update
                // button above is not: the sentence under it says why.
                Button("Install Game Data…") {
                    target = manager.beginGameDataInstall(panel.serviceName)
                }
                .help(unavailable
                    ?? "Put Doom WADs and Quake paks on this device over USB")
                if let unavailable {
                    Text(unavailable)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(item: $target) { target in
            GameDataSheet(
                manager: manager, target: target,
                quakeOffered: QuakePak.supports(
                    chip: target.chip, profile: panel.profile ?? target.profile))
        }
    }
}

/// Choose, fetch and write a board's game data: the text interface of
/// tools/fetch_game_data.sh, and the board side the CLI never had.
///
/// Modelled on `FirmwareUpdateSheet`'s USB flow: the same monitor, footer and
/// transcript, and the same rule that the sheet only asks - the board is
/// re-verified and the layout decided by `writeGameDataOverUSB`.
struct GameDataSheet: View {
    @ObservedObject var manager: PanelManager
    @Environment(\.dismiss) private var dismiss
    /// Resolved again after a restart, which renumbers the board's USB device.
    @State private var target: PanelManager.FirmwareUpdateTarget
    let quakeOffered: Bool
    private let cache: GameDataCache?

    @State private var selection: GameDataSelection
    @State private var board: (area: GameStore.Area, contents: GameStore.Contents)?
    @State private var chooseFailure: String?
    @State private var isBusy = false
    @State private var isReadingBoard = false
    @State private var boardFailure: String?
    @State private var downloadFraction: Double?
    @State private var downloadLine: String?
    @State private var downloadFailure: String?
    @State private var cacheUsedBytes = 0
    @State private var macFreeBytes: Int?
    @State private var sharewareCached = false
    @State private var confirmWrite = false
    @State private var isWriting = false
    @State private var writeFailure: OperationOutcome?
    /// The port of a board the last read or write found in flashing mode.
    @State private var restartPort: String?
    @State private var isRestartingBoard = false
    @State private var sheetIsVisible = false
    @StateObject private var usbFlash = UsbFlashMonitor(flow: .update)

    /// `selection` and `board` start the sheet already filled, for the
    /// capture tests; the app opens it with the cache's files only.
    init(
        manager: PanelManager, target: PanelManager.FirmwareUpdateTarget,
        quakeOffered: Bool, cache: GameDataCache? = .standard,
        selection: GameDataSelection? = nil,
        board: (area: GameStore.Area, contents: GameStore.Contents)? = nil,
        failure: OperationOutcome? = nil
    ) {
        self.manager = manager
        _target = State(initialValue: target)
        self.quakeOffered = quakeOffered
        self.cache = cache
        var initial = selection ?? GameDataSelection(quakeOffered: quakeOffered)
        if let board { initial.noteBoard(board.contents) }
        _selection = State(initialValue: initial)
        _board = State(initialValue: board)
        _writeFailure = State(initialValue: failure)
        _restartPort = State(initialValue: failure?.restartPort)
    }

    var body: some View {
        Form {
            Section("Device") {
                LabeledContent("Name", value: target.displayName)
                LabeledContent("Chip", value: target.chip ?? "Not reported")
                LabeledContent("USB device") {
                    Text(target.usbDevice?.path ?? "Not connected")
                        .monospaced()
                        .textSelection(.enabled)
                }
            }
            Section("Game data") {
                gameRows(.doomWad)
                if quakeOffered { gameRows(.quakePak) }
                if let chooseFailure {
                    Text(chooseFailure)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actionsRow
            }
            spaceSection
            Section("Requirements") {
                Text(requirementText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !usbFlash.session.transcript.entries.isEmpty {
                Section("Details") {
                    UsbFlashTranscriptView(session: usbFlash.session)
                }
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
        .labeledContentStyle(.labelColumn)
        .safeAreaInset(edge: .bottom) {
            actionBar.textSelection(.enabled)
        }
        .frame(width: 560, height: 760)
        .onAppear {
            sheetIsVisible = true
            refreshCacheFacts()
        }
        .onDisappear { sheetIsVisible = false }
        .confirmationDialog(
            "Write game data to \(target.displayName)?",
            isPresented: $confirmWrite, titleVisibility: .visible
        ) {
            Button("Write") { startWrite() }
        } message: {
            Text("The checked games' files are written over USB. Files already on the "
                + "board stay where they are unless their row is unchecked or a file of the "
                + "same name replaces them. The board restarts a few times; its firmware, "
                + "settings and bundled doom1.wad are not touched.")
        }
    }

    // MARK: game rows

    private func title(_ kind: GameStore.Kind) -> String {
        kind == .doomWad ? "Doom" : "Quake"
    }

    @ViewBuilder
    private func gameRows(_ kind: GameStore.Kind) -> some View {
        // Checkbox and name side by side, not in the form's label column,
        // which would wrap a file name a letter at a time.
        HStack {
            Toggle(title(kind), isOn: Binding(
                get: { selection.isGameChecked(kind) },
                set: { selection.setGameChecked(kind, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Text(title(kind))
                .font(.headline)
            Spacer()
            Button("Choose…") { choose(kind) }
                .disabled(isBusy)
                .help(kind == .doomWad
                    ? "Add a Doom IWAD of your own, such as doom2.wad or freedoom1.wad"
                    : "Use your own pak0.pak, or add pak1.pak")
        }
        Text(gameNote(kind))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(selection.items(of: kind)) { item in
            fileRow(item)
        }
        if kind == .quakePak && !selection.items(of: .quakePak).contains(where: {
            $0.identified.sha256 == QuakePak.sharewareSHA256
        }) {
            Text("pak0.pak, the shareware one "
                + "(\(GameStore.byteText(QuakePak.sharewareBytes))), is not downloaded yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func gameNote(_ kind: GameStore.Kind) -> String {
        switch kind {
        case .doomWad:
            return "The shareware doom1.wad ships with the firmware, in its own "
                + "\(GameStore.byteText(GameData.doomWadPartitionBytes)) doom_wad partition, "
                + "and is in the boot menu as DOOM. Each WAD added here is a menu row of its "
                + "own, named for its file."
        case .quakePak:
            return "Quake reads id1/pak0.pak, then pak1.pak if there is one. Download "
                + "fetches the shareware pak0.pak."
        }
    }

    private func fileRow(_ item: GameDataSelection.Item) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle(item.identified.storedName, isOn: Binding(
                get: { item.isChecked },
                set: { selection.setChecked(item.id, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!selection.isGameChecked(item.kind) || isBusy)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.identified.storedName)
                    .monospaced()
                Text(status(item))
                    .font(.caption)
                Text(item.identified.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(GameStore.byteText(item.identified.byteCount))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if case .chosen = item.source {
                Button {
                    selection.remove(item.id)
                    // A board file the removed one stood for is listed again.
                    if let board { selection.noteBoard(board.contents) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Remove this file from the list")
                .disabled(isBusy)
            }
        }
    }

    private func status(_ item: GameDataSelection.Item) -> String {
        var parts: [String] = []
        switch item.source {
        case .cache: parts.append("In this Mac's cache")
        case .chosen(let url): parts.append("Your file, \(url.deletingLastPathComponent().path)")
        case .board: break
        }
        if board == nil {
            parts.append("board not checked yet")
        } else if GameDataSelection.isOnBoard(item, contents: board?.contents) {
            parts.append("on the board")
        } else {
            parts.append("not on the board")
        }
        return parts.joined(separator: " · ")
    }

    private var actionsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Download Shareware") { startDownload() }
                    .disabled(isBusy || !canDownload)
                    .help("Fetch the shareware data for the checked games into this Mac's "
                        + "cache, from the mirrors tools/fetch_game_data.sh uses")
                Button("Check Board") { startBoardRead() }
                    .disabled(isBusy || target.usbDevice == nil)
                    .help("Read which game files the board holds, over USB. The board "
                        + "restarts while it is read.")
                if isReadingBoard {
                    ProgressView().controlSize(.small)
                }
            }
            if let downloadLine {
                if let downloadFraction {
                    ProgressView(value: downloadFraction) {
                        Text(downloadLine).font(.caption)
                    }
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(downloadLine).font(.caption)
                    }
                }
            }
            if let failure = downloadFailure ?? boardFailure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var canDownload: Bool {
        cache != nil && quakeOffered && selection.isGameChecked(.quakePak) && !sharewareCached
    }

    // MARK: space

    private var usableBytes: Int? {
        board?.area.usableBytes ?? GameDataSelection.expectedUsableBytes(chip: target.chip)
    }

    private var space: GameDataSelection.Space {
        selection.space(usableBytes: usableBytes, contents: board?.contents)
    }

    private var spaceSection: some View {
        Section("Space") {
            LabeledContent("On the board") {
                VStack(alignment: .leading, spacing: 4) {
                    if let usable = usableBytes {
                        Text("\(GameStore.byteText(space.neededBytes)) of "
                            + "\(GameStore.byteText(usable)) in "
                            + (board?.area.description ?? "the quake_pak partition"))
                            .monospacedDigit()
                        ProgressView(value: Double(min(space.neededBytes, usable)),
                                     total: Double(max(usable, 1)))
                            .tint(space.fits ? .accentColor : .red)
                    } else {
                        Text("\(GameStore.byteText(space.neededBytes)) selected. An S3's game "
                            + "data area is the flash past its firmware: 18 MB on a 32 MB "
                            + "board, 8 MB on a 16 MB one. Check Board reads which.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let problem = space.problem {
                        Text(problem)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            LabeledContent("On this Mac") {
                Text("The download cache uses \(GameStore.byteText(cacheUsedBytes))"
                    + (macFreeBytes.map { "; \(GameStore.byteText($0)) free" } ?? ""))
                    .monospacedDigit()
            }
        }
    }

    private var requirementText: String {
        "Everything is written over USB, after the board's hardware ID, chip and MAC "
            + "are re-verified, into the flash Quake's data has always used: the P4's "
            + "quake_pak partition, or an S3's flash past its firmware (16 MB of flash or "
            + "more). Firmware, settings and the bundled doom1.wad are not touched. The "
            + "board's boot menu lists each added WAD, and QUAKE, on firmware that reads "
            + "the game store; update the firmware first if it does not. Older firmware "
            + "still finds pak0.pak, which goes first whenever it can."
    }

    // MARK: action bar

    private var footerStatus: FlashFooterStatus? {
        if isWriting || usbFlash.session.failure != nil {
            return .usb(usbFlash.session)
        }
        return writeFailure.map { .failure($0) }
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if !isBusy || isRestartingBoard, let port = restartPort {
                    RestartFromFlashingModeButton(
                        manager: manager, port: port, hardwareID: target.hardwareID,
                        expectedGeneration: target.usbPathGeneration,
                        isRestarting: Binding(
                            get: { isRestartingBoard },
                            set: { isRestartingBoard = $0; isBusy = $0 })
                    ) { outcome in
                        restartPort = nil
                        boardFailure = nil
                        usbFlash.reset()
                        if case .ready(let refreshed) = manager.gameDataReadiness(
                            target.serviceName) {
                            target = refreshed
                        }
                        writeFailure = outcome.kind == .success ? nil : outcome
                        if outcome.kind == .success { manager.presentOperationOutcome(outcome) }
                    }
                }
                Spacer()
                Button(isWriting ? "Close" : "Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    // Only once every byte is out, as in the firmware sheet:
                    // the wait carries on and its outcome reaches the manager
                    // window.
                    .disabled(isWriting && !isWaitingForBoard)
                Button("Write over USB") {
                    writeFailure = nil
                    confirmWrite = true
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canWrite)
            }
            if let footerStatus {
                Divider()
                FlashStatusFooterView(status: footerStatus)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var canWrite: Bool {
        !isBusy && selection.hasCheckedGame && space.fits && target.usbDevice != nil
    }

    private var isWaitingForBoard: Bool {
        if case .waitingForBoard = usbFlash.session.phase { return true }
        return false
    }

    // MARK: actions

    /// The cache's size, the Mac's free space, and the cached shareware pak
    /// (hashed off the main thread, then listed: checked, unless the board
    /// already lists a pak0.pak of its own, which it would replace). The Quake
    /// checkbox itself is left as it was.
    private func refreshCacheFacts() {
        guard let cache else { return }
        let offerPak = quakeOffered
        Task.detached(priority: .utility) {
            let used = cache.usedBytes()
            let free = cache.availableBytes()
            let pak = offerPak ? cache.cached(GameData.quakeShareware) : nil
            await MainActor.run {
                cacheUsedBytes = used
                macFreeBytes = free
                sharewareCached = pak != nil
                if let pak, !selection.items(of: .quakePak).contains(where: {
                    $0.identified.storedName == pak.storedName
                }) {
                    let wasChecked = selection.isGameChecked(.quakePak)
                    let boardHasOne = selection.items(of: .quakePak).contains {
                        $0.source == .board && $0.identified.storedName == pak.storedName
                    }
                    selection.add(
                        pak, source: .cache(cache.url(for: GameData.quakeShareware)),
                        checked: !boardHasOne)
                    selection.setGameChecked(.quakePak, wasChecked)
                    if let board { selection.noteBoard(board.contents) }
                }
            }
        }
    }

    private func choose(_ kind: GameStore.Kind) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = kind == .doomWad
            ? "Choose one or more Doom IWADs."
            : "Choose Quake's pak0.pak, pak1.pak, or both."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        chooseFailure = nil
        isBusy = true
        Task {
            let results: [(URL, Result<GameData.Identified, Error>)] = await Task.detached {
                urls.map { url in
                    (url, Result {
                        try GameData.identify(
                            Data(contentsOf: url, options: .mappedIfSafe),
                            filename: url.lastPathComponent, kind: kind)
                    })
                }
            }.value
            isBusy = false
            var failures: [String] = []
            for (url, result) in results {
                switch result {
                case .success(let identified):
                    selection.add(identified, source: .chosen(url))
                case .failure(let error):
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if let board { selection.noteBoard(board.contents) }
            chooseFailure = failures.isEmpty ? nil : failures.joined(separator: "\n")
        }
    }

    private func startDownload() {
        guard let cache else { return }
        isBusy = true
        downloadFailure = nil
        downloadFraction = 0
        downloadLine = "Starting the download"
        Task {
            do {
                let identified = try await cache.fetch(GameData.quakeShareware) { fraction, line in
                    Task { @MainActor in
                        downloadFraction = fraction
                        downloadLine = line
                    }
                }
                selection.add(identified, source: .cache(cache.url(for: GameData.quakeShareware)))
                if let board { selection.noteBoard(board.contents) }
                downloadLine = nil
            } catch {
                downloadLine = nil
                downloadFailure = error.localizedDescription
            }
            isBusy = false
            refreshCacheFacts()
        }
    }

    private func startBoardRead() {
        isBusy = true
        isReadingBoard = true
        boardFailure = nil
        restartPort = nil
        usbFlash.reset()
        let monitor = usbFlash
        Task {
            let result = await manager.readGameDataOverUSB(from: target) { update in
                monitor.record(update)
            }
            isReadingBoard = false
            isBusy = false
            switch result {
            case .done(let read):
                board = (read.area, read.contents)
                selection.noteBoard(read.contents)
            case .stop(let outcome):
                boardFailure = outcome.title + ": " + outcome.message
                restartPort = outcome.restartPort
            }
        }
    }

    private func startWrite() {
        isBusy = true
        isWriting = true
        writeFailure = nil
        restartPort = nil
        usbFlash.reset()
        let monitor = usbFlash
        let chosen = selection
        monitor.record(.phase(.findingBoard))
        Task {
            let outcome = await manager.writeGameDataOverUSB(chosen, to: target) { update in
                monitor.record(update)
            }
            restartPort = outcome.restartPort
            if outcome.kind == .failure {
                monitor.fail(outcome)
                // The write may have changed the board before it stopped, so
                // what it was read to hold no longer stands. The rows and their
                // checkboxes stay; a write reads the board again and keeps any
                // file nobody unchecked.
                board = nil
            }
            isWriting = false
            isBusy = false
            if outcome.kind == .success {
                manager.presentOperationOutcome(outcome)
                dismiss()
            } else if sheetIsVisible {
                writeFailure = outcome
            } else {
                manager.presentOperationOutcome(outcome)
            }
        }
    }
}
