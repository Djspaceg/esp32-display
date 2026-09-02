import AppKit
import Foundation
import Network
import ScreenCaptureKit
import SenderProtocol

/// Device controls: capability gating and the brightness, flip,
/// rotation, power, identify, restart, and idle-text commands,
/// including the brightness echo suppression that keeps a drag from
/// fighting the device's own reports.
extension PanelManager {
    /// Why a control cannot be used right now, or nil when it can.
    ///
    /// The single source of truth for both the disabled state and the refusal
    /// message, so the two can never disagree, and specific enough to show as a
    /// tooltip on the disabled control rather than only as a message the user
    /// can never actually trigger.
    func controlUnavailableReason(
        _ serviceName: String, capability: DeviceProtocol.Capabilities
    ) -> String? {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }) else {
            return "This display is not known yet."
        }
        guard sessions[serviceName] != nil else {
            return "No streaming session is connected to this display."
        }
        guard panel.isOnline else {
            return "This display is offline."
        }
        // Firmware updates do not travel over the control protocol - espota is
        // its own exchange on port 3232 - so it may look as though this rung
        // should not apply to `.ota`. It does, and deliberately: what the
        // capability BITS mean is only defined within a control-protocol
        // generation, so on firmware from another lineage bit 4 is not
        // necessarily OTA at all, and pushing two megabytes at a panel because a
        // bit happened to be set is worse than sending someone to USB.
        guard panel.controlProtocolVersion
            == Int(DeviceProtocol.controlProtocolVersion)
        else {
            return "Flash the current firmware to enable remote controls."
        }
        guard panel.capabilities.contains(capability) else {
            if capability == .ota { return Self.otaUnavailableReason }
            return "This display does not report support for "
                + "\(Self.describe(capability))."
        }
        return nil
    }

    /// Why a local streaming action such as pause/resume cannot run.
    /// Unlike device controls, these actions do not have a capability bit or a
    /// control-protocol version, but they still require a live session and a
    /// recent heartbeat. Cocoa Scripting uses this instead of mutating an
    /// offline snapshot and reporting success for a command sent nowhere.
    func streamingUnavailableReason(_ serviceName: String) -> String? {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }) else {
            return "This display is not known yet."
        }
        guard sessions[serviceName] != nil else {
            return "No streaming session is connected to this display."
        }
        guard panel.isOnline else { return "This display is offline." }
        return nil
    }

    func canControl(
        _ serviceName: String, capability: DeviceProtocol.Capabilities
    ) -> Bool {
        controlUnavailableReason(serviceName, capability: capability) == nil
    }

    private static func describe(_ capability: DeviceProtocol.Capabilities) -> String {
        switch capability {
        case .brightness: return "brightness control"
        case .brightnessLevel: return "brightness levels"
        case .flip: return "rotation"
        case .rotate: return "quarter-turn rotation"
        case .identify: return "identify"
        case .restart: return "remote restart"
        case .ota: return "firmware updates"
        case .touch: return "touch gestures"
        case .power: return "power control"
        default: return "this control"
        }
    }

    /// Why a panel that is otherwise reachable does not offer firmware updates.
    ///
    /// Its own message because the generic one - "this display does not report
    /// support for firmware updates" - is true and useless: OTA is off on every
    /// panel until someone sets a password over USB, so the answer is always the
    /// same and it is a thing the user can go and do.
    ///
    /// ONE MESSAGE FOR TWO CAUSES, and they are worth naming together. The bit is
    /// advertised only while the panel is actually listening
    /// (`otapolicy::advertisesCapability` keys on `Status::On` alone), so it is
    /// absent both when no password is stored and when a password is stored but
    /// OTA could not start - the WiFi radio was not up when setup ran. From out
    /// here those are indistinguishable, and the panel's own `CFGSHOW` is where
    /// the difference is visible, so the message says what to check rather than
    /// asserting which one it is.
    private static let otaUnavailableReason =
        "Firmware updates are off until this panel has an OTA password. Set one "
        + "over USB with tools/espdisp.py set-password, then let the panel rejoin "
        + "WiFi. A panel that has a password but could not start listening does "
        + "not advertise updates either - tools/espdisp.py config CFGSHOW says "
        + "which."

    /// Run a control action, refusing with an accurate reason if the display
    /// cannot honour it. The UI disables these controls using the same check,
    /// so the refusal is a backstop for a panel that went offline mid-click.
    private func control(
        _ serviceName: String,
        capability: DeviceProtocol.Capabilities,
        action: (DeviceSession) -> Void
    ) {
        if let reason = controlUnavailableReason(serviceName, capability: capability) {
            operationOutcome = .failure(
                "\(Self.describe(capability).capitalizedFirst) unavailable", reason)
            return
        }
        guard let session = sessions[serviceName] else { return }
        action(session)
    }

    func setBrightness(high: Bool, for serviceName: String) {
        control(serviceName, capability: .brightness) { session in
            updatePanel(serviceName) { $0.brightnessHigh = high }
            session.setBrightness(high: high)
        }
    }

    /// Set an exact backlight level on firmware that accepts one.
    ///
    /// The panel value is updated straight away so a slider tracks the finger
    /// rather than waiting a round trip. The device's own reports are then
    /// suppressed until it catches up, because they lag the drag and would
    /// otherwise fight the thumb.
    func setBrightnessLevel(_ level: Int, for serviceName: String) {
        control(serviceName, capability: .brightnessLevel) { session in
            let clamped = min(
                max(level, DeviceProtocol.brightnessLevelRange.lowerBound),
                DeviceProtocol.brightnessLevelRange.upperBound)
            updatePanel(serviceName) { $0.brightness = clamped }
            commandedBrightness[serviceName] = (level: clamped, at: Date())
            session.setBrightnessLevel(clamped)
        }
    }

    /// Whether a level the device reported should be ignored in favour of what
    /// the user just asked for.
    ///
    /// Reports are ignored until the device converges on the commanded value,
    /// or until the grace period lapses. The timeout is what makes this safe:
    /// without it a dropped command would leave the UI permanently disagreeing
    /// with the panel.
    func ignoreReportedBrightness(
        _ reported: Int, for serviceName: String
    ) -> Bool {
        guard let commanded = commandedBrightness[serviceName] else { return false }
        guard reported != commanded.level else {
            commandedBrightness[serviceName] = nil
            return false
        }
        guard Date().timeIntervalSince(commanded.at) < Self.brightnessEchoGrace else {
            commandedBrightness[serviceName] = nil
            return false
        }
        return true
    }

    func setFlip(_ flipped: Bool, for serviceName: String) {
        control(serviceName, capability: .flip) { session in
            updatePanel(serviceName) { panel in
                panel.flipped = flipped
                // The firmware treats flip as absolute (1 -> rotation 2,
                // 0 -> upright), so mirror that locally too - the next
                // acknowledgement confirms it either way.
                panel.rotation = flipped ? 2 : 0
            }
            session.setFlip(flipped)
        }
    }

    /// Set the mounting rotation in clockwise quarter turns, on a panel whose
    /// firmware accepts one. Gated on `.rotate`: older firmware refuses the
    /// opcode silently, and rectangular panels never advertise it (their
    /// 90-degree case is the landscape mechanism, not MADCTL). `setFlip`
    /// stays alongside for those panels.
    func setRotation(_ rotation: Int, for serviceName: String) {
        control(serviceName, capability: .rotate) { session in
            let clamped = min(
                max(rotation, DeviceProtocol.rotationRange.lowerBound),
                DeviceProtocol.rotationRange.upperBound)
            updatePanel(serviceName) { panel in
                panel.rotation = clamped
                panel.flipped = clamped == 2
            }
            session.setRotation(clamped)
        }
    }

    /// Turn the panel's display on or off, as a standing instruction the panel
    /// keeps until told otherwise - distinct from `sendDisplaySleep`/
    /// `sendDisplayWake`, which follow this Mac's own screens and are cleared
    /// by the next drawn frame. Every board advertises `.power` (see
    /// `DeviceProtocol.Capabilities.power`), so this is never gated on chip.
    func setPower(_ on: Bool, for serviceName: String) {
        control(serviceName, capability: .power) { session in
            updatePanel(serviceName) { $0.manuallyOff = !on }
            session.setPower(on)
        }
    }

    func identify(_ serviceName: String) {
        let seconds = settings.identifySeconds
        control(serviceName, capability: .identify) { $0.identify(seconds: seconds) }
    }

    func restart(_ serviceName: String) {
        control(serviceName, capability: .restart) { $0.restartDevice() }
    }


    /// Set the screensaver template the panel shows while nothing is driving it.
    ///
    /// Stored as the user typed it, tokens and all, so the editor round-trips and
    /// the values are re-substituted with fresh ones every time the panel is
    /// pushed to. Expansion and sanitizing happen on the way to the device,
    /// whose font is a 5x7 ASCII bitmap.
    func setIdleText(_ text: String, for serviceName: String) {
        guard panels.contains(where: { $0.serviceName == serviceName }) else { return }
        updatePanel(serviceName) { $0.idleText = text }
        persistIfNeeded(force: true)
        pushIdleText(to: serviceName)
    }

    /// How a template will actually appear on the panel, so the UI can show what
    /// was substituted and what was dropped rather than leaving the user to
    /// guess. Pass `template` to preview unsaved edits; omit it for the saved one.
    func screensaverPreview(
        for serviceName: String, template: String? = nil
    ) -> ScreensaverTemplate.Expansion {
        guard let panel = panels.first(where: { $0.serviceName == serviceName })
        else {
            return ScreensaverTemplate.Expansion(lines: [], unknownTokens: [])
        }
        return ScreensaverTemplate.expand(
            template ?? panel.idleText, values: panel.screensaverValues)
    }

    func pushIdleText(to serviceName: String) {
        guard let session = sessions[serviceName],
              let panel = panels.first(where: { $0.serviceName == serviceName }),
              panel.capabilities.contains(.idleText)
        else { return }
        // An empty template sends an empty packet, which clears the card and
        // lets the panel fall back to drawing its own.
        session.sendIdleText(
            ScreensaverTemplate.expand(
                panel.idleText, values: panel.screensaverValues).lines)
    }

}
