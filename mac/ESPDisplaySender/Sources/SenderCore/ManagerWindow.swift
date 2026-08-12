import Combine
import SenderProtocol
import SwiftUI

extension Notification.Name {
    static let espDisplayShowManager = Notification.Name("com.espdisplay.sender.showManager")
    static let espDisplayShowSettings = Notification.Name("com.espdisplay.sender.showSettings")
    /// Posted by the File menu, handled by whichever manager window is showing -
    /// the same indirection `espDisplayShowSettings` uses, and for the same reason:
    /// the menu holds no reference to a view.
    static let espDisplayAddDevice = Notification.Name("com.espdisplay.sender.addDevice")
}

// MARK: - Window

struct ManagerView: View {
    @ObservedObject var manager: PanelManager
    @State private var showingSettings = false
    @State private var showingAddDevice = false

    var body: some View {
        NavigationSplitView {
            // THE SIDEBAR IS A VSTACK, NOT JUST A LIST, so the footer below can
            // exist. Three placements for the + were tried against the built app
            // before this one, and the first two did not render at all: a Button in
            // the List's section header was dropped by the sidebar header style
            // (the accessibility tree showed one AXHeading and no button), and a
            // `.safeAreaInset(edge: .bottom)` on the List was swallowed by the
            // sidebar's scroll area (a screenshot of the sidebar's bottom showed
            // nothing). Plain layout outside the List is what works, and it is also
            // where macOS puts this control - Finder's tags, Mail's mailboxes,
            // System Settings' lists all have a + in the sidebar footer.
            sidebarList
                // The footer is an OVERLAY on the list, with the list's scrollable
                // content inset to leave room for it, because an overlay is laid out
                // in the same bounds and therefore actually appears. Three other
                // placements were tried against the built app and did not render at
                // all - see the note on `AddDisplayFooter`.
                .contentMargins(.bottom, 34, for: .scrollContent)
                .overlay(alignment: .bottom) {
                    AddDisplayFooter { showingAddDevice = true }
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            detailColumn
        }
        // Standing problems float over the content on glass rather than pushing
        // the whole window down, which is what the old full-width bar did.
        .safeAreaInset(edge: .top, spacing: 0) {
            if !manager.issues.isEmpty {
                VStack(spacing: 8) {
                    ForEach(manager.issues) { issue in
                        IssueBanner(issue: issue) {
                            manager.dismissIssue(issue.issue)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
        // No minimum frame here. A SwiftUI minimum on the hosted root is
        // reported up as the hosting controller's own minimum *plus* the
        // titlebar inset - measured, a 580pt minimum became a 620pt window
        // floor - which then fights the window's own contentMinSize. The window
        // owns the minimum; see ManagerWindowController.
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(manager: manager)
        }
        .sheet(isPresented: $showingAddDevice) {
            AddDeviceSheet(manager: manager)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .espDisplayShowSettings)
        ) { _ in
            showingSettings = true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .espDisplayAddDevice)
        ) { _ in
            showingAddDevice = true
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

    private var sidebarList: some View {
        List(selection: $manager.selectedServiceName) {
                Section {
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
                } header: {
                    Text("Displays")
                }
            }
            // The system sidebar style carries the Liquid Glass sidebar
            // treatment and selection material; a plain list does not.
            .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detailColumn: some View {
            if let panel = manager.selectedPanel {
                PanelDetailView(panel: panel, manager: manager)
                    .id(panel.serviceName)
            } else {
                // The empty state is also the new-user state, so it offers the one
                // action that works with nothing in the sidebar.
                ContentUnavailableView {
                    Label("No Display Selected", systemImage: "display")
                } description: {
                    Text("Discovered and previously known panels appear in the "
                        + "sidebar. A board that has never joined a network is not "
                        + "discovered yet - add it over its USB cable.")
                } actions: {
                    Button("Add a Display over USB…") { showingAddDevice = true }
                        .buttonStyle(.glassProminent)
                }
            }
    }
}

/// The sidebar's footer: where macOS puts the control that adds one of whatever
/// the list holds.
///
/// A plain glyph button, left-aligned on a bar, which is the shape Finder's tags,
/// Mail's mailboxes and System Settings' lists all use. It is drawn over the list
/// rather than under it, so it is present when the list is EMPTY - the state a
/// first board is added from, and the state every other configuration path in this
/// app cannot start in, since they all begin by selecting a display.
///
/// GETTING THIS TO RENDER AT ALL TOOK FOUR ATTEMPTS, all verified against the built
/// app rather than by reading the code, and the three that failed failed silently -
/// the source looked right and the control was simply not there:
///
///   1. A Button in the List's `Section` header. The sidebar header style keeps the
///      text and drops interactive subviews; the accessibility tree showed one
///      `AXHeading` and no button.
///   2. `.safeAreaInset(edge: .bottom)` on the List. Swallowed by the sidebar's
///      scroll area; a screenshot of the sidebar's bottom showed nothing.
///   3. A `VStack { List; Divider(); footer }` as the whole sidebar column. The
///      List rendered and its two siblings did not appear at all, in the screenshot
///      or in the accessibility tree.
///   4. An overlay on the List, with `contentMargins` insetting the scrollable
///      content so rows are not hidden behind it. This one renders.
private struct AddDisplayFooter: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Image(systemName: "plus")
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Add a display connected to this Mac by USB")
            .accessibilityLabel("Add a display over USB")
            .accessibilityIdentifier("add-display-over-usb")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

/// A standing problem the app cannot fix by itself. Floats above the content
/// because it usually explains why the rest of the window looks wrong.
private struct IssueBanner: View {
    let issue: ReportedIssue
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
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
        .padding(.vertical, 10)
        .glassCard(tint: .orange)
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

// MARK: - Detail

private struct PanelDetailView: View {
    let panel: PanelSnapshot
    @ObservedObject var manager: PanelManager
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var confirmRestart = false
    /// The panel the firmware update sheet is open for, or nil when it is closed.
    /// Held as the gathered target rather than a bool so the sheet cannot be
    /// opened for a panel whose address or hardware ID is not known yet.
    @State private var updateTarget: PanelManager.FirmwareUpdateTarget?
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
        Form {
            heroSection
            sourceSection
            displaySection
            connectionSection
            // Gated on the panel actually having a touch screen, so a panel that
            // cannot produce a gesture does not offer to bind one.
            if panel.capabilities.contains(.touch) {
                gestureSection
            }
            if panel.capabilities.contains(.idleText) {
                screensaverSection
            }
            firmwareSection
            diagnosticsSection
            dangerSection
        }
        .formStyle(.grouped)
        // A third for the label, the rest for the value. Grouped rows otherwise
        // push content to the trailing edge, which left the screensaver editor
        // and the label naming it at opposite ends of the window.
        .labeledContentStyle(.labelColumn)
        .background(paneBackground)
        // Identity moves into the merged titlebar, so the hero no longer
        // repeats the name and the window spends less height on chrome.
        //
        // Only the subtitle is set here. `navigationTitle` does not reach
        // `NSWindow.title` when the view is hosted in a hand-built window
        // rather than a SwiftUI scene - measured, the window kept its own title
        // - so the title is driven from ManagerWindowController instead. One
        // owner per property, or they overwrite each other.
        .navigationSubtitle(panel.statusText)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Rename", systemImage: "pencil") {
                    beginNameEdit()
                }
                .help("Rename this display")
                .popover(isPresented: $isEditingName, arrowEdge: .bottom) {
                    renamePopover
                }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button(panel.paused ? "Resume" : "Pause") {
                    manager.setPaused(!panel.paused, for: panel.serviceName)
                }
                .disabled(!panel.isOnline)
                .help(panel.paused ? "Resume sending frames" : "Stop sending frames")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Identify", systemImage: "light.beacon.max") {
                    manager.identify(panel.serviceName)
                }
                .disabled(!manager.canControl(panel.serviceName, capability: .identify))
                .help(controlHelp(.identify, "Flash this panel so you can spot it"))
            }
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
        .sheet(item: $updateTarget) { target in
            FirmwareUpdateSheet(manager: manager, target: target)
        }
    }

    /// The panel's own picture, blurred past recognition, as the material the
    /// glass above it refracts.
    ///
    /// Using the mirrored content as the backdrop is the point of the new design
    /// language: the surface reacts to what the app is actually doing. It is
    /// blurred hard and dimmed because this pane is full of small telemetry
    /// text, and dropped entirely under Reduce Transparency.
    @ViewBuilder
    private var paneBackground: some View {
        if let frame = currentFrame, !reduceTransparency {
            Image(decorative: frame.image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 70, opaque: true)
                .opacity(0.28)
                .backgroundExtensionEffect()
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
    }

    private var currentFrame: PreviewFrame? {
        guard manager.preview.serviceName == panel.serviceName else { return nil }
        return manager.preview.frame
    }

    // MARK: sections

    /// The hero scrolls with everything else rather than being pinned above the
    /// form.
    ///
    /// It was pinned, via `safeAreaInset`, so the glass would have moving
    /// content to refract. That turned out to propagate an intrinsic minimum
    /// height all the way up through NSHostingController: measured, a window
    /// asked to shrink to 380pt refused to go below 465. Once the form needed
    /// more room than the window would give, SwiftUI held its minimum size and
    /// AppKit anchored it bottom-left, so the content ran off the *top* of the
    /// window where nothing could scroll it back.
    ///
    /// The row background is cleared because the card brings its own glass, and
    /// glass does not stack.
    private var heroSection: some View {
        Section {
            MirrorHero(panel: panel, preview: manager.preview)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 6, trailing: 0))
        }
    }

    private var sourceSection: some View {
        Section {
            LabeledContent("Source") {
                HStack(spacing: 8) {
                    // Bound to what the panel *is* set to, not to the last thing
                    // clicked: backing out of the macOS picker leaves the source
                    // alone, so the dropdown returns to its previous value.
                    Picker("Source", selection: sourceKind) {
                        ForEach(PanelSourceKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    // Only windows and applications need the macOS picker:
                    // they are too many and too short-lived to list, and
                    // choosing the kind already selected fires nothing, so
                    // re-picking one needs its own control.
                    if panel.source.kind == .window {
                        Button("Choose…") {
                            manager.chooseSource(for: panel.serviceName, style: .window)
                        }
                        .help("Pick a different window")
                    }
                }
            }
            // Displays are listed inline, so switching monitors is one click.
            if panel.source.kind == .display {
                LabeledContent("Display") {
                    Picker("Display", selection: displaySelection) {
                        ForEach(manager.displayOptions(for: panel.serviceName), id: \.self)
                        { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Which screen this panel mirrors")
                }
            }
            LabeledContent("Currently showing", value: panel.sourceDescription)
            // Only meaningful for a region, so it is not shown otherwise.
            if panel.source.kind == .region {
                regionControls
            }
        } header: {
            Text("Source")
        } footer: {
            Text("A region streams a rectangle of one screen, locked to the panel's "
                + "\(PixelConvert.width):\(PixelConvert.height) shape — 1× sends one "
                + "screen point per panel pixel, higher multiples frame more and "
                + "scale it down. Choosing a display, window, or application "
                + "instead uses the macOS picker. Either choice is remembered and "
                + "reapplied when the sender restarts.")
        }
    }

    /// The marquee controls, shown only while Region is the chosen source.
    ///
    /// Only the button that summons the marquee lives here. The scale presets
    /// and rotate moved onto the marquee overlay itself: adjusting a rectangle
    /// you cannot see is meaningless, so controls that reshape it exist only
    /// while it is on screen showing their effect (RegionSelector.presetZones).
    private var regionControls: some View {
        LabeledContent("Rectangle") {
            HStack(spacing: 8) {
                // Not gated on the panel being online: choosing what to send
                // is a decision about this Mac's screen, and the preview
                // shows the answer with the panel switched off.
                Button(manager.isChoosingRegion ? "Done" : "Adjust…") {
                    if manager.isChoosingRegion {
                        manager.finishChoosingRegion()
                    } else {
                        manager.chooseRegion(for: panel.serviceName)
                    }
                }
                .help("Drag an aspect-locked rectangle over your screen to "
                    + "choose what this panel shows; its size presets and "
                    + "rotation are on the rectangle itself")
                if let region = panel.source.region {
                    Text(region.sizeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    /// The gesture preset, read back from the panel so the dropdown shows what is
    /// in force rather than the last thing clicked.
    private var gesturePreset: Binding<GesturePreset> {
        Binding(
            get: { panel.gesturePreset },
            set: { manager.setGesturePreset($0, for: panel.serviceName) })
    }

    /// The dropdown's value: derived from the stored source, so a cancelled
    /// chooser cannot leave it showing something that was never applied.
    private var sourceKind: Binding<PanelSourceKind> {
        Binding(
            get: { panel.source.kind },
            set: { manager.selectSourceKind($0, for: panel.serviceName) })
    }

    /// Which display a display source is pointed at.
    private var displaySelection: Binding<String> {
        Binding(
            get: {
                if case .display(let name) = panel.source { return name }
                return ""
            },
            set: { manager.selectDisplay($0, for: panel.serviceName) })
    }

    private var displaySection: some View {
        Section("Display") {
            // Unconditional, unlike the rotation controls below: every board
            // has a backlight or panel-command brightness sink, so `.power`
            // is advertised everywhere (see `Capabilities.power`).
            LabeledContent("Power") {
                // labelsHidden, unlike the Brightness/Orientation switch
                // fallbacks below: those keep "High"/"Rotate 180°" because the
                // label names what turning it ON means. "On" adds nothing
                // "Power" hasn't already said, and an unlabeled switch is the
                // narrower, more reliably fixed-width control - the same
                // reasoning that already gives the segmented Orientation
                // picker labelsHidden.
                Toggle("On", isOn: Binding(
                    get: { !panel.manuallyOff },
                    set: { manager.setPower($0, for: panel.serviceName) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!manager.canControl(panel.serviceName, capability: .power))
                    .help(controlHelp(
                        .power,
                        "Turn the panel's display off without unplugging it. "
                            + "Persists across a reboot until turned back on."))
            }
            if manager.canControl(panel.serviceName, capability: .brightnessLevel)
                || panel.capabilities.contains(.brightnessLevel)
            {
                LabeledContent("Brightness") {
                    HStack(spacing: 10) {
                        // No `step:`. The range is 1...255, and a step made
                        // macOS draw a tick mark per step - 254 of them,
                        // merging into what looked like a stray rule under the
                        // slider. The binding already rounds on the way out.
                        //
                        // Left to fill the value column rather than capped at a
                        // width, which made a short slider float in the middle
                        // of an otherwise empty row.
                        Slider(value: brightnessLevel, in: brightnessBounds)
                            .disabled(!manager.canControl(
                                panel.serviceName, capability: .brightnessLevel))
                            .help(controlHelp(
                                .brightnessLevel, "Set the panel backlight"))
                            .accessibilityLabel("Brightness level")
                        Text("\(brightnessPercent)%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            } else {
                LabeledContent("Brightness") {
                    Toggle("High", isOn: Binding(
                        get: { panel.brightnessHigh },
                        set: { manager.setBrightness(high: $0, for: panel.serviceName) }))
                        .toggleStyle(.switch)
                        // A switch Toggle stretches to fill, stranding its
                        // switch at the far edge of the row from the words
                        // naming it. fixedSize keeps the pair together.
                        .fixedSize()
                        .disabled(!manager.canControl(
                            panel.serviceName, capability: .brightness))
                        .help(controlHelp(.brightness, "Set the panel backlight"))
                }
            }
            if manager.canControl(panel.serviceName, capability: .rotate)
                || panel.capabilities.contains(.rotate)
            {
                // Square panels advertise quarter-turn rotation, so the
                // orientation control becomes a four-way choice. Rectangular
                // panels keep the 180 toggle below: their 90-degree case is
                // the sender-side landscape mechanism, and their firmware
                // never advertises `.rotate`.
                LabeledContent("Orientation") {
                    Picker("Orientation", selection: Binding(
                        get: { panel.rotation },
                        set: { manager.setRotation($0, for: panel.serviceName) })) {
                        Text("0°").tag(0)
                        Text("90°").tag(1)
                        Text("180°").tag(2)
                        Text("270°").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!manager.canControl(panel.serviceName, capability: .rotate))
                    .help(controlHelp(
                        .rotate,
                        "Turn the image clockwise to match how the panel is mounted"))
                }
            } else {
                LabeledContent("Orientation") {
                    Toggle("Rotate 180°", isOn: Binding(
                        get: { panel.flipped },
                        set: { manager.setFlip($0, for: panel.serviceName) }))
                        .toggleStyle(.switch)
                        .fixedSize()
                        .disabled(!manager.canControl(panel.serviceName, capability: .flip))
                        .help(controlHelp(.flip, "Rotate the image on the panel"))
                }
            }
            if panel.controlProtocolVersion != Int(DeviceProtocol.controlProtocolVersion) {
                Text("Flash the current firmware to enable remote controls.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var connectionSection: some View {
        Section {
            LabeledContent("Address") {
                CopyableAddress(address: panel.address)
            }
            LabeledContent("WiFi signal", value: panel.signalDescription)
            LabeledContent("USB device") {
                HStack(spacing: 8) {
                    Picker("USB device", selection: usbPortSelection) {
                        Text("Automatic (match by name)").tag("")
                        ForEach(manager.usbPortOptions(for: panel.serviceName), id: \.self)
                        { port in
                            Text((port as NSString).lastPathComponent).tag(port)
                        }
                    }
                    .labelsHidden()
                    // Sized to its widest option rather than stretched to a
                    // fixed width, which left a popup padded with dead space.
                    .fixedSize()
                    .help(panel.usbPort ?? "Automatically match this display by its reported name")

                    Button {
                        manager.refreshUSBPorts()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh connected USB serial devices")
                }
            }
            LabeledContent("Saved WiFi") {
                HStack(spacing: 8) {
                    Picker("Saved WiFi", selection: $selectedSSID) {
                        Text("Select a network…").tag("")
                        ForEach(manager.savedNetworkNames, id: \.self) { ssid in
                            Text(ssid).tag(ssid)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    Button("Apply") {
                        manager.applySavedNetwork(selectedSSID, to: panel.serviceName)
                    }
                    .disabled(selectedSSID.isEmpty)

                    Button(manager.savedNetworkNames.isEmpty ? "Add…" : "Edit…") {
                        manager.configureUSB(
                            preferredSSID: selectedSSID.isEmpty ? nil : selectedSSID)
                    }
                }
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("Automatic verifies the reported display name; a manual assignment is saved with this display. WiFi credentials are stored in your login Keychain and applied over USB.")
        }
    }

    /// The gesture preset and, below it, what each gesture will actually do.
    ///
    /// The readout is not written out here. It is generated from the same
    /// resolver that dispatches a real gesture, so it describes the behaviour
    /// rather than restating it — a binding that changed without the help
    /// following is not expressible.
    private var gestureSection: some View {
        Section {
            LabeledContent("Preset") {
                Picker("Preset", selection: gesturePreset) {
                    ForEach(GesturePreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help(panel.gesturePreset.summary)
            }
            LabeledContent("Gestures") {
                gestureHelp
            }
        } header: {
            Text("Touch")
        } footer: {
            Text(panel.gesturePreset.summary
                + " Directions follow what is on the panel, so they stay correct "
                + "when it is rotated or flipped — the list above is for how it is "
                + "facing now. A gesture not listed does nothing under this preset.")
        }
    }

    /// One row per bound gesture, plus whatever stands between the preset and
    /// working: firmware too old to report a long press, or a permission macOS
    /// has not granted yet.
    private var gestureHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(GestureHelpRow.rows(
                    for: panel.gesturePreset, landscape: panel.landscape)
                ) { row in
                    GridRow {
                        Text(row.gesture).font(.callout.weight(.medium))
                        Text(row.effect)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Both of these are the difference between a preset that works and a
            // gesture that silently does nothing, which is the one outcome a
            // touch binding cannot afford.
            if panel.gesturePreset.usesLongPress,
                !panel.capabilities.contains(.touchLongPress)
            {
                Label(
                    "Press and hold needs newer firmware on this panel. The other "
                        + "gestures work now.",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if panel.gesturePreset == .multimedia, !MediaControl.isAuthorized {
                HStack(spacing: 8) {
                    Label(
                        "Playback control needs Accessibility permission.",
                        systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Allow…") { MediaControl.requestAuthorization() }
                        .controlSize(.small)
                }
            }
        }
    }

    private var screensaverSection: some View {
        Section {
            LabeledContent("Template") {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $editedIdleText)
                        .font(.body.monospaced())
                        .frame(height: 72)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .glassCard(cornerRadius: 8)
                        .accessibilityLabel("Screensaver template")
                    HStack(spacing: 8) {
                        Button("Save") {
                            manager.setIdleText(editedIdleText, for: panel.serviceName)
                        }
                        .disabled(editedIdleText == panel.idleText)
                        Menu("Insert Token") {
                            ForEach(ScreensaverTemplate.tokens) { token in
                                Button("\(token.placeholder) — \(token.summary)") {
                                    insertToken(token)
                                }
                            }
                        }
                        .fixedSize()
                        Button("Use Default") {
                            editedIdleText = ScreensaverTemplate.standard
                        }
                        .disabled(editedIdleText == ScreensaverTemplate.standard)
                        .help("The card the panel draws on its own, as a template you can edit")
                        Button("Clear") {
                            editedIdleText = ""
                            manager.setIdleText("", for: panel.serviceName)
                        }
                        .disabled(panel.idleText.isEmpty && editedIdleText.isEmpty)
                    }
                }
            }
            LabeledContent("On the panel") {
                ScreensaverPanelPreview(expansion: livePreview)
            }
            if !livePreview.unknownTokens.isEmpty {
                Label(
                    "Not a token: "
                        + livePreview.unknownTokens.map { "{\($0)}" }
                            .joined(separator: ", "),
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Screensaver")
        } footer: {
            Text("Wrap a value in braces to substitute it, for example "
                + "\"\(ScreensaverTemplate.tokens[0].placeholder)\". Write \"{{\" for a "
                + "literal brace. Up to \(IdleText.maxLines) lines of "
                + "\(IdleText.maxLineBytes) characters, shown with how long ago they were "
                + "sent. The panel's font is plain ASCII, so anything else is dropped.")
        }
    }

    private var firmwareSection: some View {
        Section("Firmware") {
            LabeledContent("Version", value: panel.firmwareVersion ?? "Legacy firmware")
            LabeledContent(
                "Frame protocol",
                value: panel.frameProtocolVersion.map(String.init) ?? "2")
            LabeledContent(
                "Control protocol",
                value: panel.controlProtocolVersion.map(String.init) ?? "Not available")
            LabeledContent("Uptime", value: panel.uptimeDescription)
            // Only for a panel that advertises a battery. A C6 has no PMU and
            // will never report one, so an unconditional row would read as a
            // flat or missing battery instead of hardware that does not exist.
            if panel.capabilities.contains(.battery) {
                LabeledContent("Battery", value: panel.batteryDescription)
            }
        }
    }

    private var diagnosticsSection: some View {
        Section {
            DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                LabeledContent("Frames displayed", value: panel.framesShown.formatted())
                LabeledContent("Frames dropped", value: panel.framesDropped.formatted())
                LabeledContent("Sender errors", value: panel.sendErrors.formatted())
                LabeledContent(
                    "Changed bands", value: String(format: "%.0f%%", panel.diffPercent))
                LabeledContent("Free heap", value: ByteCountFormatter.string(
                    fromByteCount: Int64(panel.freeHeap), countStyle: .memory))
                LabeledContent("Packet pacing", value: "\(panel.spacingMicros) µs")
                if let hardwareID = panel.hardwareID {
                    LabeledContent("Hardware ID", value: hardwareID)
                }
            }
        }
    }

    private var dangerSection: some View {
        Section {
            // Not marked destructive: it opens a sheet rather than doing
            // anything, and the sheet has its own confirmation naming the
            // direction - update, reinstall or downgrade.
            Button("Update Firmware…") {
                updateTarget = manager.beginFirmwareUpdate(panel.serviceName)
            }
            .disabled(!manager.canControl(panel.serviceName, capability: .ota))
            .help(controlHelp(.ota, "Push a firmware bundle to this panel"))
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

    // MARK: helpers

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

    /// Renaming, from the toolbar rather than from an editable heading.
    ///
    /// The name now lives in the titlebar, and a titlebar is not somewhere to
    /// put a text field that triggers a USB write and a device restart. A
    /// popover keeps the commit explicit.
    private var renamePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename Display")
                .font(.headline)
            TextField("Device name", text: $editedName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .focused($nameIsFocused)
                .onSubmit(saveName)
                .onExitCommand(perform: cancelNameEdit)
            Text("Written over USB to the connected display, which then restarts and "
                + "reconnects on its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) { cancelNameEdit() }
                Button("Save") { saveName() }
                    .buttonStyle(.glassProminent)
                    .disabled(!nameHasChanges)
            }
        }
        .padding(14)
    }

    /// The template as it is being edited, expanded against this panel's live
    /// values. Previewing the unsaved text is the point: the user is composing
    /// against a 4x28 character budget and needs to see what survives it.
    private var livePreview: ScreensaverTemplate.Expansion {
        manager.screensaverPreview(for: panel.serviceName, template: editedIdleText)
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

// MARK: - Hero

/// What one panel is showing, and whether it is still being fed.
///
/// Deliberately narrow in scope: the name and connection state now live in the
/// merged titlebar, so this is only the picture, the capture state, and the two
/// numbers that qualify it. Repeating the name here as a heading cost a whole
/// line of window height to say what the titlebar already said.
private struct MirrorHero: View {
    let panel: PanelSnapshot
    @ObservedObject var preview: FramePreview

    @Namespace private var glassNamespace

    /// Panel geometry, so the placeholder is the same shape as a real frame.
    private static let thumbnailHeight: CGFloat = 96

    private var frame: PreviewFrame? {
        // Never show one panel's frame against another's details.
        guard preview.serviceName == panel.serviceName else { return nil }
        return preview.frame
    }

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            // The same one third / two thirds split the rows below use, so the
            // picture sits in the label column and its state in the value
            // column. Centred rather than baseline-aligned: an image's text
            // baseline is just its bottom edge, which would hang the status
            // pill off the foot of the thumbnail.
            LabelColumnLayout(alignment: .center) {
                thumbnail
                    .frame(maxWidth: .infinity, alignment: .trailing)
                VStack(alignment: .leading, spacing: 7) {
                    statusPill
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let lastError = panel.lastError {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .glassCard(cornerRadius: 16)
        }
    }

    /// State as its own small glass capsule, so "is this working" reads at a
    /// glance from across the room rather than as one more line of body text.
    private var statusPill: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(panel.captureStatus.summary)
                .font(.callout)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassCard(cornerRadius: 11, tint: pillTint)
        .glassEffectID("status", in: glassNamespace)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mirroring status: \(panel.captureStatus.summary)")
    }

    /// The frame at its own aspect ratio, with no filler behind it. A fixed
    /// square box letterboxed a portrait frame with black bars, which read as
    /// though the panel itself were showing black borders.
    private var thumbnail: some View {
        Group {
            if let frame {
                Image(decorative: frame.image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: Self.thumbnailHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                    .aspectRatio(
                        CGFloat(PixelConvert.width) / CGFloat(PixelConvert.height),
                        contentMode: .fit)
                    .frame(height: Self.thumbnailHeight)
                    .overlay(
                        Image(systemName: "display.slash")
                            .font(.system(size: 22))
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
        case .waiting, .recovering, .failed: return .orange
        case .suspended: return .secondary
        }
    }

    /// Only a real problem tints the glass. Tinting it for every transient
    /// reconnect would make the colour meaningless.
    private var pillTint: Color? {
        panel.captureStatus.needsAttention ? .orange : nil
    }

    /// Frame totals are deliberately absent: they live in Diagnostics, and
    /// repeating them here spent the hero's attention on a number nobody reads
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

// MARK: - Small pieces

/// The panel's own IP address, selectable and copyable.
///
/// An address you can read but not take anywhere is only half useful - it is
/// wanted for an ssh, a ping, or a browser, all of which mean copying it.
private struct CopyableAddress: View {
    let address: String?
    @State private var copied = false

    var body: some View {
        if let address {
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
            }
        } else {
            Text("Resolving…").foregroundStyle(.secondary)
        }
    }
}

/// The screensaver template as the panel will render it: fixed-width lines on a
/// dark card, at the panel's line budget.
///
/// Deliberately *not* glass. This stands in for a physical panel showing opaque
/// pixels, and making it translucent would misrepresent what the device does.
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
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.black.opacity(0.85)))
        }
    }
}

// MARK: - Hosting

@MainActor
final class ManagerWindowController: NSObject, NSWindowDelegate {
    private let manager: PanelManager
    private let mainMenu = MainMenuController()
    private var window: NSWindow?
    private var titleObserver: AnyCancellable?

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
    }

    /// Keep the merged titlebar showing the selected panel's name.
    ///
    /// Done here rather than with `navigationTitle` because that modifier does
    /// not reach `NSWindow.title` for a view hosted in a hand-built window, so
    /// the titlebar would have shown the app's name forever. `objectWillChange`
    /// fires before the change lands, hence the hop to the next main-actor turn.
    private func observeTitle() {
        titleObserver = manager.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.syncTitle() }
        }
        syncTitle()
    }

    private func syncTitle() {
        guard let window else { return }
        let title = manager.selectedPanel?.displayName ?? "ESPDisplaySender"
        if window.title != title { window.title = title }
    }

    private func makeWindowIfNeeded() -> NSWindow {
        if let window { return window }
        let controller = NSHostingController(rootView: ManagerView(manager: manager))
        let window = NSWindow(contentViewController: controller)
        window.title = "ESPDisplaySender"
        window.setContentSize(NSSize(width: 1000, height: 700))
        // contentMinSize rather than minSize: with fullSizeContentView the
        // content view is the whole window, so constraining the frame and
        // constraining the content are off by the titlebar height.
        window.contentMinSize = NSSize(width: 760, height: 420)
        // fullSizeContentView lets the sidebar's glass run the whole height of
        // the window and up behind the titlebar, which is what makes the
        // sidebar and the title area read as one surface rather than two.
        window.styleMask = [
            .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
        ]
        // Unified compact: the title sits inline with the toolbar buttons on
        // reduced margins, so identity and actions share one shallow band
        // instead of stacking a title row above a toolbar row.
        window.toolbarStyle = .unifiedCompact
        // The title is wanted now - it carries the selected panel's name and
        // status, which the hero used to repeat.
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // The toolbar itself is left alone. It used to be cleared on every
        // show(), which threw away the SwiftUI toolbar and its glass controls.
        window.center()
        window.setFrameAutosaveName("ESPDisplaySender.Manager")
        window.delegate = self
        self.window = window
        observeTitle()
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
        .frame(width: 1000, height: 700)
}
#endif
