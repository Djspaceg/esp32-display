import AppKit
import Foundation
import Network
import ScreenCaptureKit
import SenderProtocol

/// Capture sources: the attached-display list, the region-capture
/// marquee, the live preview, and the macOS picker. What a panel
/// SHOWS, as opposed to how the device behaves (DeviceControls) or
/// which record owns it (Records).
extension PanelManager {
    // MARK: displays

    /// Re-read the attached displays.
    func refreshDisplays() {
        Task { @MainActor in
            // Displays shaped like the panel are skipped for the same reason the
            // swipe ring skips them: they are this app's own output, so pointing
            // a panel at one is a mirror of itself or a feedback loop.
            // A screen used as a device is skipped for the same reason: it
            // shows this app's output.
            let names = await DisplayCapture.capturableDisplays()
                .filter { !Self.isPanelShaped($0.display.width, $0.display.height) }
                .map(\.name)
                .filter { !coveredDisplayNames.contains($0) }
            if names != displayNames { displayNames = names }
        }
    }

    /// Displays to offer for a panel, including one it is set to but which is no
    /// longer attached - dropping it would silently retarget the panel just
    /// because a monitor was unplugged.
    func displayOptions(for serviceName: String) -> [String] {
        guard case .display(let current) = panels.first(
            where: { $0.serviceName == serviceName })?.source,
            !current.isEmpty, !displayNames.contains(current)
        else { return displayNames }
        return displayNames + [current]
    }

    /// Point a panel at a named display.
    func selectDisplay(_ name: String, for serviceName: String) {
        guard !name.isEmpty else { return }
        guard !refusesCoveredScreen(name) else { return }
        let source = PanelSource.display(name)
        updatePanel(serviceName) { panel in
            panel.source = source
            panel.sourceDescription = source.label
        }
        // A live session is handed a filter directly; one that starts later reads
        // the stored source instead.
        if let session = sessions[serviceName] {
            Task { @MainActor in
                guard let chosen = await DisplayCapture.capturableDisplays()
                    .first(where: { $0.name == name })
                else { return }
                session.usePickerFilter(await DisplayCapture.displayFilter(chosen.display))
            }
        }
        refreshPreviewDriver()
        persistIfNeeded(force: true)
    }

    // MARK: capture region

    /// Whether the marquee is on screen, so the button can read "Done".
    var isChoosingRegion: Bool { regionSelector.isVisible }

    /// Put the marquee on screen for this panel and make its region the live
    /// source straight away.
    ///
    /// Applied immediately rather than on a confirm step, because the panel and
    /// the in-window preview are the feedback: you drag the rectangle and watch
    /// what arrives, which is only useful if it is already streaming.
    func chooseRegion(for serviceName: String) {
        selectedServiceName = serviceName
        // One marquee at a time: a screen device's closes for a board's.
        if screenDevices.choosingRegionFor != nil { screenDevices.finishChoosingRegion() }
        regionSelector.excludedDisplays = coveredDisplayNames

        let panel = panels.first { $0.serviceName == serviceName }
        guard let geometry = panel?.geometry else {
            operationOutcome = .failure(
                "Screen size unknown",
                "Connect this device over USB or wait for its network advertisement "
                    + "to report a usable resolution before choosing a region.")
            return
        }
        regionTarget = serviceName
        // Remembered whole, not just the rectangle: Escape has to be able to put
        // back a source that was not a region at all.
        sourceBeforeRegion = panel?.source
        // On rectangular glass the rotation decides the shape: landscape at 90
        // and 270, portrait at 0 and 180, matching the frames capture streams
        // (`DisplayCapture.streamsLandscape`). A region of the other shape
        // would only be letterboxed, so it is turned to match.
        let rectangular = geometry.width != geometry.height
        let startLandscape = rectangular && (panel?.rotation ?? 0) % 2 != 0
        let existing = panel?.source.region
        let reusable = existing.flatMap { region -> RegionSpec? in
            guard region.matchesAspect(of: geometry) else { return nil }
            guard rectangular,
                  region.streamsLandscape(on: geometry) != startLandscape,
                  let screen = DisplayCapture.screen(named: region.display)
            else { return region }
            return region.rotated(in: screen.frame.size)
        }
        guard let region = reusable
            ?? Self.startingRegion(
                geometry: geometry, landscape: startLandscape) else {
            operationOutcome = .failure(
                "No display available",
                "macOS reported no screen to draw a region on.")
            return
        }
        apply(region, to: serviceName)
        regionSelector.activeScale = region.matchingScale(geometry: geometry)
        regionSelector.allowsRotate = !rectangular
        regionSelector.show(region)
    }

