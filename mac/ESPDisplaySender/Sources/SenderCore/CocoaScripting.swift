import AppKit
import Foundation
import SenderProtocol

/// The manager-window operations exposed to AppleScript.
///
/// Keeping this as a small protocol makes the command handler testable without
/// constructing an AppKit window. The scripting surface deliberately has no
/// access to the controller beyond these three non-destructive operations.
@MainActor
protocol CocoaScriptingWindowControlling: AnyObject {
    var isVisible: Bool { get }
    func show()
    func hide()
}

/// Stable AppleScript failures. The positive range is application-defined and
/// keeps caller handling deterministic instead of leaking whichever Cocoa error
/// happened to be produced internally.
struct CocoaScriptingFailure: Error, Equatable {
    enum Code: Int {
        case unavailable = 1000
        case missingArgument = 1001
        case displayNotFound = 1002
        case ambiguousDisplay = 1003
        case invalidValue = 1004
        case operationUnavailable = 1005
        case sourceNotFound = 1006
        case ambiguousSource = 1007
    }

    let code: Code
    let message: String
}

/// The complete public command allowlist. Tests pin this list against the SDEF,
/// so adding a script command requires an intentional review of both the
/// dictionary and the handler rather than accidentally exposing a model method.
enum CocoaScriptingSurface {
    static let commandNames: Set<String> = [
        "show manager",
        "hide manager",
        "manager visible",
        "list displays",
        "display status",
        "select display",
        "pause display",
        "resume display",
        "identify display",
        "set display power",
        "set display brightness",
        "set display rotation",
        "set display source",
        "set display idle text",
        "set display gesture preset",
        "sender settings",
        "set sender settings",
    ]
}

/// A typed, allowlisted scripting facade over `PanelManager`.
///
/// No KVC scriptability is enabled on `PanelManager` or `PanelSnapshot`; doing
/// so would also make restart, forget, firmware, Wi-Fi, password, USB, rename,
/// and raw device paths discoverable. Every operation here is an explicit safe
/// delegation instead.
@MainActor
final class CocoaScriptingHandler {
    private let manager: PanelManager
    private let window: CocoaScriptingWindowControlling
    private let attachedDisplayNames: @MainActor () -> [String]

    init(
        manager: PanelManager,
        window: CocoaScriptingWindowControlling,
        attachedDisplayNames: @escaping @MainActor () -> [String]
    ) {
        self.manager = manager
        self.window = window
        self.attachedDisplayNames = attachedDisplayNames
    }

    convenience init(
        manager: PanelManager,
        window: CocoaScriptingWindowControlling
    ) {
        self.init(
            manager: manager,
            window: window,
            attachedDisplayNames: { manager.displayNames })
    }

    func showManager() { window.show() }
    func hideManager() { window.hide() }
    var managerIsVisible: Bool { window.isVisible }

    /// Stable routing keys, sorted so callers do not see UI sorting changes as
    /// API changes. A display name can still be used by every command through
    /// the resolver below when it is unique.
    func listDisplays() -> [String] {
        manager.panels.map(\.serviceName).sorted()
    }

    func displayStatus(_ name: String) throws -> String {
        let panel = try resolvePanel(name)
        let battery: Any = panel.battery.map { _ in panel.batteryDescription } ?? NSNull()
        let object: [String: Any] = [
            "serviceName": panel.serviceName,
            "displayName": panel.displayName,
            "selected": manager.selectedServiceName == panel.serviceName,
            "online": panel.isOnline,
            "status": panel.statusText,
            "paused": panel.paused,
            "powerOn": !panel.manuallyOff,
            "brightness": panel.brightness,
            "rotationDegrees": panel.rotation * 90,
            "source": panel.source.label,
            "sourceDescription": panel.sourceDescription,
            "idleText": panel.idleText,
            "gesturePreset": panel.gesturePreset.rawValue,
            "firmwareVersion": panel.firmwareVersion ?? NSNull(),
            "address": panel.address ?? NSNull(),
            "battery": battery,
        ]
        return try json(object)
    }

    @discardableResult
    func selectDisplay(_ name: String) throws -> String {
        let panel = try resolvePanel(name)
        manager.selectedServiceName = panel.serviceName
        return panel.serviceName
    }

