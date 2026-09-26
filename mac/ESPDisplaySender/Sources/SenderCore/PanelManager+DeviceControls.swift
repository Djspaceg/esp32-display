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
    enum Operation: Equatable {
        case brightness
        case brightnessLevel
        case brightnessLevels
        case flip
        case rotate
        case automaticRotation
        case power
        case identify
        case restart
        case savedWiFi
        case rename
        case otaPassword
        case firmwareUpdate
        case wirelessFirmwareUpdate
        case streaming
    }

    enum OperationPath: Equatable {
        case network
        case usbSerial(String)
        case usbBootloaderCandidate(String)
    }

    enum OperationAvailability: Equatable {
        case available([OperationPath])
        case unavailable(String)
    }

    private enum USBEvidence {
        case verified
        case brightness
        case power
        case orientation
        case quarterTurn
        case automaticRotation
        case brightnessLevels
    }

    private indirect enum OperationRequirement {
        case networkControl(DeviceProtocol.Capabilities)
        case liveNetworkSession
        case usbSerial(USBEvidence)
        case usbBootloader
        case either([OperationRequirement])
    }

    /// One rule drives disabled state, help text, refusal, and dispatch.
    func operationAvailability(
        _ serviceName: String, operation: Operation
    ) -> OperationAvailability {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }) else {
            return .unavailable("This display is not known yet.")
        }
        let requirement = Self.requirement(for: operation)
        let paths = availablePaths(
            satisfying: requirement, serviceName: serviceName, panel: panel)
        if !paths.isEmpty { return .available(paths) }
        return .unavailable(
            unavailableReason(
                for: operation, requirement: requirement,
                serviceName: serviceName, panel: panel))
    }

    func operationUnavailableReason(
        _ serviceName: String, operation: Operation
    ) -> String? {
        guard case .unavailable(let reason) =
            operationAvailability(serviceName, operation: operation)
        else { return nil }
        return reason
    }

    func canPerform(_ operation: Operation, for serviceName: String) -> Bool {
        if case .available = operationAvailability(serviceName, operation: operation) {
            return true
        }
        return false
    }

    func controlUnavailableReason(
        _ serviceName: String, capability: DeviceProtocol.Capabilities
    ) -> String? {
        operationUnavailableReason(
            serviceName, operation: Self.operation(for: capability))
    }

    func streamingUnavailableReason(_ serviceName: String) -> String? {
        operationUnavailableReason(serviceName, operation: .streaming)
    }

    func canControl(
        _ serviceName: String, capability: DeviceProtocol.Capabilities
    ) -> Bool {
        controlUnavailableReason(serviceName, capability: capability) == nil
    }

    func supportsBrightnessLevel(_ serviceName: String) -> Bool {
        guard let panel = panels.first(where: { $0.serviceName == serviceName })
        else { return false }
        if panel.capabilities.contains(.brightnessLevel)
            || verifiedUSBDevice(for: serviceName)?.serialStatus?.brightnessLevel != nil {
            return true
        }
        // Keep the legacy high/low switch for firmware that advertises it over
        // WiFi. A cold USB record has no capability packet, so show the exact
        // row disabled with the serial-evidence reason instead of hiding it.
        if panel.capabilities.contains(.brightness) { return false }
        switch usbSerialState(for: serviceName) {
        case .absent:
            return false
        case .enumeratedUnverified, .verified, .restarting, .mismatch, .ambiguous:
            return true
        }
    }

    /// Turn the streamed region on its side when a rotation change crosses
    /// between an even and an odd quarter turn.
    ///
    /// On rectangular glass the region's shape is what makes 90 and 270
    /// landscape: the firmware addresses whatever shape the frames arrive in,
    /// and only the half turn of the rotation reaches the panel directly. So
    /// there the crossing sets the shape outright - landscape for an odd
    /// rotation, portrait for an even one - rather than toggling it, which
    /// keeps a region the user already dragged landscape at 0 degrees
    /// landscape when they pick 90. On square glass (or before the geometry is
    /// known) any shape turns with the glass, so it toggles.
    ///
    /// Separate from setRotation so it is reachable in tests: setRotation refuses
    /// to record a rotation it cannot deliver, so it needs a live session or a
    /// verified USB device, while the decision this makes needs neither.
    func applyRegionQuarterTurn(from previous: Int, to next: Int,
                                for serviceName: String) {
        guard previous % 2 != next % 2 else { return }
        if let geometry = geometry(of: serviceName),
           geometry.width != geometry.height {
            guard let region = panels.first(
                where: { $0.serviceName == serviceName })?.source.region,
                region.isLandscape != (next % 2 != 0)
            else { return }
        }
        rotateRegion(for: serviceName)
    }

    /// Follow a rotation the panel reports that this app did not just ask for:
    /// one set over serial or from another Mac. On rectangular glass the
    /// region's shape is what makes 90 and 270 landscape, so a reported change
    /// of parity sets it exactly as picking the rotation here would. Reports
    /// inside `rotationEchoGrace` of this app's own command are skipped: the
    /// panel's periodic info can still carry the old value, and following it
    /// would turn the region back and forth. Square glass is left alone.
    func followReportedRotation(from previous: Int?, for serviceName: String) {
        guard let previous,
              let next = panels.first(
                  where: { $0.serviceName == serviceName })?.rotation,
              previous % 2 != next % 2,
              let geometry = geometry(of: serviceName),
              geometry.width != geometry.height
        else { return }
        if let commanded = commandedRotationAt[serviceName],
           Date().timeIntervalSince(commanded) < Self.rotationEchoGrace {
            return
        }
        applyRegionQuarterTurn(from: previous, to: next, for: serviceName)
    }

    func supportsQuarterTurnRotation(_ serviceName: String) -> Bool {
        guard let panel = panels.first(where: { $0.serviceName == serviceName })
        else { return false }
        if panel.capabilities.contains(.rotate), panel.geometry != nil { return true }
        guard let device = verifiedUSBDevice(for: serviceName) else { return false }
        return usbDevice(device, reports: .quarterTurn)
    }

    private static func requirement(for operation: Operation) -> OperationRequirement {
        switch operation {
        case .brightness:
            return .networkControl(.brightness)
        case .brightnessLevel:
            return .either([
                .networkControl(.brightnessLevel),
                .usbSerial(.brightness),
            ])
        case .brightnessLevels:
            return .usbSerial(.brightnessLevels)
        case .flip:
            return .either([.networkControl(.flip), .usbSerial(.orientation)])
        case .rotate:
            return .either([.networkControl(.rotate), .usbSerial(.quarterTurn)])
        case .automaticRotation:
            return .usbSerial(.automaticRotation)
        case .power:
            return .either([.networkControl(.power), .usbSerial(.power)])
        case .identify:
            return .networkControl(.identify)
        case .restart:
            return .networkControl(.restart)
        case .savedWiFi, .rename, .otaPassword:
            return .usbSerial(.verified)
        case .firmwareUpdate:
            return .either([.networkControl(.ota), .usbBootloader])
        case .wirelessFirmwareUpdate:
            return .networkControl(.ota)
        case .streaming:
            return .liveNetworkSession
        }
    }

    private static func operation(
        for capability: DeviceProtocol.Capabilities
    ) -> Operation {
        switch capability {
        case .brightness: return .brightness
        case .brightnessLevel: return .brightnessLevel
        case .flip: return .flip
        case .rotate: return .rotate
        case .identify: return .identify
        case .restart: return .restart
        case .ota: return .wirelessFirmwareUpdate
        case .power: return .power
        default: return .streaming
        }
    }

    private func availablePaths(
        satisfying requirement: OperationRequirement,
        serviceName: String,
        panel: PanelSnapshot
    ) -> [OperationPath] {
        switch requirement {
        case .networkControl(let capability):
            // A quarter turn needs the panel's shape, to know whether the
            // region has to turn with it.
            if capability == .rotate, panel.geometry == nil { return [] }
            guard networkControlReady(serviceName, panel: panel),
                  panel.capabilities.contains(capability)
            else { return [] }
            return [.network]
        case .liveNetworkSession:
            guard sessions[serviceName] != nil, panel.isOnline else { return [] }
            return [.network]
        case .usbSerial(let evidence):
            guard case .verified(let device) = usbSerialState(for: serviceName),
                  usbDevice(device, reports: evidence)
            else { return [] }
            return [.usbSerial(device.path)]
        case .usbBootloader:
            // A bootloader write needs the device's own reported identity, not
            // the live CFGSHOW status a runtime control needs: everything it is
            // checked against is read again right before esptool writes.
            guard let device = usbFlashDevice(for: serviceName)
            else { return [] }
            return [.usbBootloaderCandidate(device.path)]
        case .either(let requirements):
            return requirements.flatMap {
                availablePaths(
                    satisfying: $0, serviceName: serviceName, panel: panel)
            }
        }
    }

    private func networkControlReady(
        _ serviceName: String, panel: PanelSnapshot
    ) -> Bool {
        sessions[serviceName] != nil
            && panel.isOnline
            && panel.controlProtocolVersion
                == Int(DeviceProtocol.controlProtocolVersion)
    }

    private func usbDevice(
        _ device: WifiConfigUI.USBDeviceOption, reports evidence: USBEvidence
    ) -> Bool {
        guard let status = device.serialStatus else { return false }
        switch evidence {
        case .verified:
            return true
        case .brightness:
            return status.brightnessLevel != nil
        case .power:
            return status.manuallyOff != nil
        case .orientation:
            return status.rotation != nil || status.flipped != nil
        case .quarterTurn:
            return (status.rotation != nil || status.flipped != nil)
                && status.capabilities?.contains(.rotate) == true
                && device.board.map(Self.usbBoardSupportsQuarterTurns) == true
        case .automaticRotation:
            return status.motionAvailable == true
                && status.automaticRotationEnabled != nil
                && status.effectiveRotation != nil
        case .brightnessLevels:
            return status.brightnessLevels != nil
        }
    }

    private static func usbBoardSupportsQuarterTurns(_ board: String) -> Bool {
        GeneratedBoardCatalog.quarterTurnProfiles.contains(board)
    }

    private func unavailableReason(
        for operation: Operation,
        requirement: OperationRequirement,
        serviceName: String,
        panel: PanelSnapshot
    ) -> String {
        if operation == .streaming {
            return "Streaming and pause require a live WiFi session."
        }

        if (operation == .brightness || operation == .brightnessLevel),
           case .verified = usbSerialState(for: serviceName) {
            return "Brightness over USB needs firmware support that this "
                + "display does not report."
        }

        if operation == .firmwareUpdate,
           let device = usbUpdateDevice(for: serviceName),
           !Self.usbDeviceIdentifiesItselfForFlashing(device) {
            return "USB is connected, but the app cannot verify the board "
                + "family, chip, profile, and partition safely."
        }

        if Self.includesUSB(requirement) {
            switch usbSerialState(for: serviceName) {
            case .enumeratedUnverified:
                return "USB is connected, but the app has not verified this "
                    + "display's hardware ID yet."
            case .mismatch:
                return "The connected USB device does not match this display."
            case .ambiguous:
                return "More than one USB device matches this display. Refresh "
                    + "USB devices and choose the correct one."
            case .restarting:
                return "The display is restarting; USB controls will return when "
                    + "it answers CFGSHOW."
            case .verified(let device):
                if operation == .brightness || operation == .brightnessLevel {
                    return "Brightness over USB needs firmware support that this "
                        + "display does not report."
                }
                if operation == .automaticRotation {
                    return "Automatic orientation needs a motion sensor and "
                        + "current firmware support over USB."
                }
                if operation == .brightnessLevels {
                    return "Brightness presets need current firmware support "
                        + "over USB."
                }
                if Self.includesUSBSerial(requirement),
                   device.serialStatus != nil {
                    return "This firmware does not report support for this control "
                        + "over the available connection."
                }
            case .absent:
                break
            }
        }

        if Self.includesNetwork(requirement) {
            if sessions[serviceName] != nil || panel.discovered {
                if panel.isOnline,
                   panel.controlProtocolVersion
                    != Int(DeviceProtocol.controlProtocolVersion) {
                    return "Flash the current firmware to enable remote controls."
                }
                if networkControlReady(serviceName, panel: panel),
                   let capability = Self.networkCapability(in: requirement),
                   !panel.capabilities.contains(capability) {
                    if capability == .ota {
                        return "Wireless updating needs WiFi and an active OTA "
                            + "password. Connect over USB to set one."
                    }
                    return "This display does not report support for "
                        + "\(Self.describe(capability))."
                }
                return "The display is visible on WiFi but has not started a "
                    + "control session yet."
            }
            if !Self.includesUSB(requirement) {
                if operation == .wirelessFirmwareUpdate {
                    return "Wireless updating needs WiFi and an active OTA password. "
                        + "Connect over USB to set one."
                }
                return "This control needs the display to be connected over WiFi."
            }
        }

        if Self.includesUSB(requirement) && !Self.includesNetwork(requirement) {
            return "Connect this display to this Mac over USB."
        }
        return "Connect this display over USB or let it rejoin WiFi."
    }

    private static func includesNetwork(_ requirement: OperationRequirement) -> Bool {
        switch requirement {
        case .networkControl, .liveNetworkSession: return true
        case .either(let requirements): return requirements.contains(where: includesNetwork)
        case .usbSerial, .usbBootloader: return false
        }
    }

    private static func includesUSB(_ requirement: OperationRequirement) -> Bool {
        switch requirement {
        case .usbSerial, .usbBootloader: return true
        case .either(let requirements): return requirements.contains(where: includesUSB)
        case .networkControl, .liveNetworkSession: return false
        }
    }

    private static func includesUSBSerial(
        _ requirement: OperationRequirement
    ) -> Bool {
        switch requirement {
        case .usbSerial: return true
        case .either(let requirements):
            return requirements.contains(where: includesUSBSerial)
        case .networkControl, .liveNetworkSession, .usbBootloader: return false
        }
    }

    private static func networkCapability(
        in requirement: OperationRequirement
    ) -> DeviceProtocol.Capabilities? {
        switch requirement {
        case .networkControl(let capability): return capability
        case .either(let requirements):
            return requirements.compactMap(networkCapability).first
        case .liveNetworkSession, .usbSerial, .usbBootloader: return nil
        }
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

    @discardableResult
    func requireOperation(
        _ operation: Operation, for serviceName: String, title: String
    ) -> Bool {
        if let reason = operationUnavailableReason(serviceName, operation: operation) {
            operationOutcome = .failure(
                "\(title) unavailable", reason)
            return false
        }
        return true
    }

    private func preferredPath(
        for operation: Operation, serviceName: String
    ) -> OperationPath? {
        switch operationAvailability(serviceName, operation: operation) {
        case .available(let paths):
            return paths.first
        case .unavailable(let reason):
            operationOutcome = .failure(
                "\(Self.operationTitle(operation)) unavailable", reason)
            return nil
        }
    }

    private static func operationTitle(_ operation: Operation) -> String {
        switch operation {
        case .brightness, .brightnessLevel, .brightnessLevels: return "Brightness"
        case .flip, .rotate: return "Rotation"
        case .automaticRotation: return "Automatic orientation"
        case .power: return "Power control"
        case .identify: return "Identify"
        case .restart: return "Remote restart"
        case .savedWiFi: return "WiFi configuration"
        case .rename: return "Rename"
        case .otaPassword: return "OTA password"
        case .firmwareUpdate, .wirelessFirmwareUpdate: return "Firmware updates"
        case .streaming: return "Streaming"
        }
    }

    private func performUSBControl(
        _ command: String,
        path: String,
        serviceName: String
    ) async {
        let generation = usbPathGeneration(path)
        let sender = usbControlSender
        let result = await Task.detached(priority: .utility) {
            sender(command, path, 4)
        }.value
        guard generation == usbPathGeneration(path) else {
            operationOutcome = .failure(
                "USB control unavailable",
                "The display is restarting; USB controls will return when it "
                    + "answers CFGSHOW.")
            return
        }
        switch result {
        case .success:
            await reprobeAfterUSBControl(path)
        case .failure(let reason):
            await reprobeAfterUSBControl(path)
            operationOutcome = .failure("USB control failed", reason)
        }
    }

    private func reprobeAfterUSBControl(_ path: String) async {
        if let usbControlReprobe {
            await usbControlReprobe(path, 3)
        } else {
            _ = await probeUSBDevice(path, timeout: 3)
        }
    }

    private func queueUSBControl(
        _ command: String,
        path: String,
        serviceName: String,
        coalescingBrightness: Bool = false
    ) {
        if coalescingBrightness {
            pendingUSBBrightness[serviceName] = (command, path)
            guard usbBrightnessTasks[serviceName] == nil else { return }
            let work = Task { @MainActor [weak self] in
                guard let self else { return }
                while true {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard let pending = self.pendingUSBBrightness.removeValue(
                        forKey: serviceName)
                    else { break }
                    await self.performUSBControl(
                        pending.command, path: pending.path,
                        serviceName: serviceName)
                }
                self.usbBrightnessTasks[serviceName] = nil
            }
            usbBrightnessTasks[serviceName] = work
        } else {
            Task { @MainActor [weak self] in
                await self?.performUSBControl(
                    command, path: path, serviceName: serviceName)
            }
        }
    }

    func setBrightness(high: Bool, for serviceName: String) {
        guard preferredPath(for: .brightness, serviceName: serviceName) == .network,
              let session = sessions[serviceName]
        else { return }
        updatePanel(serviceName) { $0.brightnessHigh = high }
        session.setBrightness(high: high)
    }

    /// Set an exact backlight level on firmware that accepts one.
    ///
    /// The panel value is updated straight away so a slider tracks the finger
    /// rather than waiting a round trip. The device's own reports are then
    /// suppressed until it catches up, because they lag the drag and would
    /// otherwise fight the thumb.
    func setBrightnessLevel(_ level: Int, for serviceName: String) {
        let clamped = min(
            max(level, DeviceProtocol.brightnessLevelRange.lowerBound),
            DeviceProtocol.brightnessLevelRange.upperBound)
        guard let path = preferredPath(for: .brightnessLevel, serviceName: serviceName)
        else { return }
        switch path {
        case .network:
            guard let session = sessions[serviceName] else { return }
            updatePanel(serviceName) { $0.brightness = clamped }
            commandedBrightness[serviceName] = (level: clamped, at: Date())
            session.setBrightnessLevel(clamped)
        case .usbSerial(let port):
            guard let command = ConfigCommands.setBrightnessLevel(clamped) else { return }
            updatePanel(serviceName) { $0.brightness = clamped }
            queueUSBControl(
                command, path: port, serviceName: serviceName,
                coalescingBrightness: true)
        case .usbBootloaderCandidate:
            return
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
        guard let path = preferredPath(for: .flip, serviceName: serviceName)
        else { return }
        let previous = panels.first { $0.serviceName == serviceName }?.rotation
        commandedRotationAt[serviceName] = Date()
        updatePanel(serviceName) { panel in
            panel.flipped = flipped
            panel.rotation = flipped ? 2 : 0
        }
        // Only reachable from an odd rotation that something else set; the
        // flip then means upright or upside-down, so the region stands up.
        if let previous {
            applyRegionQuarterTurn(
                from: previous, to: flipped ? 2 : 0, for: serviceName)
        }
        switch path {
        case .network:
            guard let session = sessions[serviceName] else { return }
            session.setFlip(flipped)
        case .usbSerial(let port):
            queueUSBControl(
                ConfigCommands.setFlip(flipped), path: port,
                serviceName: serviceName)
        case .usbBootloaderCandidate:
            return
        }
    }

    /// Set the mounting rotation in clockwise quarter turns, on a panel whose
    /// firmware accepts one. Gated on `.rotate`: older firmware refuses the
    /// opcode silently, and firmware before rectangular landscape never
    /// advertised it on rectangular glass. `setFlip` stays alongside for
    /// those panels.
    func setRotation(_ rotation: Int, for serviceName: String) {
        let clamped = min(
            max(rotation, DeviceProtocol.rotationRange.lowerBound),
            DeviceProtocol.rotationRange.upperBound)
        guard let path = preferredPath(for: .rotate, serviceName: serviceName)
        else { return }
        let previous = panels.first { $0.serviceName == serviceName }?.rotation
        commandedRotationAt[serviceName] = Date()
        updatePanel(serviceName) { panel in
            panel.rotation = clamped
            panel.flipped = clamped == 2
        }
        // A quarter turn exchanges the glass's long and short sides, so the
        // streamed region has to turn with it or the captured shape lies across
        // the panel the wrong way. Only the ODD/EVEN change matters: 0 to 2 is a
        // half turn and keeps the same shape, while 0 to 1 or 1 to 2 does not.
        //
        // On square glass a square region rotates to itself, so this only
        // bites when the marquee has been dragged to a non-square shape. On
        // rectangular glass it is the whole of landscape: 90 and 270 capture a
        // region lying on its side (320x170 on the 1.9-inch), and the panel
        // draws the landscape frames that produces - automatic correction on
        // the panel stays a 180 flip on top.
        //
        // Done beside updatePanel rather than after the transport switch, so it
        // follows the app's own record of the orientation. That record is already
        // updated above whether or not the command reaches the panel, and having
        // the region disagree with it would be the greater surprise.
        if let previous {
            applyRegionQuarterTurn(from: previous, to: clamped, for: serviceName)
        }
        switch path {
        case .network:
            guard let session = sessions[serviceName] else { return }
            session.setRotation(clamped)
        case .usbSerial(let port):
            guard let command = ConfigCommands.setRotation(clamped) else { return }
            queueUSBControl(command, path: port, serviceName: serviceName)
        case .usbBootloaderCandidate:
            return
        }
    }

    func automaticRotationStatus(
        _ serviceName: String
    ) -> WifiConfigUI.USBStatus? {
        guard let status = verifiedUSBDevice(for: serviceName)?.serialStatus,
              status.motionAvailable == true,
              status.automaticRotationEnabled != nil,
              status.effectiveRotation != nil
        else { return nil }
        return status
    }

    func setAutomaticRotation(_ enabled: Bool, for serviceName: String) {
        guard case .usbSerial(let port) =
            preferredPath(for: .automaticRotation, serviceName: serviceName)
        else { return }
        if let index = usbDevices.firstIndex(where: { $0.path == port }),
           var status = usbDevices[index].serialStatus {
            status.automaticRotationEnabled = enabled
            usbDevices[index].serialStatus = status
        }
        queueUSBControl(
            ConfigCommands.setAutomaticRotation(enabled), path: port,
            serviceName: serviceName)
    }

    func brightnessLevels(
        _ serviceName: String
    ) -> WifiConfigUI.BrightnessLevels? {
        verifiedUSBDevice(for: serviceName)?.serialStatus?.brightnessLevels
    }

    func setBrightnessLevels(
        _ levels: WifiConfigUI.BrightnessLevels, for serviceName: String
    ) {
        guard case .usbSerial(let port) =
            preferredPath(for: .brightnessLevels, serviceName: serviceName),
              let command = ConfigCommands.setBrightnessLevels(
                  low: levels.low, high: levels.high,
                  idle: levels.idle, survey: levels.survey)
        else { return }
        if let index = usbDevices.firstIndex(where: { $0.path == port }),
           var status = usbDevices[index].serialStatus {
            status.brightnessLevels = levels
            usbDevices[index].serialStatus = status
        }
        queueUSBControl(command, path: port, serviceName: serviceName)
    }

    /// Turn the panel's display on or off, as a standing instruction the panel
    /// keeps until told otherwise - distinct from `sendDisplaySleep`/
    /// `sendDisplayWake`, which follow this Mac's own screens and are cleared
    /// by the next drawn frame. Every board advertises `.power` (see
    /// `DeviceProtocol.Capabilities.power`), so this is never gated on chip.
    func setPower(_ on: Bool, for serviceName: String) {
        guard let path = preferredPath(for: .power, serviceName: serviceName)
        else { return }
        updatePanel(serviceName) { $0.manuallyOff = !on }
        switch path {
        case .network:
            guard let session = sessions[serviceName] else { return }
            session.setPower(on)
        case .usbSerial(let port):
            queueUSBControl(
                ConfigCommands.setPower(on), path: port,
                serviceName: serviceName)
        case .usbBootloaderCandidate:
            return
        }
    }

    func identify(_ serviceName: String) {
        guard preferredPath(for: .identify, serviceName: serviceName) == .network,
              let session = sessions[serviceName]
        else { return }
        let seconds = settings.identifySeconds
        session.identify(seconds: seconds)
    }

    func restart(_ serviceName: String) {
        guard preferredPath(for: .restart, serviceName: serviceName) == .network,
              let session = sessions[serviceName]
        else { return }
        session.restartDevice()
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
