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
    /// The firmware version the board reported, shown as is.
    @State private var boardVersion: String?
    @State private var boardSource: FirmwareSourceIdentity?
    @State private var inspecting = false
    @State private var inspectionGeneration = 0
    @State private var inspectedPathGeneration: Int?
    /// The inspected device as the manager listed it when the inspection's
    /// CFGSHOW finished, so a later answer can be told from an earlier one.
    @State private var deviceAtInspection: WifiConfigUI.USBDeviceOption?
    @State private var tool: UsbOnboarding.ToolAvailability = .missing(searched: [])

    @State private var bundle: FirmwareBundle?
    @State private var bundledReleases: BundledFirmware.ReleaseSet?
    @State private var bundleLabel = ""
    @State private var bundleIsShipped = false
    @State private var bundleProblem: String?
    /// Where the catalog in `bundledReleases` came from, in words.
    @State private var sourceName = "bundled with the app"
    /// The last file or folder the user picked that could not be used. Shown
    /// beside whatever firmware is still loaded, and cleared by the next
    /// successful load or a new board.
    @State private var loadError: String?
    @State private var selectedTarget = ""
    @State private var selectedProfile = ""
    /// The catalog folder chosen with "Use Dev Builds…", remembered so the
    /// folder picker opens there next time. The shipped firmware stays the
    /// default source.
    @AppStorage("AddDevice.devCatalogFolder") private var devCatalogFolder = ""

    /// One of the app's saved networks, which are added in Settings and only
    /// chosen here. Empty until one is.
    @State private var savedSSID = ""
    @State private var name = ""
    @State private var eraseAll = false

    @State private var running = false
    @StateObject private var flash = UsbFlashMonitor(flow: .onboarding)
    @State private var confirming = false
    @State private var work: Task<Void, Never>?
    /// Showing the repair flow in place of the form, for a board that drops
    /// off USB before it can be chosen here.
    @State private var repairing = false
    @State private var prepared = false
    /// Whether the form is on screen, so a failure is only taken off the
    /// manager window's alert when this sheet is there to show it instead.
    @State private var formIsShowing = false

    var body: some View {
        if repairing {
            UsbRepairView(manager: manager, family: nil, closeTitle: "Back") { repairedPort in
                finishRepair(port: repairedPort)
            }
            .frame(width: 560, height: 620)
        } else {
            addForm
        }
    }

    private var addForm: some View {
        Form {
            deviceSection
            if mode == .flashAndConfigure {
                firmwareSection
            }
            networkSection
            verdictSection
            // Progress and failure are in the floating footer, always on
            // screen; the transcript stays here.
            if !flash.session.transcript.entries.isEmpty {
                Section("Details") {
                    UsbFlashTranscriptView(session: flash.session)
                }
            }
        }
        .formStyle(.grouped)
        // Every message in here - errors above all - can be selected and
        // copied. Set once at the root, so a message added later cannot be
        // the one that forgot.
        .textSelection(.enabled)
        .labeledContentStyle(.labelColumn)
        .safeAreaInset(edge: .bottom) {
            actionBar.textSelection(.enabled)
        }
        .frame(width: 560, height: 620)
        // Once per sheet: coming back from the repair flow must not reset the
        // network and firmware already chosen.
        .onAppear {
            formIsShowing = true
            guard !prepared else { return }
            prepared = true
            prepare()
        }
        .onDisappear {
            formIsShowing = false
            // The sheet going away must not leave esptool running against a board
            // with nobody watching. Unlike the OTA push - where the transfer is
            // finished before the sheet can be closed - a flash can be in the
            // middle of writing flash, and the sheet's own Close button is disabled
            // for exactly that window. This covers the window closing some other
            // way.
            work?.cancel()
        }
        .onChange(of: manager.usbDevices) { _, _ in
            usbDevicesChanged()
        }
        .onChange(of: mode) { _, selected in
            if selected == .flashAndConfigure,
               detection.chip == nil,
               !port.isEmpty,
               !inspecting,
               !running {
                inspect(preserveMode: true)
            }
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
                        ForEach(manager.usbDevices) { device in
                            if let recordName = manager.associatedDisplayName(
                                forUSBPath: device.path) {
                                Text("\(device.displayName) — already added as \(recordName)")
                                    .tag(device.path)
                                    .disabled(true)
                            } else {
                                Text(device.displayName).tag(device.path)
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(running)
                    .help(port.isEmpty ? "Choose a connected display" : port)
                    .onChange(of: port) { _, _ in
                        work?.cancel()
                        inspect()
                    }

                    Button {
                        manager.refreshUSBDevices()
                        // The user's choice of what to do survives a re-read.
                        inspect(preserveMode: true)
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
                    Text(boardDescription
                        + (boardVersion.map { " · runs \($0)" } ?? ""))
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
                        Text(option.label)
                            .tag(option)
                            .disabled(
                                option == .configureOnly
                                    && requiresFirmwareForStableIdentity)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(running)
            }
            if requiresFirmwareForStableIdentity {
                Text("Set up WiFi only is unavailable for this board: its firmware "
                    + "does not report a hardware ID this app can record a display "
                    + "under, so it is flashed first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Not listed?") {
                Button("Repair a Board…") { startRepair() }
                    .disabled(running)
                    .help("For a board that appears for a moment after it is plugged "
                        + "in, then disappears")
            }
        } header: {
            Text("Device")
        } footer: {
            Text("The chip is read from the board. The C6 and S3 families each "
                + "ship one universal image that serves every display in the "
                + "family, so the chip picks it on its own. A P4 image drives the "
                + "display pins of whatever P4 it lands on, so its board must be "
                + "known - from what the board reports or by choosing it - "
                + "before its image is offered.")
        }
    }

    @ViewBuilder
    private var firmwareSection: some View {
        Section {
            if let loadError {
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !compatibleProfiles.isEmpty {
                Picker("Board model", selection: $selectedProfile) {
                    Text("Choose…").tag("")
                    ForEach(compatibleProfiles, id: \.self) { profile in
                        Text(GeneratedBoardCatalog.boardNameByProfile[profile] ?? profile)
                            .tag(profile)
                    }
                }
                .disabled(running)
                .onChange(of: selectedProfile) { _, _ in preselectExactTarget() }
            }
            if let bundle {
                if let bundleNote {
                    Text(bundleNote)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Shown as the bundle names it, with what it does to the
                // version the board reports. Never hidden for being unknown.
                LabeledContent("Version", value: (bundle.firmwareBuild.map {
                    "\(bundle.firmwareVersion)+\($0)"
                } ?? bundle.firmwareVersion) + (plan.direction.map { dir in
                    " · \(dir)" + (boardVersion.map { " from \($0)" } ?? "")
                } ?? ""))
                LabeledContent("Built", value: bundle.builtAt)
                LabeledContent("File", value: bundleLabel)
                LabeledContent("Images", value: bundle.targets.joined(separator: ", "))
                if !compatibleTargets.isEmpty {
                    Picker("Exact target", selection: $selectedTarget) {
                        Text("Choose…").tag("")
                        ForEach(compatibleTargets, id: \.self) { target in
                            Text(target).tag(target)
                        }
                    }
                    .disabled(running)
                }
            } else if bundledReleases != nil, bundleProblem == nil {
                // The app ships firmware; it is picked once the board is read,
                // or once its model is chosen above. Never "no firmware".
                Text(compatibleProfiles.isEmpty
                    ? "The firmware \(sourceName) is chosen once the board "
                        + "has been read."
                    : "Choose the board model above, and the firmware "
                        + "\(sourceName) for it is used.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                .help("Any .espdispfw bundle, from any build")
                Button("Use Dev Builds…") { chooseDevCatalog() }
                    .disabled(running)
                    .help("A catalog folder such as the repo's firmware-dev, "
                        + "with its manifest.json")
                if !bundleIsShipped, BundledFirmware.catalogURL() != nil {
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
            if manager.savedNetworkNames.isEmpty {
                LabeledContent("Network") {
                    Text("None saved on this Mac yet")
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("Network", selection: $savedSSID) {
                    Text("Choose a network…").tag("")
                    ForEach(manager.savedNetworkNames, id: \.self) { ssid in
                        Text(ssid).tag(ssid)
                    }
                }
                .disabled(running)
            }
            HStack {
                Spacer()
                // Settings is its own window, so it opens beside this sheet,
                // and a network added there appears in the picker at once.
                Button(manager.savedNetworkNames.isEmpty
                    ? "Add a Network in Settings…" : "WiFi Settings…"
                ) {
                    SettingsPane.open(.wifiNetworks)
                }
                .buttonStyle(.link)
                .textSelection(.disabled)
                .disabled(running)
            }
            TextField("Name for this display (optional)", text: $name)
                .disabled(running)
        } header: {
            Text("WiFi")
        } footer: {
            Text("The network is one of this Mac's saved networks, which are added "
                + "and edited in Settings. Its credentials are sent over the cable "
                + "and saved on the board, which is what lets one firmware bundle "
                + "serve any network. A name is shortened to letters, numbers and "
                + "dashes; leave it blank to keep the board's own.")
        }
        // A network added or removed in Settings while this sheet is open.
        // The first one saved is chosen, as when the sheet opens; one that
        // goes away is not replaced by another nobody chose.
        .onChange(of: manager.savedNetworkNames) { old, names in
            guard !running else { return }
            if old.isEmpty, savedSSID.isEmpty, let first = names.first {
                savedSSID = first
            } else if !savedSSID.isEmpty, !names.contains(savedSSID) {
                savedSSID = ""
            }
        }
    }

    private var verdictSection: some View {
        Section("What this will do") {
            if let migration = usbPartitionMigration {
                Label(
                    "Partition table rewrite",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(
                    "This USB flash will rewrite the partition table from "
                        + "\(migration.from) to \(migration.to). The replacement "
                        + "table and app are written together.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(shownPlan.headline)
                    .fontWeight(.medium)
                Text(shownPlan.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            // WHY THE BUTTON IS GREY, next to the button. The verdict section
            // says it too, but it scrolls under this footer, and a disabled
            // button with its reason out of sight reads as no reason at all.
            if !plan.canStart, !running {
                VStack(alignment: .leading, spacing: 4) {
                    Text(shownPlan.headline)
                        .font(.callout.weight(.semibold))
                    Text(shownPlan.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            actionButtons
            // At the bottom of the floating footer, so it is on screen for the
            // whole run without scrolling.
            if running || flash.session.failure != nil {
                Divider()
                FlashStatusFooterView(status: .usb(flash.session))
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var actionButtons: some View {
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
            // Every reason this is off is a plan action with words: an
            // associated device empties the request's port, and a missing
            // hardware ID is `.identifyBoard`.
            .disabled(!plan.canStart || running)
        }
    }

    // MARK: - derived

    private var ssid: String { savedSSID }

    /// What to send for the password, from the saved credential, or that there
    /// is nothing to send yet.
    private var credential: UsbOnboarding.Credential {
        guard !savedSSID.isEmpty,
              let saved = manager.savedWifiCredential(for: savedSSID)
        else { return .incomplete }
        return .ready(saved.isOpenNetwork ? .openNetwork : .set(saved.password))
    }

    private var requiresFirmwareForStableIdentity: Bool {
        if case .answered(_, let hardwareID) = existing {
            return ConfigCommands.canonicalHardwareID(hardwareID) == nil
        }
        return false
    }

    private var effectiveMode: UsbOnboarding.Mode {
        requiresFirmwareForStableIdentity ? .flashAndConfigure : mode
    }

    private var request: UsbOnboarding.Request {
        let evidenceIsCurrent = port.isEmpty
            || inspectedPathGeneration == manager.usbPathGeneration(port)
        let eligible = evidenceIsCurrent && !manager.isUSBDeviceAssociated(port)
        return UsbOnboarding.Request(
            port: eligible ? port : "",
            availablePorts: manager.usbSerialPorts,
            mode: effectiveMode,
            tool: tool,
            bundle: bundle,
            target: selectedTarget.isEmpty ? nil : selectedTarget,
            detection: detection,
            existing: existing,
            ssid: ssid,
            credential: credential,
            shipsFirmware: bundledReleases != nil,
            boardChoices: compatibleProfiles,
            hardwareIDKnown: selectedHardwareID != nil,
            boardBeingRead: inspecting,
            bundleProblem: bundleProblem,
            alreadyAddedAs: manager.associatedDisplayName(forUSBPath: port),
            chosenBoard: selectedProfile.isEmpty ? nil : selectedProfile,
            boardFirmwareVersion: boardVersion,
            boardFirmwareSource: boardSource,
            unavailableReason: unavailableReason)
    }

    private var compatibleTargets: [String] {
        guard let bundle, let chip = detection.chip else { return [] }
        return Array(Set(bundle.images
            .filter { $0.chip == chip }
            .flatMap(\.targets))).sorted()
    }

    /// The note on the loaded selection, when it was offered as the file
    /// describes itself rather than as its catalog named it.
    private var bundleNote: String? {
        guard let bundle, let releases = bundledReleases else { return nil }
        return releases.selections.values.first { $0.bundle == bundle }?.note
    }

    /// Why the loaded catalog's image for the detected chip is listed but
    /// unusable, so the plan can say it instead of "nothing for this board".
    private var unavailableReason: String? {
        guard let releases = bundledReleases, let chip = detection.chip else { return nil }
        for entry in releases.catalog.families.values where entry.chip == chip {
            let options = releases.revisions(for: entry.family)
            if !options.contains(where: \.isAvailable),
               let reason = options.compactMap(\.unavailableReason).first {
                return reason
            }
        }
        return nil
    }

    private var compatibleProfiles: [String] {
        guard let releases = bundledReleases, let chip = detection.chip else { return [] }
        return releases.selections.values
            .filter { $0.catalogEntry.chip == chip }
            .flatMap { $0.catalogEntry.profiles }
            .sorted()
    }

    private func preselectExactTarget() {
        if let releases = bundledReleases, let chip = detection.chip {
            if let identity = manager.usbReleaseIdentity(for: port),
               let resolution = try? releases.resolveUpdate(
                    family: identity.family, chip: chip,
                    profile: identity.profile, partition: identity.partition,
                    transport: .usb) {
                bundle = resolution.selection.bundle
                bundleLabel = resolution.selection.url.lastPathComponent
                    + " (\(sourceName))"
                selectedTarget = resolution.canonicalTarget
                selectedProfile = identity.profile ?? ""
            } else if !selectedProfile.isEmpty,
                      let selection = releases.selections.values.first(where: {
                          $0.catalogEntry.chip == chip
                            && $0.catalogEntry.profiles.contains(selectedProfile)
                      }),
                      let recovered = try? releases.selectForRecovery(
                        family: selection.catalogEntry.family,
                        profile: selectedProfile) {
                bundle = recovered.bundle
                bundleLabel = recovered.url.lastPathComponent + " (\(sourceName))"
                selectedTarget = recovered.catalogEntry.family
            } else if let resolution = try? releases.resolveUpdate(
                family: manager.usbTarget(for: port),
                chip: chip,
                profile: nil,
                partition: nil,
                transport: .usb
            ) {
                // Neither complete runtime identity nor an explicit profile was
                // available, so fall back to the one bundled family that the
                // detected chip alone can identify.
                bundle = resolution.selection.bundle
                bundleLabel = resolution.selection.url.lastPathComponent
                    + " (\(sourceName))"
                selectedTarget = resolution.canonicalTarget
            } else {
                bundle = nil
                selectedTarget = ""
            }
        }
        let compatible = compatibleTargets
        guard !compatible.isEmpty else {
            selectedTarget = ""
            return
        }
        if let reported = manager.usbTarget(for: port), compatible.contains(reported) {
            selectedTarget = reported
        } else if compatible.contains(selectedTarget) {
            return
        } else {
            selectedTarget = ""
        }
    }

    private var selectedHardwareID: String? {
        if let hardwareID = manager.usbHardwareID(for: port) { return hardwareID }
        if case .answered(_, let hardwareID) = existing,
           let hardwareID = ConfigCommands.canonicalHardwareID(hardwareID) {
            return hardwareID
        }
        if case .detected(_, let mac) = detection {
            return ConfigCommands.canonicalHardwareID(mac)
        }
        return nil
    }

    private var existingDeviceName: String? {
        if case .answered(let name, _) = existing, !name.isEmpty { return name }
        return nil
    }

    private var plan: UsbOnboardingPlan { UsbOnboardingPlan.make(request) }

    /// The plan's words, except where they would send the user to type a
    /// network or a password here. Those come from Settings now, so these two
    /// steps say so instead.
    private var shownPlan: (headline: String, detail: String) {
        switch plan.action {
        case .chooseNetwork where manager.savedNetworkNames.isEmpty:
            return ("Add a WiFi network in Settings",
                    "The board needs credentials of its own to reach this Mac, and "
                        + "they come from this Mac's saved networks. Add one in "
                        + "Settings, under WiFi Networks, and it appears here.")
        case .chooseNetwork:
            return (plan.headline,
                    "Choose one of this Mac's saved networks. " + plan.detail)
        case .enterPassword:
            return ("The saved credential for \"\(ssid)\" cannot be sent",
                    "Edit it in Settings, under WiFi Networks, with its password "
                        + "or as an open network.")
        default:
            return (plan.headline, plan.detail)
        }
    }

    private var boardDescription: String {
        if let recordName = manager.associatedDisplayName(forUSBPath: port) {
            return "Already added as \"\(recordName)\""
        }
        switch detection {
        case .detected(let chip, let mac):
            guard let mac else { return chip }
            return "\(chip) · \(mac)"
        case .failed:
            return "Could not be read"
        case .notAttempted:
            if inspecting { return "Reading…" }
            switch existing {
            case .answered(let name, _) where !name.isEmpty:
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

    /// From the start of a run that writes flash until the board restarts:
    /// Stop is withheld for that window (see the action bar).
    private var isWritingFlash: Bool {
        guard effectiveMode == .flashAndConfigure else { return false }
        switch flash.session.phase {
        case .waitingForBoard, .configuring: return false
        default: return true
        }
    }

    private var confirmationTitle: String {
        guard let chip = detection.chip else { return "Write this board?" }
        return "Write firmware to this \(chip)?"
    }

    private var confirmationMessage: String {
        var message = ""
        if let migration = usbPartitionMigration {
            message = "This USB flash rewrites the partition table from "
                + "\(migration.from) to \(migration.to). "
        }
        message += "Everything the board needs is written at the addresses the "
            + "bundle carries, which replaces whatever firmware is on it now."
        if eraseAll {
            message += " The whole chip is erased first, so any network or name "
                + "already saved on it is lost."
        }
        return message
    }

    private var usbPartitionMigration: USBPartitionMigrationNotice? {
        guard effectiveMode == .flashAndConfigure,
              let current = manager.usbReleaseIdentity(for: port)?.partition,
              let required = bundle?
                .image(forTarget: selectedTarget)?
                .partition,
              current != required
        else { return nil }
        return USBPartitionMigrationNotice(from: current, to: required)
    }

    // MARK: - actions

    private func prepare() {
        manager.refreshUSBDevices()
        manager.refreshSavedNetworks()
        tool = EsptoolInstallation.locate()
        loadShippedBundle()
        if let first = manager.savedNetworkNames.first { savedSSID = first }
        // One device connected is not a guess about which board it is - there is
        // only one - and it saves the most common case a click. Still shown in the
        // picker, and still re-chooseable.
        let eligible = manager.usbDevices.filter {
            !manager.isUSBDeviceAssociated($0.path)
        }
        if port.isEmpty, eligible.count == 1 {
            port = eligible[0].path
        }
    }

    private func loadShippedBundle() {
        switch BundledFirmware.load() {
        case .ready(let releases):
            bundledReleases = releases
            bundle = nil
            sourceName = "bundled with the app"
            loadError = nil
            bundleLabel = FirmwareReleaseCatalog.fileName + " (\(sourceName))"
            bundleIsShipped = true
            bundleProblem = nil
            preselectExactTarget()
        case .unreadable(let path, let reason):
            bundledReleases = nil
            bundle = nil
            bundleLabel = ""
            bundleIsShipped = false
            bundleProblem = "The firmware bundled with the app (\(path)) could not "
                + "be read: \(reason)"
        case .none:
            bundledReleases = nil
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
    private func inspect(preserveMode: Bool = false) {
        detection = .notAttempted
        existing = .notChecked
        loadError = nil
        boardVersion = nil
        boardSource = nil
        selectedTarget = ""
        selectedProfile = ""
        work?.cancel()
        inspectionGeneration += 1
        let generation = inspectionGeneration
        let target = port
        let pathGeneration = manager.usbPathGeneration(target)
        inspectedPathGeneration = pathGeneration
        guard !target.isEmpty, !running else {
            inspecting = false
            return
        }
        inspecting = true
        work = Task {
            // A cancelled earlier inspection can finish after this one starts.
            // Only the newest generation owns the shared spinner.
            defer {
                if generation == inspectionGeneration { inspecting = false }
            }
            let report = await manager.probeExistingFirmwareReport(at: target)
            let answered = report.existing
            // The user may have changed the port, or closed the sheet, during the
            // three seconds CFGSHOW is allowed. Answers about a port nobody is
            // asking about any more are dropped rather than displayed.
            guard !Task.isCancelled, target == port,
                  pathGeneration == manager.usbPathGeneration(target)
            else { return }
            existing = answered
            deviceAtInspection = manager.usbDevices.first { $0.path == target }
            boardVersion = report.version
            boardSource = report.source
            if case .answered(let name, let hardwareID) = answered {
                manager.noteUSBIdentity(
                    path: target,
                    name: name,
                    hardwareID: hardwareID)
                preselectExactTarget()
            }
            if !preserveMode {
                mode = UsbOnboarding.suggestedMode(for: answered)
            }
            let needsHardwareID = selectedHardwareID == nil
            guard ((preserveMode ? .flashAndConfigure : mode) == .flashAndConfigure
                    || needsHardwareID),
                  case .installed(let path) = tool
            else { return }
            // esptool has the port: the manager's retry of an unanswered
            // CFGSHOW must not write over it.
            let read: UsbOnboarding.ChipDetection
            do {
                manager.holdUSBIdentifyRetries()
                defer { manager.releaseUSBIdentifyRetries() }
                read = await UsbOnboarder.detectChip(
                    port: target, tool: EsptoolCommand.Tool(path: path))
            }
            guard !Task.isCancelled, target == port,
                  pathGeneration == manager.usbPathGeneration(target)
            else { return }
            detection = read
            if case .detected(_, let mac) = read {
                manager.noteUSBIdentity(
                    path: target, name: nil,
                    hardwareID: ConfigCommands.canonicalHardwareID(mac))
            }
            preselectExactTarget()
        }
    }

    private func startRepair() {
        work?.cancel()
        inspecting = false
        repairing = true
    }

    /// Back from the repair flow, on the board it repaired when it got that far,
    /// so what that board still needs - usually its WiFi - is the next step here.
    private func finishRepair(port repairedPort: String?) {
        repairing = false
        manager.refreshUSBDevices()
        guard let repairedPort, manager.usbSerialPorts.contains(repairedPort) else { return }
        if port == repairedPort {
            inspect()
        } else {
            port = repairedPort
        }
    }

    private func usbDevicesChanged() {
        guard !running, !port.isEmpty else { return }
        guard manager.usbSerialPorts.contains(port),
              !manager.isUSBDeviceAssociated(port)
        else {
            port = ""
            return
        }
        if inspectedPathGeneration != manager.usbPathGeneration(port) {
            inspect()
            return
        }
        // The board was silent when inspected and has since answered the
        // manager's retry at this same connection: take that answer rather than
        // keep saying nothing answered. An answer from before the inspection
        // is not one. The chosen mode is left alone.
        if case .silent = existing, !inspecting,
           let device = manager.usbDevices.first(where: { $0.path == port }),
           let answeredAt = device.verifiedGeneration,
           answeredAt == inspectedPathGeneration,
           device.verifiedGeneration != deviceAtInspection?.verifiedGeneration
               || device.serialStatus != deviceAtInspection?.serialStatus {
            existing = .answered(name: device.name ?? "", hardwareID: device.hardwareID)
            boardVersion = device.serialStatus?.firmwareVersion
            boardSource = device.serialStatus?.firmwareSource
            preselectExactTarget()
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
            // Read first: a file that fails must not throw away the firmware
            // that was already loaded.
            let chosen = try FirmwareBundle.read(contentsOf: url)
            bundledReleases = nil
            bundle = chosen
            bundleLabel = url.lastPathComponent
            bundleIsShipped = false
            bundleProblem = nil
            loadError = nil
            preselectExactTarget()
        } catch {
            loadError = "\(url.lastPathComponent) could not be read: "
                + error.localizedDescription
        }
    }

    /// Load a catalog folder on disk - the repo's firmware-dev, or any folder
    /// tools/espdisp.py wrote - so a dev build is flashable without a new app.
    private func chooseDevCatalog() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a firmware catalog folder (it holds manifest.json), "
            + "such as the repo's firmware-dev."
        panel.prompt = "Use Builds"
        if !devCatalogFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: devCatalogFolder)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch BundledFirmware.load(catalogDirectory: url) {
        case .ready(let releases):
            devCatalogFolder = url.path
            bundledReleases = releases
            bundle = nil
            sourceName = "from \(url.lastPathComponent)"
            bundleLabel = FirmwareReleaseCatalog.fileName + " (\(sourceName))"
            bundleIsShipped = false
            bundleProblem = nil
            loadError = nil
            preselectExactTarget()
        case .unreadable(let path, let reason):
            loadError = "\(path) could not be used: \(reason)"
        case .none:
            loadError = "\(url.path) has no firmware catalog."
        }
    }

    private func start() {
        guard plan.canStart, !manager.isUSBDeviceAssociated(port),
              !inspecting,
              let hardwareID = selectedHardwareID,
              let change = credential.passwordChange
        else { return }
        running = true
        flash.reset(flow: effectiveMode == .flashAndConfigure ? .onboarding : .configureOnly)
        flash.record(.phase(.findingBoard))
        let job = PanelManager.USBOnboardRequest(
            port: port,
            mode: effectiveMode,
            bundle: bundle,
            target: selectedTarget.isEmpty ? nil : selectedTarget,
            chip: detection.chip,
            mac: {
                if case .detected(_, let mac) = detection { return mac }
                return nil
            }(),
            hardwareID: hardwareID,
            usbPathGeneration: manager.usbPathGeneration(port),
            existingName: existingDeviceName,
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
            let monitor = flash
            let succeeded = await manager.onboardUSBDevice(job) { update in
                monitor.record(update)
            }
            running = false
            if !succeeded, let outcome = manager.operationOutcome,
               outcome.kind == .failure {
                // Shown here, now, with the step, what was last seen and the
                // transcript. Taken off the manager window too: its alert sits
                // behind this sheet and would only appear once the sheet was
                // closed, repeating an old failure after the fact.
                flash.fail(outcome)
                if formIsShowing { manager.clearOperationOutcome() }
            }
            if succeeded {
                dismiss()
            } else {
                // Left open with the port, the firmware and the network still filled
                // in, so a retry is one button. The footer says what happened.
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