    func setPaused(_ paused: Bool, display name: String) throws {
        let panel = try resolvePanel(name)
        if let reason = manager.streamingUnavailableReason(panel.serviceName) {
            throw CocoaScriptingFailure(
                code: .operationUnavailable,
                message: "Cannot \(paused ? "pause" : "resume") \"\(panel.displayName)\": \(reason)")
        }
        manager.setPaused(paused, for: panel.serviceName)
    }

    func identify(_ name: String) throws {
        let panel = try resolvePanel(name)
        try requireControl(.identify, for: panel)
        manager.identify(panel.serviceName)
    }

    func setPower(_ on: Bool, display name: String) throws {
        let panel = try resolvePanel(name)
        try requireControl(.power, for: panel)
        manager.setPower(on, for: panel.serviceName)
    }

    func setBrightness(_ level: Int, display name: String) throws {
        guard DeviceProtocol.brightnessLevelRange.contains(level) else {
            throw CocoaScriptingFailure(
                code: .invalidValue,
                message: "Brightness must be in \(DeviceProtocol.brightnessLevelRange.lowerBound)...\(DeviceProtocol.brightnessLevelRange.upperBound).")
        }
        let panel = try resolvePanel(name)
        try requireControl(.brightnessLevel, for: panel)
        manager.setBrightnessLevel(level, for: panel.serviceName)
    }

    func setRotation(degrees: Int, display name: String) throws {
        guard [0, 90, 180, 270].contains(degrees) else {
            throw CocoaScriptingFailure(
                code: .invalidValue,
                message: "Rotation must be 0, 90, 180, or 270 degrees.")
        }
        let panel = try resolvePanel(name)
        try requireControl(.rotate, for: panel)
        manager.setRotation(degrees / 90, for: panel.serviceName)
    }

    /// Only Automatic and a currently attached named macOS display are
    /// scriptable. Window, application, and region sources need interactive UI
    /// and are intentionally not accepted here.
    func setSource(_ sourceName: String, display name: String) throws {
        let panel = try resolvePanel(name)
        let requested = normalized(sourceName)
        guard !requested.isEmpty else {
            throw CocoaScriptingFailure(
                code: .invalidValue,
                message: "Source must be \"automatic\" or the name of an attached display.")
        }
        if requested == "automatic" {
            manager.useAutomaticSource(for: panel.serviceName)
            return
        }

        let names = attachedDisplayNames()
        if let exact = names.first(where: { $0 == sourceName }) {
            manager.selectDisplay(exact, for: panel.serviceName)
            return
        }
        let matches = names.filter {
            $0.localizedCaseInsensitiveCompare(sourceName) == .orderedSame
        }
        guard !matches.isEmpty else {
            throw CocoaScriptingFailure(
                code: .sourceNotFound,
                message: "No attached display is named \"\(sourceName)\".")
        }
        guard matches.count == 1 else {
            throw CocoaScriptingFailure(
                code: .ambiguousSource,
                message: "The source name \"\(sourceName)\" matches more than one attached display.")
        }
        manager.selectDisplay(matches[0], for: panel.serviceName)
    }

