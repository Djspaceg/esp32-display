import AppKit
import Foundation
import Network
import ScreenCaptureKit
import SenderProtocol

/// Inputs reported by a panel - gestures, knob, and whatever BOOT or power
/// button presses the input map gave this Mac: duplicate suppression, the
/// per-panel preset and assignments, keeping the board's copy of the map
/// current, and the actions (pause, media keys, key presses, window and
/// source cycling) an input maps to.
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
        // A knob gesture is the board saying it has a knob, whatever discovery
        // has reported, so its page offers the knob's Accessibility way back.
        if touch.gesture.isKnob, !panel.knobReported {
            updatePanel(serviceName) { $0.knobReported = true }
        }

        // The orientation comes from the gesture itself rather than from this
        // panel's last known state, so a swipe is read against the frame that was
        // actually on screen when the finger moved - not the one that has since
        // replaced it.
        let action: TouchAction
        switch panel.function(for: touch.gesture, landscape: touch.landscape) {
        case .mac(let bound):
            action = bound
        case .nothing:
            // Logged, because an unbound gesture and a broken one look identical
            // from the outside: in both cases nothing happens.
            print("[\(serviceName)] touch \(touch.gesture) -> unbound in "
                + "\(panel.gesturePreset.rawValue)")
            return
        case .board(let function):
            // The board runs these itself; one reaching here means its copy of
            // the map is behind, which the next EINP corrects.
            print("[\(serviceName)] touch \(touch.gesture) -> \(function) is the "
                + "board's; its map is out of date")
            return
        }
        // Logged because a gesture is otherwise untraceable: if the mapping or
        // the packet is wrong, the only symptom is that nothing happens, which
        // is indistinguishable from the panel never having sent anything.
        print("[\(serviceName)] touch \(touch.gesture) -> \(action)")
        // Media keys need the Accessibility grant. It is asked for when a
        // gesture first needs it - the knob is a volume knob under every
        // preset - once per launch, so a turn does not stack prompts. macOS
        // never asks again once the prompt is declined, so a standing notice
        // says what is wrong and opens the settings pane; it replaces the
        // failure alert a refused key used to raise on every detent or swipe.
        if action.needsAccessibility {
            guard mediaKeysAuthorized() else {
                requestMediaKeyAuthorization()
                reportMissingMediaKeyGrant()
                return
            }
            mediaKeyGrantSeen()
        }
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
        case .mute:
            sendMediaKey(.mute, for: serviceName)
        case .track(let next):
            sendMediaKey(next ? .nextTrack : .previousTrack, for: serviceName)
        case .cycleWindow(let forward):
            Task { @MainActor [weak self] in
                await self?.cycleWindow(forward: forward, for: serviceName)
            }
        case .showFullDisplay:
            useAutomaticSource(for: serviceName)
        case .keyPress(let combo):
            if let failure = keyPressSender(combo) {
                let name = panel.displayName.isEmpty ? serviceName : panel.displayName
                operationOutcome = .failure("\(name) could not press \(combo.label)", failure)
            }
        }
    }

    /// Post a media key for a gesture, surfacing a refusal.
    ///
    /// Reported rather than dropped because the likely refusal is a missing
    /// Accessibility grant, and macOS does not error on a posted event it decides
    /// to discard - so the only symptom would be a panel that appears to have
    /// stopped noticing fingers.
    private func sendMediaKey(_ key: MediaControl.Key, for serviceName: String) {
        guard let failure = mediaKeySender(key) else { return }
        let name = panels.first { $0.serviceName == serviceName }?.displayName
            ?? serviceName
        operationOutcome = .failure(
            "\(name) could not control volume or playback", failure)
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

    /// Raise the Accessibility notice, unless the user dismissed it this
    /// launch, and ask for the window the first time it appears.
    private func reportMissingMediaKeyGrant() {
        guard !accessibilityNoticeDismissed else { return }
        let firstReport = !issues.contains { $0.issue == .accessibility }
        report(
            .accessibility,
            detail: MacPermission.accessibility.message(for: .needsAccess),
            permissionState: .needsAccess)
        if firstReport { onAttentionNeeded?() }
    }

    /// Withdraw the Accessibility notice once the grant is there, so coming
    /// back from System Settings clears it without another gesture.
    func refreshMediaKeyAuthorization() {
        accessibilityPermissionIsAllowed = mediaKeysAuthorized()
        if accessibilityPermissionIsAllowed { mediaKeyGrantSeen() }
    }

    /// The grant is there: withdraw the notice, and end any dismissal, so a
    /// grant taken away later in this launch is reported again rather than
    /// leaving every media key silently refused.
    private func mediaKeyGrantSeen() {
        accessibilityPermissionIsAllowed = true
        accessibilityNoticeDismissed = false
        resolve(.accessibility)
    }

    /// Choose which gesture bindings a panel uses.
    ///
    /// The Accessibility prompt is raised here rather than at the first gesture,
    /// so the permission is dealt with while the user is looking at the setting
    /// that needs it instead of discovering it later by swiping and getting
    /// nothing.
    ///
    /// A preset fills in every assignment at once: the user's own ones are
    /// cleared, so what the preset says is what every input does.
    func setGesturePreset(_ preset: GesturePreset, for serviceName: String) {
        guard panels.contains(where: { $0.serviceName == serviceName }) else { return }
        updatePanel(serviceName) { panel in
            panel.gesturePreset = preset
            panel.inputAssignments = [:]
        }
        persistIfNeeded(force: true)
        requestAuthorizationIfAssignmentsNeedIt(serviceName)
        syncInputMap(for: serviceName)
    }

    /// Give one input its own function. Choosing what the preset already
    /// gives it, in both orientations and on the board, removes the
    /// assignment instead, so a board set back by hand reads as its preset
    /// again. (Nothing on a gesture the preset leaves unbound is kept: the
    /// preset still has the board report it, Nothing has the board drop it.)
    func setInputFunction(
        _ function: InputFunction, for input: DeviceProtocol.TouchGesture,
        on serviceName: String
    ) {
        guard let panel = panels.first(where: { $0.serviceName == serviceName })
        else { return }
        var assigned = panel
        assigned.inputAssignments[input] = function
        var unassigned = panel
        unassigned.inputAssignments[input] = nil
        let matchesPreset = [false, true].allSatisfy {
            panel.presetFunction(for: input, landscape: $0) == function
        } && assigned.boardCodes[input] == unassigned.boardCodes[input]
        updatePanel(serviceName) { panel in
            panel.inputAssignments[input] = matchesPreset ? nil : function
        }
        persistIfNeeded(force: true)
        requestAuthorizationIfAssignmentsNeedIt(serviceName)
        syncInputMap(for: serviceName)
    }

    private func requestAuthorizationIfAssignmentsNeedIt(_ serviceName: String) {
        guard let panel = panels.first(where: { $0.serviceName == serviceName }),
              panel.assignmentsNeedAccessibility, !mediaKeysAuthorized()
        else { return }
        requestPermissionAccess(for: MacPermission.accessibility)
    }

    /// Send the board the map this app wants, if what it last reported is
    /// different or not yet in force for this app (a board another app set
    /// up runs its defaults for anyone else until they send their own).
    /// Called on every EINP (every two seconds) and on each change, so a map
    /// lost to a dropped datagram is put back within one report, and nothing
    /// is sent while the two agree.
    func syncInputMap(for serviceName: String) {
        guard let session = sessions[serviceName],
              let panel = panels.first(where: { $0.serviceName == serviceName }),
              panel.capabilities.contains(.inputMap), panel.boardMapIsNameable,
              !panel.boardMapIsCurrent
        else { return }
        session.sendInputMap(DeviceProtocol.inputMapPacket(
            panel.boardCodes, flags: panel.boardFlags))
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
                && !coveredDisplayNames.contains($0.name)
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
            session.usePickerFilter(await DisplayCapture.displayFilter(chosen.display))
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
