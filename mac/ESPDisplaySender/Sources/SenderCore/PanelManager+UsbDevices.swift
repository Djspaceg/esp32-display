import AppKit
import Foundation
import Network
import ScreenCaptureKit
import SenderProtocol

/// The USB device inventory: connected serial ports, coalesced
/// identity probes, path generations (so a result from an unplugged
/// device is never applied after macOS reuses its path), and
/// device-to-record association.
extension PanelManager {
    enum USBSerialState: Equatable {
        case absent
        case enumeratedUnverified
        case verified(WifiConfigUI.USBDeviceOption)
        case restarting
        case mismatch
        case ambiguous
    }

    func stableHardwareID(of panel: PanelSnapshot) -> String? {
        ConfigCommands.canonicalHardwareID(panel.hardwareID)
            ?? ConfigCommands.canonicalHardwareID(panel.usbHardwareID)
    }

    func panelAssociated(withHardwareID hardwareID: String) -> PanelSnapshot? {
        let canonical = ConfigCommands.canonicalHardwareID(hardwareID)
        return panels.first { stableHardwareID(of: $0) == canonical }
    }

    func associatedDisplayName(forUSBPath path: String) -> String? {
        guard let hardwareID = usbDevices.first(where: { $0.path == path })?.hardwareID
        else { return nil }
        return panelAssociated(withHardwareID: hardwareID)?.displayName
    }

    func isUSBDeviceAssociated(_ path: String) -> Bool {
        associatedDisplayName(forUSBPath: path) != nil
    }

    func usbHardwareID(for path: String) -> String? {
        usbDevices.first(where: { $0.path == path })?.hardwareID
    }

    func usbTarget(for path: String) -> String? {
        usbDevices.first(where: { $0.path == path })?.target
    }

    func usbReleaseIdentity(for path: String) -> FirmwareReleaseCatalog.Identity? {
        guard let device = usbDevices.first(where: { $0.path == path }) else { return nil }
        return FirmwareReleaseCatalog.Identity(
            family: device.target, chip: device.chip,
            profile: device.board, partition: device.partition)
    }

