import AppKit
import SenderProtocol
import SwiftUI
import UniformTypeIdentifiers

/// Add a display that is not on the network yet, over its USB cable.
///
/// WHAT THIS DIALOG IS FOR, in one sentence: a board that has never joined a
/// network is never discovered, so it never appears in the sidebar, so every
/// existing way to give it credentials - all of which start "select a display" -
/// cannot be reached. This starts from the cable instead.
///
/// Every judgement it makes is made in SenderProtocol and asked for here:
/// `UsbOnboardingPlan` for what is missing and whether to offer to start,
/// `FirmwareBundle.flashPlan` for what gets written where, `EsptoolCommand` for the
/// argv, `SerialSettlePolicy` for when the board can be spoken to after a reset.
/// This file is the form and the wiring.
struct AddDeviceSheet: View {
    @ObservedObject var manager: PanelManager
    @Environment(\.dismiss) private var dismiss

    /// The serial device. Chosen, never guessed - see `UsbOnboardingPlan`'s
    /// `chooseDevice` case for why an app that picks one for you is a hazard here.
    @State private var port = ""
    @State private var mode: UsbOnboarding.Mode = .flashAndConfigure
    @State private var detection: UsbOnboarding.ChipDetection = .notAttempted
    @State private var existing: UsbOnboarding.ExistingFirmware = .notChecked
    @State private var inspecting = false
    @State private var tool: UsbOnboarding.ToolAvailability = .missing(searched: [])

    @State private var bundle: FirmwareBundle?
    @State private var bundleLabel = ""
    @State private var bundleIsShipped = false
    @State private var bundleProblem: String?

    /// Empty means the network is being typed in rather than chosen.
    @State private var savedSSID = ""
    @State private var typedSSID = ""
    @State private var typedPassword = ""
    @State private var openNetwork = false
    @State private var name = ""
    @State private var eraseAll = false

    @State private var running = false
    @State private var progress: UsbOnboarder.Progress?
    @State private var confirming = false
    @State private var work: Task<Void, Never>?

