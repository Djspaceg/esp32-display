import AppKit
import Combine
import SenderProtocol
import SwiftUI

/// The app's own Settings window, opened from the app menu's Settings… (⌘,)
/// and from the links on a display's page. Laid out the way System Settings
/// is: a searchable sidebar of sections, and the selected section's grouped
/// cards beside it.
///
/// Everything here is app-wide. Above all the saved WiFi networks and the
/// order they fill every board's ten preset slots, which are added, edited,
/// removed and reordered here and nowhere else.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case streaming
    case wifiNetworks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .streaming: return "Streaming"
        case .wifiNetworks: return "WiFi Networks"
        }
    }

    var summary: String {
        switch self {
        case .general:
            return "How the device list is ordered and how long Identify lasts."
        case .streaming:
            return "Frame rate, packet pacing and tile compression for every device."
        case .wifiNetworks:
            return "The networks this Mac copies to every device's preset slots."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .streaming: return "play.rectangle.fill"
        case .wifiNetworks: return "wifi"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .streaming: return .indigo
        case .wifiNetworks: return .blue
        }
    }

    /// Words the sidebar search finds this pane by, besides its title: the
    /// names of the settings on it.
    var keywords: [String] {
        switch self {
        case .general:
            return ["sort", "order", "device list", "display list", "sidebar", "identify", "led"]
        case .streaming:
            return ["frame rate", "fps", "pacing", "packet", "tile", "quality",
                    "compression", "lossless", "lossy"]
        case .wifiNetworks:
            return ["wifi", "wi-fi", "network", "ssid", "password", "preset",
                    "slot", "keychain", "open network"]
        }
    }

    /// Whether a sidebar search for `query` shows this pane. An empty query
    /// shows every pane.
    func matches(_ query: String) -> Bool {
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return true }
        return ([title] + keywords).contains {
            $0.localizedCaseInsensitiveContains(words)
        }
    }

    /// Open the Settings window at `pane`, from anywhere: posted rather than
    /// called, so a view or the menu needs no reference to the window.
    @MainActor
    static func open(_ pane: SettingsPane? = nil) {
        NotificationCenter.default.post(
            name: .espDisplayShowSettings, object: nil,
            userInfo: pane.map { ["pane": $0.rawValue] })
    }
}

/// Which pane the window shows, the sidebar search, and the back and forward
/// history System Settings' toolbar arrows walk.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published private(set) var pane: SettingsPane = .general
    @Published var query = ""
    @Published private(set) var backStack: [SettingsPane] = []
    @Published private(set) var forwardStack: [SettingsPane] = []

    var visiblePanes: [SettingsPane] {
        SettingsPane.allCases.filter { $0.matches(query) }
    }

    func show(_ next: SettingsPane) {
        guard next != pane else { return }
        backStack.append(pane)
        forwardStack.removeAll()
        pane = next
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(pane)
        pane = previous
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(pane)
        pane = next
    }
}

struct SettingsView: View {
    @ObservedObject var manager: PanelManager
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(navigation: navigation)
                .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 260)
        } detail: {
            detail
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button("Back", systemImage: "chevron.left") {
                            navigation.goBack()
                        }
                        .disabled(navigation.backStack.isEmpty)
                        .help("Show the previous section")
                        Button("Forward", systemImage: "chevron.right") {
                            navigation.goForward()
                        }
                        .disabled(navigation.forwardStack.isEmpty)
                        .help("Show the next section")
                    }
                }
        }
        // System Settings' sidebar is always there; there is nothing to hide
        // it for.
        .toolbar(removing: .sidebarToggle)
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.pane {
        case .general: GeneralSettingsPane(manager: manager)
        case .streaming: StreamingSettingsPane(manager: manager)
        case .wifiNetworks: WifiSettingsPane(manager: manager)
        }
    }
}

/// The sidebar: the search field, then one row per pane.
struct SettingsSidebar: View {
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        List(selection: Binding(
            get: { Optional(navigation.pane) },
            set: { if let pane = $0 { navigation.show(pane) } })
        ) {
            // A row of the list rather than an overlay or inset on it: the
            // sidebar's scroll area swallows those (see `ManagerView`), and a
            // row always draws. It carries no tag, so it is never selected.
            SettingsSearchField(text: $navigation.query)
                .listRowSeparator(.hidden)
                .padding(.bottom, 6)
            ForEach(navigation.visiblePanes) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    SettingsPaneIcon(pane: pane, size: 22)
                }
                .tag(pane)
            }
            if navigation.visiblePanes.isEmpty {
                Text("No Results")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
        }
        .listStyle(.sidebar)
    }
}

/// System Settings' rounded, tinted square behind a white glyph.
struct SettingsPaneIcon: View {
    let pane: SettingsPane
    var size: CGFloat

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                pane.tint.gradient,
                in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The sidebar's search field, drawn the way System Settings draws its own.
struct SettingsSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search settings")
            if !text.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") {
                    text = ""
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

/// The card at the top of a pane: its icon, its name and what it is for, as
/// System Settings opens each of its own panes.
private struct SettingsPaneHeader: View {
    let pane: SettingsPane

