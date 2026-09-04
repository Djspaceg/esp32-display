import AppKit
import Foundation
import Network
import ScreenCaptureKit
import SenderProtocol

/// Record lifecycle: discovery, session registration, hardware-ID
/// identity binding and service-name migration, and removal. The
/// invariants that keep one physical board attached to exactly one
/// sidebar record live here.
extension PanelManager {
    func noteDiscovery(_ devices: [DeviceBrowser.Device]) {
        let visible = Set(devices.map(\.name))
        unownedServiceNames.formIntersection(visible)
        for index in panels.indices {
            let isVisible = visible.contains(panels[index].serviceName)
            panels[index].discovered = isVisible
            if !isVisible {
                // These values are evidence from this browse generation, not
                // durable hardware facts. Clear them when the service leaves so
                // a reboot into target-less firmware cannot inherit an earlier
                // S3 target and pass an OTA safety check on stale metadata.
                panels[index].chip = nil
                panels[index].target = nil
                panels[index].profile = nil
                panels[index].partition = nil
                panels[index].geometry = nil
            }
        }
        // Discovery attaches live state to records; it does not create records.
        // A physical board becomes a sidebar item only through Add Display over
        // USB, where its stable hardware ID is established first. Records loaded
        // from older versions are grandfathered and continue matching by their
        // saved service name until EINF confirms the hardware ID.
        // Recorded after the append loop so it reaches panels that already
        // existed - a panel restored from disk, or one whose first browse result
        // arrived before its TXT query answered.
        //
        // Only written when the record is there. NWBrowser can report a service
        // and then report it again with metadata attached, so overwriting with
        // nil would let the second-best result erase a chip that had already
        // arrived, and there is no such thing as a panel that stops knowing
        // which chip it is.
        //
        // Indexed rather than routed through updatePanel, which creates a row
        // for a name it does not find: a superseded service name must not come
        // back as a second row for a panel that has already been renamed.
        for device in devices where device.metadata.chip != nil {
            guard let index = panels.firstIndex(where: { $0.serviceName == device.name })
            else { continue }
            panels[index].chip = device.metadata.chip
        }
        for device in devices where device.metadata.target != nil {
            guard let index = panels.firstIndex(where: { $0.serviceName == device.name })
            else { continue }
            panels[index].target = device.metadata.target
        }
        for device in devices where device.metadata.profile != nil {
            guard let index = panels.firstIndex(where: { $0.serviceName == device.name })
            else { continue }
            panels[index].profile = device.metadata.profile
        }
        for device in devices where device.metadata.partition != nil {
            guard let index = panels.firstIndex(where: { $0.serviceName == device.name })
            else { continue }
            panels[index].partition = device.metadata.partition
        }
        // The resolution takes the same treatment and for the same reason: a
        // second browse result without metadata must not erase a `res` that has
        // already arrived. A panel does not stop knowing its own screen size.
        for device in devices where device.metadata.geometry != nil {
            guard let index = panels.firstIndex(where: { $0.serviceName == device.name })
            else { continue }
            panels[index].geometry = device.metadata.geometry
        }
        sortPanels()
        if selectedServiceName == nil {
            selectedServiceName = panels.first?.serviceName
        }
    }

    func hasRecord(forServiceName serviceName: String) -> Bool {
        panels.contains { $0.serviceName == serviceName }
            && !supersededServiceNames.contains(serviceName)
    }

    func shouldLaunchDiscoveredService(_ serviceName: String) -> Bool {
        guard !supersededServiceNames.contains(serviceName),
              !unownedServiceNames.contains(serviceName)
        else { return false }
        if hasRecord(forServiceName: serviceName) { return true }
        // A record may have been renamed outside this process. One paused
        // provisional session obtains EINF so the stable hardware ID can bind
        // it; non-matches are suppressed above.
        return panels.contains { stableHardwareID(of: $0) != nil }
    }


    func register(
        _ session: DeviceSession,
        allowUnowned: Bool = false,
        provisional: Bool = false
    ) {
        guard !supersededServiceNames.contains(session.name) else {
            session.stop()
            return
        }
        let ownsName = panels.contains { $0.serviceName == session.name }
        guard ownsName || provisional else {
            if !allowUnowned { session.stop() }
            return
        }
        sessions[session.name] = session
        session.setFPS(settings.fps)
        session.applyPacing(
            spacingMicros: settings.spacingMicros, adaptive: settings.adaptivePacing)
        session.applyTileQuality(settings.tileQuality)
        // No frames leave until EINF proves this service is the owned hardware.
        session.setPaused(true)
        if session.name == previewFocus {
            session.setPreviewEnabled(true)
        }
        if ownsName { refreshPreviewDriver() }
    }

