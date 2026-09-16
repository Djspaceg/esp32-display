import AppKit
import Foundation
import Network
import ScreenCaptureKit
import SenderProtocol

/// Serial configuration over USB: rename, WiFi credentials, OTA
/// password, and onboarding a new display (the only path that
/// creates a sidebar record).
extension PanelManager {
    func rename(_ newName: String, for serviceName: String) {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }) else { return }
        guard requireOperation(.rename, for: serviceName, title: "Rename") else { return }
        switch WifiConfigUI.renameDevice(
            currentName: panel.displayName,
            newName: newName,
            preferredPort: panel.usbPort,
            expectedHardwareID: panel.usbHardwareID ?? panel.hardwareID)
        {
        case .success(let appliedName):
            if appliedName != serviceName,
               let index = panels.firstIndex(where: { $0.serviceName == serviceName }) {
                supersededServiceNames.insert(serviceName)
                supersededServiceNames.remove(appliedName)
                sessions.removeValue(forKey: serviceName)?.stop()
                panels[index].serviceName = appliedName
                panels[index].displayName = appliedName
                if selectedServiceName == serviceName {
                    selectedServiceName = appliedName
                }
                sortPanels()
            } else {
                updatePanel(serviceName) { $0.displayName = appliedName }
            }
            markUSBRestarting(appliedName)
            persistIfNeeded(force: true)
            operationOutcome = .success(
                "Name saved",
                "The display is restarting as \"\(appliedName)\". Streaming "
                    + "reconnects automatically.")
        case .failure(let failure):
            operationOutcome = .failure(failure)
        }
    }

    /// Set a panel's OTA password over USB, validating it the same way the
    /// panel will (`OTAPasswordPolicy.judge`), so a rejection is a message
    /// from this Mac in under a second rather than a round trip through the
    /// panel's own `CFGERR`.
    ///
    /// On success the password is remembered in Keychain when `remember` is
    /// true, exactly as a password typed into the firmware update sheet
    /// would be - this is the same secret, filed under the same hardware ID,
    /// so a push right after setting it here does not ask for it again.
    func setOTAPassword(_ password: String, remember: Bool, for serviceName: String) {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }) else { return }
        let verdict = OTAPasswordPolicy.judge(password)
        guard verdict.isAcceptable else {
            operationOutcome = .failure(
                "Invalid OTA password", OTAPasswordPolicy.explain(verdict) ?? "")
            return
        }
        guard requireOperation(
            .otaPassword, for: serviceName, title: "OTA password")
        else { return }
        switch WifiConfigUI.setOTAPassword(
            password,
            currentName: panel.displayName,
            preferredPort: panel.usbPort,
            expectedHardwareID: panel.usbHardwareID ?? panel.hardwareID)
        {
        case .success:
            markUSBRestarting(serviceName)
            var keychainNote = ""
            if remember, let hardwareID = panel.hardwareID {
                if let failure = setRememberedOTAPassword(password, for: hardwareID) {
                    keychainNote = " The password was set, but Keychain storage failed: "
                        + failure
                }
            }
            operationOutcome = .success(
                "OTA password saved",
                "The OTA password was saved and the display is restarting. "
                    + "Wireless updates become available after it rejoins WiFi "
                    + "and reports that its OTA listener is active." + keychainNote)
        case .failure(let failure):
            operationOutcome = .failure(failure)
        }
    }

    /// Clear a panel's OTA password over USB, turning OTA back off, and
    /// forget any remembered copy - a cleared password left in Keychain
    /// would silently offer itself the next time someone opens the update
    /// sheet for a panel that no longer has OTA enabled at all.
    func clearOTAPassword(for serviceName: String) {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }) else { return }
        guard requireOperation(
            .otaPassword, for: serviceName, title: "OTA password")
        else { return }
        switch WifiConfigUI.clearOTAPassword(
            currentName: panel.displayName,
            preferredPort: panel.usbPort,
            expectedHardwareID: panel.usbHardwareID ?? panel.hardwareID)
        {
        case .success:
            markUSBRestarting(serviceName)
            if let hardwareID = panel.hardwareID {
                _ = setRememberedOTAPassword(nil, for: hardwareID)
            }
            operationOutcome = .success(
                "OTA password cleared",
                "The display is restarting with OTA disabled.")
        case .failure(let failure):
            operationOutcome = .failure(failure)
        }
    }

    func applySavedNetwork(_ ssid: String, to serviceName: String) {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }) else { return }
        guard !ssid.isEmpty else {
            operationOutcome = .failure(
                "No network selected", "Select a saved WiFi network first.")
            return
        }
        guard requireOperation(
            .savedWiFi, for: serviceName, title: "WiFi configuration")
        else { return }
        switch WifiConfigUI.applySavedNetwork(
            ssid,
            currentName: panel.displayName,
            preferredPort: panel.usbPort,
            expectedHardwareID: panel.usbHardwareID ?? panel.hardwareID)
        {
        case .success:
            markUSBRestarting(serviceName)
            operationOutcome = .success(
                "WiFi saved",
                "The display is restarting and joining \"\(ssid)\". Streaming "
                    + "reconnects automatically.")
        case .failure(let failure):
            operationOutcome = .failure(failure)
        }
    }

    func wifiPresets(
        for serviceName: String
    ) async -> Result<WifiPresetSnapshot, WifiConfigUI.ConfigFailure> {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }) else {
            return .failure(WifiConfigUI.ConfigFailure(
                title: "Display not found",
                message: "The selected display is no longer available."))
        }
        let currentName = panel.displayName
        let preferredPort = panel.usbPort
        let expectedHardwareID = panel.usbHardwareID ?? panel.hardwareID
        return await Task.detached(priority: .userInitiated) {
            WifiConfigUI.wifiPresets(
                currentName: currentName,
                preferredPort: preferredPort,
                expectedHardwareID: expectedHardwareID)
        }.value
    }

    /// Apply an explicit slot collection from the preset sheet.
    ///
    /// `protectedSlot` carries the slot the display is currently joined
    /// through. It is passed rather than inferred so that the sheet's own view
    /// of which slot is active - the one it shows as Active and refuses to let
    /// the user edit - is the same one the write refuses to touch.
    func syncWifiPresets(
        _ desired: [String?],
        protectedSlot: Int? = nil,
        for serviceName: String
    ) async -> Result<WifiPresetSnapshot, WifiConfigUI.ConfigFailure> {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }) else {
            return .failure(WifiConfigUI.ConfigFailure(
                title: "Display not found",
                message: "The selected display is no longer available."))
        }
        let currentName = panel.displayName
        let preferredPort = panel.usbPort
        let expectedHardwareID = panel.usbHardwareID ?? panel.hardwareID
        let result = await Task.detached(priority: .userInitiated) {
            WifiConfigUI.syncWifiPresets(
                desired,
                currentName: currentName,
                protectedSlot: protectedSlot,
                preferredPort: preferredPort,
                expectedHardwareID: expectedHardwareID)
        }.value
        // A hand-edited collection is now what the board holds, which is not
        // what the automatic sync last recorded. Forget the signature so the
        // next verified probe reconciles the board with the saved collection.
        if let hardwareID = stableHardwareID(of: panel) {
            forgetWifiPresetSync(hardwareID: hardwareID)
        }
        return result
    }

    func configureUSB(preferredSSID: String? = nil) {
        guard let panel = selectedPanel else {
            operationOutcome = .failure(
                "No display selected", "Select a display before configuring WiFi.")
            return
        }
        guard requireOperation(
            .savedWiFi, for: panel.serviceName, title: "WiFi configuration")
        else { return }
        let result = WifiConfigUI.run(
            currentName: panel.displayName,
            expectedHardwareID: panel.usbHardwareID ?? panel.hardwareID,
            preferredPort: panel.usbPort,
            preferredSSID: preferredSSID)
        refreshSavedNetworks()
        refreshUSBPorts()
        switch result {
        case .success(let confirmation):
            // nil means the user cancelled, which needs no announcement.
            if let confirmation {
                if confirmation.restartsDisplay {
                    markUSBRestarting(panel.serviceName)
                }
                operationOutcome = .success(confirmation.title, confirmation.message)
            }
        case .failure(let failure):
            operationOutcome = .failure(failure)
        }
    }


    // MARK: adding a display over USB

    /// Everything one onboarding run needs, gathered by the sheet so this cannot
    /// be called half-configured.
    ///
    /// The port is in here as a value rather than being looked up, and it is used
    /// once: for the flash. Nothing persists it. The same physical board was seen
    /// on this machine at /dev/cu.usbmodem1101 and then at /dev/cu.usbmodem101
    /// after a reset, so a stored path stops being that board's path the first time
    /// it restarts - which on this path is immediately, twice.
    struct USBOnboardRequest {
        var port: String
        var mode: UsbOnboarding.Mode
        /// nil in configure-only mode, where nothing is written.
        var bundle: FirmwareBundle?
        /// Exact firmware target selected in the Add Display sheet.
        var target: String?
        var chip: String?
        var mac: String?
        /// Canonical station-MAC identity learned from CFGSHOW or esptool.
        var hardwareID: String?
        /// USB enumeration generation captured by the Add sheet. It must still
        /// match immediately before any write begins.
        var usbPathGeneration: Int
        /// Name reported before onboarding, used when the user leaves Name blank.
        var existingName: String?
        var tool: EsptoolCommand.Tool?
        var ssid: String
        var password: ConfigCommands.PasswordChange
        /// Empty to leave the board's own name alone.
        var name: String
        /// Erase the whole chip first. Never on by default: it takes NVS with it,
        /// which is where a board that has been set up before keeps its
        /// credentials and its name.
        var eraseAll: Bool
    }

    /// Write/configure one physical board and create its durable sidebar record.
    /// The record is saved before network discovery: discovery makes an existing
    /// record online, but is never allowed to invent ownership of hardware.
    ///
    /// Returns whether it got all the way, so the sheet can stay open on a failure
    /// with everything still filled in.
    func onboardUSBDevice(
        _ request: USBOnboardRequest,
        progress: @escaping @Sendable (UsbOnboarder.Progress) -> Void
    ) async -> Bool {
        guard let stableID = ConfigCommands.canonicalHardwareID(
            request.hardwareID ?? request.mac)
        else {
            operationOutcome = .failure(
                "Could not identify this board",
                "A permanent display record needs the board's hardware ID. Refresh "
                    + "the USB devices and select it again before continuing.")
            return false
        }
        if let existing = panelAssociated(withHardwareID: stableID) {
            selectedServiceName = existing.serviceName
            operationOutcome = .failure(
                "Display already added",
                "\(existing.displayName) is already represented in the sidebar.")
            return false
        }
        let requestedName = WifiConfigUI.normalizedDeviceName(request.name)
        let priorName = WifiConfigUI.normalizedDeviceName(request.existingName ?? "")
        let recordName = !requestedName.isEmpty
            ? requestedName
            : !priorName.isEmpty
                ? priorName
                : "espdisplay-" + stableID.suffix(4)
        if let collision = panels.first(where: {
            $0.serviceName == recordName
                && stableHardwareID(of: $0) != stableID
        }) {
            operationOutcome = .failure(
                "Display name already in use",
                "\(collision.displayName) already owns the name \"\(recordName)\". "
                    + "Enter a unique name for this board before adding it.")
            return false
        }
        guard usbPathGeneration(request.port) == request.usbPathGeneration,
              usbDevices.contains(where: { $0.path == request.port && $0.isConnected })
        else {
            operationOutcome = .failure(
                "USB device changed",
                "The selected serial port was unplugged, renumbered, or reused. "
                    + "Refresh the device list and select the board again.")
            return false
        }

        // Re-read identity at the last safe point before a write. CFGSHOW is
        // enough on current firmware; blank/legacy boards are verified through
        // esptool's chip and MAC read, which is non-destructive.
        var cfgIdentityMatched = false
        var cfgTarget: String?
        if case .identified(let identity) = await probeUSBDevice(request.port, timeout: 3),
           let reportedID = ConfigCommands.canonicalHardwareID(identity.hardwareID) {
            guard reportedID == stableID else {
                operationOutcome = .failure(
                    "USB device mismatch",
                    "The board now connected at \(request.port) is not the one "
                        + "that was selected, so nothing was written.")
                return false
            }
            cfgIdentityMatched = true
            cfgTarget = identity.target
            if let selectedTarget = request.target,
               let reportedTarget = identity.target,
               selectedTarget != reportedTarget {
                operationOutcome = .failure(
                    "USB target mismatch",
                    "The selected target is \(selectedTarget), but CFGSHOW reports "
                        + "\(reportedTarget). Nothing was written.")
                return false
            }
        }
        var verifiedChip = request.chip
        if request.mode == .flashAndConfigure || !cfgIdentityMatched {
            guard let tool = request.tool else {
                operationOutcome = .failure(
                    "Could not verify this board",
                    "esptool is required to re-read the chip and MAC before writing.")
                return false
            }
            let detection = await UsbOnboarder.detectChip(port: request.port, tool: tool)
            guard case .detected(let chip, let mac) = detection,
                  ConfigCommands.canonicalHardwareID(mac) == stableID,
                  request.chip == nil || request.chip == chip
            else {
                operationOutcome = .failure(
                    "USB device mismatch",
                    "The chip or MAC at \(request.port) changed after inspection, "
                        + "so nothing was written.")
                return false
            }
            verifiedChip = chip
        }
        guard usbPathGeneration(request.port) == request.usbPathGeneration else {
            operationOutcome = .failure(
                "USB device changed",
                "The serial device changed during verification, so nothing was written.")
            return false
        }

        let steps = UsbOnboarding.configurationSteps(
            name: request.name, ssid: request.ssid, password: request.password)

        if request.mode == .flashAndConfigure {
            let exactTarget = request.target
                ?? cfgTarget
                ?? (verifiedChip == "esp32c6" ? "c6" : nil)
            guard let bundle = request.bundle,
                  let chip = verifiedChip,
                  let exactTarget,
                  let image = bundle.image(forTarget: exactTarget),
                  image.chip == chip,
                  let tool = request.tool,
                  let writes = bundle.flashPlan(forTarget: exactTarget)
            else {
                // The sheet's button is gated on `UsbOnboardingPlan.canStart`, so
                // reaching here means the two disagree. Reported rather than
                // asserted: an alert that says what is missing beats a crash in a
                // shipped app.
                operationOutcome = .failure(
                    "Cannot write this board",
                    "The firmware, exact target, chip and esptool are not all known "
                        + "and mutually compatible, so nothing was sent.")
                return false
            }
            do {
                try await UsbOnboarder.flash(
                    writes: writes, chip: chip, port: request.port, tool: tool,
                    eraseAll: request.eraseAll, onProgress: progress)
            } catch let failure as WifiConfigUI.ConfigFailure {
                operationOutcome = .failure(failure)
                return false
            } catch {
                operationOutcome = .failure(
                    "Flashing failed", error.localizedDescription)
                return false
            }
        }

        let finalPort: String
        switch await UsbOnboarder.sendConfiguration(
            steps: steps, flashedPort: request.port,
            expectedHardwareID: stableID, onProgress: progress)
        {
        case .success(let port):
            finalPort = port
        case .failure(let failure):
            operationOutcome = .failure(failure)
            return false
        }

        // Remembered only once the board has taken it, so a credential that was
        // refused does not end up in the keychain looking like a working one. Same
        // ordering WifiConfigUI.run uses.
        var keychainNote = ""
        switch request.password {
        case .set(let password):
            keychainNote = WifiCredentialStore.save(ssid: request.ssid, password: password)
                ? " The credential is saved in your Keychain."
                : " The board was configured, but Keychain storage failed."
        case .openNetwork:
            keychainNote = WifiCredentialStore.save(ssid: request.ssid, password: "")
                ? " The open network is saved in your Keychain."
                : " The board was configured, but Keychain storage failed."
        case .keepCurrent:
            break
        }
        refreshSavedNetworks()
        refreshUSBPorts()

        // Recheck after the write/configuration window: another Add sheet or a
        // background identity probe may have associated this board meanwhile.
        if let existing = panelAssociated(withHardwareID: stableID) {
            selectedServiceName = existing.serviceName
            operationOutcome = .success(
                "Display already recorded",
                "\(existing.displayName) was configured and its existing record is selected.")
            return true
        }

        let serviceName = recordName
        let record = PanelSnapshot(
            serviceName: serviceName,
            displayName: recordName,
            hardwareID: stableID,
            usbPort: finalPort,
            usbHardwareID: stableID)
        supersededServiceNames.remove(serviceName)
        panels.append(record)
        sortPanels()
        selectedServiceName = serviceName
        persistIfNeeded(force: true)

        let wrote = request.mode == .flashAndConfigure
            ? "\(request.bundle?.firmwareVersion ?? "the firmware") is on the board and it "
            : "The board "
        let named = request.name.isEmpty
            ? ""
            : " It is called \"\(WifiConfigUI.normalizedDeviceName(request.name))\"."
        operationOutcome = .success(
            request.mode == .flashAndConfigure ? "Board set up" : "WiFi saved",
            wrote + "is joining \"\(request.ssid)\". Its record is now in the "
                + "sidebar and becomes Online when the board announces itself, "
                + "which takes a few seconds." + named + keychainNote)
        return true
    }

    /// The saved credential for a network, for the onboarding sheet.
    ///
    /// Keychain access stays in the manager rather than in the view, which is where
    /// every other credential read in this app already lives.
    func savedWifiCredential(for ssid: String) -> SavedWiFiCredential? {
        guard !ssid.isEmpty else { return nil }
        return WifiCredentialStore.credential(for: ssid)
    }

}