    /// Take the marquee away. The region stays in force as the panel's source.
    func finishChoosingRegion() {
        regionSelector.hide()
        regionTarget = nil
        sourceBeforeRegion = nil
        persistIfNeeded(force: true)
    }

    /// Abandon the rectangle and put back whatever the panel was showing before.
    func cancelChoosingRegion() {
        defer { finishChoosingRegion() }
        guard let target = regionTarget, let previous = sourceBeforeRegion,
            previous != panels.first(where: { $0.serviceName == target })?.source
        else { return }

        switch previous {
        case .region(let region):
            apply(region, to: target)
        case .automatic:
            useAutomaticSource(for: target)
        case .display(let name):
            selectDisplay(name, for: target)
        case .window:
            // The window itself cannot be re-resolved without a picker
            // selection, but the stored intent is what a session reads, so
            // restoring it is enough.
            updatePanel(target) { panel in
                panel.source = previous
                panel.sourceDescription = previous.label
            }
            sessions[target]?.clearRegion()
            refreshPreviewDriver()
        }
    }

    /// Resize the region to a preset multiple of the panel, keeping its centre.
    func setRegionScale(_ scale: Int, for serviceName: String) {
        guard let geometry = geometry(of: serviceName) else { return }
        transformRegion(for: serviceName) { region, _, size in
            return region.scaled(to: scale, geometry: geometry, in: size)
        }
    }

    /// Turn the region on its side, for a panel mounted the other way up.
    func rotateRegion(for serviceName: String) {
        transformRegion(for: serviceName) { region, _, size in
            // Rotation swaps the rectangle's own sides, so it needs no geometry:
            // whatever shape the region is, on its side is on its side.
            region.rotated(in: size)
        }
    }

    /// The panel's advertised geometry, or nil if it has not said.
    ///
    /// Reads the snapshot rather than the session, so it answers for a panel that
    /// is being framed while offline - which is the case region mode exists to
    /// support, since the preview works with the panel switched off.
    func geometry(of serviceName: String) -> PanelGeometry? {
        panels.first { $0.serviceName == serviceName }?.geometry
    }

    /// Whether the device's board has no screen, as far as this app has heard.
    func hasNoScreen(_ serviceName: String) -> Bool {
        panels.first { $0.serviceName == serviceName }?.hasNoScreen ?? false
    }

    private func transformRegion(
        for serviceName: String,
        _ transform: (RegionSpec, PanelGeometry?, CGSize) -> RegionSpec
    ) {
        guard let region = panels.first(
            where: { $0.serviceName == serviceName })?.source.region,
            let screen = DisplayCapture.screen(named: region.display)
        else { return }
        let updated = transform(
            region, geometry(of: serviceName), screen.frame.size)
        apply(updated, to: serviceName)
        // Only nudge the marquee if it is the thing being looked at; moving a
        // hidden window would be wasted work.
        if regionSelector.isVisible, regionTarget == serviceName {
            regionSelector.activeScale = geometry(of: serviceName).flatMap {
                updated.matchingScale(geometry: $0)
            }
            regionSelector.apply(updated)
        }
    }

    /// Record a region and push it to the session.
    func apply(_ region: RegionSpec, to serviceName: String) {
        let source = PanelSource.region(region)
        updatePanel(serviceName) { panel in
            panel.source = source
            panel.sourceDescription = source.label
        }
        sessions[serviceName]?.useRegion(region)
        // With no session, this is what makes the marquee visible in the preview
        // as it is dragged. PreviewDriver reconfigures rather than restarts for a
        // region change, so a drag stays smooth.
        refreshPreviewDriver()
        // Not forced: a drag produces these continuously, and the throttle keeps
        // it from writing the records file on every frame of the drag. The final
        // position is flushed by finishChoosingRegion.
        persistIfNeeded()
    }

    /// A sensible first rectangle: 2x the panel, centred on the focused screen.
    /// 2x rather than 1x so it is big enough to see and grab.
    private static func startingRegion(
        geometry: PanelGeometry, landscape: Bool
    ) -> RegionSpec? {
        guard let screen = DisplayCapture.preferredScreen() else { return nil }
        return RegionSpec.centered(
            on: screen.name, geometry: geometry, scale: 2,
            landscape: landscape, in: screen.size)
    }

    // MARK: live preview

    /// Whether the manager window is on screen. Converting frames for a window
    /// nobody can see would be pure waste, so the preview is switched off with
    /// the window rather than left running for the life of the process.
    func setPreviewVisible(_ visible: Bool) {
        guard previewVisible != visible else { return }
        previewVisible = visible
        updatePreviewFocus()
    }

