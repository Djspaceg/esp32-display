import Combine
import SenderProtocol
import SwiftUI

/// One repair run: catch the board, then offer the real firmware for it.
@MainActor
final class UsbRepairModel: ObservableObject {
    enum Stage: Equatable {
        case choosing
        case catching
        case rescued(UsbRescuer.RescuedBoard)
        case clearing(UsbRescuer.RescuedBoard)
        case installing(UsbRescuer.RescuedBoard)
        case installed(port: String)
        /// The board is kept when the rescue image got on, so the install can
        /// be tried again without catching it twice.
        case failed(UsbRescuer.RescuedBoard?)
    }

    @Published var family: UsbRescue.Family? {
        didSet { if family != oldValue { carrier = nil } }
    }
    /// The board the user names, for a family whose image drives carrier pins
    /// (P4). Nothing is written until it is one of that family's boards.
    @Published var carrier: String?

    struct CarrierChoice: Identifiable, Equatable {
        let profile: String
        let name: String
        var id: String { profile }
    }

    var needsCarrier: Bool {
        guard let family else { return false }
        return GeneratedBoardCatalog.carrierEvidenceFamilies.contains(family.key)
    }

    /// The chosen family's boards, in catalog order, named as printed on them.
    var carrierChoices: [CarrierChoice] {
        guard let family, needsCarrier,
              let profiles = GeneratedBoardCatalog.expected[family.key]?.profiles
        else { return [] }
        return profiles.map {
            CarrierChoice(
                profile: $0,
                name: GeneratedBoardCatalog.hardwareByProfile[$0]?.first ?? $0)
        }
    }

    var canStart: Bool {
        guard family != nil, !isRunning else { return false }
        guard needsCarrier else { return true }
        return carrierChoices.contains { $0.profile == carrier }
    }
    /// Set by the run itself; internal only so a capture can show a stage.
    @Published internal(set) var stage: Stage = .choosing
    /// What Install would write, or why nothing can be.
    @Published private(set) var installOffer: String?
    @Published private(set) var installProblem: String?
    let monitor = UsbFlashMonitor(flow: .repair)
    private var work: Task<Void, Never>?
    private var monitorChanges: AnyCancellable?
    /// The manager whose background probes this repair holds, from Start
    /// until Start Over or close: between the stages too, so no CFGSHOW of the
    /// app's own lands on the board while the next stage opens it.
    private weak var holding: PanelManager?

