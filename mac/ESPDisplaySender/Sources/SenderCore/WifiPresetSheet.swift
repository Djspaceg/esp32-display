import SenderProtocol
import SwiftUI

/// What one display holds in its ten preset slots, read over USB.
///
/// Read-only on purpose. The saved networks and their order are edited once,
/// for every display, in Settings (`WifiNetworksSection`); this sheet shows
/// what reached this display and can copy the saved list to it now, through
/// the same copy the automatic sync makes.
struct WifiPresetSheet: View {
    @ObservedObject var manager: PanelManager
    let panel: PanelSnapshot

    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: WifiPresetSnapshot?
    @State private var isBusy = false
    /// The last read or copy that failed. Cleared when the next one starts and
    /// replaced by its result, so it is never shown over a newer answer.
    @State private var failure: WifiConfigUI.ConfigFailure?
    @State private var confirmation: String?

    var body: some View {
        Form {
            Section {
                ForEach(Array(ConfigCommands.wifiPresetSlotRange), id: \.self) { slot in
                    slotRow(slot)
                }
            } header: {
                Text("On This Display")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The app's saved networks are copied here automatically, "
                        + "in the order set in Settings, whenever this display is "
                        + "connected by USB. Only the first 10 are selectable from "
                        + "the device. The slot the display is currently joined "
                        + "through is left alone, so a copy never restarts it.")
                    if let omitted = manager.wifiPresetSyncReport(
                        for: panel.serviceName)?.omitted, !omitted.isEmpty {
                        Text("Beyond the first 10, these saved networks are not "
                            + "on the display: " + omitted.joined(separator: ", "))
                    }
                }
            }

            if let snapshot {
                Section("On-device Access") {
                    if snapshot.localSelectorAvailable {
                        Label(
                            "This display can open the preset picker from its signal screen.",
                            systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label(
                            "This display stores presets, but has no local button or touch "
                                + "path for opening the picker.",
                            systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    if snapshot.activeSlot == nil {
                        Text("The current connection uses the display's direct WiFi credential.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let failure {
                Section {
                    Label(failure.title, systemImage: "exclamationmark.triangle.fill")
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                    Text(failure.message)
                        .foregroundStyle(.secondary)
                }
            } else if let confirmation {
                Section {
                    Label(confirmation, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
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
            HStack(spacing: 10) {
                Button("Reload") {
                    Task { await load() }
                }
                .disabled(isBusy)
                Button("Edit Saved Networks…") {
                    dismiss()
                    // The manager window owns the Settings sheet; this one has
                    // to be gone before it can open.
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .espDisplayShowSettings, object: nil)
                    }
                }
                .disabled(isBusy)
                .help("Saved networks and their order are set once, in Settings, "
                    + "for every display")
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
                Button("Copy Now") {
                    Task { await copy() }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy || snapshot == nil || manager.savedNetworkNames.isEmpty)
                .help("Copy the saved networks to this display now")
            }
            .padding(12)
            .glassCard(cornerRadius: 16)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .overlay {
            if isBusy {
                ProgressView(snapshot == nil ? "Reading display..." : "Copying...")
                    .padding(24)
                    .glassCard(cornerRadius: 16)
            }
        }
        .frame(width: 620, height: 650)
        .interactiveDismissDisabled(isBusy)
        .task(id: panel.serviceName) {
            await load()
        }
        // A copy the automatic sync finished is a fresh reading of this
        // display, and the board answering is what resolves an earlier read
        // failure, so it replaces both rather than waiting for Reload.
        .onChange(of: manager.wifiPresetSyncReport(for: panel.serviceName)?.snapshot) {
            _, fresh in
            guard let fresh, !isBusy else { return }
            snapshot = fresh
            failure = nil
        }
    }

    private func slotRow(_ slot: Int) -> some View {
        let ssid = snapshot?.slots[slot]?.ssid
        return LabeledContent {
            HStack(spacing: 10) {
                Text(ssid ?? (snapshot == nil ? "—" : "Empty"))
                    .foregroundStyle(ssid == nil ? .secondary : .primary)
                if let ssid, !manager.savedNetworkNames.contains(ssid) {
                    Text("(only on display)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if snapshot?.activeSlot == slot {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        } label: {
            Text("Slot \(slot)")
                .monospacedDigit()
        }
    }

    @MainActor
    private func load() async {
        guard !isBusy else { return }
        isBusy = true
        failure = nil
        confirmation = nil
        defer { isBusy = false }
        switch await manager.wifiPresets(for: panel.serviceName) {
        case .success(let loaded):
            snapshot = loaded
        case .failure(let problem):
            failure = problem
        }
    }

    @MainActor
    private func copy() async {
        guard !isBusy else { return }
        isBusy = true
        failure = nil
        confirmation = nil
        defer { isBusy = false }
        switch await manager.copySavedWifiPresets(to: panel.serviceName) {
        case .success(let report):
            snapshot = report.snapshot
            let count = report.storedCount
            confirmation = (count == 1
                ? "1 WiFi preset is on the display."
                : "\(count) WiFi presets are on the display.")
                + (report.unusable.isEmpty ? "" : " Skipped, because the saved "
                    + "credential is unusable: "
                    + report.unusable.joined(separator: ", ") + ".")
        case .failure(let problem):
            failure = problem
        }
    }
}

#if DEBUG
#Preview("WiFi Presets") {
    WifiPresetSheet(
        manager: PanelManager.preview,
        panel: PanelManager.preview.panels[0])
}
#endif
