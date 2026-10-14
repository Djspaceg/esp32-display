import Foundation
import SenderProtocol

/// What a switch from a board's page is doing, for its WiFi row.
enum WifiSwitchState: Equatable, Sendable {
    /// `CFGWIFIUSE` went out at `since`, and the board is restarting onto the
    /// network. Over once the board reports it, or after
    /// `PanelManager.wifiSwitchPatience`.
    case switching(String, since: Date)
    /// Why the last switch did not happen. Cleared by the next one.
    case failed(String)
}

/// Switching a board to one of the saved networks, from the WiFi pop-up on
/// its page.
///
/// Only over USB: `CFGWIFIUSE` is a serial config command, and the network
/// control protocol has no WiFi command at all (brightness, flip, rotation,
/// power, identify and restart only). The saved collection is copied first,
/// through the same sync the automatic copy runs, so the chosen network is in
/// one of the board's slots before that slot is chosen.
extension PanelManager {
    /// How long a switch shows as in progress while the board restarts and
    /// rejoins, after which the row shows what the board reports again.
    static let wifiSwitchPatience: TimeInterval = 90

    /// Why the board's WiFi pop-up cannot switch, or nil when it can. A copy
    /// to the board in flight disables it rather than refusing a choice
    /// afterwards, so no error is left behind by picking too early.
    func wifiSwitchUnavailableReason(for serviceName: String) -> String? {
        if let device = wifiPresetSyncDevice(for: serviceName) {
            if let hardwareID = ConfigCommands.canonicalHardwareID(device.hardwareID),
               wifiPresetSyncTasks[hardwareID] != nil {
                return "Copying the saved networks to this display."
            }
            return nil
        }
        if usbRestartingServices.contains(serviceName) {
            return "This display is restarting."
        }
        if let device = verifiedUSBDevice(for: serviceName) {
            if !Self.runsStreamFirmware(device.serialStatus) {
                return "This display is running its rescue firmware, which "
                    + "cannot switch networks."
            }
            return "This display is busy over USB. Try again in a moment."
        }
        if usbSerialPairedDevice(for: serviceName) != nil {
            return "Connected by USB. Waiting for this display to answer."
        }
        return "Connect this display to the Mac by USB to switch its network. "
            + "Over WiFi the display has no command for it."
    }

    /// Copy the saved networks to the board, then choose `ssid`'s slot, which
    /// restarts the board onto it. Holds the board's sync slot while it runs,
    /// so the automatic copy does not write beside it.
    func switchWifi(to ssid: String, for serviceName: String) {
        if let reason = wifiSwitchUnavailableReason(for: serviceName) {
            setWifiSwitchState(.failed(reason), for: serviceName)
            return
        }
        guard let device = wifiPresetSyncDevice(for: serviceName),
              let hardwareID = ConfigCommands.canonicalHardwareID(device.hardwareID)
        else { return }
        let savedSSIDs = savedNetworkNames
        guard savedSSIDs.contains(ssid) else {
            setWifiSwitchState(
                .failed("\"\(ssid)\" is not saved on this Mac."), for: serviceName)
            return
        }
        guard wifiPresetSyncTasks[hardwareID] == nil else {
            setWifiSwitchState(
                .failed("Still copying networks to this display. Try again in a moment."),
                for: serviceName)
            return
        }

        setWifiSwitchState(.switching(ssid, since: Date()), for: serviceName)
        let path = device.path
        let generation = usbPathGeneration(path)
        let signature = currentWifiPresetSyncSignature(hardwareID: hardwareID)
        let lookup = wifiCredentialLookup
        let sender = usbControlSender
        wifiPresetSyncTasks[hardwareID] = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                var credentials: [String: SavedWiFiCredential] = [:]
                for saved in savedSSIDs {
                    credentials[saved] = lookup(saved)
                }
                return WifiConfigUI.switchSavedWifiPreset(
                    to: ssid, savedSSIDs: savedSSIDs, credentials: credentials,
                    port: path, send: sender)
            }.value
            guard let self else { return }
            guard !Task.isCancelled else {
                // `forgetWifiPresetSync` let go of the board under it, but the
                // work it started ran on: if the choice went out, the board is
                // restarting onto it all the same.
                if case .success(let outcome) = result, outcome.restarted {
                    self.markUSBRestarting(serviceName)
                } else {
                    self.setWifiSwitchState(nil, for: serviceName)
                }
                return
            }
            self.wifiPresetSyncTasks[hardwareID] = nil
            switch result {
            case .success(let outcome):
                // The restart may renumber the port before this runs, so a new
                // generation is not a failure here; it only means what was
                // copied is not recorded as this board's state.
                if self.usbPathGeneration(path) == generation {
                    self.syncedWifiPresetSignatures[hardwareID] = signature
                }
                self.wifiPresetSyncReports[hardwareID] = outcome.report
                self.resolve(.wifiPresetSync, source: hardwareID)
                if outcome.restarted {
                    self.markUSBRestarting(serviceName)
                } else {
                    self.setWifiSwitchState(nil, for: serviceName)
                }
            case .failure(let failure):
                self.syncedWifiPresetSignatures[hardwareID] = nil
                self.setWifiSwitchState(.failed(failure.message), for: serviceName)
            }
        }
    }

    /// The switch state the row shows now: nil once the board reports the
    /// network it was switched to, or once the wait is over.
    func wifiSwitchState(for serviceName: String, asOf now: Date) -> WifiSwitchState? {
        guard let state = wifiSwitchStates[serviceName] else { return nil }
        guard case .switching(let ssid, let since) = state else { return state }
        let reported = panels.first { $0.serviceName == serviceName }?
            .boardSSID(asOf: now)
        if reported == ssid || now.timeIntervalSince(since) > Self.wifiSwitchPatience {
            return nil
        }
        return state
    }

    /// A copy to the board went through, or the board left USB: a failed
    /// switch on it describes a state that is gone, so its error goes too.
    func clearWifiSwitchFailures(hardwareID: String) {
        for panel in panels where stableHardwareID(of: panel) == hardwareID {
            if case .failed? = wifiSwitchStates[panel.serviceName] {
                setWifiSwitchState(nil, for: panel.serviceName)
            }
        }
    }

    private func setWifiSwitchState(_ state: WifiSwitchState?, for serviceName: String) {
        guard wifiSwitchStates[serviceName] != state else { return }
        objectWillChange.send()
        wifiSwitchStates[serviceName] = state
    }
}
