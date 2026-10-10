import SenderProtocol
import SwiftUI

/// The saved-network list's selection and the removal it asks for, kept out
/// of the view so a test can drive what the footer's buttons do.
@MainActor
final class WifiNetworkList: ObservableObject {
    let manager: PanelManager
    /// The selected row, by SSID. What the footer's minus removes.
    @Published var selection: String?
    /// The network the confirmation dialog is asking about.
    @Published var pendingRemoval: String?
    /// The last Keychain write that failed. Cleared by the next edit to the
    /// form and by any later change that goes through, so it never outlives
    /// the condition it reports.
    @Published var failure: WifiConfigUI.ConfigFailure?
    /// The add or edit form is open. Nothing is removed under it: removing
    /// the network being edited and then saving would quietly add it back,
    /// at the end of the order.
    @Published var isEditing = false

    init(manager: PanelManager) {
        self.manager = manager
    }

    var canRemove: Bool {
        !isEditing && (selection.map(manager.savedNetworkNames.contains) ?? false)
    }

    /// The footer's minus, or the Delete key: ask before removing the
    /// selected network, as removal always has.
    func requestRemoval() {
        guard canRemove else { return }
        pendingRemoval = selection
    }

    /// `ssid` is the network the dialog was presented for, passed in rather
    /// than read back, so the dialog clearing its binding first cannot turn
    /// the confirmation into nothing.
    func confirmRemoval(_ ssid: String? = nil) {
        guard let ssid = ssid ?? pendingRemoval else { return }
        pendingRemoval = nil
        failure = manager.removeSavedNetwork(ssid)
        if failure == nil, selection == ssid { selection = nil }
    }

    func cancelRemoval() {
        pendingRemoval = nil
    }

    /// A drag-and-drop reorder, which moves networks between every board's
    /// slots.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        failure = nil
        manager.moveSavedNetworks(fromOffsets: source, toOffset: destination)
    }

    /// The Keychain answered again, so a failure reported before no longer
    /// describes the current state, and a selection it took away is dropped.
    func namesChanged(_ names: [String]) {
        failure = nil
        if let selected = selection, !names.contains(selected) { selection = nil }
    }
}

/// The app's saved WiFi networks and the order they fill every board's ten
/// preset slots: the one place either is edited, in the Settings window's
/// WiFi Networks pane. A board's own page only says which preset it is on and
/// links here; onboarding only chooses one of them.
///
/// A macOS list: rows are selected, dragged to reorder, and each has one edit
/// button; the footer's plus adds and its minus removes the selected row.
///
/// Changes take effect at once, as everything in Settings does, and they are
/// Keychain writes - there is no draft of a password to cancel back to.
struct WifiNetworksSection: View {
    @ObservedObject var manager: PanelManager
    @StateObject private var list: WifiNetworkList

    /// The network being added (`original` nil) or edited.
    @State private var editor: Editor?
    /// Which saved networks are open, read from the Keychain when the list
    /// changes rather than on every redraw.
    @State private var openNetworks: Set<String> = []

    struct Editor: Equatable {
        var original: String?
        var ssid = ""
        var password = ""
        var isOpenNetwork = false
    }

    /// `list` is for tests, to watch what the footer's buttons do.
    init(manager: PanelManager, list: WifiNetworkList? = nil) {
        self.manager = manager
        _list = StateObject(wrappedValue: list ?? WifiNetworkList(manager: manager))
    }

    private var slotCount: Int { WifiPresetSlotPlan.capacity }
    private static let rowHeight: CGFloat = 28
    private static let footerHeight: CGFloat = 28
    /// The rows' height as the list itself measured it, so every row is
    /// shown whatever height macOS gives one: the list never scrolls inside
    /// the page, a network beyond the ten slots is in view to be dragged up,
    /// and the footer never covers a row. Estimated until the first layout.
    @State private var measuredRowsHeight: CGFloat?

    private var rowsHeight: CGFloat {
        measuredRowsHeight
            ?? CGFloat(max(manager.savedNetworkNames.count, 1)) * Self.rowHeight
    }

