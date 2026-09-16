import SenderProtocol
import SwiftUI

struct WifiPresetSheet: View {
    @ObservedObject var manager: PanelManager
    let panel: PanelSnapshot

    @Environment(\.dismiss) private var dismiss
    @State private var slots = [String?](
        repeating: nil, count: ConfigCommands.wifiPresetSlotRange.count)
    @State private var snapshot: WifiPresetSnapshot?
    @State private var isBusy = false
    @State private var failure: WifiConfigUI.ConfigFailure?
    @State private var confirmation: String?

    var body: some View {
        Form {
            Section {
                ForEach(Array(ConfigCommands.wifiPresetSlotRange), id: \.self) { slot in
                    slotRow(slot)
                }
            } header: {
                Text("Device Slots")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Only the first 10 access points are selectable from "
                        + "the device.")
                    Text("Saved networks are copied here automatically, in "
                        + "alphabetical order, whenever this display is "
                        + "connected by USB. Choose from credentials saved in "
                        + "the app's login Keychain; a network can occupy only "
                        + "one device slot. The slot the display is currently "
                        + "joined through is left alone, so a sync never "
                        + "restarts it.")
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
        .labeledContentStyle(.labelColumn)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Button("Reload") {
                    Task { await load() }
                }
                .disabled(isBusy)
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
                Button("Send to Display") {
                    Task { await synchronize() }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy || snapshot == nil)
            }
            .padding(12)
            .glassCard(cornerRadius: 16)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .overlay {
            if isBusy {
                ProgressView(snapshot == nil ? "Reading display..." : "Synchronizing...")
                    .padding(24)
                    .glassCard(cornerRadius: 16)
            }
        }
        .frame(width: 620, height: 650)
        .interactiveDismissDisabled(isBusy)
        .task(id: panel.serviceName) {
            await load()
        }
    }

    private func slotRow(_ slot: Int) -> some View {
        let index = slot - 1
        let deviceOnlySSID = snapshot?.slots[slot]?.ssid
        return LabeledContent {
            HStack(spacing: 10) {
                Picker("Slot \(slot)", selection: slotBinding(index)) {
                    Text("Empty").tag(String?.none)
                    ForEach(manager.savedNetworkNames, id: \.self) { ssid in
                        Text(ssid)
                            .tag(String?.some(ssid))
                            .disabled(isSelectedElsewhere(ssid, except: index))
                    }
                    if let deviceOnlySSID,
                       !manager.savedNetworkNames.contains(deviceOnlySSID) {
                        Text("\(deviceOnlySSID) (on display)")
                            .tag(String?.some(deviceOnlySSID))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 330)
                // The active slot is not editable here for the same reason the
                // automatic sync will not write it: replacing the credential
                // the display is joined through leaves it rejoining a network
                // that is no longer in that slot, and it reboots on the way.
                .disabled(snapshot?.activeSlot == slot)

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

    private func slotBinding(_ index: Int) -> Binding<String?> {
        Binding(
            get: { slots[index] },
            set: {
                slots[index] = $0
                failure = nil
                confirmation = nil
            })
    }

    private func isSelectedElsewhere(_ ssid: String, except index: Int) -> Bool {
        slots.enumerated().contains { $0.offset != index && $0.element == ssid }
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
            slots = ConfigCommands.wifiPresetSlotRange.map {
                loaded.slots[$0]?.ssid
            }
        case .failure(let problem):
            failure = problem
        }
    }

    @MainActor
    private func synchronize() async {
        guard !isBusy else { return }
        isBusy = true
        failure = nil
        confirmation = nil
        defer { isBusy = false }
        switch await manager.syncWifiPresets(
            slots, protectedSlot: snapshot?.activeSlot, for: panel.serviceName)
        {
        case .success(let updated):
            snapshot = updated
            slots = ConfigCommands.wifiPresetSlotRange.map {
                updated.slots[$0]?.ssid
            }
            let count = updated.slots.count
            confirmation = count == 1
                ? "1 WiFi preset is synchronized."
                : "\(count) WiFi presets are synchronized."
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