    var body: some View {
        Section {
            HStack(spacing: 14) {
                SettingsPaneIcon(pane: pane, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.title)
                        .font(.title3.weight(.semibold))
                    Text(pane.summary)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// What every pane's form shares.
private struct SettingsForm<Content: View>: View {
    let pane: SettingsPane
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            SettingsPaneHeader(pane: pane)
            content
        }
        .formStyle(.grouped)
        // Every message in here - errors above all - can be selected and
        // copied. Set once at the root, so a message added later cannot be
        // the one that forgot.
        .textSelection(.enabled)
        .labeledContentStyle(.labelColumn)
    }
}

// MARK: - Panes

/// Settings take effect as they are made, as System Settings' do. Each
/// change goes through `PanelManager.updateSettings`, which keeps the live
/// preset order whatever the copy it is handed says.
@MainActor
private func change(_ manager: PanelManager, _ edit: (inout SenderSettings) -> Void) {
    var updated = manager.settings
    edit(&updated)
    manager.updateSettings(updated)
}

private struct GeneralSettingsPane: View {
    @ObservedObject var manager: PanelManager

    var body: some View {
        SettingsForm(pane: .general) {
            Section {
                Picker("Sort devices by", selection: Binding(
                    get: { manager.settings.deviceListSortOrder },
                    set: { manager.updateDeviceListSortOrder($0) })
                ) {
                    ForEach(DeviceListSortOrder.allCases, id: \.self) { order in
                        Text(order.sidebarTitle).tag(order)
                    }
                }
            } header: {
                Text("Device List")
            } footer: {
                Text("The same choice as the sort button under the device list.")
            }

            Section {
                LabeledContent("Identify for") {
                    // The number beside a label-less stepper, as the display
                    // page's brightness presets do. A stepper carrying its own
                    // label is laid out as a whole form row inside the value
                    // column, which put its arrows past the window's edge.
                    HStack(spacing: 8) {
                        Text("\(manager.settings.identifySeconds) seconds")
                            .monospacedDigit()
                            // Read out as the stepper's value instead.
                            .accessibilityHidden(true)
                        Stepper(
                            "Identify duration in seconds",
                            value: Binding(
                                get: { manager.settings.identifySeconds },
                                set: { seconds in
                                    change(manager) { $0.identifySeconds = seconds }
                                }),
                            in: SenderSettings.identifyRange)
                            .labelsHidden()
                            .accessibilityValue(
                                "\(manager.settings.identifySeconds) seconds")
                    }
                }
            } header: {
                Text("Identify")
            } footer: {
                Text("How long Identify lights the device's LED.")
            }
        }
    }
}

private struct StreamingSettingsPane: View {
    @ObservedObject var manager: PanelManager

    /// The sliders' positions. Held here and applied once a drag settles,
    /// because each change restarts every panel's capture and should not
    /// happen at every value the thumb passes.
    @State private var fps = Double(SenderSettings.defaultFps)
    @State private var spacing = 200.0

    private var settledFPS: Int { Int(fps.rounded()) }
    private var settledSpacing: UInt32 { UInt32(spacing.rounded()) }

    var body: some View {
        SettingsForm(pane: .streaming) {
            Section {
                LabeledContent("Frame rate") {
                    HStack(spacing: 10) {
                        // No `step:` on any slider here. macOS draws a tick per
                        // step, and these ranges are wide enough (55 frame
                        // rates, 238 pacing values) that the ticks merge into a
                        // solid rule under the control. The values round.
                        Slider(
                            value: $fps,
                            in: Double(SenderSettings.fpsRange.lowerBound)
                                ... Double(SenderSettings.fpsRange.upperBound),
                            onEditingChanged: { if !$0 { commitSliders() } })
                        .frame(maxWidth: 240)
                        .accessibilityLabel("Frame rate")
                        Text("\(settledFPS) fps")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .trailing)
                    }
                }
            } header: {
                Text("Frame Rate")
            } footer: {
                Text("The device's SPI bus and WiFi link set the real ceiling, not the Mac. Changing this restarts capture.")
            }

            Section {
                Toggle("Tune automatically", isOn: Binding(
                    get: { manager.settings.adaptivePacing },
                    set: { on in change(manager) { $0.adaptivePacing = on } }))
                LabeledContent("Packet pacing") {
                    HStack(spacing: 10) {
                        Slider(
                            value: $spacing,
                            in: Double(SenderSettings.spacingRange.lowerBound)
                                ... Double(SenderSettings.spacingRange.upperBound),
                            onEditingChanged: { if !$0 { commitSliders() } })
                        .frame(maxWidth: 240)
                        .disabled(manager.settings.adaptivePacing)
                        .accessibilityLabel("Packet pacing")
                        Text("\(settledSpacing) µs")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .trailing)
                    }
                }
            } header: {
                Text("Pacing")
            } footer: {
                Text("Sleep between packet chunks. Longer means fewer frames dropped by the device and a lower peak rate. Automatic tuning follows the device's reported drop rate.")
            }

            Section {
                Picker("Compression", selection: Binding(
                    get: { manager.settings.tileQuality },
                    set: { policy in change(manager) { $0.tileQuality = policy } })
                ) {
                    Text("Lossless only").tag(TileLossyPolicy.losslessOnly)
                    Text("Automatic").tag(TileLossyPolicy.auto)
                    Text("Aggressive").tag(TileLossyPolicy.aggressive)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Tile compression")
            } header: {
                Text("Tile quality")
            } footer: {
                Text("Devices streaming the tile protocol can compress busy regions 4:1 with slight loss, like a high-quality JPEG. Automatic keeps flat colors and gradients pixel-perfect and compresses only textured content; Aggressive compresses whenever it is smaller; Lossless never does, trading frame rate on photos and video. Other devices are unaffected.")
            }

            Section {
                HStack {
                    Spacer()
                    // Only what this pane shows. The display list's order and
                    // the saved networks are not streaming settings.
                    Button("Restore Defaults") {
                        let defaults = SenderSettings()
                        // The sliders first, so a position still waiting to
                        // be applied cannot land after the reset.
                        fps = Double(defaults.fps)
                        spacing = Double(defaults.spacingMicros)
                        change(manager) {
                            $0.fps = defaults.fps
                            $0.spacingMicros = defaults.spacingMicros
                            $0.adaptivePacing = defaults.adaptivePacing
                            $0.tileQuality = defaults.tileQuality
                        }
                    }
                }
            }
        }
        .onAppear {
            fps = Double(manager.settings.fps)
            spacing = Double(manager.settings.spacingMicros)
        }
        // A change made elsewhere - Restore Defaults, AppleScript - moves the
        // sliders too.
        .onChange(of: manager.settings.fps) { _, value in fps = Double(value) }
        .onChange(of: manager.settings.spacingMicros) { _, value in
            spacing = Double(value)
        }
        // Leaving the pane - another section, or closing the window - keeps
        // the position shown rather than dropping a wait still running.
        .onDisappear { commitSliders() }
        // Each new position cancels the wait the last one started, so only a
        // position the thumb rests on is applied. Releasing the thumb, or
        // leaving the pane, applies it at once.
        .task(id: settledFPS) {
            guard settledFPS != manager.settings.fps else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let value = settledFPS
            change(manager) { $0.fps = value }
        }
        .task(id: settledSpacing) {
            guard settledSpacing != manager.settings.spacingMicros else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let value = settledSpacing
            change(manager) { $0.spacingMicros = value }
        }
    }

    private func commitSliders() {
        let (fps, spacing) = (settledFPS, settledSpacing)
        guard fps != manager.settings.fps || spacing != manager.settings.spacingMicros
        else { return }
        change(manager) {
            $0.fps = fps
            $0.spacingMicros = spacing
        }
    }
}

private struct WifiSettingsPane: View {
    @ObservedObject var manager: PanelManager

