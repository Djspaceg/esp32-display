import SenderProtocol
import SwiftUI
import UniformTypeIdentifiers

/// What a chosen bundle means for one panel, in words, plus how deliberate the
/// confirmation has to be.
///
/// A separate pure type rather than `if` branches in the view for the usual
/// reason - a view cannot be tested - and for one specific to this sheet: the
/// whole point of it is that the awkward answers are told apart. "This bundle is
/// older than what the panel is running" and "these versions cannot be compared"
/// are different situations with different right actions, and collapsing them
/// into "cannot update" would be the dishonesty this type exists to prevent.
/// `FirmwareUpdatePlanTests` asserts that each one is reachable and says something
/// different.
struct FirmwareUpdatePlan: Equatable {
    /// What pushing this image would do, which decides the button's verb and how
    /// hard it is to reach.
    enum Action: Equatable {
        /// The bundle is newer. The ordinary case.
        case update
        /// Same version. Allowed - reinstalling is a legitimate way to recover a
        /// panel that is behaving oddly - but named for what it is.
        case reinstall
        /// The bundle is OLDER. A downgrade, which someone may well want after a
        /// bad release, and which must never be presented as an update.
        case downgrade
        /// There is an image, but which way round the versions go is not
        /// knowable.
        case uncertain
        /// The panel did not say what chip it is, so the image has to be chosen
        /// by hand before anything else can be decided.
        case chooseImage
        /// The panel named a chip this bundle has no image for. The one case here
        /// that is simply the wrong file.
        case blocked
    }

    let headline: String
    let detail: String
    let action: Action

    /// Whether the sheet may offer to push at all.
    var canPush: Bool {
        switch action {
        case .update, .reinstall, .downgrade, .uncertain: return true
        case .chooseImage, .blocked: return false
        }
    }

    /// The verb on the button and in the confirmation, so the two agree and
    /// neither says "Update" for a downgrade.
    var verb: String {
        switch action {
        case .update: return "Update"
        case .reinstall: return "Reinstall"
        case .downgrade: return "Downgrade"
        case .uncertain: return "Push"
        case .chooseImage, .blocked: return "Update"
        }
    }

    /// Whether this is the case where the user is being asked to accept
    /// something surprising rather than merely to confirm.
    var isCautionary: Bool {
        switch action {
        case .downgrade, .uncertain: return true
        case .update, .reinstall, .chooseImage, .blocked: return false
        }
    }

    /// Turn the FEAT-003 classifier's answer into what the sheet says.
    ///
    /// `chipConfirmed` is false when the image was chosen by hand because the
    /// panel never named its chip. It adds a sentence rather than changing the
    /// verdict, deliberately: an unconfirmed chip is missing information, not a
    /// contradiction, and `classify_ota_target` in tools/espdisp.py takes the same
    /// three-valued stance. What makes that safe to offer is that the panel
    /// validates the image header's chip id before it moves the boot slot, so a
    /// wrong guess costs a transfer and reads `bad image` on the glass rather than
    /// bricking the panel.
    static func make(
        _ availability: FirmwareUpdateAvailability, chipConfirmed: Bool
    ) -> FirmwareUpdatePlan {
        let caveat = chipConfirmed
            ? ""
            : " This panel did not report which chip it is, so this image was "
                + "chosen by hand. The panel checks the image header before it "
                + "switches over, so the wrong one is refused rather than "
                + "installed."
        switch availability {
        case .updateAvailable(let image, let bundleVersion, let panelVersion):
            return FirmwareUpdatePlan(
                headline: "Update to \(bundleVersion)",
                detail: "This panel is running \(panelVersion). The bundle's "
                    + "\(image.chip) image is \(bundleVersion)." + caveat,
                action: .update)
        case .upToDate(let image, let version):
            return FirmwareUpdatePlan(
                headline: "Already running \(version)",
                detail: "The bundle's \(image.chip) image is the same version "
                    + "this panel reports. Pushing it reinstalls the same "
                    + "firmware, which is a way to recover a panel that is "
                    + "misbehaving." + caveat,
                action: .reinstall)
        case .bundleIsOlder(let image, let bundleVersion, let panelVersion):
            return FirmwareUpdatePlan(
                headline: "This bundle is older",
                detail: "This panel is running \(panelVersion); the bundle's "
                    + "\(image.chip) image is \(bundleVersion). Pushing it is a "
                    + "downgrade." + caveat,
                action: .downgrade)
        case .versionsIncomparable(let image, let bundleVersion, let panelVersion):
            return FirmwareUpdatePlan(
                headline: "Cannot tell which is newer",
                detail: "This panel reports \(panelVersion) and the bundle's "
                    + "\(image.chip) image says \(bundleVersion). At least one of "
                    + "those is not a dotted version number, so which one is "
                    + "newer cannot be worked out here." + caveat,
                action: .uncertain)
        case .noImageForChip(let chip, let bundleChips):
            return FirmwareUpdatePlan(
                headline: "Nothing in this bundle for this panel",
                detail: "This panel is an \(chip). This bundle carries "
                    + "\(describe(bundleChips)). Build one that includes "
                    + "\(chip), or pick a different file.",
                action: .blocked)
        case .chipUnknown(let bundleChips):
            return FirmwareUpdatePlan(
                headline: "This panel did not say which chip it is",
                detail: "Firmware older than the chip record does not advertise "
                    + "one, and a build that cannot name its own chip says "
                    + "\"unknown\". This bundle carries \(describe(bundleChips)), "
                    + "so choose which image to push - or update over USB with "
                    + "tools/espdisp.py flash, which reads the chip from the "
                    + "board.",
                action: .chooseImage)
        }
    }

