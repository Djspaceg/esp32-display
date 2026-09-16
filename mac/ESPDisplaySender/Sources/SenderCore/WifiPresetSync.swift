import Foundation
import SenderProtocol

struct WifiPresetSnapshot: Equatable, Sendable {
    var roster: ConfigCommands.WiFiPresetRoster
    var slots: [Int: ConfigCommands.WiFiPresetSlot]

    var activeSlot: Int? { roster.activeSlot }
    var localSelectorAvailable: Bool { roster.localSelectorAvailable }

    /// The SSID the display is currently joined through, when it is joined
    /// through a slot rather than its direct credential.
    var activeSSID: String? {
        guard let activeSlot else { return nil }
        return slots[activeSlot]?.ssid
    }
}

/// Which saved network goes in which device slot.
///
/// Two rules meet here and can disagree, so the order they are applied in is
/// the whole point of this type:
///
/// 1. The app's saved networks are sorted by SSID and truncated to the ten
///    slots the device has.
/// 2. The slot the device reports as ACTIVE is not touched. Its content stays
///    exactly where it is, so the board never has to be reactivated and never
///    reboots as a side effect of a sync.
///
/// Rule 2 wins, because the cost of getting it wrong is a display that reboots
/// every couple of minutes trying to join a preset that is no longer there.
/// The active SSID is therefore pinned to the slot it already occupies and is
/// always retained, even when alphabetical order would have placed it
/// elsewhere or truncation would have dropped it. The remaining saved networks
/// are then sorted and laid into the slots that are left, in ascending slot
/// order. Sorting is total across the sync and only the pinned slot is an
/// exception to it, rather than the ordering being abandoned.
enum WifiPresetSlotPlan {
    static var capacity: Int { ConfigCommands.wifiPresetSlotRange.count }

    struct Assignment: Equatable, Sendable {
        /// One entry per device slot, index 0 being slot 1.
        var slots: [String?]
        /// The active slot, which no command in this plan may touch.
        var protectedSlot: Int?
        /// Saved networks that did not fit in the device's slots.
        var omitted: [String]
    }

    /// Case-insensitive SSID order, matching how the app already lists saved
    /// networks, with an exact tiebreak so the result is stable.
    static func sortedSSIDs(_ ssids: [String]) -> [String] {
        var seen = Set<String>()
        return ssids
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { lhs, rhs in
                switch lhs.localizedCaseInsensitiveCompare(rhs) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return lhs < rhs
                }
            }
    }

    static func assignment(
        savedSSIDs: [String],
        snapshot: WifiPresetSnapshot
    ) -> Assignment {
        var slots = [String?](repeating: nil, count: capacity)
        var remaining = sortedSSIDs(savedSSIDs)

        // Pin the active slot first, before anything is allowed to compete for
        // it. When the roster names an active slot whose contents could not be
        // read, the slot is still reserved and still left alone - an unknown
        // active credential is exactly the one that must not be replaced.
        var protectedSlot: Int?
        if let activeSlot = snapshot.activeSlot {
            protectedSlot = activeSlot
            if let activeSSID = snapshot.slots[activeSlot]?.ssid {
                slots[activeSlot - 1] = activeSSID
                remaining.removeAll { $0 == activeSSID }
            }
        }

        var openSlots = ConfigCommands.wifiPresetSlotRange
            .filter { $0 != protectedSlot }
        var omitted: [String] = []
        for ssid in remaining {
            guard let slot = openSlots.first else {
                omitted.append(ssid)
                continue
            }
            openSlots.removeFirst()
            slots[slot - 1] = ssid
        }
        return Assignment(
            slots: slots, protectedSlot: protectedSlot, omitted: omitted)
    }
}

enum WifiPresetSyncPlanner {
    enum PlanFailure: Error, Equatable {
        case wrongSlotCount(Int)
        case duplicateSSID(String)
        case missingCredential(slot: Int, ssid: String)
        case invalidCredential(slot: Int, ssid: String)
        case invalidProtectedSlot(Int)
        /// A plan that would rewrite or clear the slot the display is currently
        /// joined through. Refused rather than reordered, because the display
        /// would keep the slot active while its credential changed underneath.
        case activeSlotRewrite(slot: Int)
    }