    func retire(_ serviceName: String, sessionID: UUID? = nil) {
        if let sessionID, sessions[serviceName]?.id != sessionID { return }
        sessions[serviceName] = nil
        if previewFocus == serviceName { preview.clearFrame() }
        // No session left to preview from, so the stand-in takes over.
        defer { refreshPreviewDriver() }
        guard !supersededServiceNames.contains(serviceName) else { return }
        updatePanel(serviceName) { panel in
            panel.discovered = false
            panel.displayFPS = 0
            panel.captureStatus = .failed(
                "No session is running for this display, so nothing is being sent.")
            panel.lastError = "Gave up trying to reach this display. It is retried "
                + "automatically once it reappears on the network."
        }
    }


    func canForget(_ serviceName: String) -> Bool {
        panels.contains { $0.serviceName == serviceName }
    }

    func forget(_ serviceName: String) {
        guard let index = panels.firstIndex(where: { $0.serviceName == serviceName })
        else { return }
        let panel = panels[index]
        supersededServiceNames.insert(serviceName)
        sessions.removeValue(forKey: serviceName)?.stop()
        commandedBrightness[serviceName] = nil
        lastTouchSequence[serviceName] = nil
        if pickerTarget == serviceName { pickerTarget = nil }
        if regionTarget == serviceName {
            regionSelector.hide()
            regionTarget = nil
            sourceBeforeRegion = nil
        }
        if let hardwareID = stableHardwareID(of: panel) {
            _ = setRememberedOTAPassword(nil, for: hardwareID)
        }
        panels.remove(at: index)
        if selectedServiceName == serviceName {
            let next = panels.isEmpty ? nil : min(index, panels.count - 1)
            selectedServiceName = next.map { panels[$0].serviceName }
        }
        persistIfNeeded(force: true)
    }

    func flushPersistence() {
        persistIfNeeded(force: true)
    }



    /// Lift a session's provisional pause on its FIRST identity bind only.
    /// EINF repeats every 2 seconds and every arrival re-binds, so unpausing
    /// unconditionally here silently undid any user pause within seconds of
    /// it being set - the "panel keeps un-pausing itself" bug.
    private func liftProvisionalPause(_ serviceName: String) {
        guard let session = sessions[serviceName],
              identityBoundSessionIDs.insert(session.id).inserted
        else { return }
        session.setPaused(false)
    }

    /// Bind a paused discovery session to one owned hardware record. Returns
    /// whether the record's service name migrated, or nil when this service is
    /// not owned and the provisional session was stopped.
    func bindSessionIdentity(
        hardwareID: String, serviceName: String
    ) -> Bool? {
        let actualID = ConfigCommands.canonicalHardwareID(hardwareID) ?? hardwareID
        if let exact = panels.first(where: { $0.serviceName == serviceName }) {
            let expectedID = stableHardwareID(of: exact)
            if let expectedID, expectedID != actualID {
                rejectProvisionalSession(serviceName)
                return nil
            }
            unownedServiceNames.remove(serviceName)
            liftProvisionalPause(serviceName)
            return false
        }

        let reconciled = reconcilePanelIdentity(
            hardwareID: actualID, serviceName: serviceName)
        guard panels.contains(where: { $0.serviceName == serviceName }) else {
            rejectProvisionalSession(serviceName)
            return nil
        }
        unownedServiceNames.remove(serviceName)
        liftProvisionalPause(serviceName)
        refreshPreviewDriver()
        return reconciled
    }

    private func rejectProvisionalSession(_ serviceName: String) {
        unownedServiceNames.insert(serviceName)
        sessions.removeValue(forKey: serviceName)?.stop()
    }

    /// Migrate a persisted record when the same hardware reappears under a
    /// different Bonjour name. The service name remains the live routing key,
    /// while EINF's hardware ID preserves identity across USB renames.
    private func reconcilePanelIdentity(
        hardwareID: String, serviceName: String
    ) -> Bool {
        let targetID = ConfigCommands.canonicalHardwareID(hardwareID) ?? hardwareID
        guard let oldIndex = panels.firstIndex(where: {
            stableHardwareID(of: $0) == targetID && $0.serviceName != serviceName
        }) else { return false }

        let oldServiceName = panels[oldIndex].serviceName
        supersededServiceNames.remove(serviceName)
        supersededServiceNames.insert(oldServiceName)
        sessions[oldServiceName] = nil
        var migrated = panels.remove(at: oldIndex)
        migrated.serviceName = serviceName
        if let currentIndex = panels.firstIndex(where: { $0.serviceName == serviceName }) {
            let current = panels[currentIndex]
            migrated.discovered = current.discovered
            migrated.lastSeen = [migrated.lastSeen, current.lastSeen]
                .compactMap { $0 }
                .max()
            panels[currentIndex] = migrated
        } else {
            panels.append(migrated)
        }
        if selectedServiceName == oldServiceName {
            selectedServiceName = serviceName
        }
        sortPanels()
        return true
    }

}
