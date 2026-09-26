import AppKit
import Foundation
import Network
import ScreenCaptureKit
import SenderProtocol

/// Telemetry ingestion: DeviceSession.Status and
/// FrameSender.DeviceEvent land here, guarded by session ID and
/// superseded-name checks, and are copied into the published
/// snapshots.
extension PanelManager {
    func updateAudio(
        _ status: PanelAudioSnapshot,
        for serviceName: String,
        sessionID: UUID? = nil
    ) {
        if let sessionID, sessions[serviceName]?.id != sessionID { return }
        guard !supersededServiceNames.contains(serviceName),
              panels.contains(where: { $0.serviceName == serviceName })
        else { return }
        updatePanel(serviceName) { panel in
            panel.audioStatus = status
        }
    }

    func clearAudio(for serviceName: String) {
        guard !supersededServiceNames.contains(serviceName),
              panels.contains(where: { $0.serviceName == serviceName })
        else { return }
        updatePanel(serviceName) { panel in
            panel.audioStatus = nil
        }
    }

    func update(_ status: DeviceSession.Status, sessionID: UUID? = nil) {
        if let sessionID, sessions[status.serviceName]?.id != sessionID { return }
        guard !supersededServiceNames.contains(status.serviceName) else { return }
        let reconciledIdentity: Bool
        if let hardwareID = status.info?.deviceID {
            guard let reconciled = bindSessionIdentity(
                hardwareID: hardwareID, serviceName: status.serviceName)
            else { return }
            reconciledIdentity = reconciled
        } else {
            guard panels.contains(where: { $0.serviceName == status.serviceName })
            else { return }
            reconciledIdentity = false
        }
        updatePanel(status.serviceName) { panel in
            panel.lastSeen = status.updatedAt
            panel.lastHeartbeatAt = status.heartbeatAge.map {
                status.updatedAt.addingTimeInterval(-$0)
            }
            panel.displayFPS = status.displayFPS
            panel.framesSent = status.framesSent
            panel.sendErrors = status.sendErrors
            panel.diffPercent = status.diffPercent
            panel.framesShown = status.stats.shown
            panel.framesDropped = status.stats.dropped
            panel.freeHeap = status.stats.heap
            panel.spacingMicros = status.spacingMicros
            panel.paused = status.paused
            panel.sourceDescription = status.sourceDescription
            panel.landscape = status.landscape
            panel.captureStatus = status.captureStatus
            panel.lastFrameAt = status.lastFrameAt
            // A parked session is alive but deliberately not capturing, which
            // otherwise looks identical to a panel that is simply idle.
            panel.lastError = status.parked
                ? "Not reachable, so capture is stopped for this display. It resumes "
                    + "automatically as soon as the panel answers again."
                : nil
            if let address = status.resolvedAddress { panel.address = address }
            // The session's last EINF, replayed every status tick. Its
            // orientation can predate a rotation this app or USB has set
            // since, and every fresh EINF already arrives as `.info`, so the
            // replay leaves orientation alone.
            if let info = status.info {
                Self.apply(info, to: &panel, includeOrientation: false)
            }
        }
        persistIfNeeded(force: reconciledIdentity)
    }