    static func commands(
        desired: [String?],
        existing: [Int: ConfigCommands.WiFiPresetSlot],
        credentials: [String: SavedWiFiCredential],
        protectedSlot: Int? = nil
    ) -> Result<[String], PlanFailure> {
        guard desired.count == ConfigCommands.wifiPresetSlotRange.count else {
            return .failure(.wrongSlotCount(desired.count))
        }
        if let protectedSlot,
           !ConfigCommands.wifiPresetSlotRange.contains(protectedSlot) {
            return .failure(.invalidProtectedSlot(protectedSlot))
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

            if slot == protectedSlot {
                // No SET and no CLEAR for the active slot, not even a rewrite
                // with identical content. The only acceptable plan for it is
                // the empty one.
                guard selected == existing[slot]?.ssid else {
                    return .failure(.activeSlotRewrite(slot: slot))
                }
                continue
            }

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

/// What one automatic sync did, for the caller to report without having to
/// re-read the display.
struct WifiPresetSyncReport: Equatable, Sendable {
    var snapshot: WifiPresetSnapshot
    /// Saved networks that did not fit in the display's ten slots.
    var omitted: [String]
    /// Saved networks skipped because the app could not produce a credential
    /// the display would accept.
    var unusable: [String]
    var commandCount: Int

    var storedCount: Int { snapshot.slots.count }
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

    /// Copy the app's saved networks into the display's slots.
    ///
    /// This is the automatic path: it reads the display first, sorts and
    /// truncates around whatever slot the display reports as active, writes,
    /// and reads back to confirm. It never activates a slot - activation
    /// restarts the board and belongs to the on-device picker.
    static func syncSavedWifiPresets(
        savedSSIDs: [String],
        credentials: [String: SavedWiFiCredential],
        port: String,
        send: WifiPresetCommandSender = {
            command, port, timeout in
            sendCommand(command, port: port, timeout: timeout)
        }
    ) -> Result<WifiPresetSyncReport, ConfigFailure> {
        let before: WifiPresetSnapshot
        switch readWifiPresets(port: port, send: send) {
        case .success(let snapshot): before = snapshot
        case .failure(let failure): return .failure(failure)
        }

        // A saved network the app cannot turn into a command the device would
        // accept is dropped from this sync rather than failing all ten. It is
        // named in the report instead.
        var usable: [String] = []
        var unusable: [String] = []
        for ssid in WifiPresetSlotPlan.sortedSSIDs(savedSSIDs) {
            if let credential = credentials[ssid],
               credential.ssid == ssid,
               ConfigCommands.setWifiPreset(
                slot: ConfigCommands.wifiPresetSlotRange.lowerBound,
                ssid: credential.ssid,
                password: credential.password) != nil {
                usable.append(ssid)
            } else {
                unusable.append(ssid)
            }
        }

        let assignment = WifiPresetSlotPlan.assignment(
            savedSSIDs: usable, snapshot: before)
        switch apply(
            assignment.slots,
            before: before,
            protectedSlot: assignment.protectedSlot,
            credentials: credentials,
            port: port,
            send: send)
        {
        case .success(let applied):
            return .success(WifiPresetSyncReport(
                snapshot: applied.snapshot,
                omitted: assignment.omitted,
                unusable: unusable,
                commandCount: applied.commandCount))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    static func syncWifiPresets(
        _ desired: [String?],
        credentials: [String: SavedWiFiCredential],
        port: String,
        protectedSlot: Int? = nil,
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
        return apply(
            desired, before: before, protectedSlot: protectedSlot,
            credentials: credentials, port: port, send: send
        ).map(\.snapshot)
    }

    /// Plan, write, and read back. Separated from reading so the automatic path
    /// and the sheet share one set of write and verification rules and one
    /// `before` snapshot.
    private static func apply(
        _ desired: [String?],
        before: WifiPresetSnapshot,
        protectedSlot: Int?,
        credentials: [String: SavedWiFiCredential],
        port: String,
        send: WifiPresetCommandSender
    ) -> Result<(snapshot: WifiPresetSnapshot, commandCount: Int), ConfigFailure> {
        let commands: [String]
        switch WifiPresetSyncPlanner.commands(
            desired: desired, existing: before.slots, credentials: credentials,
            protectedSlot: protectedSlot)
        {
        case .success(let planned): commands = planned
        case .failure(let failure):
            return .failure(configFailure(for: failure))
        }

        // A sync stores credentials; it never chooses one. CFGWIFIUSE restarts
        // the display, so a plan containing anything but SET and CLEAR is a bug
        // in the planner and is refused here rather than sent.
        guard commands.allSatisfy({
            $0.hasPrefix("CFGWIFISET ") || $0.hasPrefix("CFGWIFICLEAR ")
        }) else {
            return .failure(ConfigFailure(
                title: "WiFi preset sync refused",
                message: "The plan contained a command that is not storing or "
                    + "clearing a preset, so nothing was sent."))
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

        // The failure this exists to catch: the display left holding an active
        // slot whose credential the sync removed or replaced. It rejoins that
        // preset on every boot, fails, and reboots - observed at roughly 75 to
        // 160 second intervals. The readback is what proves it did not happen.
        guard after.activeSlot == before.activeSlot,
              after.activeSSID == before.activeSSID
        else {
            return .failure(ConfigFailure(
                title: "WiFi preset verification failed",
                message: "The display's active network changed during "
                    + "synchronization. Reload the presets and confirm the "
                    + "display is still joined to the network you expect."))
        }
        return .success((after, commands.count))
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
        case .invalidProtectedSlot(let slot):
            return ConfigFailure(
                title: "Invalid WiFi preset collection",
                message: "Slot \(slot) is not a device slot.")
        case .activeSlotRewrite(let slot):
            return ConfigFailure(
                title: "Active WiFi preset protected",
                message: "Slot \(slot) is the network this display is currently "
                    + "joined through, so it was left alone and nothing was sent. "
                    + "Choose a different network on the display first.")
        }
    }
}
