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
/// button; the footer's plus adds and its minus removes the selected row. The
/// add and edit form is a section of its own below the list, so the list's
/// card keeps its shape while it is open.
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

    /// No "open network" switch: an empty password is an open network
    /// (`SavedWiFiCredential.isOpenNetwork`).
    struct Editor: Equatable {
        var original: String?
        var ssid = ""
        var password = ""
        /// Editing a network whose saved password could not be read. Saving
        /// with the field still empty would make it open, so the form says so.
        var passwordUnreadable = false
    }

    /// `list` and `editing` are for tests: to watch what the footer's buttons
    /// do, and to read the form as it is drawn while open.
    init(manager: PanelManager, list: WifiNetworkList? = nil, editing: Editor? = nil) {
        self.manager = manager
        _list = StateObject(wrappedValue: list ?? WifiNetworkList(manager: manager))
        _editor = State(initialValue: editing)
    }

    private var slotCount: Int { WifiPresetSlotPlan.capacity }
    private static let footerHeight: CGFloat = 28

    /// The rows' height: a fixed height per row, so the card is the same shape
    /// whatever is selected or being dragged, and every row shows - the list
    /// never scrolls inside the page, and a network past the ten slots is in
    /// view to be dragged up.
    private var rowsHeight: CGFloat {
        CGFloat(max(manager.savedNetworkNames.count, 1)) * WifiNetworkTable.rowHeight
    }

    var body: some View {
        attachBehaviour(Section {
            networkList
                .frame(height: rowsHeight + Self.footerHeight)
                .listRowInsets(EdgeInsets())
        } header: {
            Text("Saved Networks")
        } footer: {
            Text("Every device connected by USB receives the first \(slotCount) "
                + "networks, in this order, as the presets its own picker "
                + "offers; drag a network to change its slot. A device's active "
                + "network stays in its slot, so a copy never restarts it. "
                + "Passwords are kept in your login Keychain, and changes here "
                + "take effect immediately.")
        })
        if let current = editor {
            Section {
                editorRows(current)
                if let failure = list.failure { problemRows(failure) }
            } header: {
                Text(current.original == nil ? "New Network" : "Network Details")
            }
        } else if let failure = list.failure {
            Section { problemRows(failure) }
        }
        if !syncIssues.isEmpty {
            Section {
                ForEach(syncIssues, id: \.self) { detail in
                    Label(detail, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// The list's own behaviour, on the list's section only, so it is attached
    /// once rather than to every section this view returns.
    private func attachBehaviour<Content: View>(_ content: Content) -> some View {
        content
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
    /// `DisplayListFooter`).
    private var networkList: some View {
        WifiNetworkTable(
            rows: manager.savedNetworkNames.map {
                WifiNetworkTable.Row(ssid: $0, isOpen: openNetworks.contains($0))
            },
            selection: $list.selection,
            editingDisabled: editor != nil,
            onMove: { list.move(fromOffsets: $0, toOffset: $1) },
            onEdit: { beginEdit($0) },
            onDelete: { list.requestRemoval() })
        .frame(height: rowsHeight)
        .frame(maxHeight: .infinity, alignment: .top)
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
                + "copied to the devices afterwards and each keeps the presets "
                + "it already holds, this one included."
        }
        return keychain + " and clears the network from each device's presets "
            + "the next time it is connected by USB. A device joined through it "
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

    private func beginAdd() {
        list.failure = nil
        editor = Editor()
    }

    private func beginEdit(_ ssid: String) {
        list.failure = nil
        list.selection = ssid
        // The saved password fills the field, so Save without a change keeps
        // it. One that cannot be read leaves the field empty, and the form
        // says that saving it empty would make the network open.
        editor = Self.editor(for: ssid, saved: manager.savedCredential(for: ssid))
    }

    /// The form for editing `ssid`, whose saved credential reads as `saved`:
    /// nil when its password could not be read.
    static func editor(for ssid: String, saved: SavedWiFiCredential?) -> Editor {
        Editor(
            original: ssid, ssid: ssid, password: saved?.password ?? "",
            passwordUnreadable: saved == nil)
    }

    @ViewBuilder
    private func editorRows(_ current: Editor) -> some View {
        let isNew = current.original == nil
        if isNew {
            TextField("Network name (SSID)", text: editorBinding(\.ssid))
                .onSubmit { if canCommit(current) { commit(current) } }
        } else {
            LabeledContent("Network", value: current.original ?? "")
        }
        SecureField("Password", text: editorBinding(\.password),
                    prompt: Text("None for an open network"))
            .onSubmit { if canCommit(current) { commit(current) } }
        // Derived from the fields on every change, so it disappears the
        // moment what was typed becomes valid.
        if let problem = typingProblem(current) {
            Text(problem)
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if current.passwordUnreadable, current.password.isEmpty {
            Text("The saved password could not be read from your login Keychain, "
                + "so it is not shown here. Enter it again to save. To make this "
                + "an open network, remove it and add it with no password.")
                .font(.callout)
                .foregroundStyle(.orange)
        } else {
            Text(current.password.isEmpty
                ? "With no password, this is saved as an open network."
                : "Kept in your login Keychain.")
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

    /// What to say while typing, or nil. An empty name or password is simply
    /// not finished yet, so it only disables the button rather than reading
    /// as an error.
    private func typingProblem(_ editor: Editor) -> String? {
        let ssid = editor.ssid.trimmingCharacters(in: .whitespaces)
        if ssid.isEmpty { return nil }
        return PanelManager.savedNetworkProblem(
            ssid: ssid, password: editor.password)?.message
    }

    private func canCommit(_ editor: Editor) -> Bool { Self.canCommit(editor) }

    /// Whether the form can be saved as filled in. A password that could not
    /// be read is never saved as an open network by an empty field: that is
    /// one press of Return away, and the real password would be lost.
    static func canCommit(_ editor: Editor) -> Bool {
        if editor.passwordUnreadable && editor.password.isEmpty { return false }
        return PanelManager.savedNetworkProblem(
            ssid: editor.ssid.trimmingCharacters(in: .whitespaces),
            password: editor.password) == nil
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
            ssid: editor.ssid, password: editor.password) {
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