    /// Route preview frames from the selected panel's session only, and tell
    /// every other session to stop producing them.
    func updatePreviewFocus() {
        let target = previewVisible ? selectedServiceName : nil
        guard target != previewFocus else {
            refreshPreviewDriver()
            return
        }
        if let previous = previewFocus {
            sessions[previous]?.setPreviewEnabled(false)
        }
        previewFocus = target
        preview.focus(on: target)
        cameraPreview.focus(on: target)
        if let target {
            sessions[target]?.setPreviewEnabled(true)
        }
        refreshPreviewDriver()
    }

    /// Start, stop, or re-aim the session-less preview.
    ///
    /// It runs only when the window is up, a panel is selected, and that panel
    /// has no session - a session produces its own previews from the frames it is
    /// really sending, which is always the better picture.
    func refreshPreviewDriver() {
        guard previewVisible,
            let name = selectedServiceName,
            sessions[name] == nil,
            let panel = panels.first(where: { $0.serviceName == name }),
            // Nothing to preview for a device with no screen.
            !panel.hasNoScreen
        else {
            previewDriver.stop()
            return
        }
        // Capped well below the streaming rate: nothing is being sent, so this
        // only has to look alive.
        previewDriver.run(
            serviceName: name,
            source: panel.source,
            defaultDisplay: defaultDisplayName,
            geometry: Self.previewGeometry(for: panel),
            landscape: Self.previewLandscape(for: panel),
            fps: min(settings.fps, 15))

        // Say what the picture is. Without this the hero shows a live image
        // directly above "nothing is being sent", which reads as a contradiction
        // rather than as a viewfinder. Corrected by `onUnavailable` if the source
        // turns out not to be capturable.
        updatePanel(name) { panel in
            panel.captureStatus = .suspended(
                "Previewing on this Mac. The device is offline, so nothing "
                    + "is being sent to it yet.")
        }
    }

    /// The frame shape the offline viewfinder uses for a panel: the one
    /// streaming would send. Before the panel has reported its size, a region
    /// already has the shape the rotation gave it (`applyRegionQuarterTurn`
    /// turns it either way), and any other source takes the preview capture's
    /// own geometry, which is rectangular until the size is known.
    nonisolated static func previewLandscape(for panel: PanelSnapshot) -> Bool {
        if let geometry = panel.geometry {
            return DisplayCapture.streamsLandscape(
                geometry: geometry, rotation: panel.rotation)
        }
        if let region = panel.source.region { return region.isLandscape }
        return DisplayCapture.streamsLandscape(
            geometry: previewGeometry(for: panel), rotation: panel.rotation)
    }

    /// The frame size the offline viewfinder captures at: the panel's own once
    /// it is known, so a square panel is not previewed through a 172x320 frame.
    nonisolated static func previewGeometry(for panel: PanelSnapshot) -> PanelGeometry {
        panel.geometry ?? .panel172x320
    }

    /// Accept a frame from a session. Frames from a panel that is no longer
    /// selected are dropped by `FramePreview` itself, since a callback already
    /// in flight can outlive a selection change.
    func acceptPreview(
        image: CGImage, landscape: Bool, from serviceName: String,
        sessionID: UUID? = nil
    ) {
        if let sessionID, sessions[serviceName]?.id != sessionID { return }
        preview.accept(image: image, landscape: landscape, from: serviceName)
    }

    func acceptCamera(
        jpeg: Data, resolution: CameraProtocol.Resolution, from serviceName: String,
        sessionID: UUID? = nil
    ) {
        if let sessionID, sessions[serviceName]?.id != sessionID { return }
        CameraExtensionBridge.shared.forward(jpeg: jpeg, resolution: resolution)
        cameraPreview.accept(jpeg: jpeg, resolution: resolution, from: serviceName)
    }