    var body: some View {
        SettingsForm(pane: .wifiNetworks) {
            WifiNetworksSection(manager: manager)
        }
    }
}

// MARK: - Window

/// Owns the one Settings window. Created by the manager window's controller,
/// which also installs the menu that opens it.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let manager: PanelManager
    let navigation = SettingsNavigation()
    private var window: NSWindow?
    private var titleObserver: AnyCancellable?
    /// Called once the window has closed, so the app can drop back to an
    /// accessory when nothing else is on screen.
    var onClose: () -> Void = {}

    /// The narrowest the window goes: the widest card row, the tile-quality
    /// segments, still fits beside the sidebar. At 640 they ran 12 pt past
    /// the right edge.
    static let minimumContentSize = NSSize(width: 680, height: 420)

    init(manager: PanelManager) {
        self.manager = manager
    }

    func show(_ pane: SettingsPane? = nil) {
        if let pane {
            // A pane a search is hiding would open behind an empty sidebar.
            if !pane.matches(navigation.query) { navigation.query = "" }
            navigation.show(pane)
        }
        NSApp.setActivationPolicy(.regular)
        let window = makeWindowIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindowIfNeeded() -> NSWindow {
        if let window { return window }
        let controller = NSHostingController(
            rootView: SettingsView(manager: manager, navigation: navigation))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 720, height: 620))
        // The window owns the minimum, for the reason `ManagerWindowController`
        // gives: a SwiftUI minimum is reported up with the titlebar added.
        window.contentMinSize = Self.minimumContentSize
        window.styleMask = [
            .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
        ]
        // The section's name beside the back and forward arrows, as in System
        // Settings, with the sidebar running up behind the titlebar.
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("ESPDisplaySender.Settings")
        window.delegate = self
        self.window = window
        // `navigationTitle` does not reach NSWindow.title in a hand-built
        // window; see `ManagerWindowController.observeTitle`.
        titleObserver = navigation.$pane.sink { [weak window] pane in
            window?.title = pane.title
        }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView(manager: PanelManager.preview, navigation: SettingsNavigation())
        .frame(width: 720, height: 620)
}
#endif
