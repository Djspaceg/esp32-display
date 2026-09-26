import Foundation
import SenderProtocol

/// Copying the app's saved WiFi networks into a board's ten device slots,
/// automatically, whenever that board is present on USB.
///
/// The app holds every credential already, so there is nothing for the user to
/// press: a board that answers CFGSHOW on a serial port gets the current
/// collection, and a change to the collection is pushed to every board that is
/// still attached.
///
/// Three things this deliberately does not do:
///
/// - It never sends `CFGWIFIUSE`. Activating a preset restarts the board, and
///   choosing a network is the on-device picker's job, not a side effect of
///   plugging in a cable.
/// - It never touches the slot the board reports as active. See
///   `WifiPresetSlotPlan`.
/// - It does nothing at all when the app has no saved networks. An empty
///   collection means "nothing to copy", not "erase the board's presets".
extension PanelManager {
    /// The serial state a preset sync requires.
    ///
    /// This is `usbSerialState`'s `.verified`, not the weaker `usbFlashDevice`:
    /// preset commands go to the running firmware's config console, so a live
    /// CFGSHOW response at the current path generation is the thing that has to
    /// be true. A board that only identifies itself well enough to be flashed
    /// is not necessarily answering the console.
    ///
    /// AND IT HAS TO BE THE STREAM FIRMWARE. The rescue image answers CFGSHOW
    /// with an identity-only CFGINFO - id, board, target, chip, partition - and
    /// ignores every other line, so a board running it verifies and would then
    /// time out on CFGWIFISHOW. Stream firmware is recognised by `fw=` or by
    /// `ssid64=`: `fw=` is its last token and a 1.5.0 build from before the
    /// serial fix (91114af) can lose it to a 256-byte cut, while `ssid64=` is its
    /// first and survives. The rescue image sends neither. Such a board is
    /// waited for, not reported: the stream firmware's next CFGSHOW arrives here
    /// again.
    ///
    /// Nor while a USB flash or onboarding run owns the board; the run's end
    /// re-probes it (`finishUSBFlash`).
    func wifiPresetSyncDevice(
        for serviceName: String
    ) -> WifiConfigUI.USBDeviceOption? {
        guard let device = verifiedUSBDevice(for: serviceName),
              device.isConnected,
              !device.path.isEmpty,
              device.hardwareID?.isEmpty == false,
              Self.runsStreamFirmware(device.serialStatus),
              let hardwareID = ConfigCommands.canonicalHardwareID(device.hardwareID),
              usbFlashesInFlight[hardwareID] == nil
        else { return nil }
        return device
    }

    /// Whether a CFGSHOW status came from the stream firmware's console.
    static func runsStreamFirmware(_ status: WifiConfigUI.USBStatus?) -> Bool {
        guard let status else { return false }
        return status.firmwareVersion?.isEmpty == false || status.currentSSID != nil
    }

    /// A USB flash or onboarding run is starting on this board: automatic
    /// preset syncs hold off until `finishUSBFlash`.
    func beginUSBFlash(hardwareID: String) {
        guard let canonical = ConfigCommands.canonicalHardwareID(hardwareID) else { return }
        usbFlashesInFlight[canonical, default: 0] += 1
        usbFlashEpochs[canonical, default: 0] += 1
    }

