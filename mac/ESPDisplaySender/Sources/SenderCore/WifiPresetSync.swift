import Foundation
import SenderProtocol

struct WifiPresetSnapshot: Equatable, Sendable {
    var roster: ConfigCommands.WiFiPresetRoster
    var slots: [Int: ConfigCommands.WiFiPresetSlot]

    var activeSlot: Int? { roster.activeSlot }
    var localSelectorAvailable: Bool { roster.localSelectorAvailable }
}

enum WifiPresetSyncPlanner {
    enum PlanFailure: Error, Equatable {
        case wrongSlotCount(Int)
        case duplicateSSID(String)
        case missingCredential(slot: Int, ssid: String)
        case invalidCredential(slot: Int, ssid: String)
    }

    static func commands(
        desired: [String?],
        existing: [Int: ConfigCommands.WiFiPresetSlot],
        credentials: [String: SavedWiFiCredential]
    ) -> Result<[String], PlanFailure> {
        guard desired.count == ConfigCommands.wifiPresetSlotRange.count else {
            return .failure(.wrongSlotCount(desired.count))
        }

        var seen = Set<String>()
        for ssid in desired.compactMap({ $0 }) {
            guard seen.insert(ssid).inserted else {
                return .failure(.duplicateSSID(ssid))
            }
        }

        var setCommands: [String] = []
        var clearCommands: [String] = []
        for slot in ConfigCommands.wifiPresetSlotRange {
            let selected = desired[slot - 1]
            guard let selected else {
                if existing[slot] != nil,
                   let command = ConfigCommands.clearWifiPreset(slot: slot) {
                    clearCommands.append(command)
                }
                continue
            }

            guard let credential = credentials[selected] else {
                if existing[slot]?.ssid == selected {
                    continue
                }
                return .failure(.missingCredential(slot: slot, ssid: selected))
            }
            guard credential.ssid == selected,
                  let command = ConfigCommands.setWifiPreset(
                    slot: slot, ssid: credential.ssid,
                    password: credential.password)
            else {
                return .failure(.invalidCredential(slot: slot, ssid: selected))
            }
            setCommands.append(command)
        }

        // Clear only after every replacement credential has been accepted into
        // the plan. The device has no transaction, so this ordering preserves
        // the old choices if validation or an early serial write fails.
        return .success(setCommands + clearCommands)
    }
}

extension WifiConfigUI {
    typealias WifiPresetCommandSender =
        (_ command: String, _ port: String, _ timeout: TimeInterval) -> CommandResult

    static func readWifiPresets(
        port: String,
        send: WifiPresetCommandSender = {
            command, port, timeout in
            sendCommand(command, port: port, timeout: timeout)
        }
    ) -> Result<WifiPresetSnapshot, ConfigFailure> {
        let rosterReply: String
        switch send(ConfigCommands.showWifiPresets, port, 3) {
        case .success(let reply): rosterReply = reply
        case .failure(let reason):
            return .failure(ConfigFailure(
                title: "Could not read WiFi presets", message: reason))
        }
        guard let roster = ConfigCommands.wifiPresetRoster(from: rosterReply) else {
            return .failure(ConfigFailure(
                title: "Could not read WiFi presets",
                message: "The display returned an invalid preset roster. "
                    + "Flash current firmware and try again."))
        }

        var slots: [Int: ConfigCommands.WiFiPresetSlot] = [:]
        for slot in roster.validSlots.sorted() {
            guard let command = ConfigCommands.showWifiPreset(slot: slot) else {
                continue
            }
            let reply: String
            switch send(command, port, 3) {
            case .success(let value): reply = value
            case .failure(let reason):
                return .failure(ConfigFailure(
                    title: "Could not read WiFi preset \(slot)", message: reason))
            }
            guard let parsed = ConfigCommands.wifiPresetSlot(from: reply),
                  parsed.slot == slot,
                  parsed.active == (roster.activeSlot == slot)
            else {
                return .failure(ConfigFailure(
                    title: "Could not read WiFi preset \(slot)",
                    message: "The display returned inconsistent slot data."))
            }
            slots[slot] = parsed
        }
        return .success(WifiPresetSnapshot(roster: roster, slots: slots))
    }

    static func syncWifiPresets(
        _ desired: [String?],
        credentials: [String: SavedWiFiCredential],
        port: String,
        send: WifiPresetCommandSender = {
            command, port, timeout in
            sendCommand(command, port: port, timeout: timeout)
        }
    ) -> Result<WifiPresetSnapshot, ConfigFailure> {
        let before: WifiPresetSnapshot
        switch readWifiPresets(port: port, send: send) {
        case .success(let snapshot): before = snapshot
        case .failure(let failure): return .failure(failure)
        }

        let commands: [String]
        switch WifiPresetSyncPlanner.commands(
            desired: desired, existing: before.slots, credentials: credentials)
        {
        case .success(let planned): commands = planned
        case .failure(let failure):
            return .failure(configFailure(for: failure))
        }

        for (index, command) in commands.enumerated() {
            if case .failure(let reason) = send(command, port, 6) {
                return .failure(ConfigFailure(
                    title: "WiFi preset sync stopped",
                    message: "Command \(index + 1) of \(commands.count) failed: \(reason). "
                        + "The display may contain part of the requested collection; "
                        + "reload it before retrying."))
            }
        }

        let after: WifiPresetSnapshot
        switch readWifiPresets(port: port, send: send) {
        case .success(let snapshot): after = snapshot
        case .failure(let failure): return .failure(failure)
        }
        for slot in ConfigCommands.wifiPresetSlotRange {
            guard after.slots[slot]?.ssid == desired[slot - 1] else {
                return .failure(ConfigFailure(
                    title: "WiFi preset verification failed",
                    message: "Slot \(slot) did not match after synchronization."))
            }
        }
        return .success(after)
    }

    private static func configFailure(
        for failure: WifiPresetSyncPlanner.PlanFailure
    ) -> ConfigFailure {
        switch failure {
        case .wrongSlotCount(let count):
            return ConfigFailure(
                title: "Invalid WiFi preset collection",
                message: "Expected 10 slots, but received \(count).")
        case .duplicateSSID(let ssid):
            return ConfigFailure(
                title: "Duplicate WiFi preset",
                message: "\"\(ssid)\" is assigned more than once.")
        case .missingCredential(let slot, let ssid):
            return ConfigFailure(
                title: "Credential not found",
                message: "Slot \(slot) uses \"\(ssid)\", but its password is not "
                    + "available in Keychain. Add the credential again or clear the slot.")
        case .invalidCredential(let slot, let ssid):
            return ConfigFailure(
                title: "Invalid WiFi credential",
                message: "Slot \(slot) uses \"\(ssid)\", whose SSID or password exceeds "
                    + "the device limits.")
        }
    }
}