    var body: some View {
        Form {
            deviceSection
            if mode == .flashAndConfigure {
                firmwareSection
            }
            networkSection
            verdictSection
            if running {
                progressSection
            }
        }
        .formStyle(.grouped)
        .labeledContentStyle(.labelColumn)
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
        .frame(width: 560, height: 620)
        .onAppear(perform: prepare)
        .onDisappear {
            // The sheet going away must not leave esptool running against a board
            // with nobody watching. Unlike the OTA push - where the transfer is
            // finished before the sheet can be closed - a flash can be in the
            // middle of writing flash, and the sheet's own Close button is disabled
            // for exactly that window. This covers the window closing some other
            // way.
            work?.cancel()
        }
        .confirmationDialog(
            confirmationTitle, isPresented: $confirming, titleVisibility: .visible
        ) {
            Button(plan.verb, role: plan.writesFlash ? .destructive : nil) {
                start()
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: - sections

    private var deviceSection: some View {
        Section {
            LabeledContent("USB device") {
                HStack(spacing: 8) {
                    Picker("USB device", selection: $port) {
                        Text("Choose…").tag("")
                        ForEach(manager.usbSerialPorts, id: \.self) { candidate in
                            Text((candidate as NSString).lastPathComponent)
                                .tag(candidate)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(running)

                    Button {
                        manager.refreshUSBPorts()
                        inspect()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(running)
                    .help("Look for USB serial devices again")
                }
            }
            LabeledContent("Board") {
                HStack(spacing: 6) {
                    if inspecting {
                        ProgressView().controlSize(.small)
                    }
                    Text(boardDescription)
                        .foregroundStyle(detection.chip == nil ? .secondary : .primary)
                }
            }
            // A MENU PICKER, in the same `LabeledContent` shape every other control
            // in this window uses, because that is the one that renders correctly
            // under this form's `.labelColumn` style. Two attempts at a radio group
            // did not, and both were seen on the built app rather than guessed at:
            // it drew "Flash firmware and set up WiFi" and "Set up WiFi only" on top
            // of each other in the trailing column and truncated its own label to
            // "What to", with the label on the right - and it did the same when
            // given its own VStack with the label hidden.
            LabeledContent("What to do") {
                Picker("What to do", selection: $mode) {
                    ForEach(UsbOnboarding.Mode.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(running)
            }
        } header: {
            Text("Device")
        } footer: {
            Text("The chip is read off the board, so there is nothing to choose "
                + "between a C6 and an S3. A board that already runs this firmware "
                + "is offered WiFi setup on its own; a blank one is offered the "
                + "firmware as well.")
        }
    }

    @ViewBuilder
    private var firmwareSection: some View {
        Section {
            if let bundle {
                LabeledContent("Version", value: bundle.firmwareVersion)
                LabeledContent("Built", value: bundle.builtAt)
                LabeledContent("File", value: bundleLabel)
                LabeledContent("Images", value: bundle.chips.joined(separator: ", "))
            } else {
                Text(bundleProblem
                    ?? "This copy of the app was packaged without a firmware "
                        + "bundle. Choose an .espdispfw file, or build one with "
                        + "tools/espdisp.py bundle.")
                    .font(.callout)
                    .foregroundStyle(bundleProblem == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(bundle == nil ? "Choose Firmware…" : "Use a Different File…") {
                    chooseFile()
                }
                .disabled(running)
                if !bundleIsShipped, BundledFirmware.defaultBundleURL() != nil {
                    Button("Use the Bundled Firmware") { loadShippedBundle() }
                        .disabled(running)
                }
            }
            Toggle("Erase the whole chip first", isOn: $eraseAll)
                .disabled(running)
        } header: {
            Text("Firmware")
        } footer: {
            Text("Erasing takes NVS with it, which is where a board keeps its "
                + "network and its name, so it is off unless you ask. Without it "
                + "the parts being written are replaced and everything else on the "
                + "chip is left where it is.")
        }
    }

    private var networkSection: some View {
        Section {
            Picker("Network", selection: $savedSSID) {
                Text("Type a network…").tag("")
                ForEach(manager.savedNetworkNames, id: \.self) { ssid in
                    Text(ssid).tag(ssid)
                }
            }
            .disabled(running)
            if savedSSID.isEmpty {
                TextField("Network name (SSID)", text: $typedSSID)
                    .disabled(running)
                SecureField("Password", text: $typedPassword)
                    .disabled(running || openNetwork)
                Toggle("Open network (no password)", isOn: $openNetwork)
                    .disabled(running)
            }
            TextField("Name for this display (optional)", text: $name)
                .disabled(running)
        } header: {
            Text("WiFi")
        } footer: {
            Text("The credentials are sent over the cable and saved on the board, "
                + "which is what lets one firmware bundle serve any network. A "
                + "password you type is kept in your login Keychain. A name is "
                + "shortened to letters, numbers and dashes; leave it blank to keep "
                + "the board's own.")
        }
    }

    private var verdictSection: some View {
        Section("What this will do") {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.headline)
                    .fontWeight(.medium)
                Text(plan.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var progressSection: some View {
        Section("Progress") {
            VStack(alignment: .leading, spacing: 8) {
                if let percent = writingPercent {
                    ProgressView(value: Double(percent), total: 100)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(progressDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(running ? "Stop" : "Cancel", role: .cancel) {
                if running {
                    work?.cancel()
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)
            // Stopping is offered while the chip is being read and while the board
            // is being waited for, and NOT while flash is being written: there is
            // nothing honest to do with a half-written partition table from this
            // side, and a board interrupted between its bootloader and its app does
            // not boot. The same argument the OTA sheet makes about a half-written
            // app slot, one step earlier in the process.
            .disabled(running && isWritingFlash)
            .help(running && isWritingFlash
                ? "Writing flash cannot be interrupted safely"
                : "")
            Button(plan.verb) {
                if plan.writesFlash {
                    confirming = true
                } else {
                    start()
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!plan.canStart || running)
        }
        .padding(12)
        .glassCard(cornerRadius: 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: - derived

    private var ssid: String {
        savedSSID.isEmpty
            ? typedSSID.trimmingCharacters(in: .whitespaces)
            : savedSSID
    }

    /// What to do about the password, or that there is nothing to send yet.
    private var credential: UsbOnboarding.Credential {
        if savedSSID.isEmpty {
            if openNetwork { return .ready(.openNetwork) }
            return typedPassword.isEmpty ? .incomplete : .ready(.set(typedPassword))
        }
        guard let saved = manager.savedWifiCredential(for: savedSSID) else {
            return .incomplete
        }
        return .ready(saved.password.isEmpty ? .openNetwork : .set(saved.password))
    }

    private var request: UsbOnboarding.Request {
        UsbOnboarding.Request(
            port: port,
            availablePorts: manager.usbSerialPorts,
            mode: mode,
            tool: tool,
            bundle: bundle,
            detection: detection,
            existing: existing,
            ssid: ssid,
            credential: credential)
    }

    private var plan: UsbOnboardingPlan { UsbOnboardingPlan.make(request) }

    private var boardDescription: String {
        switch detection {
        case .detected(let chip, let mac):
            guard let mac else { return chip }
            return "\(chip) · \(mac)"
        case .failed:
            return "Could not be read"
        case .notAttempted:
            if inspecting { return "Reading…" }
            switch existing {
            case .answered(let name) where !name.isEmpty:
                return "Already set up as \"\(name)\""
            case .answered:
                return "Already running this firmware"
            case .silent:
                return "Nothing answered on this port"
            case .notChecked:
                return port.isEmpty ? "No device chosen" : "Not read yet"
            }
        }
    }

    private var isWritingFlash: Bool {
        if case .writing = progress { return true }
        return false
    }

    private var writingPercent: Int? {
        if case .writing(let percent, _) = progress { return percent }
        return nil
    }

    private var progressDescription: String {
        switch progress {
        case .none:
            return "Starting…"
        case .readingChip:
            return "Reading the board…"
        case .writing(let percent, let status):
            guard let percent else { return status }
            return "\(percent)% · \(status)"
        case .waitingForBoard:
            return "Waiting for the board to restart…"
        case .configuring(let label):
            return label
        }
    }

    private var confirmationTitle: String {
        guard let chip = detection.chip else { return "Write this board?" }
        return "Write firmware to this \(chip)?"
    }

    private var confirmationMessage: String {
        var message = "Everything the board needs is written at the addresses the "
            + "bundle carries, which replaces whatever firmware is on it now."
        if eraseAll {
            message += " The whole chip is erased first, so any network or name "
                + "already saved on it is lost."
        }
        return message
    }

    // MARK: - actions

    private func prepare() {
        manager.refreshUSBPorts()
        manager.refreshSavedNetworks()
        tool = EsptoolInstallation.locate()
        loadShippedBundle()
        if let first = manager.savedNetworkNames.first { savedSSID = first }
        // One device connected is not a guess about which board it is - there is
        // only one - and it saves the most common case a click. Still shown in the
        // picker, and still re-chooseable.
        if port.isEmpty, manager.usbSerialPorts.count == 1 {
            port = manager.usbSerialPorts[0]
        }
        inspect()
    }

    private func loadShippedBundle() {
        switch BundledFirmware.load() {
        case .ready(let shipped, let url):
            bundle = shipped
            bundleLabel = url.lastPathComponent + " (bundled with the app)"
            bundleIsShipped = true
            bundleProblem = nil
        case .unreadable(let path, let reason):
            bundle = nil
            bundleLabel = ""
            bundleIsShipped = false
            bundleProblem = "The firmware bundled with the app (\(path)) could not "
                + "be read: \(reason)"
        case .none:
            bundle = nil
            bundleLabel = ""
            bundleIsShipped = false
            bundleProblem = nil
        }
    }

    /// Ask the board what it is, without writing to it.
    ///
    /// CFGSHOW FIRST, esptool second, and the order matters: CFGSHOW is a line on
    /// an already-open tty and leaves the board running, while every esptool run
    /// ends by resetting it. A board that answers CFGSHOW and only needs
    /// credentials is therefore never reset at all.
    private func inspect() {
        detection = .notAttempted
        existing = .notChecked
        let target = port
        guard !target.isEmpty, !running else { return }
        inspecting = true
        work = Task {
            // Cleared on every exit path, including the two early returns below: a
            // spinner that never stops reads as a hang.
            defer { inspecting = false }
            let answered = await Task.detached {
                UsbOnboarder.probeExistingFirmware(port: target)
            }.value
            // The user may have changed the port, or closed the sheet, during the
            // three seconds CFGSHOW is allowed. Answers about a port nobody is
            // asking about any more are dropped rather than displayed.
            guard !Task.isCancelled, target == port else { return }
            existing = answered
            mode = UsbOnboarding.suggestedMode(for: answered)
            guard mode == .flashAndConfigure, case .installed(let path) = tool
            else { return }
            let read = await UsbOnboarder.detectChip(
                port: target, tool: EsptoolCommand.Tool(path: path))
            guard !Task.isCancelled, target == port else { return }
            detection = read
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a firmware bundle written by tools/espdisp.py bundle."
        panel.prompt = "Open"
        if let type = UTType(filenameExtension: FirmwareBundle.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            bundle = try FirmwareBundle.read(contentsOf: url)
            bundleLabel = url.lastPathComponent
            bundleIsShipped = false
            bundleProblem = nil
        } catch {
            bundle = nil
            bundleLabel = ""
            bundleIsShipped = false
            bundleProblem = error.localizedDescription
        }
    }

    private func start() {
        guard plan.canStart, let change = credential.passwordChange else { return }
        running = true
        progress = mode == .flashAndConfigure ? .writing(percent: nil, status: "Starting…")
            : .waitingForBoard
        let job = PanelManager.USBOnboardRequest(
            port: port,
            mode: mode,
            bundle: bundle,
            chip: detection.chip,
            mac: {
                if case .detected(_, let mac) = detection { return mac }
                return nil
            }(),
            tool: {
                if case .installed(let path) = tool {
                    return EsptoolCommand.Tool(path: path)
                }
                return nil
            }(),
            ssid: ssid,
            password: change,
            name: name,
            eraseAll: eraseAll)
        // Not `.task`: this outlives nothing here, but it must survive the form
        // redrawing, and cancellation is wired to the Stop button rather than to the
        // view's lifetime.
        work = Task {
            let succeeded = await manager.onboardUSBDevice(job) { update in
                Task { @MainActor in progress = update }
            }
            running = false
            progress = nil
            if succeeded {
                dismiss()
            } else {
                // Left open with the port, the firmware and the network still filled
                // in, so a retry is one button. The outcome alert says what
                // happened.
                manager.refreshUSBPorts()
            }
        }
    }
}

#if DEBUG
#Preview("Add Display") {
    AddDeviceSheet(manager: PanelManager.preview)
}
#endif