    /// The port this record's board is on right now: the one connected port
    /// whose board reported the record's hardware ID. Worked out afresh from
    /// the ports present and what the boards on them said, never remembered.
    func currentUSBPort(for serviceName: String) -> String? {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }),
              let hardwareID = stableHardwareID(of: panel)
        else { return nil }
        let matches = usbDevices.filter { $0.hardwareID == hardwareID }
        if matches.count == 1 { return matches[0].path }
        if matches.count > 1 { return "Ambiguous" }
        return nil
    }

    /// A connected port whose USB serial is one this record's board answered
    /// behind: the board is plugged in, whether or not it has answered yet.
    func usbSerialPairedDevice(for serviceName: String) -> WifiConfigUI.USBDeviceOption? {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }),
              !panel.usbSerialNumbers.isEmpty
        else { return nil }
        return usbDevices.first {
            $0.isConnected && $0.usbSerial.map(panel.usbSerialNumbers.contains) == true
        }
    }

    /// `currentUSBPort` as a hint for a command that finds its port by asking,
    /// nil when there is no single port.
    func pairedUSBPath(for serviceName: String) -> String? {
        currentUSBPort(for: serviceName).flatMap { $0 == "Ambiguous" ? nil : $0 }
    }

    /// Current-generation, identity-bound serial state for one durable record.
    /// Paths and remembered assignments are only hints; CFGSHOW identity is the
    /// proof that makes a normal control safe.
    func usbSerialState(for serviceName: String) -> USBSerialState {
        guard let panel = panels.first(where: { $0.serviceName == serviceName })
        else { return .absent }
        let connected = usbDevices.filter { $0.isConnected && !$0.path.isEmpty }
        guard !connected.isEmpty else { return .absent }
        guard let expectedID = stableHardwareID(of: panel) else {
            return .enumeratedUnverified
        }
        let matches = connected.filter {
            ConfigCommands.canonicalHardwareID($0.hardwareID) == expectedID
        }
        if matches.count > 1 { return .ambiguous }
        if let match = matches.first {
            if usbRestartingServices.contains(serviceName) { return .restarting }
            guard match.verifiedGeneration == usbPathGeneration(match.path),
                  match.serialStatus != nil
            else { return .enumeratedUnverified }
            return .verified(match)
        }
        if connected.contains(where: { $0.hardwareID != nil }) { return .mismatch }
        if usbRestartingServices.contains(serviceName) { return .restarting }
        return .enumeratedUnverified
    }

    func verifiedUSBDevice(
        for serviceName: String
    ) -> WifiConfigUI.USBDeviceOption? {
        guard case .verified(let device) = usbSerialState(for: serviceName)
        else { return nil }
        return device
    }

    /// The connected USB device a write for this record would go to, whether or
    /// not it has said enough about itself to be written yet.
    ///
    /// This is deliberately weaker than `usbSerialState`: a bootloader write
    /// does not need the live CFGSHOW status a runtime control needs, because
    /// the board's identity is read again over serial and then independently
    /// out of esptool before anything is written. What it does need is a device
    /// that is unambiguously this record's: it reports this record's hardware
    /// ID. A record with no hardware ID has no USB device.
    func usbUpdateDevice(
        for serviceName: String
    ) -> WifiConfigUI.USBDeviceOption? {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }),
              let expectedID = stableHardwareID(of: panel)
        else { return nil }
        let matches = usbDevices.filter {
            $0.isConnected && !$0.path.isEmpty
                && ConfigCommands.canonicalHardwareID($0.hardwareID) == expectedID
        }
        // Two boards claiming one identity is not a write target.
        return matches.count == 1 ? matches.first : nil
    }

    /// A USB device that is flashable on its own terms: it named its firmware
    /// family, chip, physical profile, partition layout, and its own six-byte
    /// hardware ID. That reported identity is what the preflight and esptool are
    /// checked against immediately before a write, so a board that does not
    /// fully identify itself is still refused here.
    func usbFlashDevice(
        for serviceName: String
    ) -> WifiConfigUI.USBDeviceOption? {
        guard let device = usbUpdateDevice(for: serviceName),
              Self.usbDeviceIdentifiesItselfForFlashing(device)
        else { return nil }
        return device
    }

    nonisolated static func usbDeviceIdentifiesItselfForFlashing(
        _ device: WifiConfigUI.USBDeviceOption
    ) -> Bool {
        device.hardwareID?.isEmpty == false
            && device.target?.isEmpty == false
            && device.board?.isEmpty == false
            && device.chip?.isEmpty == false
            && device.partition?.isEmpty == false
    }

    /// Refresh transport paths without blocking the main actor. Newly seen paths
    /// are identified automatically, and a path whose answer was missed is asked
    /// again on the retry schedule; the explicit refresh action below re-probes
    /// every connected device.
    func refreshUSBPorts() {
        let added = updateUSBPorts(WifiConfigUI.candidatePorts())
        identifyUSBPorts(added)
    }

    @discardableResult
    func updateUSBPorts(_ paths: [String]) -> [String] {
        let existing = Dictionary(
            usbDevices.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first })
        let removed = Set(existing.keys).subtracting(paths)
        for path in removed { invalidateUSBPath(path) }
        let added = paths.filter { existing[$0] == nil }
        for path in added { usbPathGenerations[path, default: 0] += 1 }
        let refreshed = paths.map { path -> WifiConfigUI.USBDeviceOption in
            if let known = existing[path] { return known }
            var device = WifiConfigUI.USBDeviceOption(path: path)
            device.usbSerial = usbSerialReader(path)
            return device
        }
        if refreshed != usbDevices { usbDevices = refreshed }
        if !removed.isEmpty { sortPanels() }
        return added
    }

    func refreshUSBDevices() {
        refreshUSBPorts()
        for path in usbSerialPorts { invalidateUSBPath(path) }
        sortPanels()
        identifyUSBPorts(usbSerialPorts)
    }

    func usbPathGeneration(_ path: String) -> Int {
        usbPathGenerations[path, default: 0]
    }

    private func invalidateUSBPath(_ path: String) {
        usbPathGenerations[path, default: 0] += 1
        usbProbeTasks[path]?.task.cancel()
        usbProbeTasks[path] = nil
        usbIdentifyRetries[path] = nil
        if let index = usbDevices.firstIndex(where: { $0.path == path }) {
            // Unplugged or renumbered: the next time this board is verified it
            // is a fresh USB connection, and the user asked for a copy on every
            // connection. Its presets may also have been changed elsewhere
            // while it was away.
            if let hardwareID = usbDevices[index].hardwareID {
                forgetWifiPresetSync(hardwareID: hardwareID)
            }
            usbDevices[index].serialStatus = nil
            usbDevices[index].verifiedGeneration = nil
        }
    }

    /// Record identity learned either by a background CFGSHOW probe or by the
    /// setup sheet's selected-device inspection.
    func noteUSBIdentity(
        path: String,
        name: String?,
        hardwareID: String?,
        target: String? = nil,
        board: String? = nil,
        chip: String? = nil,
        partition: String? = nil,
        serialStatus: WifiConfigUI.USBStatus? = nil,
        verifiedGeneration: Int? = nil
    ) {
        guard let index = usbDevices.firstIndex(where: { $0.path == path }) else { return }
        let canonicalID = ConfigCommands.canonicalHardwareID(hardwareID)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName?.isEmpty == false { usbDevices[index].name = trimmedName }
        if let canonicalID { usbDevices[index].hardwareID = canonicalID }
        if let target, !target.isEmpty { usbDevices[index].target = target }
        if let board, !board.isEmpty { usbDevices[index].board = board }
        if let chip, !chip.isEmpty { usbDevices[index].chip = chip }
        if let partition, !partition.isEmpty { usbDevices[index].partition = partition }
        if let serialStatus { usbDevices[index].serialStatus = serialStatus }
        if let verifiedGeneration {
            usbDevices[index].verifiedGeneration = verifiedGeneration
        }
        if let canonicalID, serialStatus?.firmwareVersion != nil {
            clearRecovery(ofBoardAnswering: canonicalID)
        }

        guard let canonicalID else {
            sortPanels()
            return
        }
        // The board's console answered behind this USB serial: that serial is
        // this record's board from now on, wherever it is plugged in.
        if let serial = usbDevices[index].usbSerial {
            var learned = false
            for panelIndex in panels.indices {
                let owns = stableHardwareID(of: panels[panelIndex]) == canonicalID
                let has = panels[panelIndex].usbSerialNumbers.contains(serial)
                if owns, !has {
                    panels[panelIndex].usbSerialNumbers.append(serial)
                    learned = true
                } else if !owns, has {
                    panels[panelIndex].usbSerialNumbers.removeAll { $0 == serial }
                    learned = true
                }
            }
            if learned { persistIfNeeded(force: true) }
        }
        var rotationBefore: (serviceName: String, rotation: Int)?
        if let status = serialStatus,
           let panelIndex = panels.firstIndex(where: {
               stableHardwareID(of: $0) == canonicalID
           }) {
            if let version = status.firmwareVersion, !version.isEmpty {
                panels[panelIndex].firmwareVersion = version
                // Written even when nil: this reply came from the stream
                // firmware that is running now, so a missing src= means this
                // build does not name itself, not that an older answer stands.
                panels[panelIndex].noteFirmwareSource(
                    status.firmwareSource, reportedWith: version)
            }
            // Kept as reported: "" is the board saying no network is set, which
            // is an answer, where nil is not having asked.
            panels[panelIndex].currentSSID = status.currentSSID
            panels[panelIndex].networkConnected = status.networkConnected
            panels[panelIndex].networkReportedAt = Date()
            if let rssi = status.rssi { panels[panelIndex].rssi = rssi }
            rotationBefore = (
                panels[panelIndex].serviceName, panels[panelIndex].rotation)
            if let rotation = status.rotation {
                panels[panelIndex].rotation = rotation
                panels[panelIndex].flipped = rotation == 2
            } else if let flipped = status.flipped {
                panels[panelIndex].flipped = flipped
                panels[panelIndex].rotation = flipped ? 2 : 0
            }
            sessions[panels[panelIndex].serviceName]?.setPanelRotation(
                panels[panelIndex].rotation)
            if let level = status.brightnessLevel {
                panels[panelIndex].brightness = level
            }
            if let high = status.brightnessHigh {
                panels[panelIndex].brightnessHigh = high
            }
            if let manuallyOff = status.manuallyOff {
                panels[panelIndex].manuallyOff = manuallyOff
            }
            if let target, !target.isEmpty { panels[panelIndex].target = target }
            if let board, !board.isEmpty { panels[panelIndex].profile = board }
            if let chip, !chip.isEmpty { panels[panelIndex].chip = chip }
            if let partition, !partition.isEmpty {
                panels[panelIndex].partition = partition
            }
        }
        if let panelIndex = panels.firstIndex(where: {
            stableHardwareID(of: $0) == canonicalID
        }), let board, let geometry = GeneratedBoardCatalog.geometryByProfile[board] {
            panels[panelIndex].geometry = geometry
            if let region = panels[panelIndex].source.region,
               !region.matchesAspect(of: geometry) {
                let aligned = region.realigned(to: geometry)
                panels[panelIndex].source = .region(aligned)
                panels[panelIndex].sourceDescription = PanelSource.region(aligned).label
                sessions[panels[panelIndex].serviceName]?.useRegion(aligned)
                refreshPreviewDriver()
                persistIfNeeded(force: true)
            }
        }
        // After the geometry above, which is what says the glass is rectangular.
        if let rotationBefore {
            followReportedRotation(
                from: rotationBefore.rotation, for: rotationBefore.serviceName)
            followRotationAwaitingGeometry(for: rotationBefore.serviceName)
            alignRegionToRotation(for: rotationBefore.serviceName)
            // The offline viewfinder takes its frame shape from the rotation.
            refreshPreviewDriver()
        }
        sortPanels()
    }

    func noteUSBIdentity(
        path: String,
        identity: WifiConfigUI.USBIdentity,
        generation: Int
    ) {
        if let index = usbDevices.firstIndex(where: { $0.path == path }) {
            // A current probe that omits id= must not inherit an older board's
            // identity from this macOS path.
            usbDevices[index].hardwareID = identity.hardwareID
        }
        noteUSBIdentity(
            path: path,
            name: identity.name,
            hardwareID: identity.hardwareID,
            target: identity.target,
            board: identity.board,
            chip: identity.chip,
            partition: identity.partition,
            serialStatus: identity.status,
            verifiedGeneration: generation)
        if identity.status != nil, let hardwareID = identity.hardwareID {
            let matchingServices = panels.compactMap { panel in
                stableHardwareID(of: panel) == hardwareID
                    ? panel.serviceName : nil
            }
            var restartStateChanged = false
            for serviceName in matchingServices {
                if usbRestartingServices.remove(serviceName) != nil {
                    restartStateChanged = true
                }
            }
            if restartStateChanged {
                objectWillChange.send()
                sortPanels()
            }
            // A board that just answered CFGSHOW at this generation is a board
            // whose presets can be brought up to date. This is the "on USB
            // connect" trigger: every path to a verified serial endpoint -
            // first enumeration, explicit refresh, reprobe after a control -
            // arrives here, and the signature check makes the repeat ones free.
            for serviceName in matchingServices {
                syncWifiPresetsIfNeeded(for: serviceName)
            }
        }
    }

    func markUSBRestarting(_ serviceName: String) {
        guard !usbRestartingServices.contains(serviceName) else { return }
        objectWillChange.send()
        usbRestartingServices.insert(serviceName)
        sortPanels()
        // A board whose tty survives its restart is never seen as a new port,
        // so ask it again on the retry schedule rather than waiting on a refresh.
        if let path = usbUpdateDevice(for: serviceName)?.path {
            let generation = usbPathGeneration(path)
            let soon = ProcessInfo.processInfo.systemUptime
                + usbIdentifyRetryDelay(afterAttempt: 1)
            if let pending = usbIdentifyRetries[path], pending.generation == generation {
                // Already scheduled, perhaps far out after earlier misses: the
                // restart is a reason to ask soon.
                // A fresh schedule too, so a miss mid-reboot is asked again in
                // seconds, not at the long end of the backoff.
                usbIdentifyRetries[path] = (generation, 0, min(pending.nextAt, soon))
            } else {
                usbIdentifyRetries[path] = (generation, 0, soon)
            }
        }
    }

    /// Return one coalesced CFGSHOW probe for this path and publish its identity.
    func probeUSBDevice(
        _ path: String, timeout: TimeInterval = 2
    ) async -> WifiConfigUI.PortProbe {
        let generation = usbPathGenerations[path, default: 0]
        let task: Task<WifiConfigUI.PortProbe, Never>
        if let existing = usbProbeTasks[path], existing.generation == generation {
            task = existing.task
        } else {
            task = Task.detached(priority: .utility) {
                WifiConfigUI.probePort(path, timeout: timeout)
            }
            usbProbeTasks[path] = (generation, task)
        }
        let result = await task.value
        if usbProbeTasks[path]?.generation == generation {
            usbProbeTasks[path] = nil
        }
        guard usbPathGenerations[path, default: 0] == generation,
              usbDevices.contains(where: { $0.path == path })
        else {
            return .unavailable("USB device changed while it was being identified")
        }
        guard case .identified(let identity) = result else {
            noteUnansweredUSBProbe(path, generation: generation)
            return result
        }
        // A reply with no id= names nothing to pair the port with. Usually it
        // is the start of an answer another reader of the same port took the
        // rest of (a serial capture, a monitor). Taken as the answer it would
        // wipe the port's hardware ID and count as answered, so the board
        // would never be asked again and never verify. The port is asked again
        // instead, and what is known about it is left alone. The caller still
        // gets the reply: firmware from before id= answers this way, and the
        // Add Display sheet can still flash it.
        if identity.hardwareID == nil {
            noteUnansweredUSBProbe(path, generation: generation)
            return result
        }
        usbIdentifyRetries[path] = nil
        if let index = usbDevices.firstIndex(where: { $0.path == path }) {
            // A completed CFGSHOW probe is authoritative for discovery-scoped
            // facts. Clear an older value when current firmware omits it.
            usbDevices[index].target = identity.target
            usbDevices[index].board = identity.board
            usbDevices[index].chip = identity.chip
            usbDevices[index].partition = identity.partition
            usbDevices[index].serialStatus = nil
            usbDevices[index].verifiedGeneration = nil
        }
        noteUSBIdentity(path: path, identity: identity, generation: generation)
        return result
    }

    func probeExistingFirmware(
        at path: String
    ) async -> UsbOnboarding.ExistingFirmware {
        await probeExistingFirmwareReport(at: path).existing
    }

    /// The CFGSHOW answer plus the firmware version the board reported, as
    /// reported: any version is a recognised, answering board.
    func probeExistingFirmwareReport(
        at path: String
    ) async -> (
        existing: UsbOnboarding.ExistingFirmware, version: String?,
        source: FirmwareSourceIdentity?
    ) {
        let deadline = Date(timeIntervalSinceNow: 3)
        var result = await probeUSBDevice(path, timeout: 3)
        if case .unavailable = result {
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0.05 {
                result = await probeUSBDevice(path, timeout: remaining)
            }
        }
        switch result {
        case .identified(let identity):
            return (.answered(
                name: identity.name,
                hardwareID: identity.hardwareID),
                identity.status?.firmwareVersion,
                identity.status?.firmwareSource)
        case .unavailable:
            return (.silent, nil, nil)
        }
    }

    /// The ports a background identity probe may ask CFGSHOW: none while a
    /// repair holds probes.
    func portsToIdentify(_ ports: [String]) -> [String] {
        usbProbeHolds == 0 ? ports : []
    }

    /// Schedule the next ask for a port that did not answer. Silence is not
    /// reported: a board mid-boot, a blank board and one running other firmware
    /// all look like this, and every one of them can still be flashed.
    ///
    /// Coalesced awaiters of one probe all land here; only the first of them,
    /// or a retry whose time had come, moves the schedule on.
    ///
    /// A port that belongs to a display is asked until it answers or is
    /// unplugged. Any other serial device (an Arduino, a printer, a board with
    /// other firmware) is let go after `usbUnknownPortRetryAttempts`, about two
    /// minutes: past that, each ask only disturbs whoever else is using it.
    private func noteUnansweredUSBProbe(_ path: String, generation: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        var attempts = 1
        if let pending = usbIdentifyRetries[path], pending.generation == generation {
            guard pending.nextAt <= now else { return }
            attempts = pending.attempts + 1
        }
        let belongs = usbPortBelongsToADisplay(path)
        if !belongs, let index = usbDevices.firstIndex(where: { $0.path == path }),
           usbDevices[index].verifiedGeneration != nil {
            // No display record means no setter can be driving it, so an
            // earlier answer at this connection need not keep it off the
            // schedule: it has gone quiet (reset, crash loop) and is asked again.
            usbDevices[index].serialStatus = nil
            usbDevices[index].verifiedGeneration = nil
        }
        guard belongs || attempts <= usbUnknownPortRetryAttempts else {
            usbIdentifyRetries[path] = nil
            return
        }
        usbIdentifyRetries[path] = (
            generation, attempts,
            now + usbIdentifyRetryDelay(afterAttempt: attempts))
    }

    /// Whether a display record's board is on this port: by the USB serial
    /// macOS reports for it (learned where the board answered before), by the
    /// hardware ID the board here reported, or as a restarting record's
    /// device. Anything else is asked like any other device until it answers.
    func usbPortBelongsToADisplay(_ path: String) -> Bool {
        if let serial = usbDevices.first(where: { $0.path == path })?.usbSerial,
           panels.contains(where: { $0.usbSerialNumbers.contains(serial) }) {
            return true
        }
        if panels.contains(where: {
            usbRestartingServices.contains($0.serviceName)
                && usbUpdateDevice(for: $0.serviceName)?.path == path
        }) { return true }
        guard let hardwareID = ConfigCommands.canonicalHardwareID(
            usbDevices.first(where: { $0.path == path })?.hardwareID)
        else { return false }
        return panelAssociated(withHardwareID: hardwareID) != nil
    }

    func usbIdentifyRetryDelay(afterAttempt attempts: Int) -> TimeInterval {
        guard let last = usbIdentifyRetryDelays.last else { return 30 }
        let index = attempts - 1
        return usbIdentifyRetryDelays.indices.contains(index)
            ? usbIdentifyRetryDelays[index] : last
    }

    /// Unanswered ports whose next ask is due. None while anything in the app
    /// has a USB port: a CFGSHOW written over esptool, a flash, a preset sync
    /// or a control write would talk over it. Ownership
    /// is checked app-wide rather than per board because a board that has not
    /// answered may not have a hardware ID to match a run against. Another
    /// program's esptool is kept out by its lock (`WifiConfigUI.probePort`).
    ///
    /// A board that answered at this connection and is not restarting is not
    /// asked again: it is the only kind the synchronous setters (rename, WiFi,
    /// OTA password) will drive, so a retry can never be reading their port.
    func usbPortsDueForIdentifyRetry(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [String] {
        guard usbProbeHolds == 0, usbIdentifyRetryHolds == 0,
              usbControlsInFlight == 0,
              usbFlashesInFlight.isEmpty,
              wifiPresetSyncTasks.isEmpty, usbBrightnessTasks.isEmpty
        else { return [] }
        let restartingIDs = Set(panels.compactMap { panel in
            usbRestartingServices.contains(panel.serviceName)
                ? stableHardwareID(of: panel) : nil
        })
        return usbDevices.compactMap { device in
            let answered = device.verifiedGeneration == usbPathGeneration(device.path)
                && device.serialStatus != nil
            let restarting = ConfigCommands.canonicalHardwareID(device.hardwareID)
                .map(restartingIDs.contains) ?? false
            guard device.isConnected, !device.path.isEmpty,
                  !answered || restarting,
                  let pending = usbIdentifyRetries[device.path],
                  pending.generation == usbPathGeneration(device.path),
                  pending.nextAt <= now,
                  usbProbeTasks[device.path] == nil
            else { return nil }
            return device.path
        }
    }

    func holdUSBIdentifyRetries() {
        usbIdentifyRetryHolds += 1
    }

    func releaseUSBIdentifyRetries() {
        usbIdentifyRetryHolds = max(0, usbIdentifyRetryHolds - 1)
    }

    /// Ask these ports what they are, and ask again any port whose answer was
    /// missed and is due. Called on every two-second port refresh.
    func identifyUSBPorts(_ ports: [String]) {
        var paths = portsToIdentify(ports)
        for path in usbPortsDueForIdentifyRetry() where !paths.contains(path) {
            paths.append(path)
        }
        for path in paths {
            Task { @MainActor [weak self] in
                _ = await self?.probeUSBDevice(path)
            }
        }
    }

    func refreshSavedNetworks() {
        // Reconciled with the stored preset order, so a network the Keychain
        // gained outside Settings joins the end of it.
        guard applySavedNetworkNames(wifiNetworkNamesReader()) else { return }
        // The app's own collection changed. Every board still attached gets it.
        syncWifiPresetsToAttachedDevices()
    }

    /// Ask the device over USB which network it is actually on, and record
    /// the answer against the panel.
    ///
    /// Best-effort and silent: this runs on appearing, not on a button press,
    /// so a board that happens to be unreachable over USB right now (no
    /// cable, wrong port assigned, mid-reboot) should not raise an alert -
    /// the rows just keep what they already showed. `Task.detached` because `WifiConfigUI.currentNetwork` is
    /// blocking serial I/O with up to a several-second timeout, and this
    /// actor must not stall on it.
    func refreshCurrentSSID(for serviceName: String) {
        guard !serialIODisabled,
              let panel = panels.first(where: { $0.serviceName == serviceName })
        else { return }
        let currentName = panel.displayName
        let expectedHardwareID = panel.usbHardwareID ?? panel.hardwareID
        let preferredPort = pairedUSBPath(for: serviceName)
        Task { @MainActor [weak self] in
            let network = await Task.detached {
                WifiConfigUI.currentNetwork(
                    currentName: currentName,
                    expectedHardwareID: expectedHardwareID,
                    preferredPort: preferredPort)
            }.value
            guard let network else { return }
            self?.updatePanel(serviceName) {
                $0.currentSSID = network.ssid
                $0.networkConnected = network.connected
                $0.networkReportedAt = Date()
            }
        }
    }

}