    func setIdleText(_ text: String, display name: String) throws {
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }),
              text.utf8.count <= 4_096
        else {
            throw CocoaScriptingFailure(
                code: .invalidValue,
                message: "Idle text must not contain NUL and must be at most 4096 UTF-8 bytes.")
        }
        let panel = try resolvePanel(name)
        manager.setIdleText(text, for: panel.serviceName)
    }

    func setGesturePreset(_ presetName: String, display name: String) throws {
        let preset: GesturePreset?
        switch normalized(presetName) {
        case "sourcecycling", "source-cycling", "source cycling":
            preset = .sourceCycling
        case "multimedia":
            preset = .multimedia
        case "windowcycling", "window-cycling", "window cycling":
            preset = .windowCycling
        default:
            preset = nil
        }
        guard let preset else {
            throw CocoaScriptingFailure(
                code: .invalidValue,
                message: "Gesture preset must be sourceCycling, multimedia, or windowCycling.")
        }
        let panel = try resolvePanel(name)
        manager.setGesturePreset(preset, for: panel.serviceName)
    }

    func senderSettings() throws -> String {
        let settings = manager.settings
        return try json([
            "fps": settings.fps,
            "spacingMicros": Int(settings.spacingMicros),
            "adaptivePacing": settings.adaptivePacing,
            "identifySeconds": settings.identifySeconds,
            "tileQuality": settings.tileQuality.rawValue,
        ])
    }

    func updateSenderSettings(
        fps: Int? = nil,
        spacingMicros: Int? = nil,
        adaptivePacing: Bool? = nil,
        identifySeconds: Int? = nil,
        tileQuality: String? = nil
    ) throws {
        guard fps != nil || spacingMicros != nil || adaptivePacing != nil
                || identifySeconds != nil || tileQuality != nil
        else {
            throw CocoaScriptingFailure(
                code: .missingArgument,
                message: "Set at least one sender setting.")
        }
        if let fps, !SenderSettings.fpsRange.contains(fps) {
            throw CocoaScriptingFailure(
                code: .invalidValue,
                message: "Frame rate must be in \(SenderSettings.fpsRange.lowerBound)...\(SenderSettings.fpsRange.upperBound).")
        }
        if let spacingMicros {
            guard spacingMicros >= 0,
                  let spacing = UInt32(exactly: spacingMicros),
                  SenderSettings.spacingRange.contains(spacing)
            else {
                throw CocoaScriptingFailure(
                    code: .invalidValue,
                    message: "Pacing must be in \(SenderSettings.spacingRange.lowerBound)...\(SenderSettings.spacingRange.upperBound) microseconds.")
            }
        }
        if let identifySeconds, !SenderSettings.identifyRange.contains(identifySeconds) {
            throw CocoaScriptingFailure(
                code: .invalidValue,
                message: "Identify duration must be in \(SenderSettings.identifyRange.lowerBound)...\(SenderSettings.identifyRange.upperBound) seconds.")
        }

        let quality: TileLossyPolicy?
        if let tileQuality {
            quality = TileLossyPolicy.allCases.first {
                normalized($0.rawValue) == normalized(tileQuality)
            }
            guard quality != nil else {
                throw CocoaScriptingFailure(
                    code: .invalidValue,
                    message: "Tile quality must be losslessOnly, auto, or aggressive.")
            }
        } else {
            quality = nil
        }

        var updated = manager.settings
        if let fps { updated.fps = fps }
        if let spacingMicros { updated.spacingMicros = UInt32(spacingMicros) }
        if let adaptivePacing { updated.adaptivePacing = adaptivePacing }
        if let identifySeconds { updated.identifySeconds = identifySeconds }
        if let quality { updated.tileQuality = quality }
        manager.updateSettings(updated)
    }

    private func resolvePanel(_ rawName: String) throws -> PanelSnapshot {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw CocoaScriptingFailure(
                code: .missingArgument,
                message: "A display service name or unique display name is required.")
        }
        if let exact = manager.panels.first(where: { $0.serviceName == name }) {
            return exact
        }
        let matches = manager.panels.filter {
            $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        guard !matches.isEmpty else {
            throw CocoaScriptingFailure(
                code: .displayNotFound,
                message: "No display is named \"\(name)\".")
        }
        guard matches.count == 1 else {
            let services = matches.map(\.serviceName).sorted().joined(separator: ", ")
            throw CocoaScriptingFailure(
                code: .ambiguousDisplay,
                message: "The display name \"\(name)\" is ambiguous; use one of these service names: \(services).")
        }
        return matches[0]
    }

    private func requireControl(
        _ capability: DeviceProtocol.Capabilities,
        for panel: PanelSnapshot
    ) throws {
        if let reason = manager.controlUnavailableReason(
            panel.serviceName, capability: capability)
        {
            throw CocoaScriptingFailure(
                code: .operationUnavailable,
                message: "The command is unavailable for \"\(panel.displayName)\": \(reason)")
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func json(_ object: [String: Any]) throws -> String {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys])
            guard let string = String(data: data, encoding: .utf8) else {
                throw CocoaScriptingFailure(
                    code: .unavailable,
                    message: "The scripting result could not be encoded as UTF-8.")
            }
            return string
        } catch let failure as CocoaScriptingFailure {
            throw failure
        } catch {
            throw CocoaScriptingFailure(
                code: .unavailable,
                message: "The scripting result could not be encoded: \(error.localizedDescription)")
        }
    }
}

