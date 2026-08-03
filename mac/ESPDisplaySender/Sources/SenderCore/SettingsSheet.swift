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
        VStack(alignment: .leading, spacing: 16) {
            Text("Streaming")
                .font(.headline)

            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow(alignment: .firstTextBaseline) {
                    Text("Frame rate")
                        .gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: { Double(draft.fps) },
                                    set: { draft.fps = Int($0.rounded()) }),
                                in: Double(SenderSettings.fpsRange.lowerBound)
                                    ... Double(SenderSettings.fpsRange.upperBound),
                                step: 1)
                            .frame(width: 200)
                            .accessibilityLabel("Frame rate")
                            Text("\(draft.fps) fps")
                                .monospacedDigit()
                                .frame(width: 56, alignment: .leading)
                        }
                        Text("The panel's SPI bus and WiFi link set the real ceiling, not the Mac. Changing this restarts capture.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                GridRow(alignment: .firstTextBaseline) {
                    Text("Packet pacing")
                        .gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Tune automatically", isOn: $draft.adaptivePacing)
                            .toggleStyle(.checkbox)
                        HStack(spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: { Double(draft.spacingMicros) },
                                    set: { draft.spacingMicros = UInt32($0.rounded()) }),
                                in: Double(SenderSettings.spacingRange.lowerBound)
                                    ... Double(SenderSettings.spacingRange.upperBound),
                                step: 10)
                            .frame(width: 200)
                            .disabled(draft.adaptivePacing)
                            .accessibilityLabel("Packet pacing")
                            Text("\(draft.spacingMicros) µs")
                                .monospacedDigit()
                                .frame(width: 56, alignment: .leading)
                        }
                        Text("Sleep between packet chunks. Longer means fewer frames dropped by the panel and a lower peak rate. Automatic tuning follows the panel's reported drop rate.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                GridRow(alignment: .firstTextBaseline) {
                    Text("Identify for")
                        .gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Stepper(
                            value: $draft.identifySeconds,
                            in: SenderSettings.identifyRange
                        ) {
                            Text("\(draft.identifySeconds) seconds")
                                .monospacedDigit()
                        }
                        .frame(width: 160)
                        .accessibilityLabel("Identify duration in seconds")
                        Text("How long Identify lights the panel's LED.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button("Restore Defaults") { draft = SenderSettings() }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    manager.updateSettings(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { draft = manager.settings }
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsSheet(manager: PanelManager.preview)
}
#endif
