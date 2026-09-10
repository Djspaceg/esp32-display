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
        /// The bundle is newer. The ordinary upgrade case.
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
        case .update: return "Upgrade"
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
    /// `chipConfirmed` means the panel reported both an exact target and an
    /// independently matching chip. Missing identity is a refusal for same-chip
    /// S3 variants rather than a manual chip guess.
    static func make(
        _ availability: FirmwareUpdateAvailability, chipConfirmed: Bool
    ) -> FirmwareUpdatePlan {
        let caveat = chipConfirmed
            ? ""
            : " The exact target and independently reported chip must both match "
                + "before this image can be sent."
        switch availability {
        case .updateAvailable(let image, let bundleVersion, let panelVersion):
            return FirmwareUpdatePlan(
                headline: "Upgrade to \(bundleVersion)",
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
        case .noImageForTarget(let target, let bundleTargets):
            return FirmwareUpdatePlan(
                headline: "Nothing in this bundle for this target",
                detail: "This panel reports exact target \(target). This bundle "
                    + "carries \(describeTargets(bundleTargets)).",
                action: .blocked)
        case .targetUnknown(let bundleTargets):
            return FirmwareUpdatePlan(
                headline: "Exact firmware target not reported",
                detail: "ESP32-S3 boards can use different displays and pin maps "
                    + "while reporting the same chip. This bundle carries "
                    + "\(describeTargets(bundleTargets)); reconnect over USB to "
                    + "read CFGSHOW target metadata. C6 can use its unique c6 target.",
                action: .chooseImage)
        case .targetChipMismatch(let target, let imageChip, let panelChip):
            return FirmwareUpdatePlan(
                headline: "Target and chip disagree",
                detail: "Target \(target) selects a \(imageChip) image, but the panel "
                    + "reports \(panelChip). Nothing can be sent safely.",
                action: .blocked)
        case .chipUnknownForTarget(let target, let expectedChip):
            return FirmwareUpdatePlan(
                headline: "Chip metadata not reported",
                detail: "Target \(target) selects a \(expectedChip) image, but the "
                    + "panel did not independently report that chip.",
                action: .blocked)
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

    /// Firmware predating CFGSHOW's `fw=` field cannot be version-compared, but
    /// a compatible image may still be installed over fully verified USB.
    static func makeForUnknownPanelVersion(
        _ compatibility: FirmwareUpdateAvailability,
        bundleVersion: String,
        chipConfirmed: Bool
    ) -> FirmwareUpdatePlan {
        guard let image = compatibility.image else {
            return make(compatibility, chipConfirmed: chipConfirmed)
        }
        let caveat = chipConfirmed
            ? ""
            : " The exact target and independently reported chip must both match "
                + "before this image can be sent."
        return FirmwareUpdatePlan(
            headline: "Running version not reported",
            detail: "The installed firmware does not report its version over USB. "
                + "The bundle's \(image.chip) image is \(bundleVersion). The app "
                + "will re-verify the USB board before writing it." + caveat,
            action: .uncertain)
    }

    private static func describeTargets(_ targets: [String]) -> String {
        switch targets.count {
        case 0: return "no exact targets"
        case 1: return "target \(targets[0])"
        default:
            let last = targets[targets.count - 1]
            let rest = targets.dropLast().joined(separator: ", ")
            return "targets \(rest) and \(last)"
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

/// Pure copy and ordering for the release-note section of the update sheet.
enum FirmwareReleaseNotesPresentation: Equatable {
    case available(version: String, items: [String])
    case unavailable
    case empty

    static func make(version: String, items: [String]?) -> FirmwareReleaseNotesPresentation {
        guard let items else { return .unavailable }
        return items.isEmpty ? .empty : .available(version: version, items: items)
    }

    var accessibilityLabel: String {
        switch self {
        case .available(let version, let items):
            return "Release notes for \(version). \(items.joined(separator: " "))"
        case .unavailable:
            return "Release notes unavailable. This older firmware bundle does not include release notes."
        case .empty:
            return "Release notes unavailable. No release notes were included in this firmware bundle."
        }
    }

    var fallbackText: String? {
        switch self {
        case .available:
            return nil
        case .unavailable:
            return "Release notes are unavailable in this older firmware bundle."
        case .empty:
            return "No release notes were included in this firmware bundle."
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
    @Environment(\.dismiss) private var dismiss
    private let bundledFirmware: BundledFirmware.Availability

    @State private var target: PanelManager.FirmwareUpdateTarget
    @State private var selectedTransport: PanelManager.FirmwareUpdateTransport
    @State private var isRefreshingUSBDevices = false
    @State private var usbRefreshTask: Task<Void, Never>?

    /// The file, once one has been read successfully.
    @State private var bundle: FirmwareBundle?
    @State private var bundleURL: URL?
    @State private var automaticIdentity: FirmwareReleaseCatalog.Identity?
    /// Why the file the user picked could not be used. Kept as a message rather
    /// than an error, because `FirmwareBundleError` already writes messages for
    /// exactly this reader and rewording them here would only make them worse.
    @State private var readFailure: String?
    /// The bundle no longer permits manual chip selection: exact target metadata
    /// must choose the image, with C6 as the sole chip-derived legacy exception.
    @State private var password = ""
    @State private var rememberPassword = false
    @State private var passwordProblem: String?
    @State private var confirmPush = false
    @State private var otaProgress: FirmwarePusher.Progress?
    @State private var usbProgress: UsbOnboarder.Progress?
    /// A sheet-owned failure appears immediately above the action bar. Routing
    /// this through the manager window's alert defers it behind this sheet.
    @State private var updateFailure: OperationOutcome?
    @State private var isPushing = false
    @State private var sheetIsVisible = false

    init(
        manager: PanelManager,
        target: PanelManager.FirmwareUpdateTarget,
        bundledFirmware: BundledFirmware.Availability? = nil
    ) {
        self.manager = manager
        self.bundledFirmware = bundledFirmware ?? BundledFirmware.load()
        _target = State(initialValue: target)
        _selectedTransport = State(
            initialValue: target.usbDevice != nil ? .usb : .wifi)
    }

    var body: some View {
        Form {
            panelSection
            transportSection
            bundleSection
            if let bundle {
                releaseNotesSection(bundle)
                verdictSection(bundle)
                if selectedTransport == .wifi, plan(bundle).canPush {
                    passwordSection
                }
            }
            if let updateFailure {
                failureSection(updateFailure)
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
        .frame(width: 560, height: 620)
        .onAppear {
            sheetIsVisible = true
            prefillPassword()
            loadBundledFirmwareIfAvailable()
        }
        .onDisappear {
            sheetIsVisible = false
            usbRefreshTask?.cancel()
        }
        .onChange(of: selectedTransport) { _, _ in
            updateFailure = nil
            passwordProblem = nil
            otaProgress = nil
            usbProgress = nil
        }
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
            LabeledContent(
                "Running",
                value: target.firmwareVersion ?? "Not reported over USB")
            LabeledContent("Chip", value: chipDescription)
            LabeledContent("Target", value: targetDescription)
            LabeledContent("Address", value: target.address ?? "Not available")
            LabeledContent("USB device") {
                HStack(spacing: 8) {
                    let path = target.usbDevice?.path
                    Text(path ?? "Not connected")
                        .foregroundStyle(path == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                        .monospaced()
                    Button {
                        refreshUSBDevice()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh USB device")
                    .disabled(isPushing || isRefreshingUSBDevices)
                    .help("Refresh connected USB serial ports")
                }
            }
        }
    }

    private func refreshUSBDevice() {
        guard !isPushing, !isRefreshingUSBDevices else { return }
        isRefreshingUSBDevices = true
        updateFailure = nil
        manager.refreshUSBDevices()
        let paths = manager.usbSerialPorts
        usbRefreshTask = Task {
            defer {
                isRefreshingUSBDevices = false
                usbRefreshTask = nil
            }
            for path in paths {
                guard !Task.isCancelled else { return }
                _ = await manager.probeUSBDevice(path)
            }
            guard !Task.isCancelled else { return }
            applyRefreshedTarget()
        }
    }

    private func applyRefreshedTarget() {
        let canResolveAutomaticFirmware: Bool
        switch manager.firmwareUpdateReadiness(target.serviceName) {
        case .ready(let refreshed):
            target = refreshed
            canResolveAutomaticFirmware = true
        case .notReady:
            target.address = nil
            target.usbDevice = nil
            target.usbPathGeneration = nil
            target.usbAllowsLegacyIdentity = false
            canResolveAutomaticFirmware = false
        }
        if !target.transports.contains(selectedTransport),
           let fallback = target.transports.first {
            selectedTransport = fallback
        }
        reloadAutomaticFirmwareAfterRefresh(
            canResolve: canResolveAutomaticFirmware)
    }

    private var transportSection: some View {
        Section("Update methods") {
            LabeledContent(
                "USB",
                value: target.usbDevice != nil ? "Available" : "Unavailable")
            LabeledContent(
                "WiFi (OTA)",
                value: target.address != nil ? "Available" : "Unavailable")
            Picker("Use", selection: $selectedTransport) {
                ForEach(PanelManager.FirmwareUpdateTransport.allCases) { transport in
                    Text(transportLabel(transport))
                        .tag(transport)
                        .disabled(!target.transports.contains(transport))
                }
            }
            .pickerStyle(.segmented)
            .disabled(isPushing || isRefreshingUSBDevices)
        }
    }

    /// `unknown` from the panel and no record at all are different facts, and the
    /// row says which, because it decides whether the user has to choose an image.
    private var chipDescription: String {
        guard let chip = effectiveChip, !chip.isEmpty else {
            return "Not reported"
        }
        return chip == ServiceMetadata.unknownChip ? "Reported as unknown" : chip
    }

    private var targetDescription: String {
        effectiveTarget ?? "Not reported"
    }

    @ViewBuilder
    private var bundleSection: some View {
        Section("Firmware bundle") {
            if let bundle, let bundleURL {
                LabeledContent("File", value: bundleURL.lastPathComponent)
                LabeledContent("Version", value: bundle.firmwareVersion)
                LabeledContent("Built", value: bundle.builtAt)
                LabeledContent("Source", value: sourceDescription(bundle))
                ForEach(bundle.images, id: \.offset) { image in
                    LabeledContent(image.targets.joined(separator: ", "),
                                   value: imageDescription(image))
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
    private func releaseNotesSection(_ bundle: FirmwareBundle) -> some View {
        let presentation = FirmwareReleaseNotesPresentation.make(
            version: bundle.firmwareVersion, items: bundle.releaseNotes)
        Section {
            releaseNotesContent(presentation)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(presentation.accessibilityLabel)
        } header: {
            Text("Release notes").accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func releaseNotesContent(_ presentation: FirmwareReleaseNotesPresentation) -> some View {
        switch presentation {
        case .available(_, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(verbatim: item)
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .unavailable, .empty:
            Text(presentation.fallbackText ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func verdictSection(_ bundle: FirmwareBundle) -> some View {
        let plan = plan(bundle)
        let usbWillDetect = selectedTransport == .usb && effectiveTarget == nil
        Section("What this would do") {
            VStack(alignment: .leading, spacing: 6) {
                Text(usbWillDetect
                    ? "Verify the USB board, then choose its image"
                    : plan.headline)
                    .fontWeight(.medium)
                Text(usbWillDetect
                    ? "Before writing, the app re-reads the board's hardware ID, "
                        + "target, chip and MAC with CFGSHOW and esptool, then uses "
                        + "only the matching exact-target image from this bundle."
                    : plan.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if selectedTransport == .usb, !usbBundleCanWrite(bundle) {
                Label(
                    "USB updating needs a current bundle with all flash parts "
                        + "for a compatible exact target.",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
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

    private func failureSection(_ failure: OperationOutcome) -> some View {
        Section("Update failed") {
            VStack(alignment: .leading, spacing: 6) {
                Text(failure.title)
                    .fontWeight(.medium)
                    .textSelection(.enabled)
                Text(failure.message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
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
                if isWaitingForResult {
                    Text("This can take a while on a large image. You can close "
                        + "this window; if it is closed, the result appears in "
                        + "the manager window. Otherwise it appears here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(dismissTitle, role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                // Cancelling mid-transfer is not offered, because there is
                // nothing honest to do with a half-written flash partition from
                // this side: the panel decides, and it decides by failing the
                // image's MD5 and carrying on with what it booted.
                //
                // Once every byte is out that argument stops applying and the
                // button comes back as Close, because there is nothing left to
                // interrupt. The tail is ten thirty-second attempts, so a panel
                // that is connected but silent used to hold the sheet for five
                // minutes with no way out but quitting the app. Closing does not
                // abandon the push: the Task outlives the sheet and the outcome
                // still arrives as an alert.
                .disabled(isPushing && !isWaitingForResult)
                .help(isWaitingForResult
                    ? "Close this window and let the update finish. Its result "
                        + "will appear in the manager window."
                    : "")
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

    /// Which firmware family is under discussion. A matched bundled selection
    /// may canonicalize an otherwise incomplete runtime identity to the one
    /// shipped family the detected chip uniquely identifies.
    private var effectiveTarget: String? {
        if let family = automaticIdentity?.family { return family }
        guard let family = target.target, !family.isEmpty else { return nil }
        return family
    }

    private var effectiveChip: String? {
        automaticIdentity?.chip ?? target.chip
    }

    private var chipIsConfirmed: Bool {
        guard let chip = effectiveChip,
              let exactTarget = effectiveTarget,
              let bundle
        else { return false }
        return !chip.isEmpty
            && chip != ServiceMetadata.unknownChip
            && bundle.image(forTarget: exactTarget)?.chip == chip
    }

    private func plan(_ bundle: FirmwareBundle) -> FirmwareUpdatePlan {
        if let panelVersion = target.firmwareVersion {
            return FirmwareUpdatePlan.make(
                bundle.availability(
                    forTarget: effectiveTarget,
                    chip: effectiveChip,
                    panelVersion: panelVersion),
                chipConfirmed: chipIsConfirmed)
        }
        return FirmwareUpdatePlan.makeForUnknownPanelVersion(
            bundle.availability(
                forTarget: effectiveTarget,
                chip: effectiveChip,
                panelVersion: bundle.firmwareVersion),
            bundleVersion: bundle.firmwareVersion,
            chipConfirmed: chipIsConfirmed)
    }

    private func plan(_ bundle: FirmwareBundle?) -> FirmwareUpdatePlan? {
        bundle.map { plan($0) }
    }

    private var pushButtonTitle: String {
        guard let bundle else { return "Update Firmware" }
        return "\(plan(bundle).verb) Firmware"
    }

    /// Every byte is out and the panel is deciding. Nothing this side can still
    /// interrupt, which is what makes leaving safe.
    private var isWaitingForResult: Bool {
        if case .finishing = otaProgress { return true }
        return false
    }

    /// "Cancel" before a push and "Close" during one, because during one it does
    /// not cancel anything and a button that lies about that is worse than a
    /// disabled button.
    private var dismissTitle: String {
        isPushing ? "Close" : "Cancel"
    }

    private var canBeginPush: Bool {
        guard !isPushing, !isRefreshingUSBDevices, let bundle else { return false }
        switch selectedTransport {
        case .wifi:
            return plan(bundle).canPush && !password.isEmpty
        case .usb:
            return target.usbDevice != nil && usbBundleCanWrite(bundle)
        }
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
        guard let bundle else { return "" }
        switch selectedTransport {
        case .wifi:
            guard let image = bundle.payloadImage(forTarget: effectiveTarget) else {
                return ""
            }
            return "\(byteCount(image.byteCount)) will be written to the panel's "
                + "inactive firmware slot, and it will restart onto it."
        case .usb:
            let bytes = effectiveTarget.flatMap { bundle.flashPlan(forTarget: $0) }
                .map { $0.reduce(0) { $0 + $1.payload.count } }
            let amount = bytes.map { "\(byteCount($0)) in the bundle" }
                ?? "The matching image and flash parts"
            return "\(amount) will be written over USB after the board's hardware "
                + "ID, chip and MAC are re-verified. No whole-chip erase is "
                + "performed, so saved WiFi, name, settings and OTA password remain."
        }
    }

    private var progressFraction: Double? {
        if case .sending(let sent, let total) = otaProgress, total > 0 {
            return Double(sent) / Double(total)
        }
        if case .writing(let percent?, _) = usbProgress {
            return Double(percent) / 100
        }
        return nil
    }

    private var progressDescription: String {
        if selectedTransport == .usb {
            switch usbProgress {
            case .none: return "Starting…"
            case .readingChip: return "Re-verifying the board's chip and MAC…"
            case .writing(let percent, let status):
                guard let percent else { return status }
                return "\(percent)% · \(status)"
            case .waitingForBoard: return "Waiting for the board to restart…"
            case .configuring(let label): return label
            }
        }
        switch otaProgress {
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

    private func transportLabel(
        _ transport: PanelManager.FirmwareUpdateTransport
    ) -> String {
        switch transport {
        case .wifi: return "WiFi"
        case .usb: return "USB"
        }
    }

    private func usbBundleCanWrite(_ bundle: FirmwareBundle) -> Bool {
        if let exactTarget = effectiveTarget {
            return bundle.flashPlan(forTarget: exactTarget) != nil
        }
        if let chip = target.chip,
           !chip.isEmpty,
           chip != ServiceMetadata.unknownChip {
            return bundle.images.contains {
                $0.chip == chip && $0.targets.contains {
                    bundle.flashPlan(forTarget: $0) != nil
                }
            }
        }
        return false
    }

    private func imageDescription(_ image: FirmwareBundle.Image) -> String {
        "\(byteCount(image.byteCount)) · \(image.chip) · \(image.board)"
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

    private func loadBundledFirmwareIfAvailable() {
        guard bundle == nil else { return }
        resolveBundledFirmware()
    }

    private func resolveBundledFirmware() {
        switch bundledFirmware {
        case .ready(let releases):
            do {
                let selected = try releases.selectForUpdate(
                    live: .init(
                        family: target.target, chip: target.chip,
                        profile: target.profile, partition: target.partition),
                    usb: target.usbDevice.map {
                        .init(
                            family: $0.target, chip: $0.chip,
                            profile: $0.board, partition: $0.partition)
                    })
                bundle = selected.selection.bundle
                bundleURL = selected.selection.url
                automaticIdentity = selected.identity
                readFailure = nil
            } catch {
                bundle = nil
                bundleURL = nil
                automaticIdentity = nil
                readFailure = error.localizedDescription
            }
        case .unreadable(let path, let reason):
            readFailure = "The firmware bundled with the app (\(path)) could not "
                + "be read: \(reason)"
        case .none:
            break
        }
    }

    private func reloadAutomaticFirmwareAfterRefresh(canResolve: Bool) {
        // A manually opened file is independent of automatic resource selection.
        if bundle != nil, automaticIdentity == nil { return }
        bundle = nil
        bundleURL = nil
        automaticIdentity = nil
        readFailure = nil
        if canResolve { resolveBundledFirmware() }
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
            updateFailure = nil
            automaticIdentity = nil
            // Exact target metadata, not image count, chooses an image.
        } catch {
            bundle = nil
            bundleURL = nil
            automaticIdentity = nil
            readFailure = error.localizedDescription
        }
    }

    private func beginConfirmation() {
        updateFailure = nil
        guard selectedTransport == .wifi else {
            confirmPush = true
            return
        }
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
        guard let bundle else { return }
        isPushing = true
        updateFailure = nil
        otaProgress = nil
        usbProgress = nil

        switch selectedTransport {
        case .wifi:
            guard let exactTarget = effectiveTarget,
                  let image = bundle.payload(forTarget: exactTarget),
                  let entry = bundle.image(forTarget: exactTarget),
                  entry.chip == effectiveChip
            else {
                isPushing = false
                return
            }
            if rememberPassword {
                if let failure = manager.setRememberedOTAPassword(
                    password, for: target.hardwareID) {
                    passwordProblem = failure
                }
            } else {
                _ = manager.setRememberedOTAPassword(nil, for: target.hardwareID)
            }
            Task {
                let outcome = await manager.pushFirmware(
                    image: image, filename: entry.filename, to: target,
                    password: password
                ) { update in
                    Task { @MainActor in otaProgress = update }
                }
                finish(outcome)
            }
        case .usb:
            Task {
                let outcome = await manager.flashFirmwareOverUSB(
                    bundle: bundle, to: target
                ) { update in
                    Task { @MainActor in usbProgress = update }
                }
                finish(outcome)
            }
        }
    }

    private func finish(_ outcome: OperationOutcome) {
        isPushing = false
        if outcome.kind == .success {
            manager.presentOperationOutcome(outcome)
            dismiss()
        } else if sheetIsVisible {
            updateFailure = outcome
        } else {
            manager.presentOperationOutcome(outcome)
        }
    }
}

private extension FirmwareBundle {
    /// The manifest entry for an exact target, tolerating nil so confirmation
    /// text can be composed without unwrapping twice.
    func payloadImage(forTarget target: String?) -> FirmwareBundle.Image? {
        guard let target else { return nil }
        return image(forTarget: target)
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