/// Process-wide command target. The app installs it only after the real
/// `PanelManager` and window controller exist, so Apple events cannot create a
/// second manager or bypass normal startup.
@MainActor
enum CocoaScriptingContext {
    private(set) static var handler: CocoaScriptingHandler?

    static func install(
        manager: PanelManager,
        window: CocoaScriptingWindowControlling
    ) {
        handler = CocoaScriptingHandler(manager: manager, window: window)
    }
}

/// Shared argument coercion and deterministic error reporting for the thin
/// command classes named by the SDEF.
///
/// Cocoa invokes `performDefaultImplementation()` synchronously through the
/// Objective-C runtime. Keep that callback itself nonisolated, then enter the
/// main actor only after confirming AppKit delivered it on the main thread.
/// Dispatching synchronously to the main queue here can deadlock Apple-event
/// delivery, while returning before an asynchronous hop would lose the reply.
public class ESPDisplayScriptCommand: NSScriptCommand {
    fileprivate func execute(
        _ operation: @MainActor (CocoaScriptingHandler) throws -> Any?
    ) -> Any? {
        guard Thread.isMainThread else {
            return fail(CocoaScriptingFailure(
                code: .unavailable,
                message: "The scripting command was delivered off the main thread."))
        }
        return MainActor.assumeIsolated {
            guard let handler = CocoaScriptingContext.handler else {
                return fail(CocoaScriptingFailure(
                    code: .unavailable,
                    message: "ESPDisplaySender has not finished starting."))
            }
            do {
                return try operation(handler)
            } catch let failure as CocoaScriptingFailure {
                return fail(failure)
            } catch {
                return fail(CocoaScriptingFailure(
                    code: .unavailable, message: error.localizedDescription))
            }
        }
    }

    fileprivate func requiredDirectString() throws -> String {
        try requiredString(directParameter, name: "display")
    }

    fileprivate func requiredStringArgument(_ key: String) throws -> String {
        try requiredString(evaluatedArguments?[key], name: key)
    }

    fileprivate func requiredIntegerArgument(_ key: String) throws -> Int {
        guard let number = evaluatedArguments?[key] as? NSNumber else {
            throw CocoaScriptingFailure(
                code: .missingArgument,
                message: "The \"\(key)\" integer is required.")
        }
        return number.intValue
    }

    fileprivate func requiredBooleanArgument(_ key: String) throws -> Bool {
        guard let number = evaluatedArguments?[key] as? NSNumber else {
            throw CocoaScriptingFailure(
                code: .missingArgument,
                message: "The \"\(key)\" boolean is required.")
        }
        return number.boolValue
    }

    fileprivate func optionalIntegerArgument(_ key: String) throws -> Int? {
        guard let value = evaluatedArguments?[key] else { return nil }
        guard let number = value as? NSNumber else {
            throw CocoaScriptingFailure(
                code: .invalidValue,
                message: "The \"\(key)\" value must be an integer.")
        }
        return number.intValue
    }

    fileprivate func optionalBooleanArgument(_ key: String) throws -> Bool? {
        guard let value = evaluatedArguments?[key] else { return nil }
        guard let number = value as? NSNumber else {
            throw CocoaScriptingFailure(
                code: .invalidValue,
                message: "The \"\(key)\" value must be a boolean.")
        }
        return number.boolValue
    }

    fileprivate func optionalStringArgument(_ key: String) throws -> String? {
        guard let value = evaluatedArguments?[key] else { return nil }
        return try requiredString(value, name: key)
    }

    private func requiredString(_ value: Any?, name: String) throws -> String {
        guard let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CocoaScriptingFailure(
                code: .missingArgument,
                message: "The \"\(name)\" text is required.")
        }
        return string
    }

    private func fail(_ failure: CocoaScriptingFailure) -> Any? {
        scriptErrorNumber = failure.code.rawValue
        scriptErrorString = failure.message
        return nil
    }
}

@objc(ESPDisplayShowManagerCommand)
public final class ESPDisplayShowManagerCommand: ESPDisplayScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        execute { $0.showManager(); return nil }
    }
}