    func setCameraStreaming(
        _ enabled: Bool, resolution: CameraProtocol.Resolution, for serviceName: String
    ) {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }),
              panel.capabilities.contains(.camera),
              let session = sessions[serviceName]
        else {
            operationOutcome = .failure(
                "Camera unavailable",
                "This device has not reported a working camera connection yet.")
            return
        }
        let password: String?
        if enabled {
            guard let hardwareID = stableHardwareID(of: panel),
                  let saved = rememberedOTAPassword(for: hardwareID)
            else {
                operationOutcome = .failure(
                    "Camera authorization unavailable",
                    "Set and save an OTA password for this device before starting its camera.")
                return
            }
            password = saved
        } else {
            password = nil
        }
        session.setCameraStreaming(enabled, resolution: resolution, password: password)
        updatePanel(serviceName) {
            $0.cameraStreaming = enabled
            $0.cameraResolution = resolution
        }
        if !enabled { cameraPreview.clear() }
    }

    func attachPicker(_ picker: PickerSource) {
        self.picker = picker
        picker.onSelection = { [weak self] filter in
            Task { @MainActor in
                self?.applyPickerSelection(filter)
            }
        }
        picker.onCancellation = { [weak self] in
            Task { @MainActor in
                self?.pickerTarget = nil
            }
        }
    }


    /// Open the system content picker for a panel.
    ///
    /// `style` opens the picker directly in display, window, or application
    /// mode, so the user lands where they meant to go instead of hunting for
    /// the right tab.
    /// Switch a panel to a kind of source, opening whatever chooser that kind
    /// needs.
    ///
    /// Backing out of a chooser leaves the stored source untouched, which is what
    /// lets the dropdown show a resting value: it reads the source back, so an
    /// abandoned choice simply never appears.
    func selectSourceKind(_ kind: PanelSourceKind, for serviceName: String) {
        switch kind {
        case .automatic:
            useAutomaticSource(for: serviceName)
        case .display:
            // Resolved here rather than by opening the macOS picker: displays are
            // a short, knowable list, so the window offers them directly and the
            // second dropdown switches between them.
            refreshDisplays()
            let preferred = DisplayCapture.preferredScreen()?.name
            let chosen = [preferred, displayNames.first]
                .compactMap { $0 }
                .first { !$0.isEmpty }
            guard let chosen else {
                operationOutcome = .failure(
                    "No display available",
                    "macOS reported no capturable display to send.")
                return
            }
            selectDisplay(chosen, for: serviceName)
        case .window:
            chooseSource(for: serviceName, style: .window)
        case .region:
            chooseRegion(for: serviceName)
        }
    }

    /// Deliberately not gated on a live session. What a panel should show is a
    /// decision about this Mac's screen, and it is recorded and previewed here
    /// whether or not the panel is switched on; a session applies it when one
    /// turns up. Requiring a session meant the choice could only be made with
    /// the hardware already running.
    func chooseSource(
        for serviceName: String, style: SCShareableContentStyle? = nil
    ) {
        guard let picker else { return }
        pickerTarget = serviceName
        selectedServiceName = serviceName
        picker.present(style: style)
    }

    func setPaused(_ paused: Bool, for serviceName: String) {
        guard requireOperation(.streaming, for: serviceName, title: "Streaming")
        else { return }
        applyPaused(paused, for: serviceName)
    }

    /// A touch event already arrived through the device session. Keep its local
    /// toggle path separate from a UI/script request that still needs a live
    /// availability check at dispatch time.
    func setPausedFromDevice(_ paused: Bool, for serviceName: String) {
        applyPaused(paused, for: serviceName)
    }

    private func applyPaused(_ paused: Bool, for serviceName: String) {
        // During the identity hold the sender stays paused whatever the user
        // chooses; the choice is recorded and applied when the hold lifts.
        if !sessionAwaitsIdentity(serviceName) {
            sessions[serviceName]?.setPaused(paused)
        }
        updatePanel(serviceName) { $0.paused = paused }
    }


    private func applyPickerSelection(_ filter: SCContentFilter) {
        let target = pickerTarget ?? selectedServiceName ?? panels.first?.serviceName
        pickerTarget = nil
        guard let target else { return }
        if case .display(let name)? = PanelSource.from(filter),
            refusesCoveredScreen(name)
        { return }
        // Applied to a session only if there is one. A pick made while the panel
        // is switched off used to be thrown away here; now it is recorded and
        // previewed, and a session picks it up from the stored source when the
        // panel comes back.
        sessions[target]?.usePickerFilter(filter)
        // Record what was picked, not just how it reads: the filter itself
        // cannot be stored, but the display or application it names can be
        // resolved again on the next launch.
        //
        // A pick that cannot be identified leaves the saved choice alone. It
        // still applies to the running session via the filter; what it must not
        // do is replace a good stored choice with "Automatic", which is how a
        // deliberate selection used to appear to revert on its own.
        let identified = PanelSource.from(filter)
        updatePanel(target) { panel in
            if let identified { panel.source = identified }
            panel.sourceDescription = picker?.describe(filter) ?? "Selected content"
        }
        refreshPreviewDriver()
        persistIfNeeded(force: true)
    }

    /// Return this panel to automatic display tracking.
    func useAutomaticSource(for serviceName: String) {
        updatePanel(serviceName) { panel in
            panel.source = .automatic
            panel.sourceDescription = "Automatic"
        }
        picker?.clearSelection()
        sessions[serviceName]?.clearRegion()
        refreshPreviewDriver()
        persistIfNeeded(force: true)
    }

    /// The stored source for every panel, keyed by service name. Read once at
    /// startup to decide what each session should capture.
    func persistedSources() -> [String: PanelSource] {
        Dictionary(
            panels.map { ($0.serviceName, $0.source) },
            uniquingKeysWith: { first, _ in first })
    }

}