    var body: some View {
        Section {
            networkList
                .frame(height: rowsHeight + Self.footerHeight)
                .listRowInsets(EdgeInsets())
            if editor != nil {
                editorRows
            }
            if let failure = list.failure {
                problemRows(failure)
            }
            ForEach(syncIssues, id: \.self) { detail in
                Label(detail, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Saved Networks")
        } footer: {
            Text("Every display connected by USB receives the first \(slotCount) "
                + "networks, in this order, as the presets its on-device picker "
                + "offers; drag a network to change its slot. A display's active "
                + "network stays in its slot, so a copy never restarts it. "
                + "Passwords are kept in your login Keychain, and changes here "
                + "take effect immediately.")
        }
        // By set, not order: a move changes no credential, so it reads none.
        .task(id: Set(manager.savedNetworkNames)) { reloadOpenNetworks() }
        .onAppear { manager.refreshSavedNetworks() }
        .onChange(of: manager.savedNetworkNames) { _, names in
            list.namesChanged(names)
            // The network being edited went away some other way.
            if let original = editor?.original, !names.contains(original) {
                editor = nil
            }
        }
        .onChange(of: editor != nil, initial: true) { _, open in
            list.isEditing = open
        }
        .confirmationDialog(
            list.pendingRemoval.map { "Remove \"\($0)\"?" } ?? "Remove network?",
            isPresented: Binding(
                get: { list.pendingRemoval != nil },
                set: { if !$0 { list.cancelRemoval() } }),
            titleVisibility: .visible,
            presenting: list.pendingRemoval
        ) { ssid in
            Button("Remove Network", role: .destructive) { list.confirmRemoval(ssid) }
            Button("Cancel", role: .cancel) { list.cancelRemoval() }
        } message: { _ in
            Text(removalMessage)
        }
    }

    /// The rows, and the plus and minus under them. The footer is an overlay
    /// on the space the frame leaves below the rows - the placement the
    /// display list's own footer needed to render at all (see
    /// `DisplayListFooter`). A row of the form would do too, but takes a full
    /// row's height.
    private var networkList: some View {
        List(selection: $list.selection) {
            ForEach(Array(manager.savedNetworkNames.enumerated()), id: \.element) {
                index, ssid in
                networkRow(ssid, index: index)
                    .tag(ssid)
            }
            .onMove { list.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, Self.rowHeight)
        // A selectable row takes the click as the start of a text selection,
        // and the row would stop selecting and dragging.
        .textSelection(.disabled)
        .scrollDisabled(true)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: {
            _, height in
            if height > 0 { measuredRowsHeight = height }
        }
        .onDeleteCommand { list.requestRemoval() }
        .overlay {
            if manager.savedNetworkNames.isEmpty {
                Text("No networks are saved on this Mac yet.")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, Self.footerHeight)
            }
        }
        .overlay(alignment: .bottom) { listFooter }
    }

    private var listFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 2) {
                Button("Add Network…", systemImage: "plus") { beginAdd() }
                    .disabled(editor != nil)
                    .help("Add a network to this Mac")
                    .accessibilityLabel("Add network")
                Button("Remove", systemImage: "minus") { list.requestRemoval() }
                    .disabled(!list.canRemove || editor != nil)
                    .help(list.canRemove
                        ? "Remove the selected network from this Mac"
                        : "Select a network to remove")
                    .accessibilityLabel("Remove selected network")
                Spacer(minLength: 0)
            }
            .labelStyle(FooterGlyphLabelStyle())
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .frame(height: Self.footerHeight - 1)
        }
    }

    /// What removing a network does to the displays. Removing the last one is
    /// different: with nothing saved the copy does nothing at all, so the
    /// displays keep what they hold rather than being erased.
    private var removalMessage: String {
        let keychain = "This deletes the saved password from your login Keychain"
        if manager.savedNetworkNames.count <= 1 {
            return keychain + ". It is the last saved network, so nothing is "
                + "copied to the displays afterwards and each keeps the presets "
                + "it already holds, this one included."
        }
        return keychain + " and clears the network from each display's presets "
            + "the next time it is connected by USB. A display joined through it "
            + "keeps it."
    }

    /// The preset-sync problems behind the manager window's banner, repeated
    /// here because that banner is in another window. They resolve on their
    /// own the same way, when a later copy succeeds.
    private var syncIssues: [String] {
        manager.issues.filter { $0.issue == .wifiPresetSync }
            .flatMap { $0.detail.components(separatedBy: "\n") }
            .filter { !$0.isEmpty }
    }

    private func networkRow(_ ssid: String, index: Int) -> some View {
        HStack(spacing: 10) {
            // Words rather than a dash past the tenth row, which beside the
            // footer's minus would read as a control.
            Text(index < slotCount ? "Slot \(index + 1)" : "Not copied")
                .font(index < slotCount ? .body : .caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
                .help(index < slotCount
                    ? "The preset slot this network fills on every display"
                    : "Displays have \(slotCount) preset slots; drag this network "
                        + "up to copy it")
            // The name is the one thing in the row that gives way, by
            // truncating in the middle; everything after it keeps its size.
            Text(ssid)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(index < slotCount ? .primary : .secondary)
            if openNetworks.contains(ssid) {
                Text("Open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Spacer(minLength: 8)
            Button("Edit…", systemImage: "pencil") { beginEdit(ssid) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .fixedSize()
                .disabled(editor != nil)
                .help("Edit \"\(ssid)\"")
                .accessibilityLabel("Edit \(ssid)")
        }
        .contentShape(Rectangle())
    }

    private func beginAdd() {
        list.failure = nil
        editor = Editor()
    }

    private func beginEdit(_ ssid: String) {
        list.failure = nil
        list.selection = ssid
        let saved = manager.savedCredential(for: ssid)
        editor = Editor(
            original: ssid, ssid: ssid,
            isOpenNetwork: saved?.isOpenNetwork ?? false)
    }

    @ViewBuilder
    private var editorRows: some View {
        if let current = editor {
            let isNew = current.original == nil
            Text(isNew ? "New Network" : "Edit \"\(current.original ?? "")\"")
                .fontWeight(.semibold)
            TextField("Network name (SSID)", text: editorBinding(\.ssid))
                .disabled(!isNew)
                .onSubmit { if canCommit(current) { commit(current) } }
            Toggle("Open network (no password)", isOn: editorBinding(\.isOpenNetwork))
            if !current.isOpenNetwork {
                SecureField(
                    isNew ? "Password" : "New password",
                    text: editorBinding(\.password))
                    .onSubmit { if canCommit(current) { commit(current) } }
            }
            // Derived from the fields on every change, so it disappears the
            // moment what was typed becomes valid.
            if let problem = typingProblem(current) {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    editor = nil
                    list.failure = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { commit(current) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit(current))
            }
        }
    }

    /// What to say while typing, or nil. An empty name or password is simply
    /// not finished yet, so it only disables the button rather than reading
    /// as an error.
    private func typingProblem(_ editor: Editor) -> String? {
        let ssid = editor.ssid.trimmingCharacters(in: .whitespaces)
        if ssid.isEmpty || (!editor.isOpenNetwork && editor.password.isEmpty) {
            return nil
        }
        return PanelManager.savedNetworkProblem(
            ssid: ssid, password: editor.password,
            isOpenNetwork: editor.isOpenNetwork)?.message
    }

    private func canCommit(_ editor: Editor) -> Bool {
        PanelManager.savedNetworkProblem(
            ssid: editor.ssid.trimmingCharacters(in: .whitespaces),
            password: editor.password,
            isOpenNetwork: editor.isOpenNetwork) == nil
    }

    private func problemRows(_ failure: WifiConfigUI.ConfigFailure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(failure.title, systemImage: "exclamationmark.triangle.fill")
                .fontWeight(.semibold)
                .foregroundStyle(.red)
            Text(failure.message)
                .foregroundStyle(.secondary)
        }
    }

    private func editorBinding<Value>(
        _ keyPath: WritableKeyPath<Editor, Value>
    ) -> Binding<Value> {
        Binding(
            get: { editor?[keyPath: keyPath] ?? Editor()[keyPath: keyPath] },
            set: {
                editor?[keyPath: keyPath] = $0
                list.failure = nil
            })
    }

    private func reloadOpenNetworks() {
        openNetworks = Set(manager.savedNetworkNames.filter {
            manager.savedCredential(for: $0)?.isOpenNetwork == true
        })
    }

    private func commit(_ editor: Editor) {
        if let problem = manager.saveNetwork(
            ssid: editor.ssid, password: editor.password,
            isOpenNetwork: editor.isOpenNetwork) {
            list.failure = problem
            return
        }
        list.failure = nil
        if editor.original == nil {
            list.selection = editor.ssid.trimmingCharacters(in: .whitespaces)
        }
        self.editor = nil
        // An edit can turn a network open or closed without changing the list.
        reloadOpenNetworks()
    }
}

/// The footer's plus and minus: a bare glyph in a fixed hit area, as macOS
/// list footers draw them. The style drops the button's title, so each button
/// carries its own `accessibilityLabel` for VoiceOver.
private struct FooterGlyphLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.icon
            .frame(width: 24, height: 20)
            .contentShape(Rectangle())
    }
}
