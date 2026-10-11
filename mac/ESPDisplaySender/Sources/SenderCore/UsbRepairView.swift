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
        case resumable(UsbRecoveryRecord)
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
        if case .resumable = stage { return false }
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

    /// Where this recovery is kept between launches; nil keeps nothing.
    var store: UsbRecoveryStore?
    /// This recovery as last kept: what Resume takes up after a failure, a
    /// Stop, or a relaunch.
    @Published private(set) var record: UsbRecoveryRecord?
    /// The USB device behind a port, from the IORegistry (a test gives its own).
    var deviceForPort: (String) -> UsbRescue.USBIdentity? = { UsbRescuer.usbDevice(forPort: $0) }
    /// The serial ports on USB now, listed from /dev without opening any.
    var listPorts: () -> [String] = { WifiConfigUI.candidatePorts() }
    @Published private(set) var attachedPorts: [String] = []
    /// Ports that appeared since a kept recovery began, marked in the list.
    @Published private(set) var newSinceRecoveryBegan: Set<String> = []
    private var portWatch: Timer?
    /// The board's own port when it is on USB already, so it is taken with
    /// nothing pressed; nil to catch it as it appears. Read by the running loop
    /// too, so a port chosen part-way through a run is taken then.
    @Published var chosenPort: String? {
        didSet { choice.port = chosenPort }
    }
    private let choice = UsbRescuer.PortChoice()

    /// Which kept recovery a sheet opens on: one that reached a board always,
    /// since there is one record and a new run would replace it; one that
    /// never did only from Recover Board.
    nonisolated static func offered(
        _ record: UsbRecoveryRecord?, fromRecoverBoard: Bool
    ) -> UsbRecoveryRecord? {
        // A family this copy of the app has no rescue image for cannot be
        // resumed; a new Start replaces such a record.
        guard let record, UsbRescue.Family.named(record.family) != nil else { return nil }
        return record.stage != .waiting || fromRecoverBoard ? record : nil
    }

    /// A sheet opened while a recovery is kept offers it as Resume. A record
    /// is only left behind by a run the app was quit or crashed in: Stop and
    /// Close remove one that never reached the board.
    convenience init(
        family: UsbRescue.Family?, pending: UsbRecoveryRecord?, store: UsbRecoveryStore? = nil
    ) {
        self.init(family: pending.flatMap { UsbRescue.Family.named($0.family) } ?? family)
        self.store = store
        guard let pending else { return }
        carrier = pending.carrier
        record = pending
        stage = .resumable(pending)
    }

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

    /// A kept recovery, which Resume takes up.
    var canResume: Bool { record != nil && !isRunning }

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

    /// A chosen port stays chosen while it is off USB: these boards come and
    /// go, and it is listed as not on USB now rather than dropped.
    func refreshPorts() {
        var ports = listPorts()
        presentPorts = Set(ports)
        if let chosenPort, !ports.contains(chosenPort) { ports.append(chosenPort) }
        attachedPorts = ports
    }

    /// The ports /dev listed at the last refresh.
    private var presentPorts: Set<String> = []

    /// /dev is listed again every second while the sheet is up, without
    /// opening anything, so the list follows a board that comes and goes.
    func watchPorts() {
        refreshPorts()
        guard portWatch == nil else { return }
        portWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.stage == .choosing || self.isLookingForTheBoard else { return }
                self.refreshPorts()
            }
        }
    }

    func isOnUSB(_ port: String) -> Bool { presentPorts.contains(port) }

    func start(manager: PanelManager) {
        begin(manager: manager, resuming: false)
    }

    private func begin(manager: PanelManager, resuming: Bool) {
        guard let family, canStart else { return }
        // One record is kept: a reached one this sheet did not open on (kept
        // since by another sheet) is offered rather than written over.
        if record == nil,
           let kept = Self.offered((manager.recoveryStore ?? store)?.load(), fromRecoverBoard: false) {
            record = kept
            stage = .resumable(kept)
            return
        }
        let carrier = needsCarrier ? self.carrier : nil
        store = manager.recoveryStore ?? store
        hold(manager)
        monitor.reset(flow: .repair)
        installOffer = nil
        installProblem = nil
        let baseline = listPorts()
        refreshPorts()
        keep(UsbRecovery.atStart(
            existing: record, resuming: resuming,
            family: family.key, carrier: carrier, baseline: baseline))
        choice.port = chosenPort
        stage = .catching
        let monitor = monitor
        let choice = choice
        work = Task {
            let result = await manager.rescueUSBBoard(
                family: family, carrier: carrier, choice: choice
            ) { [weak self] event in
                monitor.record(event)
                if case .phase(.rescue(.caught)) = event {
                    Task { @MainActor in self?.noteProgress(event) }
                }
            }
            switch result {
            case .success(let board): rescued(board)
            case .failure(let failure):
                monitor.fail(.failure(failure))
                stage = .failed(nil)
                if Task.isCancelled { noteStopped() }
            }
        }
    }

    func stop() {
        work?.cancel()
    }

    /// Stop whatever runs and let the app probe USB again. For the view going
    /// away; exactly one release per hold. A recovery that reached the board is
    /// kept for Resume.
    func close() {
        work?.cancel()
        portWatch?.invalidate()
        portWatch = nil
        if !isRunning { noteStopped() }
        release()
    }

    /// Take a kept recovery up where it stopped, finding the board on USB by
    /// its serial number. Nothing is asked of the person unless the board is
    /// not on USB at all.
    func resume(manager: PanelManager) {
        guard let record, !isRunning else { return }
        store = manager.recoveryStore ?? store
        family = UsbRescue.Family.named(record.family)
        carrier = record.carrier
        attachedPorts = listPorts()
        let located = UsbRecovery.locate(record, ports: attachedPorts, device: deviceForPort)
        monitor.reset(flow: .repair)
        switch UsbRecovery.plan(record, located: located, present: attachedPorts) {
        case .choose(let newPorts):
            newSinceRecoveryBegan = Set(newPorts)
            chosenPort = nil
            stage = .choosing
        case .adopt(let port):
            stage = .choosing
            chosenPort = port
            begin(manager: manager, resuming: true)
        case .waitForBoard:
            stage = .choosing
            chosenPort = nil
            begin(manager: manager, resuming: true)
        case .read(let port):
            readAgain(port: port, manager: manager)
        case .install(let board):
            rescued(board)
            install(manager: manager)
        }
    }

    /// Forget the kept recovery. The board is left as it is.
    func discard() {
        guard !isRunning else { return }
        record = nil
        store?.clear()
        stage = .choosing
        monitor.reset(flow: .repair)
    }

    /// The rescue image was on: ask it again, and write it again on that same
    /// port when it does not answer as the rescue image.
    private func readAgain(port: String, manager: PanelManager) {
        guard let family else { return }
        store = manager.recoveryStore ?? store
        hold(manager)
        stage = .catching
        let monitor = monitor
        let carrier = needsCarrier ? self.carrier : nil
        let hardwareID = record?.board?.hardwareID
        work = Task {
            let answer = await manager.rereadRecoveredBoard(
                port: port, family: family, carrier: carrier, hardwareID: hardwareID,
                progress: { monitor.record($0) })
            switch answer {
            case .rescue(let board):
                rescued(board)
            case .realFirmware(let port, let version):
                // Flashed since by another way: there is nothing left to do.
                monitor.record(.log(.app, "The board answered on \(port) running \(version)."))
                stage = .installed(port: port)
                noteInstalled()
                release()
            case .otherBoard(let port, let other):
                // The recorded board is not the one there now; nothing is
                // written to the one that is. The record is kept.
                monitor.fail(.failure(WifiConfigUI.ConfigFailure(
                    title: "Another board is on that port",
                    message: "\(port) now answers as board \(other), not the board this "
                        + "recovery was for, so nothing was written. Put the recovered "
                        + "board back on USB and press Resume, or Discard the recovery.")))
                stage = .failed(nil)
            case .silent where !Task.isCancelled:
                monitor.record(.log(.app, "\(port) did not answer as the rescue image; "
                    + "writing it again there."))
                stage = .choosing
                chosenPort = port
                begin(manager: manager, resuming: true)
            case .silent:
                stage = .failed(nil)
            }
        }
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
        store = manager.recoveryStore ?? store
        hold(manager)
        stage = .installing(board)
        noteInstallStarted(board)
        let monitor = monitor
        work = Task {
            switch await manager.installFirmwareAfterRepair(
                on: board, progress: { monitor.record($0) })
            {
            case .success(let port):
                stage = .installed(port: port)
                noteInstalled()
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
        monitor.reset(flow: .repair)
        if let record, record.stage != .waiting {
            stage = .resumable(record)
        } else {
            stage = .choosing
        }
    }

    func rescued(
        _ board: UsbRescuer.RescuedBoard,
        firmware: BundledFirmware.Availability = BundledFirmware.load()
    ) {
        stage = .rescued(board)
        keep(UsbRecovery.rescued(
            record ?? UsbRecovery.started(family: board.family.key, carrier: board.carrier,
                                          baseline: []),
            board: board, device: deviceForPort(board.port)))
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

    // MARK: - keeping the record

    func noteStarted(baseline: [String]) {
        guard let family else { return }
        keep(UsbRecovery.started(
            family: family.key, carrier: needsCarrier ? carrier : nil, baseline: baseline))
    }

    func noteProgress(_ event: UsbFlashEvent) {
        guard case .phase(.rescue(.caught(let port))) = event, let record else { return }
        keep(UsbRecovery.caught(record, port: port, device: deviceForPort(port)))
    }

    func noteInstallStarted(_ board: UsbRescuer.RescuedBoard) {
        let rescuedRecord = UsbRecovery.rescued(
            record ?? UsbRecovery.started(family: board.family.key, carrier: board.carrier,
                                          baseline: []),
            board: board, device: deviceForPort(board.port))
        keep(UsbRecovery.installing(rescuedRecord))
    }

    func noteInstalled() {
        record = nil
        store?.clear()
    }

    /// Stopped by the person: a run that never reached the board leaves
    /// nothing behind it, and one that did stays resumable.
    func noteStopped() {
        guard record?.stage == .waiting else { return }
        record = nil
        store?.clear()
    }

    private func keep(_ next: UsbRecoveryRecord) {
        record = next
        try? store?.save(next)
    }

    /// When the one physical action is what the person should be doing: the
    /// run is looking for the board and no port is chosen.
    var waitsForTheBoard: Bool { isLookingForTheBoard && chosenPort == nil }

    /// A run catching the board before esptool has reached it, while a port
    /// may still be chosen or changed.
    var isLookingForTheBoard: Bool {
        guard stage == .catching else { return false }
        switch monitor.session.phase {
        case nil, .rescue(.startingEsptool), .rescue(.plugIn), .rescue(.missed),
             .rescue(.seenWhileStarting), .rescue(.tooManyPorts), .rescue(.couldNotConnect):
            return true
        default:
            return false
        }
    }

    /// What the sheet says before Start.
    nonisolated static func introduction(for family: UsbRescue.Family?) -> String {
        let action = family.map { "Then put it in download mode, once. " + $0.downloadModeAction }
            ?? "Choose the chip family, and this says how to put the board in download mode."
        return "For a board missing from the list, shown as not connected, or on USB "
            + "only for a moment. If its port is listed above, choose it: esptool resets "
            + "the board over USB and nothing on it needs pressing. If it is not on USB, "
            + "leave the port on \"Not on USB\" and press Start. " + action
            + " Everything after that is done over USB. Saved WiFi and name are not "
            + "erased, and other USB devices are left alone."
    }

    /// Where a kept recovery stopped, in words.
    nonisolated static func resumeSummary(for record: UsbRecoveryRecord) -> String {
        let family = UsbRescue.Family.named(record.family)?.displayName ?? record.family
        let port = record.port.map { " on \($0)" } ?? ""
        switch record.stage {
        case .waiting:
            return "A recovery of an \(family) board was started, and nothing had reached "
                + "the board yet. Resume marks the ports that have appeared since, so a "
                + "board already in download mode can be chosen as it is."
        case .caught:
            return "esptool had reached the \(family) board\(port) and was writing the "
                + "rescue firmware. Resume writes it again."
        case .rescued:
            return "The rescue firmware is on the \(family) board\(port); the real "
                + "firmware is not installed yet."
        case .installing:
            return "The real firmware was being installed on the \(family) board\(port). "
                + "Resume installs it again."
        }
    }

    /// The instruction at the top of the progress section.
    nonisolated static func headline(for stage: Stage, phase: UsbFlashPhase?) -> String {
        switch stage {
        case .choosing:
            return "Choose the board's chip family, then press Start"
        case .catching:
            switch phase {
            case .rescue(let step): return step.title
            case nil: return UsbRescueStep.startingEsptool.title
            default: return "Got it - leave the board as it is"
            }
        case .rescued: return "Rescue firmware is on"
        case .clearing: return "Rescue firmware is on - clearing the stored override"
        case .installing: return "Rescue firmware is on - installing the real firmware"
        case .installed: return "Done - the real firmware is installed"
        case .failed: return "The repair stopped"
        case .resumable: return "Resume the recovery"
        }
    }
}

/// Recover a board the app cannot reach: one missing from the list, shown as
/// not connected, or on USB for a moment at a time. Shown on its own from
/// File > Recover Board, and in place of the Add Display and Firmware Update
/// forms in their sheets; hands back the port the recovered board answered on.
struct UsbRepairView: View {
    @ObservedObject var manager: PanelManager
    @StateObject private var model: UsbRepairModel
    let closeTitle: String
    let onClose: (String?) -> Void
    /// A kept recovery that reached a board opens whichever way in, so no
    /// other run can write over it; `offersKeptRecovery` (File > Recover Board
    /// and the launch offer) also opens one that never reached a board.
    init(
        manager: PanelManager, family: UsbRescue.Family?, offersKeptRecovery: Bool = false,
        closeTitle: String = "Back", onClose: @escaping (String?) -> Void
    ) {
        self.init(
            manager: manager,
            model: UsbRepairModel(
                family: family,
                pending: UsbRepairModel.offered(
                    manager.recoveryStore?.load(), fromRecoverBoard: offersKeptRecovery),
                store: manager.recoveryStore),
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
            if case .resumable(let record) = model.stage {
                resumeSection(record)
            } else if model.stage != .choosing {
                UsbRepairProgressSection(model: model, monitor: model.monitor)
            }
            if model.waitsForTheBoard, let family = model.family {
                Section("Put the board in download mode, once") {
                    Text(family.downloadModeAction)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Everything after this is done over USB: nothing to unplug, "
                        + "and nothing to press again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        .onAppear { model.watchPorts() }
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
            // Open while catching too: a board attached at Start that is
            // chosen here is taken at once, with nothing pressed.
            if model.stage == .choosing || model.isLookingForTheBoard {
                Picker("Its USB port", selection: $model.chosenPort) {
                    Text("Not on USB - catch it when it appears").tag(String?.none)
                    ForEach(model.attachedPorts, id: \.self) { port in
                        Text(portLabel(port)).tag(Optional(port))
                    }
                }
            }
        } header: {
            Text("Recover a board")
        } footer: {
            // Only before the run: once it starts, the progress and the board
            // it found need the room.
            if model.stage == .choosing {
                Text(UsbRepairModel.introduction(for: model.family))
            }
        }
    }

    /// The port, and what the app already knows is on it.
    private func portLabel(_ port: String) -> String {
        let name = (port as NSString).lastPathComponent
        var notes: [String] = []
        if let device = manager.usbDevices.first(where: { $0.path == port }),
           let known = [device.name, device.board].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
            notes.append(known + (device.isConnected ? ", connected" : ""))
        }
        if model.newSinceRecoveryBegan.contains(port) { notes.append("new since the recovery began") }
        if !model.isOnUSB(port) { notes.append("not on USB now") }
        return notes.isEmpty ? name : "\(name) (" + notes.joined(separator: "; ") + ")"
    }

    private func resumeSection(_ record: UsbRecoveryRecord) -> some View {
        Section("An earlier recovery stopped") {
            Text(UsbRepairModel.resumeSummary(for: record))
                .fixedSize(horizontal: false, vertical: true)
            Text("Resume finds the board on USB by its serial number and goes on from "
                + "there; nothing on the board needs touching while it is on USB. "
                + "Discard forgets it and leaves the board as it is.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            if case .resumable = model.stage {
                Button("Discard") { model.discard() }
                    .help("Forget the stopped recovery; the board is left as it is")
            }
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
            } else if model.canResume {
                Button("Resume") { model.resume(manager: manager) }
            } else {
                Button("Start Over") { model.startOver() }
            }
        case .resumable:
            Button("Resume") { model.resume(manager: manager) }
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
