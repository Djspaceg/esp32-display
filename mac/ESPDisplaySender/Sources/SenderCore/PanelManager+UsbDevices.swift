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
    func stableHardwareID(of panel: PanelSnapshot) -> String? {
        ConfigCommands.canonicalHardwareID(panel.hardwareID)
            ?? ConfigCommands.canonicalHardwareID(panel.usbHardwareID)
    }

    func panelAssociated(withHardwareID hardwareID: String) -> PanelSnapshot? {
        let canonical = ConfigCommands.canonicalHardwareID(hardwareID)
        return panels.first { stableHardwareID(of: $0) == canonical }
    }

    func associatedDisplayName(forUSBPath path: String) -> String? {
        guard let device = usbDevices.first(where: { $0.path == path }) else { return nil }
        if let hardwareID = device.hardwareID,
           let panel = panelAssociated(withHardwareID: hardwareID) {
            return panel.displayName
        }
        return panels.first(where: {
            $0.usbPort == path && $0.hardwareID == nil && $0.usbHardwareID == nil
        })?.displayName
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

    func currentUSBPort(for serviceName: String) -> String? {
        guard let panel = panels.first(where: { $0.serviceName == serviceName })
        else { return nil }
        if let explicit = explicitLegacyUSBSelections[serviceName],
           explicit.generation == usbPathGeneration(explicit.path),
           usbDevices.contains(where: { $0.path == explicit.path && $0.isConnected }) {
            return explicit.path
        }
        let hardwareID = stableHardwareID(of: panel)
        if let hardwareID {
            let matches = usbDevices.filter { $0.hardwareID == hardwareID }
            if matches.count == 1 { return matches[0].path }
            if matches.count > 1 { return "Ambiguous" }
            return nil
        }
        guard let saved = panel.usbPort, usbSerialPorts.contains(saved) else { return nil }
        return saved
    }

    func usbPortOptions(for serviceName: String) -> [WifiConfigUI.USBDeviceOption] {
        guard let panel = panels.first(where: { $0.serviceName == serviceName })
        else { return usbDevices }
        if let hardwareID = panel.usbHardwareID {
            guard !usbDevices.contains(where: { $0.hardwareID == hardwareID }) else {
                return usbDevices
            }
            let disconnected = WifiConfigUI.USBDeviceOption(
                path: panel.usbPort ?? "",
                name: panel.displayName,
                hardwareID: hardwareID,
                isConnected: false)
            return [disconnected] + usbDevices
        }
        guard let assigned = panel.usbPort,
              !assigned.isEmpty,
              !usbDevices.contains(where: { $0.path == assigned })
        else { return usbDevices }
        let disconnected = WifiConfigUI.USBDeviceOption(
            path: assigned,
            name: panel.displayName,
            isConnected: false)
        return [disconnected] + usbDevices
    }

    func usbDeviceSelection(for serviceName: String) -> String {
        guard let panel = panels.first(where: { $0.serviceName == serviceName })
        else { return "" }
        if let hardwareID = panel.usbHardwareID { return "hardware:\(hardwareID)" }
        if let path = panel.usbPort { return "path:\(path)" }
        return ""
    }

    func setUSBDeviceSelection(_ selection: String, for serviceName: String) {
        let normalized = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            explicitLegacyUSBSelections[serviceName] = nil
            updatePanel(serviceName) { panel in
                panel.usbPort = nil
                panel.usbHardwareID = nil
            }
            persistIfNeeded(force: true)
            return
        }

        let options = usbPortOptions(for: serviceName)
        if normalized.hasPrefix("hardware:"),
           let hardwareID = ConfigCommands.canonicalHardwareID(
               String(normalized.dropFirst("hardware:".count))) {
            explicitLegacyUSBSelections[serviceName] = nil
            let device = options.first { $0.hardwareID == hardwareID }
            updatePanel(serviceName) { panel in
                panel.usbHardwareID = hardwareID
                panel.usbPort = device?.path.isEmpty == false ? device?.path : nil
            }
        } else if normalized.hasPrefix("path:") {
            let path = String(normalized.dropFirst("path:".count))
            let device = options.first { $0.path == path }
            if let device, device.isConnected, device.hardwareID == nil,
               !path.isEmpty {
                explicitLegacyUSBSelections[serviceName] = (
                    path: path, generation: usbPathGeneration(path))
            } else {
                explicitLegacyUSBSelections[serviceName] = nil
            }
            updatePanel(serviceName) { panel in
                panel.usbPort = path.isEmpty ? nil : path
                panel.usbHardwareID = device?.hardwareID
            }
        }
        persistIfNeeded(force: true)
    }

    /// Compatibility entry point for path-oriented callers and tests.
    func setUSBPort(_ port: String?, for serviceName: String) {
        let normalized = port?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path = normalized, !path.isEmpty else {
            setUSBDeviceSelection("", for: serviceName)
            return
        }
        let selection = usbPortOptions(for: serviceName)
            .first(where: { $0.path == path })?.selectionID ?? "path:\(path)"
        setUSBDeviceSelection(selection, for: serviceName)
    }

    /// Refresh transport paths without blocking the main actor. Only newly seen
    /// paths are identified automatically; the explicit refresh action below
    /// re-probes every connected device.
    func refreshUSBPorts() {
        let paths = WifiConfigUI.candidatePorts()
        let existing = Dictionary(
            usbDevices.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first })
        let removed = Set(existing.keys).subtracting(paths)
        for path in removed { invalidateUSBPath(path) }
        let added = paths.filter { existing[$0] == nil }
        for path in added { usbPathGenerations[path, default: 0] += 1 }
        let refreshed = paths.map { existing[$0] ?? WifiConfigUI.USBDeviceOption(path: $0) }
        if refreshed != usbDevices { usbDevices = refreshed }
        identifyUSBPorts(added)
    }

    func refreshUSBDevices() {
        refreshUSBPorts()
        for path in usbSerialPorts { invalidateUSBPath(path) }
        identifyUSBPorts(usbSerialPorts)
    }

    func usbPathGeneration(_ path: String) -> Int {
        usbPathGenerations[path, default: 0]
    }

    private func invalidateUSBPath(_ path: String) {
        usbPathGenerations[path, default: 0] += 1
        usbProbeTasks[path]?.task.cancel()
        usbProbeTasks[path] = nil
        let expired = explicitLegacyUSBSelections.compactMap { service, selection in
            selection.path == path ? service : nil
        }
        for service in expired { explicitLegacyUSBSelections[service] = nil }
    }

    /// Record identity learned either by a background CFGSHOW probe or by the
    /// setup sheet's selected-device inspection.
    func noteUSBIdentity(
        path: String,
        name: String?,
        hardwareID: String?,
        target: String? = nil,
        board: String? = nil
    ) {
        guard let index = usbDevices.firstIndex(where: { $0.path == path }) else { return }
        let canonicalID = ConfigCommands.canonicalHardwareID(hardwareID)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName?.isEmpty == false { usbDevices[index].name = trimmedName }
        if let canonicalID { usbDevices[index].hardwareID = canonicalID }
        if let target, !target.isEmpty { usbDevices[index].target = target }
        if let board, !board.isEmpty { usbDevices[index].board = board }

        guard let canonicalID else { return }
        var associationChanged = false
        for panelIndex in panels.indices {
            if panels[panelIndex].usbPort == path {
                if let savedID = panels[panelIndex].usbHardwareID {
                    if savedID != canonicalID {
                        // macOS reused this path for another board. Preserve the
                        // stable assignment and discard only the stale path hint.
                        panels[panelIndex].usbPort = nil
                        associationChanged = true
                    }
                } else if let panelID = ConfigCommands.canonicalHardwareID(
                    panels[panelIndex].hardwareID), panelID != canonicalID {
                    // A legacy record already knows this panel's MAC from EINF.
                    // Promote it before discarding the reused path so a later
                    // probe can still find the assigned board at its new path.
                    panels[panelIndex].usbHardwareID = panelID
                    panels[panelIndex].usbPort = nil
                    associationChanged = true
                } else {
                    // Legacy path-only assignment: migrate it once, never replace
                    // a non-nil identity merely because a path was reused.
                    panels[panelIndex].usbHardwareID = canonicalID
                    associationChanged = true
                }
            } else {
                let panelID = ConfigCommands.canonicalHardwareID(
                    panels[panelIndex].hardwareID)
                let hasLegacyPath = panels[panelIndex].usbPort?.isEmpty == false
                if panels[panelIndex].usbHardwareID == canonicalID
                    || (panels[panelIndex].usbHardwareID == nil
                        && hasLegacyPath && panelID == canonicalID)
                {
                    panels[panelIndex].usbHardwareID = canonicalID
                    panels[panelIndex].usbPort = path
                    associationChanged = true
                }
            }
        }
        if associationChanged { persistIfNeeded(force: true) }
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
        guard case .identified(let identity) = result else { return result }
        if let index = usbDevices.firstIndex(where: { $0.path == path }) {
            // A completed CFGSHOW probe is authoritative for discovery-scoped
            // target metadata. Clear an older value when current firmware omits it.
            usbDevices[index].target = identity.target
            usbDevices[index].board = identity.board
        }
        noteUSBIdentity(
            path: path,
            name: identity.name,
            hardwareID: identity.hardwareID,
            target: identity.target,
            board: identity.board)
        return result
    }

    func probeExistingFirmware(
        at path: String
    ) async -> UsbOnboarding.ExistingFirmware {
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
            return .answered(
                name: identity.name,
                hardwareID: identity.hardwareID)
        case .unavailable:
            return .silent
        }
    }

    func identifyUSBPorts(_ ports: [String]) {
        for path in ports {
            Task { @MainActor [weak self] in
                _ = await self?.probeUSBDevice(path)
            }
        }
    }

    func refreshSavedNetworks() {
        savedNetworkNames = WifiCredentialStore.savedNetworkNames()
    }

    /// Ask the device over USB which network it is actually on, and record
    /// the answer against the panel.
    ///
    /// Best-effort and silent: this runs on appearing, not on a button press,
    /// so a board that happens to be unreachable over USB right now (no
    /// cable, wrong port assigned, mid-reboot) should not raise an alert -
    /// the picker just falls back to its old default, same as before this
    /// existed. `Task.detached` because `WifiConfigUI.currentSSID` is
    /// blocking serial I/O with up to a several-second timeout, and this
    /// actor must not stall on it.
    func refreshCurrentSSID(for serviceName: String) {
        guard let panel = panels.first(where: { $0.serviceName == serviceName })
        else { return }
        let currentName = panel.displayName
        let expectedHardwareID = panel.usbHardwareID ?? panel.hardwareID
        let preferredPort = panel.usbPort
        Task { @MainActor [weak self] in
            let ssid = await Task.detached {
                WifiConfigUI.currentSSID(
                    currentName: currentName,
                    expectedHardwareID: expectedHardwareID,
                    preferredPort: preferredPort)
            }.value
            guard let ssid else { return }
            self?.updatePanel(serviceName) { $0.currentSSID = ssid }
        }
    }

}