    init(family: UsbRescue.Family?) {
        self.family = family
        // Whether Stop is offered depends on the phase, so a phase change must
        // redraw the action bar too.
        monitorChanges = monitor.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var isRunning: Bool {
        switch stage {
        case .catching, .clearing, .installing: return true
        default: return false
        }
    }

    var board: UsbRescuer.RescuedBoard? {
        switch stage {
        case .rescued(let board), .clearing(let board), .installing(let board): return board
        case .failed(let board): return board
        default: return nil
        }
    }

    /// Stop is withheld only while the real firmware is being written, for the
    /// reason the Add Display sheet gives. Catching can always be stopped: the
    /// board was not booting its firmware anyway.
    var canStop: Bool {
        switch stage {
        case .catching, .clearing: return true
        case .installing:
            switch monitor.session.phase {
            case .findingBoard, .waitingForBoard: return true
            default: return false
            }
        default: return false
        }
    }

    func start(manager: PanelManager) {
        guard let family, canStart else { return }
        let carrier = needsCarrier ? self.carrier : nil
        hold(manager)
        monitor.reset(flow: .repair)
        installOffer = nil
        installProblem = nil
        stage = .catching
        let monitor = monitor
        work = Task {
            let result = await manager.rescueUSBBoard(
                family: family, carrier: carrier) { monitor.record($0) }
            switch result {
            case .success(let board): rescued(board)
            case .failure(let failure):
                monitor.fail(.failure(failure))
                stage = .failed(nil)
            }
        }
    }

    func stop() {
        work?.cancel()
    }

    /// Stop whatever runs and let the app probe USB again. For the view going
    /// away; exactly one release per hold.
    func close() {
        work?.cancel()
        release()
    }

    private func hold(_ manager: PanelManager) {
        guard holding == nil else { return }
        manager.holdUSBProbes()
        holding = manager
    }

    private func release() {
        holding?.releaseUSBProbes()
        holding = nil
    }

    func clearOverride(manager: PanelManager) {
        guard let board, !isRunning, board.storedOverride != nil else { return }
        hold(manager)
        stage = .clearing(board)
        let monitor = monitor
        work = Task {
            switch await manager.clearRescueOverride(on: board, progress: { monitor.record($0) }) {
            case .success(let reread): rescued(reread)
            case .failure(let failure):
                // The board is still on the rescue image, and what is offered
                // next is Clear Override again, so say that rather than the
                // phase's own advice.
                var outcome = OperationOutcome.failure(failure)
                outcome.nextAction = "The board is still on the rescue firmware. "
                    + "Press Clear Override to try again."
                monitor.fail(outcome)
                stage = .failed(board)
            }
        }
    }

    func install(manager: PanelManager) {
        guard let board, !isRunning, board.storedOverride == nil else { return }
        hold(manager)
        stage = .installing(board)
        let monitor = monitor
        work = Task {
            switch await manager.installFirmwareAfterRepair(
                on: board, progress: { monitor.record($0) })
            {
            case .success(let port):
                stage = .installed(port: port)
                release()
            case .failure(let failure):
                monitor.fail(.failure(failure))
                stage = .failed(board)
            }
        }
    }

    func startOver() {
        guard !isRunning else { return }
        release()
        stage = .choosing
        monitor.reset(flow: .repair)
    }

    func rescued(
        _ board: UsbRescuer.RescuedBoard,
        firmware: BundledFirmware.Availability = BundledFirmware.load()
    ) {
        stage = .rescued(board)
        switch firmware {
        case .ready(let releases):
            do {
                let resolution = try PanelManager.repairInstallSelection(
                    for: board, releases: releases)
                installOffer = "ESPDisplay \(resolution.selection.bundle.firmwareVersion) "
                    + "for \(resolution.canonicalTarget)"
                    + (board.identity.board.map { " (\($0))" } ?? "")
                installProblem = nil
            } catch {
                installOffer = nil
                installProblem = error.localizedDescription
            }
        case .unreadable(_, let reason):
            installOffer = nil
            installProblem = "The firmware bundled with the app could not be read: \(reason)"
        case .none:
            installOffer = nil
            installProblem = "This copy of the app was packaged without firmware."
        }
    }

    /// The instruction at the top of the progress section.
    nonisolated static func headline(for stage: Stage, phase: UsbFlashPhase?) -> String {
        switch stage {
        case .choosing:
            return "Unplug the board, choose its chip family, then press Start"
        case .catching:
            switch phase {
            case .rescue(let step): return step.title
            case nil: return UsbRescueStep.startingEsptool.title
            default: return "Got it - keep the board plugged in"
            }
        case .rescued: return "Rescue firmware is on"
        case .clearing: return "Rescue firmware is on - clearing the stored override"
        case .installing: return "Rescue firmware is on - installing the real firmware"
        case .installed: return "Done - the real firmware is installed"
        case .failed: return "The repair stopped"
        }
    }
}

/// Repair a board that shows up on USB for a moment after it is plugged in and
/// then vanishes. Shown in place of the Add Display and Firmware Update forms,
/// in the same sheet, and hands back the port the repaired board answered on.
struct UsbRepairView: View {
    @ObservedObject var manager: PanelManager
    @StateObject private var model: UsbRepairModel
    let closeTitle: String
    let onClose: (String?) -> Void

    init(
        manager: PanelManager, family: UsbRescue.Family?,
        closeTitle: String = "Back", onClose: @escaping (String?) -> Void
    ) {
        self.init(
            manager: manager, model: UsbRepairModel(family: family),
            closeTitle: closeTitle, onClose: onClose)
    }

    init(
        manager: PanelManager, model: @autoclosure @escaping () -> UsbRepairModel,
        closeTitle: String = "Back", onClose: @escaping (String?) -> Void
    ) {
        self.manager = manager
        _model = StateObject(wrappedValue: model())
        self.closeTitle = closeTitle
        self.onClose = onClose
    }

    var body: some View {
        Form {
            introSection
            if model.stage != .choosing {
                UsbRepairProgressSection(model: model, monitor: model.monitor)
            }
            if let board = model.board {
                boardSection(board)
            }
        }
        .formStyle(.grouped)
        // Every message in here - errors above all - can be selected and
        // copied. Set once at the root, so a message added later cannot be
        // the one that forgot.
        .textSelection(.enabled)
        .labeledContentStyle(.labelColumn)
        .safeAreaInset(edge: .bottom) { actionBar.textSelection(.enabled) }
        .onDisappear { model.close() }
    }

