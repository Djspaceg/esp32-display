import SwiftUI

/// Streaming settings that used to be command-line flags only. The app normally
/// runs as a LaunchAgent, so those flags were unreachable in practice: changing
/// the frame rate meant editing a plist and reloading the agent.
struct SettingsSheet: View {
    @ObservedObject var manager: PanelManager
    @Environment(\.dismiss) private var dismiss

    /// Edited locally and applied on Done, so dragging a slider does not
    /// restart every panel's capture on the way past each intermediate value.
    @State private var draft = SenderSettings()

    var body: some View {
        Form {
            Section {
                LabeledContent("Frame rate") {
                    HStack(spacing: 10) {
                        // No `step:` on any slider here. macOS draws a tick per
                        // step, and these ranges are wide enough (55 frame
                        // rates, 238 pacing values) that the ticks merge into a
                        // solid rule under the control. The bindings round.
                        Slider(
                            value: Binding(
                                get: { Double(draft.fps) },
                                set: { draft.fps = Int($0.rounded()) }),
                            in: Double(SenderSettings.fpsRange.lowerBound)
                                ... Double(SenderSettings.fpsRange.upperBound))
                        .frame(maxWidth: 240)
                        .accessibilityLabel("Frame rate")
                        Text("\(draft.fps) fps")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .trailing)
                    }
                }
            } header: {
                Text("Streaming")
            } footer: {
                Text("The panel's SPI bus and WiFi link set the real ceiling, not the Mac. Changing this restarts capture.")
            }

            Section {
                Toggle("Tune automatically", isOn: $draft.adaptivePacing)
                LabeledContent("Packet pacing") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { Double(draft.spacingMicros) },
                                set: { draft.spacingMicros = UInt32($0.rounded()) }),
                            in: Double(SenderSettings.spacingRange.lowerBound)
                                ... Double(SenderSettings.spacingRange.upperBound))
                        .frame(maxWidth: 240)
                        .disabled(draft.adaptivePacing)
                        .accessibilityLabel("Packet pacing")
                        Text("\(draft.spacingMicros) µs")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .trailing)
                    }
                }
            } header: {
                Text("Pacing")
            } footer: {
                Text("Sleep between packet chunks. Longer means fewer frames dropped by the panel and a lower peak rate. Automatic tuning follows the panel's reported drop rate.")
            }

            Section {
                LabeledContent("Identify for") {
                    Stepper(
                        value: $draft.identifySeconds,
                        in: SenderSettings.identifyRange
                    ) {
                        Text("\(draft.identifySeconds) seconds")
                            .monospacedDigit()
                    }
                    .fixedSize()
                    .accessibilityLabel("Identify duration in seconds")
                }
            } header: {
                Text("Identify")
            } footer: {
                Text("How long Identify lights the panel's LED.")
            }
        }
        .formStyle(.grouped)
        .labeledContentStyle(.labelColumn)
        // A floating glass action bar rather than a row bolted to the bottom of
        // the form, so the content scrolls under it.
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Button("Restore Defaults") { draft = SenderSettings() }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    manager.updateSettings(draft)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .glassCard(cornerRadius: 16)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(width: 560, height: 520)
        .onAppear { draft = manager.settings }
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsSheet(manager: PanelManager.preview)
}
#endif
