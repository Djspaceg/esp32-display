import Foundation
import XCTest

@testable import SenderCore
@testable import SenderProtocol

@MainActor
private final class ScriptWindowStub: CocoaScriptingWindowControlling {
    var isVisible = false
    func show() { isVisible = true }
    func hide() { isVisible = false }
}

@MainActor
final class CocoaScriptingHandlerTests: XCTestCase {
    private let controls = DeviceProtocol.Capabilities.identify
        .union(.power)
        .union(.brightnessLevel)
        .union(.rotate)
        .union(.idleText)

    private func panel(
        service: String = "panel-a",
        display: String = "Studio",
        online: Bool = true,
        capabilities: DeviceProtocol.Capabilities? = nil
    ) -> PanelSnapshot {
        PanelSnapshot(
            serviceName: service,
            displayName: display,
            lastHeartbeatAt: online ? Date() : nil,
            controlProtocolVersion: Int(DeviceProtocol.controlProtocolVersion),
            capabilitiesRaw: (capabilities ?? controls).rawValue,
            brightness: 80)
    }

    private func session(_ name: String) -> DeviceSession {
        DeviceSession(
            name: name,
            sender: FrameSender(host: "127.0.0.1", port: 5568),
            source: .auto(defaultDisplay: ""),
            picker: nil,
            fps: 30)
    }

    private func subject(
        panels: [PanelSnapshot]? = nil,
        attachSessions: Bool = false,
        displays: [String] = ["Built-in Display", "Desk Monitor"]
    ) -> (CocoaScriptingHandler, PanelManager, ScriptWindowStub) {
        let snapshots = panels ?? [panel()]
        let manager = PanelManager(
            previewPanels: snapshots,
            savedNetworkNames: [],
            usbSerialPorts: [])
        if attachSessions {
            for panel in snapshots { manager.register(session(panel.serviceName)) }
        }
        let window = ScriptWindowStub()
        let handler = CocoaScriptingHandler(
            manager: manager,
            window: window,
            attachedDisplayNames: { displays })
        return (handler, manager, window)
    }

    func testWindowShowHideAndVisibility() {
        let (handler, _, window) = subject()

        XCTAssertFalse(handler.managerIsVisible)
        handler.showManager()
        XCTAssertTrue(handler.managerIsVisible)
        XCTAssertTrue(window.isVisible)
        handler.hideManager()
        XCTAssertFalse(handler.managerIsVisible)
    }

