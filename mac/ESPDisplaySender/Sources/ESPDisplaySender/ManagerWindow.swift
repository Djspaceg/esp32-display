import AppKit
import SenderProtocol
import SwiftUI

extension Notification.Name {
    static let espDisplayShowManager = Notification.Name("com.espdisplay.sender.showManager")
}

struct ManagerView: View {
    @ObservedObject var manager: PanelManager

    var body: some View {
        NavigationSplitView {
            List(selection: $manager.selectedServiceName) {
                Section("Displays") {
                    ForEach(manager.panels) { panel in
                        PanelRow(panel: panel)
                            .tag(panel.serviceName)
                            .contextMenu {
                                Button("Identify") { manager.identify(panel.serviceName) }
                                    .disabled(!panel.capabilities.contains(.identify))
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
            .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 340)
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
        .frame(minWidth: 820, minHeight: 560)
        .alert(
            "Display Command Failed",
            isPresented: Binding(
                get: { manager.operationError != nil },
                set: { if !$0 { manager.clearOperationError() } }
            )
        ) {
            Button("OK") { manager.clearOperationError() }
        } message: {
            Text(manager.operationError ?? "The display did not accept the command.")
        }
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
                    if panel.isOnline {
                        Text("•")
                        Text(String(format: "%.1f fps", panel.displayFPS))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if panel.paused {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.secondary)
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

                CompactGroup("Source") {
                    CompactGrid {
                        InfoRow("Currently showing", panel.sourceDescription)
                        InfoRow("Selection") {
                            Button("Choose Source…") {
                                manager.chooseSource(for: panel.serviceName)
                            }
                            .controlSize(.small)
                            .disabled(!panel.isOnline)
                        }
                        InfoRow("") {
                            Text("Uses the macOS ScreenCaptureKit picker for displays, windows, and applications.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                CompactGroup("Display") {
                    CompactGrid {
                        InfoRow("Brightness") {
                            Toggle("High", isOn: Binding(
                                get: { panel.brightnessHigh },
                                set: { manager.setBrightness(high: $0, for: panel.serviceName) }))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .disabled(!manager.canControl(
                                    panel.serviceName, capability: .brightness))
                        }
                        InfoRow("Orientation") {
                            Toggle("Rotate 180°", isOn: Binding(
                                get: { panel.flipped },
                                set: { manager.setFlip($0, for: panel.serviceName) }))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .disabled(!manager.canControl(
                                    panel.serviceName, capability: .flip))
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
                        InfoRow("Address", panel.address ?? "Resolving…")
                        InfoRow("WiFi signal", panel.signalDescription)
                        InfoRow("Frame rate", String(format: "%.1f fps", panel.displayFPS))
                        InfoRow("Last seen") {
                            if let lastSeen = panel.lastSeen {
                                Text(lastSeen, style: .relative)
                            } else {
                                Text("Never")
                            }
                        }
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
                                .frame(maxWidth: 260)
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
                                .frame(maxWidth: 230)
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

                CompactGroup("Firmware") {
                    CompactGrid {
                        InfoRow("Version", panel.firmwareVersion ?? "Legacy firmware")
                        InfoRow("Frame protocol", panel.frameProtocolVersion.map(String.init) ?? "2")
                        InfoRow("Control protocol", panel.controlProtocolVersion.map(String.init) ?? "Not available")
                        InfoRow("Uptime", panel.uptimeDescription)
                        if panel.capabilities.contains(.ota) {
                            InfoRow("Update") {
                                Button("Install Firmware Update…") { showOTANotice() }
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                CompactGroup("Diagnostics") {
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
            selectInitialNetwork()
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
        }
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

    private func showOTANotice() {
        let alert = NSAlert()
        alert.messageText = "Firmware Update"
        alert.informativeText = "The device advertises OTA support, but no signed firmware bundle is installed in this app build."
        alert.runModal()
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
