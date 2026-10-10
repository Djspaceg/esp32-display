import AppKit
import SenderProtocol
import SwiftUI

/// The Firmware section's "Quake data" row: the button that opens
/// `QuakeDataSheet`, and the reason under it when it cannot proceed.
///
/// Its own view, holding its own sheet state, so the manager window gains one
/// line rather than another `@State` and `.sheet` of its own.
struct QuakeDataRow: View {
    let panel: PanelSnapshot
    @ObservedObject var manager: PanelManager
    @State private var target: PanelManager.FirmwareUpdateTarget?

    /// Quake runs only on the P4 and the S3 boards whose panel holds its frame,
    /// so the row is not offered elsewhere. The chip is the panel's, else its
    /// matched USB device's, as the firmware sheet's target takes it.
    @MainActor
    static func isOffered(for panel: PanelSnapshot, manager: PanelManager) -> Bool {
        let device = manager.usbUpdateDevice(for: panel.serviceName)
        return QuakePak.supports(
            chip: panel.chip ?? device?.chip, profile: panel.profile ?? device?.board)
    }

    var body: some View {
        let unavailable = manager.quakeDataUnavailableReason(panel.serviceName)
        LabeledContent("Quake data") {
            VStack(alignment: .leading, spacing: 4) {
                // Not disabled when it cannot proceed, for the reason the Update
                // button above is not: the sentence under it says why.
                Button("Install Quake Data…") {
                    target = manager.beginQuakeDataInstall(panel.serviceName)
                }
                .help(unavailable
                    ?? "Write your copy of Quake's id1/pak0.pak to this display over USB")
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
            QuakeDataSheet(manager: manager, target: target)
        }
    }
}

/// Choose a local Quake pak and write it to a matched USB board.
///
/// Modelled on `FirmwareUpdateSheet`'s USB flow: the same monitor, footer and
/// transcript, and the same rule that the sheet only asks - the board is
/// re-verified and the destination decided by `writeQuakeDataOverUSB`.
struct QuakeDataSheet: View {
    @ObservedObject var manager: PanelManager
    @Environment(\.dismiss) private var dismiss
    let target: PanelManager.FirmwareUpdateTarget

    @State private var fileURL: URL?
    @State private var validated: QuakePak.Validated?
    @State private var readFailure: String?
    @State private var isReading = false
    @State private var confirmWrite = false
    @State private var isWriting = false
    @State private var writeFailure: OperationOutcome?
    @State private var sheetIsVisible = false
    @StateObject private var usbFlash = UsbFlashMonitor(flow: .update)

    /// `chosen` starts the sheet with a file already read, for the capture
    /// tests; the app always opens it empty.
    init(
        manager: PanelManager, target: PanelManager.FirmwareUpdateTarget,
        chosen: (url: URL, validated: QuakePak.Validated)? = nil
    ) {
        self.manager = manager
        self.target = target
        _fileURL = State(initialValue: chosen?.url)
        _validated = State(initialValue: chosen?.validated)
    }

    var body: some View {
        Form {
            Section("Display") {
                LabeledContent("Display", value: target.displayName)
                LabeledContent("Chip", value: target.chip ?? "Not reported")
                LabeledContent("USB device") {
                    Text(target.usbDevice?.path ?? "Not connected")
                        .monospaced()
                        .textSelection(.enabled)
                }
            }
            fileSection
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
        .frame(width: 520, height: 620)
        .onAppear { sheetIsVisible = true }
        .onDisappear { sheetIsVisible = false }
        .confirmationDialog(
            "Write Quake's data to \(target.displayName)?",
            isPresented: $confirmWrite, titleVisibility: .visible
        ) {
            Button("Write") { startWrite() }
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: sections

    @ViewBuilder
    private var fileSection: some View {
        Section("Quake data") {
            if let fileURL, let validated {
                LabeledContent("File", value: fileURL.lastPathComponent)
                LabeledContent("Size") {
                    Text("\(validated.byteCount) bytes "
                        + "(\(PanelManager.quakeByteText(validated.byteCount)))")
                        .monospacedDigit()
                }
                LabeledContent("Contents", value: validated.isShareware
                    ? "The shareware id1/pak0.pak"
                    : "A Quake pack with \(validated.entryCount) files, not the "
                        + "shareware pak0.pak")
            }
            Button(validated == nil ? "Choose pak0.pak…" : "Choose a Different File…") {
                chooseFile()
            }
            .disabled(isWriting || isReading)
            if let readFailure {
                Text(readFailure)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if validated == nil {
                Text("Your own copy of id1/pak0.pak. tools/fetch_game_data.sh "
                    + "--game quake fetches the shareware one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var requirementText: String {
        let common = "The data is written over USB, after the board's hardware ID, "
            + "chip and MAC are re-verified, into flash kept for Quake alone; "
            + "firmware and settings are not touched. Once the data is on the "
            + "board, its boot menu offers QUAKE."
        switch target.chip {
        case QuakePak.s3Chip?:
            return "An ESP32-S3 board needs 32 MiB of flash to hold Quake's data; "
                + "a 16 MiB board is refused before anything is written. " + common
        case QuakePak.p4Chip?:
            return "An ESP32-P4 board needs the current firmware's partition "
                + "layout, which reserves a Quake partition. " + common
        default:
            return "Quake runs only on ESP32-P4 boards and ESP32-S3 boards with "
                + "32 MiB of flash. " + common
        }
    }

    private var confirmationMessage: String {
        let size = validated.map { PanelManager.quakeByteText($0.byteCount) }
            ?? "The file"
        return "\(size) will be written over USB. The board restarts afterwards; "
            + "nothing else on it is erased."
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
        !isWriting && !isReading && validated != nil && fileURL != nil
            && target.usbDevice != nil
    }

    private var isWaitingForBoard: Bool {
        if case .waitingForBoard = usbFlash.session.phase { return true }
        return false
    }

    // MARK: actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose Quake's id1/pak0.pak."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func load(_ url: URL) {
        isReading = true
        readFailure = nil
        writeFailure = nil
        Task {
            let result: Result<QuakePak.Validated, Error> = await Task.detached {
                Result {
                    try QuakePak.validate(Data(contentsOf: url, options: .mappedIfSafe))
                }
            }.value
            isReading = false
            switch result {
            case .success(let read):
                fileURL = url
                validated = read
            case .failure(let error):
                fileURL = nil
                validated = nil
                readFailure = error.localizedDescription
            }
        }
    }

    private func startWrite() {
        guard let fileURL else { return }
        isWriting = true
        writeFailure = nil
        usbFlash.reset()
        let monitor = usbFlash
        monitor.record(.phase(.findingBoard))
        Task {
            let outcome = await manager.writeQuakeDataOverUSB(
                fileURL: fileURL, to: target
            ) { update in
                monitor.record(update)
            }
            if outcome.kind == .failure { monitor.fail(outcome) }
            isWriting = false
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