    /// The run is over, however it ended. Its own settle probing never updates
    /// the device list, so what the list says about this board predates the
    /// run: it is invalidated and asked again, and a fresh CFGSHOW from the
    /// stream firmware is what starts the sync (through `noteUSBIdentity`).
    ///
    /// `wroteFlash` is whether esptool was started on the board. Only then is
    /// what was last copied unknown; a run that stopped at a check wrote
    /// nothing, and rewriting nine slots for it would be churn.
    func finishUSBFlash(hardwareID: String, wroteFlash: Bool) {
        guard let canonical = ConfigCommands.canonicalHardwareID(hardwareID),
              let count = usbFlashesInFlight[canonical]
        else { return }
        if count > 1 {
            usbFlashesInFlight[canonical] = count - 1
        } else {
            usbFlashesInFlight[canonical] = nil
        }
        if wroteFlash { syncedWifiPresetSignatures[canonical] = nil }
        guard usbFlashesInFlight[canonical] == nil else { return }
        let paths = usbDevices.indices.compactMap { index -> String? in
            guard ConfigCommands.canonicalHardwareID(usbDevices[index].hardwareID)
                    == canonical
            else { return nil }
            usbDevices[index].serialStatus = nil
            usbDevices[index].verifiedGeneration = nil
            return usbDevices[index].path
        }
        for path in paths {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let reprobe = self.usbControlReprobe {
                    await reprobe(path, 3)
                } else {
                    _ = await self.probeUSBDevice(path, timeout: 3)
                }
            }
        }
    }

    /// What a sync would be copying. Compared against the last successful sync
    /// so a repeat probe is not a repeat write.
    static func wifiPresetSyncSignature(
        hardwareID: String, ssids: [String]
    ) -> String {
        ([hardwareID] + WifiPresetSlotPlan.sortedSSIDs(ssids))
            .joined(separator: "\n")
    }

    /// Push the saved collection to every board that is attached and verified.
    /// Called when the app's own list of saved networks changes.
    func syncWifiPresetsToAttachedDevices() {
        for serviceName in panels.map(\.serviceName) {
            syncWifiPresetsIfNeeded(for: serviceName)
        }
    }

    /// Push the saved collection to one board if it is attached, verified, and
    /// does not already hold exactly this collection.
    func syncWifiPresetsIfNeeded(for serviceName: String) {
        guard let device = wifiPresetSyncDevice(for: serviceName),
              let hardwareID = device.hardwareID
        else { return }
        let savedSSIDs = savedNetworkNames
        guard !savedSSIDs.isEmpty else { return }
        let signature = Self.wifiPresetSyncSignature(
            hardwareID: hardwareID, ssids: savedSSIDs)
        guard syncedWifiPresetSignatures[hardwareID] != signature,
              wifiPresetSyncTasks[hardwareID] == nil
        else { return }

        let path = device.path
        let generation = usbPathGeneration(path)
        let lookup = wifiCredentialLookup
        let sender = usbControlSender
        let displayName = panels.first { $0.serviceName == serviceName }?
            .displayName ?? serviceName

        let epoch = usbFlashEpochs[hardwareID, default: 0]
        let work = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                var credentials: [String: SavedWiFiCredential] = [:]
                for ssid in savedSSIDs {
                    if let credential = lookup(ssid) {
                        credentials[ssid] = credential
                    }
                }
                return WifiConfigUI.syncSavedWifiPresets(
                    savedSSIDs: savedSSIDs,
                    credentials: credentials,
                    port: path,
                    send: { command, port, timeout in
                        sender(command, port, timeout)
                    })
            }.value

            guard let self else { return }
            self.wifiPresetSyncTasks[hardwareID] = nil
            // A run that started while this was running reset the board under
            // it; whatever this saw is not a verdict on the board. If that run
            // is already over, its re-probe may have been turned away by this
            // task still being registered, so the sync is tried again here.
            guard self.usbFlashEpochs[hardwareID, default: 0] == epoch else {
                if self.usbFlashesInFlight[hardwareID] == nil {
                    self.syncWifiPresetsIfNeeded(for: serviceName)
                }
                return
            }
            // The board that was written to has to still be the board that was
            // measured. A renumbered or unplugged path invalidates the result
            // rather than recording it as this board's state.
            guard self.usbPathGeneration(path) == generation else {
                self.syncedWifiPresetSignatures[hardwareID] = nil
                return
            }
            switch result {
            case .success(let report):
                self.syncedWifiPresetSignatures[hardwareID] = signature
                self.wifiPresetSyncReports[hardwareID] = report
                self.objectWillChange.send()
            case .failure(let failure):
                // Cleared so the next probe retries. A half-written collection
                // must not look synchronized.
                self.syncedWifiPresetSignatures[hardwareID] = nil
                self.report(
                    .wifiPresetSync,
                    detail: "\(displayName): \(failure.title). \(failure.message)")
            }
        }
        wifiPresetSyncTasks[hardwareID] = work
    }

    /// The last sync's report for the board behind a record, if there is one.
    func wifiPresetSyncReport(for serviceName: String) -> WifiPresetSyncReport? {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }),
              let hardwareID = stableHardwareID(of: panel)
        else { return nil }
        return wifiPresetSyncReports[hardwareID]
    }

    /// Forget a board's synchronized state, so the next time it is verified the
    /// collection is copied again.
    func forgetWifiPresetSync(hardwareID: String) {
        guard let canonical = ConfigCommands.canonicalHardwareID(hardwareID)
        else { return }
        syncedWifiPresetSignatures[canonical] = nil
        wifiPresetSyncTasks.removeValue(forKey: canonical)?.cancel()
    }
}
