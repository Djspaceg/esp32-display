import SenderProtocol
import SwiftUI

/// The app's saved WiFi networks and the order they fill every board's ten
/// preset slots: the one place either is edited, in the Settings window's
/// WiFi Networks pane. A board's own page only says which preset it is on and
/// links here; onboarding only chooses one of them.
///
/// Changes take effect at once, as everything in Settings does, and they are
/// Keychain writes - there is no draft of a password to cancel back to.
struct WifiNetworksSection: View {
    @ObservedObject var manager: PanelManager

    /// The network being added (`original` nil) or edited.
    @State private var editor: Editor?
    /// The last Keychain write that failed. Cleared by the next edit to the
    /// form and by any later change that goes through, so it never outlives
    /// the condition it reports.
    @State private var failure: WifiConfigUI.ConfigFailure?
    @State private var pendingRemoval: String?
    /// Which saved networks are open, read from the Keychain when the list
    /// changes rather than on every redraw.
    @State private var openNetworks: Set<String> = []

    struct Editor: Equatable {
        var original: String?
        var ssid = ""
        var password = ""
        var isOpenNetwork = false
    }

    private var slotCount: Int { WifiPresetSlotPlan.capacity }

    var body: some View {
        Section {
            if manager.savedNetworkNames.isEmpty && editor == nil {
                Text("No networks are saved on this Mac yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(manager.savedNetworkNames.enumerated()), id: \.element) {
                index, ssid in
                if editor?.original == ssid {
                    editorRows
                } else {
                    networkRow(ssid, index: index)
                }
            }
            if let editor, editor.original == nil {
                editorRows
            } else if editor == nil {
                Button("Add Network…") {
                    failure = nil
                    editor = Editor()
                }
            }
            if let failure {
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
                + "offers. A display's active network stays in its slot, so a copy "
                + "never restarts it. Passwords are kept in your login Keychain, "
                + "and changes here take effect immediately.")
        }
        // By set, not order: a move changes no credential, so it reads none.
        .task(id: Set(manager.savedNetworkNames)) { reloadOpenNetworks() }
        .onAppear { manager.refreshSavedNetworks() }
        // A change to the list is the Keychain answering again, so a failure
        // reported before it no longer describes the current state.
        .onChange(of: manager.savedNetworkNames) { _, _ in failure = nil }
        .confirmationDialog(
            pendingRemoval.map { "Remove \"\($0)\"?" } ?? "Remove network?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Network", role: .destructive) {
                if let ssid = pendingRemoval {
                    failure = manager.removeSavedNetwork(ssid)
                }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(removalMessage)
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
        LabeledContent {
            HStack(spacing: 8) {
                Text(ssid)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if openNetworks.contains(ssid) {
                    Text("Open")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Move Up", systemImage: "chevron.up") {
                    failure = nil
                    manager.moveSavedNetwork(ssid, by: -1)
                }
                .labelStyle(.iconOnly)
                .disabled(index == 0)
                .help("Move \"\(ssid)\" one slot earlier")
                Button("Move Down", systemImage: "chevron.down") {
                    failure = nil
                    manager.moveSavedNetwork(ssid, by: 1)
                }
                .labelStyle(.iconOnly)
                .disabled(index == manager.savedNetworkNames.count - 1)
                .help("Move \"\(ssid)\" one slot later")
                Button("Edit…") {
                    failure = nil
                    let saved = manager.savedCredential(for: ssid)
                    editor = Editor(
                        original: ssid, ssid: ssid,
                        isOpenNetwork: saved?.isOpenNetwork ?? false)
                }
                // Kept whole: beside a long network name it was the one
                // squeezed, to "E…", where the name can truncate instead.
                .fixedSize()
                .disabled(editor != nil)
                Button("Remove", systemImage: "minus.circle") {
                    pendingRemoval = ssid
                }
                .labelStyle(.iconOnly)
                .help("Remove \"\(ssid)\" from this Mac")
            }
        } label: {
            Text(index < slotCount ? "Slot \(index + 1)" : "Not copied")
                .monospacedDigit()
                .foregroundStyle(index < slotCount ? .primary : .secondary)
                .help(index < slotCount
                    ? "The preset slot this network fills on every display"
                    : "Displays have \(slotCount) preset slots; move this network "
                        + "up to copy it")
        }
    }

    @ViewBuilder
    private var editorRows: some View {
        if let current = editor {
            let isNew = current.original == nil
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
                    failure = nil
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
                failure = nil
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
            failure = problem
            return
        }
        failure = nil
        self.editor = nil
        // An edit can turn a network open or closed without changing the list.
        reloadOpenNetworks()
    }
}
