import Foundation
import SenderProtocol
@testable import SenderCore
import XCTest

final class WifiPresetSyncTests: XCTestCase {
    func testPlannerWritesCredentialsBeforeClearingOldSlots() throws {
        let existing = [
            1: ConfigCommands.WiFiPresetSlot(
                slot: 1, ssid: "Old", hasPassword: true, active: false),
            2: ConfigCommands.WiFiPresetSlot(
                slot: 2, ssid: "Stale", hasPassword: false, active: false),
        ]
        let desired: [String?] = ["New"] + Array(repeating: nil, count: 9)
        let credentials = [
            "New": SavedWiFiCredential(ssid: "New", password: "synthetic")
        ]

        let commands = try resultValue(WifiPresetSyncPlanner.commands(
            desired: desired, existing: existing, credentials: credentials))
        XCTAssertEqual(commands, [
            "CFGWIFISET 1 TmV3 c3ludGhldGlj",
            "CFGWIFICLEAR 2",
        ])
    }

    func testPlannerPreservesDeviceOnlyCredentialInItsExistingSlot() throws {
        let existing = [
            3: ConfigCommands.WiFiPresetSlot(
                slot: 3, ssid: "Device Only", hasPassword: true, active: true)
        ]
        let desired = [String?](repeating: nil, count: 2)
            + ["Device Only"]
            + [String?](repeating: nil, count: 7)
        let commands = try resultValue(WifiPresetSyncPlanner.commands(
            desired: desired, existing: existing, credentials: [:]))
        XCTAssertEqual(commands, [])
    }

    func testPlannerRejectsDuplicateAndMissingCredentials() {
        let duplicate: [String?] = ["Cafe", "Cafe"]
            + Array(repeating: nil, count: 8)
        XCTAssertEqual(
            failureValue(WifiPresetSyncPlanner.commands(
                desired: duplicate, existing: [:], credentials: [:])),
            .duplicateSSID("Cafe"))

        let missing: [String?] = ["Unknown"] + Array(repeating: nil, count: 9)
        XCTAssertEqual(
            failureValue(WifiPresetSyncPlanner.commands(
                desired: missing, existing: [:], credentials: [:])),
            .missingCredential(slot: 1, ssid: "Unknown"))
    }

    func testSyncUsesDeviceProtocolAndVerifiesFinalRoster() throws {
        var device = FakePresetDevice(slots: [
            1: ("Old", true),
            2: ("Stale", false),
        ])
        let desired: [String?] = ["New", nil, "Cafe"]
            + Array(repeating: nil, count: 7)
        let credentials = [
            "New": SavedWiFiCredential(ssid: "New", password: "synthetic"),
            "Cafe": SavedWiFiCredential(ssid: "Cafe", password: ""),
        ]

        let result = WifiConfigUI.syncWifiPresets(
            desired,
            credentials: credentials,
            port: "/dev/fake",
            send: { command, _, _ in device.send(command) })
        let snapshot = try resultValue(result)

        XCTAssertEqual(snapshot.slots[1]?.ssid, "New")
        XCTAssertNil(snapshot.slots[2])
        XCTAssertEqual(snapshot.slots[3]?.ssid, "Cafe")
        let mutations = device.commands.filter {
            $0.hasPrefix("CFGWIFISET") || $0.hasPrefix("CFGWIFICLEAR")
        }
        XCTAssertEqual(mutations, [
            "CFGWIFISET 1 TmV3 c3ludGhldGlj",
            "CFGWIFISET 3 Q2FmZQ== -",
            "CFGWIFICLEAR 2",
        ])
        XCTAssertEqual(device.commands.last, "CFGWIFISHOW 3")
    }

    private func resultValue<T, E: Error>(_ result: Result<T, E>) throws -> T {
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    private func failureValue<T>(
        _ result: Result<T, WifiPresetSyncPlanner.PlanFailure>
    ) -> WifiPresetSyncPlanner.PlanFailure? {
        guard case .failure(let error) = result else { return nil }
        return error
    }
}

private struct FakePresetDevice {
    var slots: [Int: (ssid: String, hasPassword: Bool)]
    var commands: [String] = []

    mutating func send(_ command: String) -> WifiConfigUI.CommandResult {
        commands.append(command)
        if command == ConfigCommands.showWifiPresets {
            let mask = slots.keys.reduce(0) { $0 | (1 << ($1 - 1)) }
            return .success(String(
                format: "CFGINFO wifi capacity=10 valid=0x%03x "
                    + "active=direct mode=direct local=1",
                mask))
        }
        if command.hasPrefix("CFGWIFISHOW "),
           let slot = Int(command.dropFirst("CFGWIFISHOW ".count)),
           let stored = slots[slot] {
            let ssid64 = Data(stored.ssid.utf8).base64EncodedString()
            return .success(
                "CFGINFO wifi slot=\(slot) valid=1 active=0 "
                    + "ssid64=\(ssid64) pass=\(stored.hasPassword ? "set" : "open")")
        }
        if command.hasPrefix("CFGWIFISET ") {
            let fields = command.split(separator: " ")
            guard fields.count == 4,
                  let slot = Int(fields[1]),
                  let ssidData = Data(base64Encoded: String(fields[2])),
                  let ssid = String(data: ssidData, encoding: .utf8)
            else { return .failure("bad fake set command") }
            slots[slot] = (ssid, fields[3] != "-")
            return .success("CFGOK wifi slot=\(slot) saved")
        }
        if command.hasPrefix("CFGWIFICLEAR "),
           let slot = Int(command.dropFirst("CFGWIFICLEAR ".count)) {
            slots[slot] = nil
            return .success("CFGOK wifi slot=\(slot) cleared")
        }
        return .failure("unexpected command")
    }
}