    /// `esp32c6`, or `esp32c6 and esp32s3`, or `no images at all` - which cannot
    /// happen through the reader (it refuses an empty image list) but is not
    /// worth a crash if it ever does.
    private static func describe(_ chips: [String]) -> String {
        switch chips.count {
        case 0: return "no images at all"
        case 1: return "an image for \(chips[0])"
        default:
            let last = chips[chips.count - 1]
            let rest = chips.dropLast().joined(separator: ", ")
            return "images for \(rest) and \(last)"
        }
    }
}

/// Choose a `.espdispfw` file, see what it can do for this panel, and push it.
///
/// In its own file because ManagerWindow.swift is already 1239 lines, and because
/// this flow has four stages and its own error states rather than being one more
/// row in the detail form.
struct FirmwareUpdateSheet: View {
    @ObservedObject var manager: PanelManager
    let target: PanelManager.FirmwareUpdateTarget
    @Environment(\.dismiss) private var dismiss

    /// The file, once one has been read successfully.
    @State private var bundle: FirmwareBundle?
    @State private var bundleURL: URL?
    /// Why the file the user picked could not be used. Kept as a message rather
    /// than an error, because `FirmwareBundleError` already writes messages for
    /// exactly this reader and rewording them here would only make them worse.
    @State private var readFailure: String?
    /// Which image to push when the panel did not name its chip.
    @State private var chosenChip: String?
    @State private var password = ""
    @State private var rememberPassword = false
    @State private var passwordProblem: String?
    @State private var confirmPush = false
    @State private var progress: FirmwarePusher.Progress?
    @State private var isPushing = false