    func testListStatusAndSelectionUseStableServiceNames() throws {
        let panels = [
            panel(service: "z-panel", display: "Bedroom"),
            panel(service: "a-panel", display: "Studio"),
        ]
        let (handler, manager, _) = subject(panels: panels)

        XCTAssertEqual(handler.listDisplays(), ["a-panel", "z-panel"])
        XCTAssertEqual(try handler.selectDisplay("z-panel"), "z-panel")
        XCTAssertEqual(manager.selectedServiceName, "z-panel")

        let status = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(handler.displayStatus("z-panel").utf8))
                as? [String: Any])
        XCTAssertEqual(status["serviceName"] as? String, "z-panel")
        XCTAssertEqual(status["displayName"] as? String, "Bedroom")
        XCTAssertEqual(status["selected"] as? Bool, true)
        XCTAssertEqual(status["brightness"] as? Int, 80)
    }

    func testExactServiceNameWinsBeforeDisplayNameFallback() throws {
        let panels = [
            panel(service: "Studio", display: "Other"),
            panel(service: "panel-b", display: "Studio"),
        ]
        let (handler, _, _) = subject(panels: panels)

        XCTAssertEqual(try handler.selectDisplay("Studio"), "Studio")
    }

    func testUniqueDisplayNameFallbackIsCaseInsensitive() throws {
        let (handler, _, _) = subject()

        XCTAssertEqual(try handler.selectDisplay("studio"), "panel-a")
    }

    func testAmbiguousAndUnknownDisplayNamesAreRejected() {
        let panels = [
            panel(service: "panel-a", display: "Studio"),
            panel(service: "panel-b", display: "studio"),
        ]
        let (handler, _, _) = subject(panels: panels)

        XCTAssertThrowsError(try handler.selectDisplay("STUDIO")) { error in
            XCTAssertEqual(
                error as? CocoaScriptingFailure,
                CocoaScriptingFailure(
                    code: .ambiguousDisplay,
                    message: "The display name \"STUDIO\" is ambiguous; use one of these service names: panel-a, panel-b."))
        }
        XCTAssertThrowsError(try handler.selectDisplay("Missing")) { error in
            XCTAssertEqual((error as? CocoaScriptingFailure)?.code, .displayNotFound)
        }
    }

    func testPauseAndResumeRequireALiveSession() throws {
        let (offlineHandler, _, _) = subject()
        XCTAssertThrowsError(try offlineHandler.setPaused(true, display: "panel-a")) { error in
            XCTAssertEqual((error as? CocoaScriptingFailure)?.code, .operationUnavailable)
        }

        let (handler, manager, _) = subject(attachSessions: true)
        try handler.setPaused(true, display: "panel-a")
        XCTAssertEqual(manager.panels.first?.paused, true)
        try handler.setPaused(false, display: "panel-a")
        XCTAssertEqual(manager.panels.first?.paused, false)
    }

    func testDeviceControlsRefuseMissingCapabilitiesAndApplyValidValues() throws {
        let unsupported = panel(capabilities: [])
        let (unsupportedHandler, _, _) = subject(
            panels: [unsupported], attachSessions: true)
        XCTAssertThrowsError(try unsupportedHandler.identify("panel-a")) { error in
            XCTAssertEqual((error as? CocoaScriptingFailure)?.code, .operationUnavailable)
        }

        let (handler, manager, _) = subject(attachSessions: true)
        try handler.setPower(false, display: "panel-a")
        try handler.setBrightness(123, display: "panel-a")
        try handler.setRotation(degrees: 270, display: "panel-a")

        let changed = try XCTUnwrap(manager.panels.first)
        XCTAssertTrue(changed.manuallyOff)
        XCTAssertEqual(changed.brightness, 123)
        XCTAssertEqual(changed.rotation, 3)
    }

    func testInvalidBrightnessAndRotationAreRejectedBeforeMutation() {
        let (handler, manager, _) = subject(attachSessions: true)

        XCTAssertThrowsError(try handler.setBrightness(256, display: "panel-a")) { error in
            XCTAssertEqual((error as? CocoaScriptingFailure)?.code, .invalidValue)
        }
        XCTAssertThrowsError(try handler.setRotation(degrees: 45, display: "panel-a")) { error in
            XCTAssertEqual((error as? CocoaScriptingFailure)?.code, .invalidValue)
        }
        XCTAssertEqual(manager.panels.first?.brightness, 80)
        XCTAssertEqual(manager.panels.first?.rotation, 0)
    }

    func testSourceAllowsAutomaticOrUniqueAttachedDisplayOnly() throws {
        let (handler, manager, _) = subject()

        try handler.setSource("desk monitor", display: "panel-a")
        XCTAssertEqual(manager.panels.first?.source, .display("Desk Monitor"))
        try handler.setSource("automatic", display: "panel-a")
        XCTAssertEqual(manager.panels.first?.source, .automatic)

        XCTAssertThrowsError(
            try handler.setSource("Music Window", display: "panel-a")
        ) { error in
            XCTAssertEqual((error as? CocoaScriptingFailure)?.code, .sourceNotFound)
        }
    }

    func testAmbiguousAttachedDisplayNameIsRejected() {
        let (handler, _, _) = subject(displays: ["Desk", "desk"])

        XCTAssertThrowsError(try handler.setSource("DESK", display: "panel-a")) { error in
            XCTAssertEqual((error as? CocoaScriptingFailure)?.code, .ambiguousSource)
        }
    }

    func testIdleTextAndGesturePresetMutateOnlyAllowlistedFields() throws {
        let (handler, manager, _) = subject()

        try handler.setIdleText("Back at {uptime}", display: "panel-a")
        try handler.setGesturePreset("window cycling", display: "panel-a")

        XCTAssertEqual(manager.panels.first?.idleText, "Back at {uptime}")
        XCTAssertEqual(manager.panels.first?.gesturePreset, .windowCycling)
    }

    func testInvalidIdleTextAndGesturePresetAreRejected() {
        let (handler, _, _) = subject()

        XCTAssertThrowsError(
            try handler.setIdleText(String(repeating: "x", count: 4_097), display: "panel-a")
        ) { error in
            XCTAssertEqual((error as? CocoaScriptingFailure)?.code, .invalidValue)
        }
        XCTAssertThrowsError(
            try handler.setGesturePreset("danger", display: "panel-a")
        ) { error in
            XCTAssertEqual((error as? CocoaScriptingFailure)?.code, .invalidValue)
        }
    }

    func testSenderSettingsStatusAndValidatedMutation() throws {
        let (handler, manager, _) = subject()

        try handler.updateSenderSettings(
            fps: 24,
            spacingMicros: 600,
            adaptivePacing: false,
            identifySeconds: 12,
            tileQuality: "losslessOnly")

        XCTAssertEqual(manager.settings.fps, 24)
        XCTAssertEqual(manager.settings.spacingMicros, 600)
        XCTAssertFalse(manager.settings.adaptivePacing)
        XCTAssertEqual(manager.settings.identifySeconds, 12)
        XCTAssertEqual(manager.settings.tileQuality, .losslessOnly)

        let status = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(handler.senderSettings().utf8)) as? [String: Any])
        XCTAssertEqual(status["fps"] as? Int, 24)
        XCTAssertEqual(status["tileQuality"] as? String, "losslessOnly")
    }

    func testInvalidOrEmptySenderSettingsAreRejected() {
        let (handler, manager, _) = subject()
        let original = manager.settings

        XCTAssertThrowsError(try handler.updateSenderSettings()) { error in
            XCTAssertEqual((error as? CocoaScriptingFailure)?.code, .missingArgument)
        }
        XCTAssertThrowsError(try handler.updateSenderSettings(fps: 1_000)) { error in
            XCTAssertEqual((error as? CocoaScriptingFailure)?.code, .invalidValue)
        }
        XCTAssertThrowsError(
            try handler.updateSenderSettings(tileQuality: "pixel soup")
        ) { error in
            XCTAssertEqual((error as? CocoaScriptingFailure)?.code, .invalidValue)
        }
        XCTAssertEqual(manager.settings, original)
    }
}

final class CocoaScriptingDictionaryTests: XCTestCase {
    private var dictionaryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ESPDisplaySender.sdef")
    }

    func testDictionaryMatchesTheExplicitCommandAllowlist() throws {
        let source = try String(contentsOf: dictionaryURL, encoding: .utf8)
        let expression = try NSRegularExpression(
            pattern: #"<command name="([^"]+)""#)
        let range = NSRange(source.startIndex..., in: source)
        let names = Set(expression.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        })

        XCTAssertEqual(names, CocoaScriptingSurface.commandNames)
    }

    func testDangerousOperationsAreNotPublished() throws {
        let source = try String(contentsOf: dictionaryURL, encoding: .utf8)
        let forbidden = [
            "restart", "forget", "firmware", "password", "wifi", "credential",
            "usb", "onboard", "rename", "raw command", "erase", "flash",
        ]

        for operation in forbidden {
            XCTAssertFalse(
                source.lowercased().contains("<command name=\"\(operation)"),
                "published forbidden command containing \(operation)")
        }
    }
}