    /// Publish network events immediately, independently of capture startup.
    /// This keeps the manager online and its controls usable while
    /// ScreenCaptureKit is waiting for a source or permission.
    func update(
        _ event: FrameSender.DeviceEvent,
        for serviceName: String,
        sessionID: UUID? = nil
    ) {
        if let sessionID, sessions[serviceName]?.id != sessionID { return }
        guard !supersededServiceNames.contains(serviceName) else { return }
        let now = Date()
        var reconciledIdentity = false
        switch event {
        case .heartbeat(let stats):
            updatePanel(serviceName) { panel in
                panel.lastSeen = now
                panel.lastHeartbeatAt = now
                panel.lastError = nil
                panel.framesShown = stats.shown
                panel.framesDropped = stats.dropped
                panel.freeHeap = stats.heap
            }
        case .info(let info):
            guard let reconciled = bindSessionIdentity(
                hardwareID: info.deviceID, serviceName: serviceName)
            else { return }
            reconciledIdentity = reconciled
            let keepBrightness = ignoreReportedBrightness(
                Int(info.brightness), for: serviceName)
            let previousRotation = panels.first {
                $0.serviceName == serviceName
            }?.rotation
            updatePanel(serviceName) { panel in
                panel.lastSeen = now
                panel.lastHeartbeatAt = now
                panel.lastError = nil
                Self.apply(info, to: &panel, keepBrightness: keepBrightness)
            }
            followReportedRotation(from: previousRotation, for: serviceName)
            // EINF means the device just connected or rebooted, so anything it
            // was told before is gone. This is the only moment the sender knows
            // to push it again.
            pushIdleText(to: serviceName)
        case .acknowledgement(let acknowledgement):
            let keepBrightness = ignoreReportedBrightness(
                Int(acknowledgement.brightness), for: serviceName)
            updatePanel(serviceName) { panel in
                panel.lastSeen = now
                panel.lastHeartbeatAt = now
                if !keepBrightness {
                    panel.brightness = Int(acknowledgement.brightness)
                }
                panel.brightnessHigh = acknowledgement.brightnessHigh
                panel.flipped = acknowledgement.flipped
                panel.rotation = acknowledgement.rotation
                panel.sleeping = acknowledgement.sleeping
                panel.manuallyOff = acknowledgement.manuallyOff
            }
            if !acknowledgement.succeeded {
                operationOutcome = .failure(
                    "Display command failed",
                    "The display rejected the \(acknowledgement.opcode) "
                        + "command (status \(acknowledgement.status)).")
            }
        case .touch(let touch):
            // Deliberately does not set `lastHeartbeatAt`: a finger is not
            // evidence that frames are arriving, and letting it stand in for a
            // heartbeat would keep a panel reading "Online" after its stream
            // had stopped.
            updatePanel(serviceName) { $0.lastSeen = now }
            handleTouch(touch, for: serviceName)
        case .battery(let battery):
            // Not `lastHeartbeatAt`, for the same reason as touch and one more:
            // this arrives on its own slow timer whether or not frames are
            // getting through, so treating it as a heartbeat would keep a dead
            // panel reading "Online" forever.
            updatePanel(serviceName) { panel in
                panel.lastSeen = now
                panel.battery = battery
                // Stamped so the row can age it out. The panel stops sending
                // rather than reporting a failure, so this timestamp is the only
                // evidence a reading has gone quiet.
                panel.batteryAt = now
            }
        }
        persistIfNeeded(force: reconciledIdentity)
    }


    static func apply(
        _ info: DeviceProtocol.DeviceInfo, to panel: inout PanelSnapshot,
        keepBrightness: Bool = false, includeOrientation: Bool = true
    ) {
        panel.displayName = info.name
        panel.hardwareID = info.deviceID
        panel.rssi = Int(info.rssi)
        panel.firmwareVersion = info.firmwareVersion
        panel.frameProtocolVersion = Int(info.frameProtocolVersion)
        panel.controlProtocolVersion = Int(info.controlProtocolVersion)
        panel.capabilitiesRaw = info.capabilities.rawValue
        panel.uptimeSeconds = info.uptimeSeconds
        // Only the level is held back. The high/low flag is derived on the
        // device from a PWM threshold the Mac does not know, so guessing at it
        // locally would be inventing state; the device stays authoritative.
        if !keepBrightness {
            panel.brightness = Int(info.brightness)
        }
        panel.brightnessHigh = info.brightnessHigh
        if includeOrientation {
            panel.flipped = info.flipped
            panel.rotation = info.rotation
        }
        panel.sleeping = info.sleeping
        panel.idle = info.idle
        panel.manuallyOff = info.manuallyOff
    }

}
