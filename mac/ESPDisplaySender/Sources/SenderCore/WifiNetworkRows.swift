import SwiftUI

/// The two WiFi rows of a display's Network Connection section: what the board
/// itself reports, and which of the app's presets it is on. Both only read.
///
/// The saved networks and their order are app-wide and are edited in Settings,
/// so nothing here edits, applies or copies one; the link opens Settings at
/// WiFi Networks instead.
///
/// Takes plain values rather than the manager, so a test can render it for a
/// given state without a window or a board.
struct WifiNetworkRows: View {
    /// `PanelSnapshot.boardNetworkDescription(asOf:)`.
    let connectedDescription: String
    /// `WifiNetworkRows.presetDescription(_:savedNetworkCount:)`.
    let presetDescription: String
    /// `WifiNetworkRows.skippedDescription(_:savedNetworkNames:)`; the row
    /// shows only when set.
    var skippedDescription: String? = nil
    var onOpenSettings: () -> Void = {}

    var body: some View {
        LabeledContent("Connected WiFi", value: connectedDescription)
            .help("The network this display itself reports")
        LabeledContent("WiFi preset") {
            HStack(spacing: 8) {
                Text(presetDescription)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Button("WiFi Settings…", action: onOpenSettings)
                    .buttonStyle(.link)
                    // A selectable row takes the click as the start of a
                    // selection, and the link would stop opening.
                    .textSelection(.disabled)
                    .help("Saved networks and their order are set once, in "
                        + "Settings, for every display")
            }
        }
        if let skippedDescription {
            // Not "Not copied": Settings labels a network past the tenth slot
            // that way, and those are not the ones named here.
            LabeledContent("Could not copy", value: skippedDescription)
                .help("Saved networks the last USB copy left off this display")
        }
    }

    /// Which preset slot the board is joined through, from what the last
    /// automatic copy read back from it. That copy is the only time the app
    /// reads a board's slots, so with no report yet this says when it will.
    static func presetDescription(
        _ report: WifiPresetSyncReport?, savedNetworkCount: Int
    ) -> String {
        guard let snapshot = report?.snapshot else {
            return savedNetworkCount == 0
                ? "None saved on this Mac"
                : "Not read yet (copied when connected by USB)"
        }
        guard let slot = snapshot.activeSlot else {
            return "None at the last USB copy (joined through its own WiFi setting)"
        }
        let capacity = WifiPresetSlotPlan.capacity
        guard let ssid = snapshot.slots[slot]?.ssid else {
            return "Slot \(slot) of \(capacity), at the last USB copy"
        }
        return "\(ssid) (slot \(slot) of \(capacity), at the last USB copy)"
    }

    /// The saved networks the last copy left out because no credential the
    /// display accepts could be read for them, or nil when there are none.
    /// Settings still lists them and the board's picker does not, and this is
    /// the only place that says why. Names past the tenth slot are named only
    /// when unusable too; one merely past it is what the section footer
    /// already explains.
    ///
    /// The report is replaced only by the next USB copy, and a display is
    /// usually on WiFi alone, so a name no longer saved, or one the board still
    /// holds (the slot it is joined through, which the copy never touches), is
    /// left out here rather than shown stale.
    static func skippedDescription(
        _ report: WifiPresetSyncReport?, savedNetworkNames: [String]
    ) -> String? {
        guard let report else { return nil }
        let onBoard = Set(report.snapshot.slots.values.map(\.ssid))
        let skipped = report.unusable.filter {
            savedNetworkNames.contains($0) && !onBoard.contains($0)
        }
        guard let last = skipped.last else { return nil }
        if skipped.count == 1 {
            return "\(last): no password a display accepts could be read for it "
                + "at the last USB copy. Enter it again in Settings."
        }
        let names = skipped.dropLast().joined(separator: ", ") + " and " + last
        return "\(names): no passwords a display accepts could be read for them "
            + "at the last USB copy. Enter them again in Settings."
    }
}
