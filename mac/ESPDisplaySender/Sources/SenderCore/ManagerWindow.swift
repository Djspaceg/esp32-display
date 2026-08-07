import AppKit
import SenderProtocol
import SwiftUI

extension Notification.Name {
    static let espDisplayShowManager = Notification.Name("com.espdisplay.sender.showManager")
    static let espDisplayShowSettings = Notification.Name("com.espdisplay.sender.showSettings")
}

struct ManagerView: View {
    @ObservedObject var manager: PanelManager
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            if !manager.issues.isEmpty {
                VStack(spacing: 0) {
                    ForEach(manager.issues) { issue in
                        IssueBanner(issue: issue) {
                            manager.dismissIssue(issue.issue)
                        }
                        Divider()
                    }
                }
                .background(.quaternary.opacity(0.4))
            }
            NavigationSplitView {
                List(selection: $manager.selectedServiceName) {
                    Section("Displays") {
                        ForEach(manager.panels) { panel in
                            PanelRow(panel: panel)
                                .tag(panel.serviceName)
                                .contextMenu {
                                    Button("Identify") { manager.identify(panel.serviceName) }
                                        .disabled(!manager.canControl(
                                            panel.serviceName, capability: .identify))
                                    Button(panel.paused ? "Resume" : "Pause") {
                                        manager.setPaused(!panel.paused, for: panel.serviceName)
                                    }
                                    Divider()
                                    Button("Forget Display", role: .destructive) {
                                        manager.forget(panel.serviceName)
                                    }
                                    .disabled(!manager.canForget(panel.serviceName))
                                }
                        }
                    }
                }
                // The system sidebar style, rather than a plain list: it gives
                // the inset rounded selection macOS users expect, the standard
                // section header treatment, and the right row insets - all of
                // which the default full-width square selection did not.
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
            } detail: {
                if let panel = manager.selectedPanel {
                    PanelDetailView(panel: panel, manager: manager)
                        .id(panel.serviceName)
                } else {
                    ContentUnavailableView(
                        "No Display Selected", systemImage: "display",
                        description: Text("Discovered and previously known panels appear in the sidebar."))
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(manager: manager)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .espDisplayShowSettings)
        ) { _ in
            showingSettings = true
        }
        .alert(
            manager.operationOutcome?.title ?? "",
            isPresented: Binding(
                get: { manager.operationOutcome != nil },
                set: { if !$0 { manager.clearOperationOutcome() } }
            )
        ) {
            Button("OK") { manager.clearOperationOutcome() }
        } message: {
            Text(manager.operationOutcome?.message ?? "")
        }
    }
}

