import SwiftUI

/// The WiFi row of a display's Network Connection section: a pop-up of the
/// app's saved networks with the board's own network selected, and a link to
/// Settings, where the networks are added and ordered. Choosing one switches
/// the board to it (`PanelManager.switchWifi`).
///
/// Takes a plain `Model` rather than the manager, so a test can render it for
/// a given state without a window or a board.
struct WifiNetworkRows: View {
    let model: Model
    var onChoose: (String) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}

    struct Model: Equatable {
        /// The saved networks, in the order Settings gives them.
        var savedNetworks: [String]
        /// The network the board reports, or nil when it has named none.
        var current: String?
        /// `PanelSnapshot.boardNetworkDescription(asOf:)`: what the board
        /// reports, in words, for the pop-up's help and for an item the
        /// saved list does not have.
        var currentDescription: String
        /// Why choosing cannot switch the board, or nil when it can.
        var unavailableReason: String?
        /// The network a switch is restarting the board onto.
        var switchingTo: String?
        /// A short error to show under the pop-up, or nil.
        var problem: String?

        /// What the board says beyond the name - not answering, not
        /// connected - shown under the pop-up, since the pop-up shows only the
        /// name. nil when there is nothing more to say.
        var statusNote: String? {
            guard switchingTo == nil, let current, savedNetworks.contains(current),
                  currentDescription != current
            else { return nil }
            return currentDescription
        }

        /// Why the pop-up is disabled, shown under it rather than only as a
        /// tooltip: a disabled control that does not say why reads as broken.
        /// nil while it is enabled, and while a switch in progress disables it,
        /// which the spinner already says.
        var disabledNote: String? {
            guard switchingTo == nil else { return nil }
            if let unavailableReason { return unavailableReason }
            if savedNetworks.isEmpty { return "No networks are saved on this Mac yet." }
            return nil
        }

        /// What the pop-up shows as chosen.
        var selection: String? { switchingTo ?? current }

        /// The item for a selection that is not a saved network, which the
        /// pop-up still has to show: a network this Mac has not saved, or
        /// none reported. nil when the selection is a saved network.
        var unsavedItem: String? {
            guard let selection else { return currentDescription }
            if savedNetworks.contains(selection) { return nil }
            return selection == current && currentDescription != selection
                ? currentDescription
                : "\(selection) (not saved)"
        }
    }

    var body: some View {
        LabeledContent("WiFi") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Picker("WiFi", selection: Binding(
                        get: { model.selection },
                        set: { chosen in
                            if let chosen, chosen != model.selection { onChoose(chosen) }
                        })
                    ) {
                        if let unsaved = model.unsavedItem {
                            Text(unsaved).tag(model.selection)
                        }
                        ForEach(model.savedNetworks, id: \.self) { ssid in
                            Text(ssid).tag(Optional(ssid))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(model.unavailableReason != nil
                        || model.switchingTo != nil || model.savedNetworks.isEmpty)
                    .help(model.switchingTo.map { "Restarting onto \"\($0)\"" }
                        ?? model.unavailableReason ?? model.currentDescription)
                    if model.switchingTo != nil {
                        ProgressView()
                            .controlSize(.small)
                            .help("The device is restarting onto this network")
                    }
                    Spacer(minLength: 8)
                    Button("WiFi Settings…", action: onOpenSettings)
                        .buttonStyle(.link)
                        // A selectable row takes the click as the start of a
                        // selection, and the link would stop opening.
                        .textSelection(.disabled)
                        .help("Add a network, or change the saved ones, in Settings")
                }
                if let note = model.statusNote {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let disabled = model.disabledNote {
                    Text(disabled)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let problem = model.problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The row for a board, from what it reports, the saved networks, the
    /// last copy to it and any switch in flight.
    static func model(
        current: String?,
        currentDescription: String,
        savedNetworks: [String],
        report: WifiPresetSyncReport?,
        switchState: WifiSwitchState?,
        unavailableReason: String?
    ) -> Model {
        var switchingTo: String?
        var problem: String?
        switch switchState {
        case .switching(let ssid, _): switchingTo = ssid
        case .failed(let reason): problem = reason
        case nil: problem = unreadableDescription(report, savedNetworkNames: savedNetworks)
        }
        return Model(
            savedNetworks: savedNetworks, current: current,
            currentDescription: currentDescription,
            unavailableReason: unavailableReason, switchingTo: switchingTo,
            problem: problem)
    }

    /// The saved networks the last copy left off this board because their
    /// password could not be read from the Keychain, or nil when there are
    /// none. An empty password is an open network and is copied, so it is
    /// never named here.
    ///
    /// The report is replaced only by the next USB copy, so a name no longer
    /// saved, or one the board still holds (the slot it is joined through,
    /// which the copy never touches), is left out rather than shown stale; and
    /// saving the network again takes it off (`PanelManager.saveNetwork`).
    static func unreadableDescription(
        _ report: WifiPresetSyncReport?, savedNetworkNames: [String]
    ) -> String? {
        guard let report else { return nil }
        let onBoard = Set(report.snapshot.slots.values.map(\.ssid))
        let skipped = report.unusable.filter {
            savedNetworkNames.contains($0) && !onBoard.contains($0)
        }
        guard let last = skipped.last else { return nil }
        if skipped.count == 1 {
            return "The password for \"\(last)\" could not be read from the "
                + "Keychain, so it is not on this device. Enter it again in Settings."
        }
        let names = skipped.dropLast().map { "\"\($0)\"" }.joined(separator: ", ")
            + " and \"\(last)\""
        return "The passwords for \(names) could not be read from the Keychain, "
            + "so they are not on this device. Enter them again in Settings."
    }
}