    private var introSection: some View {
        Section {
            Picker("Chip family", selection: $model.family) {
                Text("Choose…").tag(UsbRescue.Family?.none)
                ForEach(UsbRescue.Family.all) { family in
                    Text(family.displayName).tag(Optional(family))
                }
            }
            .disabled(model.stage != .choosing)
            if model.needsCarrier {
                Picker("Board", selection: $model.carrier) {
                    Text("Choose…").tag(String?.none)
                    ForEach(model.carrierChoices) { choice in
                        Text(choice.name).tag(Optional(choice.profile))
                    }
                }
                .disabled(model.stage != .choosing)
            }
        } header: {
            Text("Repair a board that drops off USB")
        } footer: {
            // Only before the run: once it starts, the progress and the board
            // it found need the room.
            if model.stage == .choosing {
                Text("For a board that appears for a moment after it is plugged in, "
                    + "then disappears. esptool is started first and waits; the board "
                    + "is caught the moment it appears and given a small rescue "
                    + "firmware that keeps USB on. Saved WiFi and name are not erased. "
                    + "Other USB devices can stay plugged in: only a port that appears "
                    + "after \"Plug the board in now\" is touched.")
            }
        }
    }

    @ViewBuilder
    private func boardSection(_ board: UsbRescuer.RescuedBoard) -> some View {
        Section("Board") {
            LabeledContent("USB device", value: board.port)
            LabeledContent("Board", value: [board.identity.board, board.identity.target]
                .compactMap { $0 }.joined(separator: " · "))
            LabeledContent("Chip", value: board.identity.chip ?? "Not reported")
            LabeledContent("Hardware ID", value: board.identity.hardwareID ?? "Not reported")
            if let forced = board.storedOverride {
                Label("Stored board override: \(forced)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("The real firmware forces this profile again at boot, which may be "
                    + "what turned its USB off. Clear it before installing; nothing else "
                    + "saved on the board is changed.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let offer = model.installOffer {
                LabeledContent("Install", value: offer)
            } else if let problem = model.installProblem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button(closeTitle) {
                if case .installed(let port) = model.stage { onClose(port) } else { onClose(nil) }
            }
            .disabled(model.isRunning)
            Spacer()
            if model.isRunning {
                Button("Stop", role: .cancel) { model.stop() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!model.canStop)
                    .help(model.canStop ? "" : "Writing flash cannot be interrupted safely")
            }
            primaryButton
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .glassCard(cornerRadius: 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch model.stage {
        case .choosing:
            Button("Start") { model.start(manager: manager) }
                .disabled(!model.canStart)
        case .catching, .clearing, .installing:
            Button("Install Real Firmware") {}
                .disabled(true)
        case .rescued(let board) where board.storedOverride != nil:
            Button("Clear Override") { model.clearOverride(manager: manager) }
        case .rescued:
            Button("Install Real Firmware") { model.install(manager: manager) }
                .disabled(model.installOffer == nil)
        case .installed(let port):
            Button("Continue") { onClose(port) }
        case .failed(let board):
            if let board, board.storedOverride != nil {
                Button("Clear Override") { model.clearOverride(manager: manager) }
            } else if let board, board.storedOverride == nil, model.installOffer != nil {
                Button("Install Again") { model.install(manager: manager) }
            } else {
                Button("Start Over") { model.startOver() }
            }
        }
    }
}

/// The instruction and the shared USB status view, observing the monitor so
/// each phase redraws only this section.
private struct UsbRepairProgressSection: View {
    @ObservedObject var model: UsbRepairModel
    @ObservedObject var monitor: UsbFlashMonitor

    var body: some View {
        Section(monitor.session.failure == nil ? "Progress" : "What went wrong") {
            let headline = UsbRepairModel.headline(for: model.stage, phase: monitor.session.phase)
            if monitor.session.failure == nil, headline != monitor.session.phase?.title {
                Text(headline)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .installed(let port) = model.stage {
                Text("The board answered on \(port) with the real firmware. Its saved "
                    + "WiFi and name were kept.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                UsbFlashStatusView(session: monitor.session)
            }
        }
    }
}