/// A standing problem the app cannot fix by itself. Shown above everything
/// because it usually explains why the rest of the window looks wrong.
private struct IssueBanner: View {
    let issue: ReportedIssue
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .fontWeight(.medium)
                Text(issue.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss this message")
            .accessibilityLabel("Dismiss: \(issue.title)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct PanelRow: View {
    let panel: PanelSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(panel.isOnline ? Color.green : panel.discovered ? Color.orange : Color.secondary)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(panel.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(panel.statusText)
                    // Only a streaming session has a meaningful rate. Showing
                    // one while nothing is being captured read as healthy when
                    // it was not.
                    if panel.isOnline && panel.captureStatus.isStreaming {
                        Text("•")
                        Text(String(format: "%.1f fps", panel.displayFPS))
                    } else if panel.isOnline && !panel.paused {
                        Text("•")
                        Text("Not mirroring")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if panel.lastError != nil || panel.captureStatus.needsAttention {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Has a problem")
            }
            if panel.paused {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Paused")
            }
        }
        .padding(.vertical, 3)
    }
}

private struct PanelDetailView: View {
    let panel: PanelSnapshot
    @ObservedObject var manager: PanelManager
    @State private var confirmRestart = false
    @State private var editedName = ""
    @State private var isEditingName = false
    @State private var selectedSSID = ""
    @State private var editedIdleText = ""
    /// Collapsed by default: these counters matter when something is wrong, and
    /// pushing everything above them off the screen the rest of the time is a
    /// poor trade.
    @State private var showDiagnostics = false
    @FocusState private var nameIsFocused: Bool

    private var normalizedName: String {
        WifiConfigUI.normalizedDeviceName(editedName)
    }

    private var nameHasChanges: Bool {
        !normalizedName.isEmpty && normalizedName != panel.displayName
    }

    private var usbPortSelection: Binding<String> {
        Binding(
            get: { panel.usbPort ?? "" },
            set: { manager.setUSBPort($0.isEmpty ? nil : $0, for: panel.serviceName) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                if let lastError = panel.lastError {
                    PanelNotice(text: lastError)
                }

                CompactGroup("Mirroring") {
                    MirrorPreview(panel: panel, preview: manager.preview)
                }

                CompactGroup("Source") {
                    CompactGrid {
                        InfoRow("Saved choice", panel.source.label)
                        InfoRow("Currently showing", panel.sourceDescription)
                        InfoRow("Selection") {
                            HStack(spacing: 6) {
                                Menu("Choose Source…") {
                                    Button("Display…") {
                                        manager.chooseSource(
                                            for: panel.serviceName, style: .display)
                                    }
                                    Button("Window…") {
                                        manager.chooseSource(
                                            for: panel.serviceName, style: .window)
                                    }
                                    Button("Application…") {
                                        manager.chooseSource(
                                            for: panel.serviceName, style: .application)
                                    }
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .controlSize(.small)
                                .disabled(!panel.isOnline)
                                .help("Pick what this panel shows. Opens the "
                                    + "macOS picker directly in the chosen mode.")
                                Button("Use Automatic") {
                                    manager.useAutomaticSource(for: panel.serviceName)
                                }
                                .controlSize(.small)
                                .disabled(panel.source == .automatic)
                                .help("Go back to tracking the configured display")
                            }
                        }
                        InfoRow("") {
                            Text("Uses the macOS ScreenCaptureKit picker for displays, windows, and applications. The choice is remembered and reapplied when the sender restarts.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                CompactGroup("Display") {
                    CompactGrid {
                        if manager.canControl(
                            panel.serviceName, capability: .brightnessLevel)
                            || panel.capabilities.contains(.brightnessLevel)
                        {
                            InfoRow("Brightness") {
                                HStack(spacing: 8) {
                                    // No `step:`. The range is 1...255, and a
                                    // step made macOS draw a tick mark per
                                    // step - 254 of them, merging into what
                                    // looked like a stray rule under the
                                    // slider. The binding already rounds to a
                                    // whole level on the way out.
                                    Slider(
                                        value: brightnessLevel,
                                        in: brightnessBounds)
                                    .frame(maxWidth: 220)
                                    .disabled(!manager.canControl(
                                        panel.serviceName, capability: .brightnessLevel))
                                    .help(controlHelp(
                                        .brightnessLevel, "Set the panel backlight"))
                                    .accessibilityLabel("Brightness level")
                                    Text("\(brightnessPercent)%")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .frame(width: 34, alignment: .trailing)
                                }
                            }
                        } else {
                            InfoRow("Brightness") {
                                Toggle("High", isOn: Binding(
                                    get: { panel.brightnessHigh },
                                    set: { manager.setBrightness(high: $0, for: panel.serviceName) }))
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .disabled(!manager.canControl(
                                        panel.serviceName, capability: .brightness))
                                    .help(controlHelp(.brightness, "Set the panel backlight"))
                            }
                        }
                        InfoRow("Orientation") {
                            Toggle("Rotate 180°", isOn: Binding(
                                get: { panel.flipped },
                                set: { manager.setFlip($0, for: panel.serviceName) }))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .disabled(!manager.canControl(
                                    panel.serviceName, capability: .flip))
                                .help(controlHelp(.flip, "Rotate the image on the panel"))
                        }
                        if panel.controlProtocolVersion
                            != Int(DeviceProtocol.controlProtocolVersion)
                        {
                            InfoRow("Controls") {
                                Text("Flash the current firmware to enable remote controls.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                CompactGroup("Connection") {
                    CompactGrid {
                        InfoRow("Address") {
                            CopyableAddress(address: panel.address)
                        }
                        InfoRow("WiFi signal", panel.signalDescription)
                        InfoRow("USB device") {
                            HStack(spacing: 6) {
                                Picker("USB device", selection: usbPortSelection) {
                                    Text("Automatic (match by name)").tag("")
                                    ForEach(manager.usbPortOptions(
                                        for: panel.serviceName), id: \.self)
                                    { port in
                                        Text((port as NSString).lastPathComponent).tag(port)
                                    }
                                }
                                .labelsHidden()
                                // Sized to its widest option rather than
                                // stretched to a fixed width, which left a
                                // popup button padded out with dead space.
                                .fixedSize()
                                .controlSize(.small)
                                .help(panel.usbPort ?? "Automatically match this display by its reported name")

                                Button {
                                    manager.refreshUSBPorts()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .controlSize(.small)
                                .help("Refresh connected USB serial devices")
                            }
                        }
                        InfoRow("") {
                            Text("Automatic verifies the reported display name. A manual assignment is saved with this display.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        InfoRow("Saved WiFi") {
                            HStack(spacing: 6) {
                                Picker("Saved WiFi", selection: $selectedSSID) {
                                    Text("Select a network…").tag("")
                                    ForEach(manager.savedNetworkNames, id: \.self) { ssid in
                                        Text(ssid).tag(ssid)
                                    }
                                }
                                .labelsHidden()
                                .fixedSize()
                                .controlSize(.small)

                                Button("Apply") {
                                    manager.applySavedNetwork(
                                        selectedSSID, to: panel.serviceName)
                                }
                                .controlSize(.small)
                                .disabled(selectedSSID.isEmpty)

                                Button(manager.savedNetworkNames.isEmpty ? "Add…" : "Edit…") {
                                    manager.configureUSB(
                                        preferredSSID: selectedSSID.isEmpty ? nil : selectedSSID)
                                }
                                .controlSize(.small)
                            }
                        }
                        InfoRow("") {
                            Text("Credentials are stored in your login Keychain and applied over USB.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if panel.capabilities.contains(.idleText) {
                    CompactGroup("Screensaver") {
                        CompactGrid {
                            InfoRow("Template") {
                                VStack(alignment: .leading, spacing: 4) {
                                    TextEditor(text: $editedIdleText)
                                        .font(.body.monospaced())
                                        .frame(height: 68)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(.separator))
                                        .accessibilityLabel("Screensaver template")
                                    HStack(spacing: 6) {
                                        Button("Save") {
                                            manager.setIdleText(
                                                editedIdleText, for: panel.serviceName)
                                        }
                                        .controlSize(.small)
                                        .disabled(editedIdleText == panel.idleText)
                                        Menu("Insert Token") {
                                            ForEach(ScreensaverTemplate.tokens) { token in
                                                Button("\(token.placeholder) — \(token.summary)") {
                                                    insertToken(token)
                                                }
                                            }
                                        }
                                        .menuStyle(.borderlessButton)
                                        .fixedSize()
                                        .controlSize(.small)
                                        Button("Use Default") {
                                            editedIdleText = ScreensaverTemplate.standard
                                        }
                                        .controlSize(.small)
                                        .disabled(editedIdleText == ScreensaverTemplate.standard)
                                        .help("The card the panel draws on its own, as a template you can edit")
                                        Button("Clear") {
                                            editedIdleText = ""
                                            manager.setIdleText("", for: panel.serviceName)
                                        }
                                        .controlSize(.small)
                                        .disabled(panel.idleText.isEmpty
                                            && editedIdleText.isEmpty)
                                    }
                                }
                            }
                            InfoRow("On the panel") {
                                ScreensaverPanelPreview(expansion: livePreview)
                            }
                            InfoRow("") {
                                VStack(alignment: .leading, spacing: 3) {
                                    if !livePreview.unknownTokens.isEmpty {
                                        Text("Not a token: "
                                            + livePreview.unknownTokens
                                                .map { "{\($0)}" }
                                                .joined(separator: ", "))
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                    Text("Wrap a value in braces to substitute it, for example "
                                        + "\"\(ScreensaverTemplate.tokens[0].placeholder)\". "
                                        + "Write \"{{\" for a literal brace.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("Up to \(IdleText.maxLines) lines of \(IdleText.maxLineBytes) characters, shown with how long ago they were sent. The panel's font is plain ASCII, so anything else is dropped.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                CompactGroup("Firmware") {
                    CompactGrid {
                        InfoRow("Version", panel.firmwareVersion ?? "Legacy firmware")
                        InfoRow("Frame protocol", panel.frameProtocolVersion.map(String.init) ?? "2")
                        InfoRow("Control protocol", panel.controlProtocolVersion.map(String.init) ?? "Not available")
                        InfoRow("Uptime", panel.uptimeDescription)
                    }
                }

                CollapsibleGroup("Diagnostics", isExpanded: $showDiagnostics) {
                    CompactGrid {
                        InfoRow("Frames displayed", panel.framesShown.formatted())
                        InfoRow("Frames dropped", panel.framesDropped.formatted())
                        InfoRow("Sender errors", panel.sendErrors.formatted())
                        InfoRow("Changed bands", String(format: "%.0f%%", panel.diffPercent))
                        InfoRow("Free heap", ByteCountFormatter.string(
                            fromByteCount: Int64(panel.freeHeap), countStyle: .memory))
                        InfoRow("Packet pacing", "\(panel.spacingMicros) µs")
                        if let hardwareID = panel.hardwareID {
                            InfoRow("Hardware ID", hardwareID)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Spacer()
                    Button("Restart Display…", role: .destructive) {
                        confirmRestart = true
                    }
                    .disabled(!manager.canControl(panel.serviceName, capability: .restart))
                    .help(controlHelp(.restart, "Reboot the panel"))
                    Button("Forget Display", role: .destructive) {
                        manager.forget(panel.serviceName)
                    }
                    .disabled(!manager.canForget(panel.serviceName))
                    .help("A display can be forgotten after its active session retires")
                }
            }
            .padding(14)
        }
        .onAppear {
            editedName = panel.displayName
            editedIdleText = panel.idleText
            selectInitialNetwork()
        }
        .onChange(of: panel.idleText) { _, newValue in
            editedIdleText = newValue
        }
        .onChange(of: panel.displayName) { _, newValue in
            if !isEditingName { editedName = newValue }
        }
        .onChange(of: manager.savedNetworkNames) { _, _ in
            selectInitialNetwork()
        }
        .confirmationDialog(
            "Restart \(panel.displayName)?", isPresented: $confirmRestart,
            titleVisibility: .visible
        ) {
            Button("Restart", role: .destructive) {
                manager.restart(panel.serviceName)
            }
        } message: {
            Text("Streaming will reconnect automatically after the panel rejoins WiFi.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 30))
                .foregroundStyle(panel.isOnline ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if isEditingName {
                        TextField("Device name", text: $editedName)
                            .textFieldStyle(.roundedBorder)
                            .font(.title2.bold())
                            .focused($nameIsFocused)
                            .onSubmit(saveName)
                            .frame(maxWidth: 320)
                            .onExitCommand(perform: cancelNameEdit)
                        Button(action: saveName) {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(!nameHasChanges)
                        .help("Save this name to the USB-connected display")
                        Button(action: cancelNameEdit) {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Cancel renaming")
                    } else {
                        Button(action: beginNameEdit) {
                            HStack(spacing: 5) {
                                Text(panel.displayName)
                                    .font(.title2.bold())
                                Image(systemName: "pencil")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Click to rename this display")
                    }
                }
                Text(panel.statusText)
                    .font(.subheadline)
                    .foregroundStyle(panel.isOnline ? Color.green : Color.secondary)
            }
            Spacer(minLength: 12)
            Button(panel.paused ? "Resume" : "Pause") {
                manager.setPaused(!panel.paused, for: panel.serviceName)
            }
            .controlSize(.small)
            .disabled(!panel.isOnline)
            Button("Identify") { manager.identify(panel.serviceName) }
                .controlSize(.small)
                .disabled(!manager.canControl(panel.serviceName, capability: .identify))
                .help(controlHelp(.identify, "Flash this panel so you can spot it"))
        }
    }

    /// Tooltip for a control: why it is unavailable, or what it does. The reason
    /// comes from the same check that disables the control, so a greyed-out
    /// switch can always explain itself.
    private func controlHelp(
        _ capability: DeviceProtocol.Capabilities, _ available: String
    ) -> String {
        manager.controlUnavailableReason(panel.serviceName, capability: capability)
            ?? available
    }

    private var brightnessBounds: ClosedRange<Double> {
        Double(DeviceProtocol.brightnessLevelRange.lowerBound)
            ... Double(DeviceProtocol.brightnessLevelRange.upperBound)
    }

    /// Bound to the slider. Reads the level the device last reported and writes
    /// through the manager, which clamps and sends it.
    private var brightnessLevel: Binding<Double> {
        Binding(
            get: {
                let reported = Double(panel.brightness)
                return min(max(reported, brightnessBounds.lowerBound),
                           brightnessBounds.upperBound)
            },
            set: { manager.setBrightnessLevel(Int($0.rounded()), for: panel.serviceName) })
    }

    private var brightnessPercent: Int {
        let upper = DeviceProtocol.brightnessLevelRange.upperBound
        let clamped = min(max(panel.brightness, 0), upper)
        return Int((Double(clamped) / Double(upper) * 100).rounded())
    }

    private func beginNameEdit() {
        editedName = panel.displayName
        isEditingName = true
        Task { @MainActor in
            nameIsFocused = true
        }
    }

    private func saveName() {
        guard isEditingName else { return }
        guard nameHasChanges else {
            cancelNameEdit()
            return
        }
        nameIsFocused = false
        isEditingName = false
        editedName = normalizedName
        manager.rename(normalizedName, for: panel.serviceName)
    }

    private func cancelNameEdit() {
        nameIsFocused = false
        isEditingName = false
        editedName = panel.displayName
    }

    private func selectInitialNetwork() {
        if selectedSSID.isEmpty || !manager.savedNetworkNames.contains(selectedSSID) {
            selectedSSID = manager.savedNetworkNames.first ?? ""
        }
    }

    /// The template as it is being edited, expanded against this panel's live
    /// values. Previewing the unsaved text is the point: the user is composing
    /// against a 4x28 character budget and needs to see what survives it.
    private var livePreview: ScreensaverTemplate.Expansion {
        manager.screensaverPreview(
            for: panel.serviceName, template: editedIdleText)
    }

    /// Append a token, on its own line when the template does not end on a
    /// blank one, so inserting from the menu never silently joins two values
    /// into one line.
    private func insertToken(_ token: ScreensaverTemplate.Token) {
        if editedIdleText.isEmpty || editedIdleText.hasSuffix("\n") {
            editedIdleText += token.placeholder
        } else {
            editedIdleText += "\n" + token.placeholder
        }
    }
}

/// The panel's own IP address, selectable and copyable.
///
/// An address you can read but not take anywhere is only half useful - it is
/// wanted for an ssh, a ping, or a browser, all of which mean copying it.
private struct CopyableAddress: View {
    let address: String?
    @State private var copied = false

    var body: some View {
        guard let address else {
            return AnyView(Text("Resolving…").foregroundStyle(.secondary))
        }
        return AnyView(
            HStack(spacing: 6) {
                Text(address)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_400_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .help("Copy \(address)")
                .accessibilityLabel("Copy address")
                if copied {
                    Text("Copied")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            })
    }
}

/// The screensaver template as the panel will render it: fixed-width lines on a
/// dark card, at the panel's line budget.
///
/// Shown because the budget is tight - four lines of 28 characters - and a
/// template that overflows it loses content silently on a device the user is
/// usually not looking at while editing.
private struct ScreensaverPanelPreview: View {
    let expansion: ScreensaverTemplate.Expansion

    var body: some View {
        if expansion.lines.isEmpty {
            Text("Nothing sent, so the panel draws its own card: "
                + "name, address, and signal.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(expansion.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.35)))
        }
    }
}

/// What the panel is being sent, right now, and whether anything is being sent
/// at all.
///
/// This sits above every other control because it answers the question the
/// window could not answer before: a broken mirror used to look exactly like a
/// working one, since the "Online" badge and frame rate are derived from device
/// heartbeats, which keep arriving whether or not a single pixel does.
private struct MirrorPreview: View {
    let panel: PanelSnapshot
    @ObservedObject var preview: FramePreview

    /// Panel geometry, so the placeholder has the same shape as a real frame.
    private static let thumbnailHeight: CGFloat = 104

    private var frame: PreviewFrame? {
        // Never show one panel's frame against another's details.
        guard preview.serviceName == panel.serviceName else { return nil }
        return preview.frame
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                    Text(panel.captureStatus.summary)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if panel.captureStatus.needsAttention {
                    Text("Choose a source below to start mirroring again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mirroring status: \(panel.captureStatus.summary). \(detail)")
    }

    /// The frame at its own aspect ratio, with no filler behind it.
    ///
    /// A fixed square box letterboxed a portrait frame with black bars, which
    /// read as part of the picture - as though the panel itself were showing
    /// black borders.
    private var thumbnail: some View {
        Group {
            if let frame {
                Image(decorative: frame.image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: Self.thumbnailHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.separator, lineWidth: 1))
            } else {
                // Only the placeholder needs a box, to stand in for the frame
                // that is not arriving. Sized to the panel's portrait aspect so
                // the row does not jump when a frame appears.
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary.opacity(0.5))
                    .aspectRatio(
                        CGFloat(PixelConvert.width) / CGFloat(PixelConvert.height),
                        contentMode: .fit)
                    .frame(height: Self.thumbnailHeight)
                    .overlay(
                        Image(systemName: "display.slash")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary))
            }
        }
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch panel.captureStatus {
        case .streaming: return "dot.radiowaves.up.forward"
        case .waiting, .recovering: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .suspended: return "pause.circle.fill"
        }
    }

    private var tint: Color {
        switch panel.captureStatus {
        case .streaming: return .green
        case .waiting, .recovering: return .orange
        case .failed: return .orange
        case .suspended: return .secondary
        }
    }

    /// The numbers underneath. Frame age is included because it is the one
    /// value that separates "mirroring has stopped" from "the source simply is
    /// not changing" - ScreenCaptureKit sends nothing at all for static
    /// content, so a still window legitimately produces no frames.
    /// Frame totals are deliberately absent: they live in Diagnostics, and
    /// repeating them here spent the row's attention on a number nobody reads
    /// at a glance.
    private var detail: String {
        var parts: [String] = []
        if panel.captureStatus.isStreaming {
            parts.append(String(format: "%.1f fps", panel.displayFPS))
        }
        parts.append(panel.frameAgeDescription)
        return parts.joined(separator: " · ")
    }
}

private struct PanelNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(.orange.opacity(0.12)))
    }
}

private struct CompactGroup<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox(title) {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
    }
}

/// A `CompactGroup` that can be folded away, for detail worth keeping but not
/// worth the vertical space it occupies on every visit.
private struct CollapsibleGroup<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    let content: Content

    init(
        _ title: String, isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isExpanded) {
                content
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            } label: {
                Text(title)
                    .font(.callout)
                    // The whole label is the hit target, not just the arrow.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
        }
    }
}

private struct CompactGrid<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Color.clear.frame(maxWidth: .infinity, minHeight: 0, maxHeight: 0)
                Color.clear.frame(maxWidth: .infinity, minHeight: 0, maxHeight: 0)
                Color.clear.frame(maxWidth: .infinity, minHeight: 0, maxHeight: 0)
            }
            .accessibilityHidden(true)
            content
        }
    }
}

private struct InfoRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    init(_ label: String, _ value: String) where Content == Text {
        self.label = label
        self.content = Text(value)
    }

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .gridCellColumns(2)
                .gridColumnAlignment(.leading)
        }
    }
}

@MainActor
final class ManagerWindowController: NSObject, NSWindowDelegate {
    private let manager: PanelManager
    private let mainMenu = MainMenuController()
    private var window: NSWindow?

    init(manager: PanelManager) {
        self.manager = manager
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        mainMenu.installIfNeeded()
        let window = makeWindowIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        // Frame previews are only produced while this window is up.
        manager.setPreviewVisible(true)
        window.makeKeyAndOrderFront(nil)
        window.toolbar = nil
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
    }

    private func makeWindowIfNeeded() -> NSWindow {
        if let window { return window }
        let controller = NSHostingController(rootView: ManagerView(manager: manager))
        let window = NSWindow(contentViewController: controller)
        window.title = "ESPDisplaySender"
        window.setContentSize(NSSize(width: 980, height: 680))
        window.minSize = NSSize(width: 820, height: 560)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.center()
        window.setFrameAutosaveName("ESPDisplaySender.Manager")
        window.delegate = self
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        manager.setPreviewVisible(false)
        DispatchQueue.main.async {
            guard NSApp.windows.allSatisfy({ !$0.isVisible }) else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

@MainActor
final class ESPDisplayApplicationDelegate: NSObject, NSApplicationDelegate {
    private let managerWindow: ManagerWindowController
    private let manager: PanelManager
    private let showAtLaunch: Bool

    init(managerWindow: ManagerWindowController, manager: PanelManager,
         showAtLaunch: Bool) {
        self.managerWindow = managerWindow
        self.manager = manager
        self.showAtLaunch = showAtLaunch
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showManagerFromNotification),
            name: .espDisplayShowManager, object: nil)
        if showAtLaunch { managerWindow.show() }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        managerWindow.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.flushPersistence()
    }

    @objc private func showManagerFromNotification(_ notification: Notification) {
        managerWindow.show()
    }
}

#if DEBUG
#Preview("Display Manager") {
    ManagerView(manager: PanelManager.preview)
        .frame(width: 980, height: 680)
}
#endif