@objc(ESPDisplayHideManagerCommand)
public final class ESPDisplayHideManagerCommand: ESPDisplayScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        execute { $0.hideManager(); return nil }
    }
}

@objc(ESPDisplayManagerVisibleCommand)
public final class ESPDisplayManagerVisibleCommand: ESPDisplayScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        execute { $0.managerIsVisible }
    }
}

@objc(ESPDisplayListDisplaysCommand)
public final class ESPDisplayListDisplaysCommand: ESPDisplayScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        execute {
            let descriptor = NSAppleEventDescriptor.list()
            for (index, name) in $0.listDisplays().enumerated() {
                descriptor.insert(
                    NSAppleEventDescriptor(string: name), at: index + 1)
            }
            return descriptor
        }
    }
}

@objc(ESPDisplayStatusCommand)
public final class ESPDisplayStatusCommand: ESPDisplayScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        execute { try $0.displayStatus(try requiredDirectString()) }
    }
}

@objc(ESPDisplaySelectCommand)
public final class ESPDisplaySelectCommand: ESPDisplayScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        execute { try $0.selectDisplay(try requiredDirectString()) }
    }
}

@objc(ESPDisplayPauseCommand)
public final class ESPDisplayPauseCommand: ESPDisplayScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        execute { try $0.setPaused(true, display: try requiredDirectString()); return nil }
    }
}

@objc(ESPDisplayResumeCommand)
public final class ESPDisplayResumeCommand: ESPDisplayScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        execute { try $0.setPaused(false, display: try requiredDirectString()); return nil }
    }
}

@objc(ESPDisplayIdentifyCommand)
public final class ESPDisplayIdentifyCommand: ESPDisplayScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        execute { try $0.identify(try requiredDirectString()); return nil }
    }
}

@objc(ESPDisplaySetPowerCommand)
public final class ESPDisplaySetPowerCommand: ESPDisplayScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        execute {
            try $0.setPower(
                try requiredBooleanArgument("enabled"),
                display: try requiredDirectString())
            return nil
        }
    }
}

@objc(ESPDisplaySetBrightnessCommand)
public final class ESPDisplaySetBrightnessCommand: ESPDisplayScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        execute {
            try $0.setBrightness(
                try requiredIntegerArgument("level"),
                display: try requiredDirectString())
            return nil
        }
    }
}

@objc(ESPDisplaySetRotationCommand)
public final class ESPDisplaySetRotationCommand: ESPDisplayScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        execute {
            try $0.setRotation(
                degrees: try requiredIntegerArgument("degrees"),
                display: try requiredDirectString())
            return nil
        }
    }
}

@objc(ESPDisplaySetSourceCommand)
public final class ESPDisplaySetSourceCommand: ESPDisplayScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        execute {
            try $0.setSource(
                try requiredStringArgument("source"),
                display: try requiredDirectString())
            return nil
        }
    }
}

@objc(ESPDisplaySetIdleTextCommand)
public final class ESPDisplaySetIdleTextCommand: ESPDisplayScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        execute {
            try $0.setIdleText(
                try requiredStringArgument("text"),
                display: try requiredDirectString())
            return nil
        }
    }
}

@objc(ESPDisplaySetGesturePresetCommand)
public final class ESPDisplaySetGesturePresetCommand: ESPDisplayScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        execute {
            try $0.setGesturePreset(
                try requiredStringArgument("preset"),
                display: try requiredDirectString())
            return nil
        }
    }
}

@objc(ESPDisplaySenderSettingsCommand)
public final class ESPDisplaySenderSettingsCommand: ESPDisplayScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        execute { try $0.senderSettings() }
    }
}

@objc(ESPDisplaySetSenderSettingsCommand)
public final class ESPDisplaySetSenderSettingsCommand: ESPDisplayScriptCommand {
    public override func performDefaultImplementation() -> Any? {
        execute {
            try $0.updateSenderSettings(
                fps: try optionalIntegerArgument("fps"),
                spacingMicros: try optionalIntegerArgument("spacingMicros"),
                adaptivePacing: try optionalBooleanArgument("adaptivePacing"),
                identifySeconds: try optionalIntegerArgument("identifySeconds"),
                tileQuality: try optionalStringArgument("tileQuality"))
            return nil
        }
    }
}
