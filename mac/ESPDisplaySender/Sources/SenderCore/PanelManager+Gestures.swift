import AppKit
import Foundation
import Network
import ScreenCaptureKit
import SenderProtocol

/// Touch gestures reported by a panel: duplicate suppression, the
/// per-panel preset, and the actions (pause, media keys, window and
/// source cycling) a gesture maps to.
extension PanelManager {
    /// Act on a gesture the panel reported.
    ///
    /// Duplicates are dropped first. UDP can deliver the same datagram twice, and
    /// every action here is a toggle or a step, so a duplicate would either undo
    /// itself (pause, then resume — indistinguishable from the tap being ignored)
    /// or move two places at once. Under the multimedia preset a duplicate would
    /// also double a volume step or skip two tracks.
    ///
    /// Which action a gesture means depends on the panel's chosen preset, so this
    /// reads the panel first and asks `TouchAction` rather than mapping directly.
    func handleTouch(
        _ touch: DeviceProtocol.TouchEvent, for serviceName: String
    ) {
        guard lastTouchSequence[serviceName] != touch.sequence else { return }
        lastTouchSequence[serviceName] = touch.sequence

        guard let panel = panels.first(where: { $0.serviceName == serviceName })
        else { return }

        // The orientation comes from the gesture itself rather than from this
        // panel's last known state, so a swipe is read against the frame that was
        // actually on screen when the finger moved - not the one that has since
        // replaced it.
        guard let action = TouchAction.action(
            for: touch.gesture, preset: panel.gesturePreset,
            landscape: touch.landscape)
        else {
            // Logged, because an unbound gesture and a broken one look identical
            // from the outside: in both cases nothing happens.
            print("[\(serviceName)] touch \(touch.gesture) -> unbound in "
                + "\(panel.gesturePreset.rawValue)")
            return
        }
        // Logged because a gesture is otherwise untraceable: if the mapping or
        // the packet is wrong, the only symptom is that nothing happens, which
        // is indistinguishable from the panel never having sent anything.
        print("[\(serviceName)] touch \(touch.gesture) -> \(action)")
        switch action {
        case .togglePause:
            setPausedFromDevice(!panel.paused, for: serviceName)
        case .cycleSource(let forward):
            Task { @MainActor [weak self] in
                await self?.cycleSource(forward: forward, for: serviceName)
            }
        case .mediaPlayPause:
            sendMediaKey(.playPause, for: serviceName)
        case .volume(let up):
            sendMediaKey(up ? .volumeUp : .volumeDown, for: serviceName)
        case .track(let next):
            sendMediaKey(next ? .nextTrack : .previousTrack, for: serviceName)
        case .cycleWindow(let forward):
            Task { @MainActor [weak self] in
                await self?.cycleWindow(forward: forward, for: serviceName)
            }
        case .showFullDisplay:
            useAutomaticSource(for: serviceName)
        }
    }

    /// Post a media key for a gesture, surfacing a refusal.
    ///
    /// Reported rather than dropped because the likely refusal is a missing
    /// Accessibility grant, and macOS does not error on a posted event it decides
    /// to discard - so the only symptom would be a panel that appears to have
    /// stopped noticing fingers.
    private func sendMediaKey(_ key: MediaControl.Key, for serviceName: String) {
        guard let failure = MediaControl.send(key) else { return }
        let name = panels.first { $0.serviceName == serviceName }?.displayName
            ?? serviceName
        operationOutcome = .failure("\(name) could not control playback", failure)
    }

    /// Step this panel through the windows currently on screen.
    ///
    /// The cursor is a window ID held in memory, not read back from the stored
    /// source. The stored form is `.window(applicationName)`, which cannot tell
    /// two windows of the same app apart, so cycling live is precise while a
    /// restart resolves to that app's largest window. Persisting the ID instead
    /// would be worse: window IDs are reissued, so a stored one points at
    /// whatever inherited the number.
    private func cycleWindow(forward: Bool, for serviceName: String) async {
        guard let session = sessions[serviceName] else { return }
        let windows = await DisplayCapture.cyclableWindows()
        guard !windows.isEmpty else {
            operationOutcome = .failure(
                "No windows to show",
                "No on-screen window is large enough to mirror.")
            return
        }

        let current = lastCycledWindow[serviceName].flatMap { id in
            windows.firstIndex { $0.window.windowID == id }
        }
        let step = forward ? 1 : -1
        // Without a cursor this is the first cycle since launch, or the window
        // being followed has closed. Entering at the near end in the direction of
        // travel means the first swipe moves one step rather than jumping to an
        // arbitrary point in the list.
        let index = current.map { ($0 + step + windows.count) % windows.count }
            ?? (forward ? 0 : windows.count - 1)
        let chosen = windows[index]
        lastCycledWindow[serviceName] = chosen.window.windowID

        session.usePickerFilter(
            SCContentFilter(desktopIndependentWindow: chosen.window))
        let app = chosen.window.owningApplication?.applicationName ?? chosen.label
        updatePanel(serviceName) { panel in
            panel.source = .window(app)
            panel.sourceDescription = chosen.label
        }
        refreshPreviewDriver()
        persistIfNeeded(force: true)
    }

    /// Choose which gesture bindings a panel uses.
    ///
    /// The Accessibility prompt is raised here rather than at the first gesture,
    /// so the permission is dealt with while the user is looking at the setting
    /// that needs it instead of discovering it later by swiping and getting
    /// nothing.
    func setGesturePreset(_ preset: GesturePreset, for serviceName: String) {
        guard panels.contains(where: { $0.serviceName == serviceName }) else { return }
        updatePanel(serviceName) { $0.gesturePreset = preset }
        persistIfNeeded(force: true)
        if preset == .multimedia, !MediaControl.isAuthorized {
            MediaControl.requestAuthorization()
        }
    }

    /// Advance this panel to the next display in the source ring.
    ///
    /// Mirrors what a picker selection does — the running session gets a filter,
    /// the snapshot records the intent, and the choice is persisted — because a
    /// source chosen by swiping should survive a restart exactly as one chosen
    /// through system UI does.
    private func cycleSource(forward: Bool, for serviceName: String) async {
        guard let session = sessions[serviceName],
              let panel = panels.first(where: { $0.serviceName == serviceName })
        else { return }

        // Skip anything shaped like the panel itself. Those are this app's own
        // virtual displays, and pointing a panel at one is either a mirror of
        // what it already shows or a feedback loop.
        let candidates = await DisplayCapture.capturableDisplays().filter {
            !Self.isPanelShaped($0.display.width, $0.display.height)
        }
        let ring = PanelSource.ring(displayNames: candidates.map(\.name))
        guard let next = PanelSource.next(
            after: panel.source, in: ring, forward: forward),
            next != panel.source
        else { return }

        switch next {
        case .automatic:
            useAutomaticSource(for: serviceName)
        case .display(let name):
            guard let chosen = candidates.first(where: { $0.name == name })
            else { return }
            session.usePickerFilter(
                SCContentFilter(display: chosen.display, excludingWindows: []))
            updatePanel(serviceName) { panel in
                panel.source = next
                panel.sourceDescription = next.label
            }
            persistIfNeeded(force: true)
        case .window, .region:
            // Neither is in the ring, so both are unreachable here: a window
            // needs a picker selection to resolve, and a region has to be drawn.
            return
        }
    }

}