    var body: some View {
        Form {
            panelSection
            bundleSection
            if let bundle {
                verdictSection(bundle)
                if plan(bundle).canPush {
                    passwordSection
                }
            }
            if isPushing {
                progressSection
            }
        }
        .formStyle(.grouped)
        .labeledContentStyle(.labelColumn)
        // A floating glass action bar, as in SettingsSheet, so the form scrolls
        // under it rather than being pushed up by a row bolted to the bottom.
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
        .frame(width: 560, height: 560)
        .onAppear(perform: prefillPassword)
        // A firmware write is at least as consequential as a restart, so the
        // confirmation is at least as deliberate as the restart one in
        // ManagerWindow - and it names the direction, so a downgrade cannot be
        // confirmed by someone who thought they were updating.
        .confirmationDialog(
            confirmationTitle, isPresented: $confirmPush, titleVisibility: .visible
        ) {
            Button(confirmationVerb, role: plan(bundle)?.isCautionary == true
                ? .destructive : nil) {
                startPush()
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: sections

    private var panelSection: some View {
        Section("Panel") {
            LabeledContent("Display", value: target.displayName)
            LabeledContent("Running", value: target.firmwareVersion)
            LabeledContent("Chip", value: chipDescription)
            LabeledContent("Address", value: target.address)
        }
    }

    /// `unknown` from the panel and no record at all are different facts, and the
    /// row says which, because it decides whether the user has to choose an image.
    private var chipDescription: String {
        guard let chip = target.chip, !chip.isEmpty else {
            return "Not reported"
        }
        return chip == ServiceMetadata.unknownChip ? "Reported as unknown" : chip
    }

    @ViewBuilder
    private var bundleSection: some View {
        Section("Firmware bundle") {
            if let bundle, let bundleURL {
                LabeledContent("File", value: bundleURL.lastPathComponent)
                LabeledContent("Version", value: bundle.firmwareVersion)
                LabeledContent("Built", value: bundle.builtAt)
                LabeledContent("Source", value: sourceDescription(bundle))
                ForEach(bundle.images, id: \.chip) { image in
                    LabeledContent(image.chip, value: imageDescription(image))
                }
                Button("Choose a Different File…") { chooseFile() }
                    .disabled(isPushing)
            } else {
                Button("Choose Firmware Bundle…") { chooseFile() }
                    .disabled(isPushing)
                if let readFailure {
                    Text(readFailure)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Plain prose rather than markdown: these strings are built
                    // by concatenation, which selects Text's String initialiser,
                    // and that one does not parse markdown - backticks would show
                    // up as backticks.
                    Text("An .espdispfw file written by tools/espdisp.py bundle, "
                        + "on this Mac or any other.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func verdictSection(_ bundle: FirmwareBundle) -> some View {
        let plan = plan(bundle)
        Section("What this would do") {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.headline)
                    .fontWeight(.medium)
                Text(plan.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The one case where the user has to make the choice the panel could
            // not make for them.
            if plan.action == .chooseImage, bundle.images.count > 1 {
                Picker("Image", selection: Binding(
                    get: { chosenChip ?? "" },
                    set: { chosenChip = $0.isEmpty ? nil : $0 })
                ) {
                    Text("Choose…").tag("")
                    ForEach(bundle.images, id: \.chip) { image in
                        Text("\(image.chip) (\(image.board))").tag(image.chip)
                    }
                }
            }
        }
    }

    private var passwordSection: some View {
        Section {
            SecureField("OTA password", text: $password)
                .disabled(isPushing)
            Toggle("Remember this password", isOn: $rememberPassword)
                .disabled(isPushing)
            if let passwordProblem {
                Text(passwordProblem)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Password")
        } footer: {
            Text("The password set on this panel with tools/espdisp.py "
                + "set-password. Remembering it keeps it in this Mac's Keychain, "
                + "filed under the panel's hardware ID so a rename does not lose "
                + "it.")
        }
    }

    private var progressSection: some View {
        Section("Progress") {
            VStack(alignment: .leading, spacing: 8) {
                if let fraction = progressFraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Text(progressDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                // Cancelling mid-transfer is not offered, because there is
                // nothing honest to do with a half-written flash partition from
                // this side: the panel decides, and it decides by failing the
                // image's MD5 and carrying on with what it booted.
                .disabled(isPushing)
            Button(pushButtonTitle) { beginConfirmation() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canBeginPush)
        }
        .padding(12)
        .glassCard(cornerRadius: 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: derived

    /// Which chip's image is under discussion: the panel's own answer when it
    /// gave one, otherwise whatever the user chose.
    private var effectiveChip: String? {
        if let chip = target.chip, !chip.isEmpty,
           chip != ServiceMetadata.unknownChip {
            return chip
        }
        return chosenChip
    }

    private var chipIsConfirmed: Bool {
        guard let chip = target.chip else { return false }
        return !chip.isEmpty && chip != ServiceMetadata.unknownChip
    }

    private func plan(_ bundle: FirmwareBundle) -> FirmwareUpdatePlan {
        FirmwareUpdatePlan.make(
            bundle.availability(
                forChip: effectiveChip, panelVersion: target.firmwareVersion),
            chipConfirmed: chipIsConfirmed)
    }

    private func plan(_ bundle: FirmwareBundle?) -> FirmwareUpdatePlan? {
        bundle.map { plan($0) }
    }

    private var pushButtonTitle: String {
        guard let bundle else { return "Update Firmware" }
        return "\(plan(bundle).verb) Firmware"
    }

    private var canBeginPush: Bool {
        guard !isPushing, let bundle else { return false }
        return plan(bundle).canPush && !password.isEmpty
    }

    private var confirmationTitle: String {
        guard let bundle else { return "Update \(target.displayName)?" }
        return "\(plan(bundle).verb) \(target.displayName)?"
    }

    private var confirmationVerb: String {
        guard let bundle else { return "Update" }
        return plan(bundle).verb
    }

    private var confirmationMessage: String {
        guard let bundle, let image = bundle.payloadImage(forChip: effectiveChip)
        else { return "" }
        return "\(byteCount(image.byteCount)) will be written to the panel's "
            + "inactive firmware slot, and it will restart onto it. USB stays the "
            + "way back: tools/espdisp.py flash."
    }

    private var progressFraction: Double? {
        guard case .sending(let sent, let total) = progress, total > 0 else {
            return nil
        }
        return Double(sent) / Double(total)
    }

    private var progressDescription: String {
        switch progress {
        case .none:
            return "Starting…"
        case .inviting(let attempt, let total):
            return attempt == 1
                ? "Inviting the panel…"
                : "Inviting the panel (attempt \(attempt) of \(total))…"
        case .authenticating:
            return "Sending the password…"
        case .waitingForPanel:
            return "Waiting for the panel to connect back…"
        case .sending(let sent, let total):
            return "Sending \(byteCount(sent)) of \(byteCount(total))"
        case .finishing:
            return "Waiting for the panel to finish writing…"
        }
    }

    private func imageDescription(_ image: FirmwareBundle.Image) -> String {
        "\(byteCount(image.byteCount)) · \(image.board)"
    }

    private func sourceDescription(_ bundle: FirmwareBundle) -> String {
        guard let commit = bundle.sourceCommit else { return "Not a git checkout" }
        let short = String(commit.prefix(12))
        return bundle.sourceDirty ? "\(short) (uncommitted changes)" : short
    }

    private func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: actions

    private func prefillPassword() {
        guard let remembered = manager.rememberedOTAPassword(
            for: target.hardwareID) else { return }
        password = remembered
        // Pre-ticked only when there was already a password to remember, so
        // leaving the toggle alone keeps whatever the user chose last time.
        rememberPassword = true
    }

    /// The open panel, restricted to the one extension this app can read.
    ///
    /// Filtering by extension rather than by a declared UTType: nothing on this
    /// Mac claims `.espdispfw`, so an exported type identifier would have to be
    /// registered in Info.plist to be filtered on, and the extension is the
    /// contract the CLI actually writes.
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
        load(url)
    }

    private func load(_ url: URL) {
        do {
            let read = try FirmwareBundle.read(contentsOf: url)
            bundle = read
            bundleURL = url
            readFailure = nil
            // A bundle with exactly one image needs no choice, so a panel that
            // did not name its chip still gets a verdict rather than a picker
            // with one entry.
            chosenChip = read.images.count == 1 ? read.images[0].chip : nil
        } catch {
            bundle = nil
            bundleURL = nil
            chosenChip = nil
            readFailure = error.localizedDescription
        }
    }

    private func beginConfirmation() {
        switch OTAPasswordPolicy.judge(password) {
        case .accept:
            passwordProblem = nil
            confirmPush = true
        case let verdict:
            // Checked before the push rather than after a two-megabyte transfer
            // fails on it: the panel would answer `Authentication Failed`, which
            // does not distinguish a password that is too short from one that is
            // simply wrong.
            passwordProblem = OTAPasswordPolicy.explain(verdict)
        }
    }

    private func startPush() {
        guard let bundle, let chip = effectiveChip,
              let image = bundle.payload(forChip: chip),
              let entry = bundle.image(forChip: chip)
        else { return }
        if rememberPassword {
            if let failure = manager.setRememberedOTAPassword(
                password, for: target.hardwareID) {
                passwordProblem = failure
            }
        } else {
            // Unticking it is a request to forget, not merely to skip saving.
            _ = manager.setRememberedOTAPassword(nil, for: target.hardwareID)
        }

        isPushing = true
        progress = nil
        // Not `.task`, deliberately: this Task must outlive the sheet's dismissal
        // at the end of it, and a `.task` modifier's work is cancelled when the
        // view goes away.
        Task {
            let succeeded = await manager.pushFirmware(
                image: image, filename: entry.filename, to: target,
                password: password
            ) { update in
                Task { @MainActor in progress = update }
            }
            isPushing = false
            // On a failure the sheet stays open with the file and the password
            // still in it, so a retry is one click. The outcome alert explains
            // what happened either way.
            if succeeded { dismiss() }
        }
    }
}

private extension FirmwareBundle {
    /// The manifest entry for a chip, tolerating a nil chip so the confirmation
    /// message can be composed without unwrapping twice.
    func payloadImage(forChip chip: String?) -> FirmwareBundle.Image? {
        guard let chip else { return nil }
        return image(forChip: chip)
    }
}

#if DEBUG
#Preview("Firmware Update") {
    FirmwareUpdateSheet(
        manager: PanelManager.preview,
        target: PanelManager.FirmwareUpdateTarget(
            serviceName: "espdisplay-9050",
            displayName: "Desk Panel",
            hardwareID: "020000123456",
            address: "192.168.1.120",
            chip: "esp32c6",
            firmwareVersion: "1.1.0"))
}
#endif
