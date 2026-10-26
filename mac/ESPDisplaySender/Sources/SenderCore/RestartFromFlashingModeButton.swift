import SwiftUI

/// Offered beside a failure that found the board in flashing mode
/// (`OperationOutcome.restartPort`): restarts it into its firmware over USB,
/// writing nothing, and hands back what happened. `isRestarting` belongs to
/// the sheet, so its other USB actions stay off while the restart runs.
struct RestartFromFlashingModeButton: View {
    @ObservedObject var manager: PanelManager
    let port: String
    let hardwareID: String
    let expectedGeneration: Int?
    @Binding var isRestarting: Bool
    let onDone: (OperationOutcome) -> Void

    var body: some View {
        Button {
            isRestarting = true
            Task {
                let outcome = await manager.restartBoardFromFlashingMode(
                    port: port, hardwareID: hardwareID, expectedGeneration: expectedGeneration)
                isRestarting = false
                onDone(outcome)
            }
        } label: {
            HStack(spacing: 6) {
                if isRestarting { ProgressView().controlSize(.small) }
                Text(isRestarting ? "Restarting the board" : "Restart the board")
            }
        }
        .disabled(isRestarting)
        .help("Takes the board out of flashing mode and back to its firmware. "
            + "Nothing is written.")
    }
}
