import SwiftUI

/// The two WiFi rows of a display's Network Connection section: what the board
/// itself reports, and the Mac's saved networks to apply to it. Kept as two
/// separate rows so the Mac's list can never read as the board's network.
///
/// Takes plain values rather than the manager, so a test can render it for a
/// given state without a window or a board.
struct WifiNetworkRows: View {
    /// `PanelSnapshot.boardNetworkDescription(asOf:)`.
    let connectedDescription: String
    let savedNetworkNames: [String]
    @Binding var selection: String
    let canApply: Bool
    let canEdit: Bool
    var applyHelp = "Apply this saved network"
    var editHelp = "Add or edit saved WiFi credentials"
    var onApply: () -> Void = {}
    var onEdit: () -> Void = {}

    var body: some View {
        LabeledContent("Connected WiFi", value: connectedDescription)
            .help("The network this display itself reports")
        LabeledContent("Saved on this Mac") {
            HStack(spacing: 8) {
                Picker("Saved on this Mac", selection: $selection) {
                    Text("Select a network…").tag("")
                    ForEach(savedNetworkNames, id: \.self) { ssid in
                        Text(ssid).tag(ssid)
                    }
                }
                .labelsHidden()
                .fixedSize()

                Button("Apply", action: onApply)
                    .disabled(selection.isEmpty || !canApply)
                    .help(applyHelp)

                Button(savedNetworkNames.isEmpty ? "Add…" : "Edit…", action: onEdit)
                    .disabled(!canEdit)
                    .help(editHelp)
            }
        }
    }
}
