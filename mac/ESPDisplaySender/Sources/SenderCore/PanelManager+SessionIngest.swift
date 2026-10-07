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
        let current = panels.first { $0.serviceName == serviceName }?.audioStatus
        holdTelemetry(serviceName, sessionID: sessionID) { $0.audio = status }
        offerTelemetry(
            serviceName,
            urgent: current == nil || current?.state != status.state)
    }

    /// Hold one field for `serviceName`. Data held for a different session is
    /// discarded first, so it cannot ride along under the new session's id.
    func holdTelemetry(
        _ serviceName: String, sessionID: UUID?,
        _ change: (inout PendingTelemetry) -> Void
    ) {
        var pending = pendingTelemetry[serviceName] ?? PendingTelemetry()
        if let sessionID, let held = pending.sessionID, held != sessionID {
            pending = PendingTelemetry()
        }
        if let sessionID { pending.sessionID = sessionID }
        change(&pending)
        pendingTelemetry[serviceName] = pending
    }

    /// Hold `serviceName`'s telemetry and write it when its budget allows.
    func offerTelemetry(_ serviceName: String, urgent: Bool) {
        let now = telemetryNow()
        switch telemetryThrottle.offer(serviceName, now: now, urgent: urgent) {
        case .flushNow:
            flushTelemetry(serviceName)
        case .flushAt(let date, let generation):
            scheduleTelemetryFlush(max(0, date.timeIntervalSince(now))) {
                [weak self] in
                guard let self,
                      self.telemetryThrottle.claim(serviceName, generation: generation)
                else { return }
                self.flushTelemetry(serviceName)
            }
        case .coalesced:
            break
        }
    }

    /// One write to `panels` carrying everything held for the panel.
    func flushTelemetry(_ serviceName: String) {
        guard let pending = pendingTelemetry.removeValue(forKey: serviceName),
              pending.audio != nil || pending.heartbeat != nil,
              !supersededServiceNames.contains(serviceName)
        else { return }
        // The guards in updateAudio and update(event) ran when the data
        // arrived; the write can land up to `interval` later.
        if let sessionID = pending.sessionID, sessions[serviceName]?.id != sessionID {
            return
        }
        telemetryThrottle.wrote(serviceName, at: telemetryNow())
        updatePanel(serviceName) { panel in
            if let audio = pending.audio { panel.audioStatus = audio }
            if let heartbeat = pending.heartbeat {
                // Held up to `interval`: never move a newer event's time back.
                panel.lastSeen = max(panel.lastSeen ?? heartbeat.at, heartbeat.at)
                panel.lastHeartbeatAt = max(
                    panel.lastHeartbeatAt ?? heartbeat.at, heartbeat.at)
                panel.lastReplyAt = max(panel.lastReplyAt ?? heartbeat.at, heartbeat.at)
                panel.lastError = nil
                panel.framesShown = heartbeat.stats.shown
                panel.framesDropped = heartbeat.stats.dropped
                panel.freeHeap = heartbeat.stats.heap
            }
        }
    }

    func clearAudio(for serviceName: String) {
        guard !supersededServiceNames.contains(serviceName),
              panels.contains(where: { $0.serviceName == serviceName })
        else { return }
        pendingTelemetry[serviceName]?.audio = nil
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
            if let replyAge = status.replyAge {
                panel.lastReplyAt = status.updatedAt.addingTimeInterval(-replyAge)
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
        let now = telemetryNow()
        var reconciledIdentity = false
        switch event {
        case .heartbeat(let stats):
            // A first heartbeat, or one after a gap, can change what the window
            // says about the panel (online, an error cleared): show it at once.
            let previous = panels.first { $0.serviceName == serviceName }?
                .lastHeartbeatAt
            holdTelemetry(serviceName, sessionID: sessionID) {
                $0.heartbeat = (stats, now)
            }
            offerTelemetry(
                serviceName,
                urgent: previous.map { now.timeIntervalSince($0) > 2 } ?? true)
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
                panel.lastReplyAt = now
                panel.lastError = nil
                Self.apply(info, to: &panel, keepBrightness: keepBrightness)
            }
            followReportedRotation(from: previousRotation, for: serviceName)
            // EINF arrives on connect, after a reboot, and every 2s after
            // that, so pushing here both restores what a rebooted panel lost
            // and keeps live tokens fresh. It is also where a panel nobody
            // has set up a screensaver for is given the default one.
            assignDefaultScreensaverIfUnset(serviceName)
            pushIdleText(to: serviceName)
        case .acknowledgement(let acknowledgement):
            let keepBrightness = ignoreReportedBrightness(
                Int(acknowledgement.brightness), for: serviceName)
            updatePanel(serviceName) { panel in
                panel.lastSeen = now
                panel.lastHeartbeatAt = now
                panel.lastReplyAt = now
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
            // It is a reply, though: the panel sent it over WiFi.
            updatePanel(serviceName) { panel in
                panel.lastSeen = now
                panel.lastReplyAt = now
            }
            handleTouch(touch, for: serviceName)
        case .battery(let battery):
            // Not `lastHeartbeatAt`, for the same reason as touch and one more:
            // this arrives on its own slow timer whether or not frames are
            // getting through, so treating it as a heartbeat would keep a dead
            // panel reading "Online" forever.
            updatePanel(serviceName) { panel in
                panel.lastSeen = now
                panel.lastReplyAt = now
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
        // The reported build is tied to the version it came with
        // (`currentFirmwareSource`), so a version change here hides a stale
        // build without discarding one that already arrived for the new one.
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
