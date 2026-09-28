import ScreenCaptureKit
import XCTest

@testable import SenderCore

/// A panel showed a days-old picture while the app called it Online: the
/// capture stream had stopped delivering frames and nothing restarted it. These
/// drive the stall monitor with a fake stream that goes silent, on a fake clock.
final class CaptureStallTests: XCTestCase {

    /// Stands in for a ScreenCaptureKit stream. `emitStatusSamples` models a
    /// stream that keeps sending idle or blank status samples with no pixels,
    /// which the old watchdog read as alive.
    private final class FakeStream: CaptureFrameSource {
        var framesCaptured: UInt64 = 0
        var lastSampleAt: Date
        init(at now: Date) { lastSampleAt = now }

        func deliverFrame(at now: Date) { deliver(.complete, at: now) }

        /// A sample with this frame status, counted as a frame only if the
        /// real capture filter would forward it.
        func deliver(_ status: SCFrameStatus, at now: Date) {
            lastSampleAt = now
            if DisplayCapture.carriesNewFrame(status) { framesCaptured += 1 }
        }
        func deliverStatusSample(at now: Date) { lastSampleAt = now }
    }

    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// The watchdog's tick.
    private let tick: TimeInterval = 2
    /// The longest a live panel may go without a new frame before capture is
    /// restarted. The report was a stale picture for days, so the point is
    /// that there is a bound at all and that it is about a minute.
    private let restartBound: TimeInterval = 65

    /// Run the watchdog from `from` until the monitor asks for a restart or
    /// `limit` passes, returning when it asked.
    private func runUntilRestart(
        _ monitor: inout CaptureStallMonitor, _ stream: FakeStream,
        from: Date, limit: TimeInterval, statusSamples: Bool,
        verdict: inout CaptureStallMonitor.Verdict?
    ) -> Date? {
        var now = from
        while now.timeIntervalSince(from) <= limit {
            now += tick
            if statusSamples { stream.deliverStatusSample(at: now) }
            let v = monitor.check(stream, at: now)
            if case .restart = v {
                verdict = v
                return now
            }
        }
        return nil
    }

    // MARK: the reported shape

    /// A stream that goes silent while still emitting status-only samples is
    /// restarted within the bound, and when the restarted stream is silent too
    /// the monitor says capture is failing; the first real frame clears it.
    func testSilentStreamIsRestartedThenReportedThenCleared() {
        var monitor = CaptureStallMonitor(now: start)
        let first = FakeStream(at: start)
        monitor.streamStarted(at: start)
        first.deliverFrame(at: start + 1)
        XCTAssertEqual(monitor.check(first, at: start + 2), .healthy)
        let lastFrame = start + 2

        // Silent from here on, apart from status samples.
        var verdict: CaptureStallMonitor.Verdict?
        let restartAt = runUntilRestart(
            &monitor, first, from: lastFrame, limit: 600, statusSamples: true,
            verdict: &verdict)
        XCTAssertNotNil(restartAt, "a stream sending only status samples was never restarted")
        if let restartAt {
            XCTAssertLessThanOrEqual(
                restartAt.timeIntervalSince(lastFrame), restartBound,
                "restart came too late")
        }
        XCTAssertEqual(verdict, .restart(failing: false),
                       "the first restart is routine and must not raise an error yet")
        XCTAssertFalse(monitor.isFailing)

        // The restarted stream delivers nothing at all.
        let restartedAt = (restartAt ?? lastFrame) + 1
        let second = FakeStream(at: restartedAt)
        monitor.streamStarted(at: restartedAt)
        verdict = nil
        let failAt = runUntilRestart(
            &monitor, second, from: restartedAt, limit: 60, statusSamples: false,
            verdict: &verdict)
        XCTAssertNotNil(failAt, "a restart that produced no frame was never retried")
        XCTAssertEqual(verdict, .restart(failing: true),
                       "a restart that brings nothing back must be reported")
        XCTAssertTrue(monitor.isFailing)

        // Still failing across the next restart: starting a stream is not proof.
        let third = FakeStream(at: (failAt ?? restartedAt) + 1)
        monitor.streamStarted(at: (failAt ?? restartedAt) + 1)
        XCTAssertTrue(monitor.isFailing, "a stream starting must not clear the failure")

        // A frame arrives: recovered, and the failure is cleared.
        let recoveredAt = (failAt ?? restartedAt) + 3
        third.deliverFrame(at: recoveredAt)
        XCTAssertEqual(monitor.check(third, at: recoveredAt + 1), .recovered)
        XCTAssertFalse(monitor.isFailing)
        XCTAssertEqual(monitor.check(third, at: recoveredAt + 3), .healthy)
    }

    /// Total silence, no samples of any kind, is restarted within the same bound.
    func testTotallySilentStreamIsRestartedWithinTheBound() {
        var monitor = CaptureStallMonitor(now: start)
        let stream = FakeStream(at: start)
        monitor.streamStarted(at: start)
        stream.deliverFrame(at: start + 1)
        _ = monitor.check(stream, at: start + 2)

        var verdict: CaptureStallMonitor.Verdict?
        let restartAt = runUntilRestart(
            &monitor, stream, from: start + 2, limit: 600, statusSamples: false,
            verdict: &verdict)
        XCTAssertNotNil(restartAt)
        if let restartAt {
            XCTAssertLessThanOrEqual(restartAt.timeIntervalSince(start + 2), restartBound)
        }
    }

    /// A source that stays broken is retried with a growing gap, capped, so it
    /// is neither abandoned nor restarted in a tight loop.
    func testFailedRestartsBackOffToTheCeiling() {
        var monitor = CaptureStallMonitor(now: start)
        let first = FakeStream(at: start)
        monitor.streamStarted(at: start)
        var now = start + CaptureStallMonitor.stallAfter
        XCTAssertEqual(monitor.check(first, at: now), .restart(failing: false))

        var gaps: [TimeInterval] = []
        for _ in 0..<7 {
            let stream = FakeStream(at: now)
            monitor.streamStarted(at: now)
            let startedAt = now
            var verdict: CaptureStallMonitor.Verdict?
            guard let at = runUntilRestart(
                &monitor, stream, from: now, limit: 600, statusSamples: false,
                verdict: &verdict)
            else { return XCTFail("a failing source stopped being retried") }
            XCTAssertEqual(verdict, .restart(failing: true))
            gaps.append(at.timeIntervalSince(startedAt))
            now = at
        }
        XCTAssertEqual(gaps, [10, 20, 40, 80, 120, 120, 120])
    }

    // MARK: no false alarms

    /// An unchanging screen also delivers nothing, so it is probed. A fresh
    /// stream on a static screen sends exactly one picture, flagged `.started`,
    /// and then only `.idle` samples. The fake routes those through the real
    /// capture filter, so if `.started` were not counted as a frame the probe
    /// would look dead and this test would see a false failure.
    ///
    /// Each probe that proves the screen static also doubles the wait before
    /// the next, to a ceiling, so a still region is not rebuilt every minute.
    func testStaticScreenProbeRestartRaisesNoFailure() {
        var monitor = CaptureStallMonitor(now: start)
        var stream = FakeStream(at: start)
        monitor.streamStarted(at: start)
        stream.deliver(.started, at: start + 0.1)
        var streamStartedAt = start
        var now = start
        var gaps: [TimeInterval] = []
        while gaps.count < 5, now.timeIntervalSince(start) < 3_600 {
            now += tick
            stream.deliver(.idle, at: now)
            let verdict = monitor.check(stream, at: now)
            XCTAssertFalse(monitor.isFailing, "a static screen raised a capture failure")
            guard case .restart(let failing) = verdict else {
                XCTAssertEqual(verdict, .healthy)
                continue
            }
            XCTAssertFalse(failing, "a static screen was reported as failing")
            gaps.append(now.timeIntervalSince(streamStartedAt))
            // The probe: a new stream, whose first sample is its picture.
            stream = FakeStream(at: now)
            monitor.streamStarted(at: now)
            streamStartedAt = now
            stream.deliver(.started, at: now + 0.1)
        }
        XCTAssertEqual(gaps, [62, 122, 242, 302, 302])

        // Ordinary activity resets the wait to the base allowance.
        stream.deliverFrame(at: now + 1)
        _ = monitor.check(stream, at: now + tick)
        stream.deliverFrame(at: now + 3)
        _ = monitor.check(stream, at: now + 2 * tick)
        XCTAssertEqual(monitor.currentStallAfter, CaptureStallMonitor.stallAfter)
    }

    /// The capture filter itself: new pictures are forwarded, status-only
    /// samples are not.
    func testFrameFilterForwardsOnlyNewPictures() {
        XCTAssertTrue(DisplayCapture.carriesNewFrame(.complete))
        XCTAssertTrue(DisplayCapture.carriesNewFrame(.started))
        for status in [SCFrameStatus.idle, .blank, .suspended, .stopped] {
            XCTAssertFalse(DisplayCapture.carriesNewFrame(status), "\(status.rawValue)")
        }
    }

    /// A failure must not sit on screen while nothing is being retried, and
    /// must come back if the stream is still broken once live again.
    func testHoldClearsAFailureAndItReturnsAfterWake() {
        var monitor = CaptureStallMonitor(now: start)
        let stalled = FakeStream(at: start)
        monitor.streamStarted(at: start)
        XCTAssertEqual(monitor.check(stalled, at: start + 60), .restart(failing: false))
        let probe = FakeStream(at: start + 60)
        monitor.streamStarted(at: start + 60)
        XCTAssertEqual(monitor.check(probe, at: start + 70), .restart(failing: true))
        XCTAssertTrue(monitor.isFailing)

        let dead = FakeStream(at: start + 70)
        monitor.streamStarted(at: start + 70)
        XCTAssertEqual(monitor.check(dead, at: start + 72, live: false), .recovered,
                       "the failure stayed up while the display slept")
        XCTAssertFalse(monitor.isFailing)
        XCTAssertEqual(monitor.check(dead, at: start + 5_000, live: false), .healthy)

        // Awake and still dead: reported again after the first-frame grace.
        XCTAssertEqual(monitor.check(dead, at: start + 5_005), .healthy)
        XCTAssertEqual(monitor.check(dead, at: start + 5_011), .restart(failing: true))
        XCTAssertTrue(monitor.isFailing)
    }

    // MARK: session wiring

    func testSilenceCountsOnlyWhileTheSessionIsLive() {
        XCTAssertTrue(DeviceSession.isCaptureLive(
            paused: false, displayAsleep: false, sessionInactive: false, windowOnScreen: true))
        XCTAssertFalse(DeviceSession.isCaptureLive(
            paused: true, displayAsleep: false, sessionInactive: false, windowOnScreen: true))
        XCTAssertFalse(DeviceSession.isCaptureLive(
            paused: false, displayAsleep: true, sessionInactive: false, windowOnScreen: true))
        XCTAssertFalse(DeviceSession.isCaptureLive(
            paused: false, displayAsleep: false, sessionInactive: true, windowOnScreen: true))
        XCTAssertFalse(DeviceSession.isCaptureLive(
            paused: false, displayAsleep: false, sessionInactive: false, windowOnScreen: false))
    }

    /// A picker selection of a whole application whose windows are all
    /// minimised or hidden delivers no frames, legitimately. That must hold
    /// the monitor like a slept display, not raise a failure every retry.
    func testApplicationWithNoOnScreenWindowRaisesNoFailure() {
        let appPIDs: [pid_t] = [4242]
        XCTAssertTrue(DeviceSession.applicationContentVisible(
            includedApplicationPIDs: [], onScreenWindowOwnerPIDs: []),
            "a selection that is not an application filter was held")
        XCTAssertTrue(DeviceSession.applicationContentVisible(
            includedApplicationPIDs: appPIDs, onScreenWindowOwnerPIDs: [7, 4242]))

        var monitor = CaptureStallMonitor(now: start)
        let stream = FakeStream(at: start)
        monitor.streamStarted(at: start)
        var now = start
        var restarts = 0
        while now.timeIntervalSince(start) < 1_800 {
            now += tick
            // The application is running but has no window on screen.
            let visible = DeviceSession.applicationContentVisible(
                includedApplicationPIDs: appPIDs, onScreenWindowOwnerPIDs: [7, 9])
            let live = DeviceSession.isCaptureLive(
                paused: false, displayAsleep: false, sessionInactive: false,
                windowOnScreen: visible)
            if case .restart = monitor.check(stream, at: now, live: live) {
                restarts += 1
                monitor.streamStarted(at: now)
            }
            XCTAssertFalse(monitor.isFailing,
                           "an application with no on-screen window raised a capture failure")
            if monitor.isFailing { break }
        }
        XCTAssertEqual(restarts, 0, "an application with nothing on screen was restarted")

        // A window appears again: silence counts once more.
        XCTAssertTrue(DeviceSession.applicationContentVisible(
            includedApplicationPIDs: appPIDs, onScreenWindowOwnerPIDs: [4242]))
    }

    /// Routine probes publish nothing; only a failed restart raises the
    /// failure, and clearing it publishes Streaming.
    func testStallVerdictsMapToStatusAndRestart() {
        let healthy = DeviceSession.stallResponse(to: .healthy)
        XCTAssertNil(healthy.status)
        XCTAssertFalse(healthy.restart)

        let probe = DeviceSession.stallResponse(to: .restart(failing: false))
        XCTAssertNil(probe.status, "a routine probe changed the status")
        XCTAssertTrue(probe.restart)

        let failing = DeviceSession.stallResponse(to: .restart(failing: true))
        XCTAssertEqual(failing.status, .failed(DeviceSession.stallFailureMessage))
        XCTAssertTrue(failing.status?.needsAttention ?? false)
        XCTAssertTrue(failing.restart)

        let recovered = DeviceSession.stallResponse(to: .recovered)
        XCTAssertEqual(recovered.status, .streaming)
        XCTAssertFalse(recovered.restart)
    }

    /// The periodic repaint relit a panel the Mac had put to sleep, holding the
    /// pre-sleep picture on it until the Mac woke. It must not run then, nor
    /// while the user has paused the panel.
    func testRefreshRepaintStopsWhileDisplaysSleepOrPaused() {
        let sender = FrameSender(host: "127.0.0.1", port: 5568)
        XCTAssertTrue(sender.refreshAllowed)
        sender.sendDisplaySleep()
        XCTAssertFalse(sender.refreshAllowed, "repaint allowed while the Mac's displays sleep")
        sender.sendDisplayWake()
        XCTAssertTrue(sender.refreshAllowed)
        sender.setPaused(true)
        XCTAssertFalse(sender.refreshAllowed, "repaint allowed while paused")
        sender.setPaused(false)
        XCTAssertTrue(sender.refreshAllowed)
        sender.stop()
    }

    /// While the session is not live (display asleep, user paused) silence is
    /// expected, and must neither restart capture nor count toward a stall.
    func testHeldSessionIsNotRestarted() {
        var monitor = CaptureStallMonitor(now: start)
        let stream = FakeStream(at: start)
        monitor.streamStarted(at: start)
        stream.deliverFrame(at: start + 1)
        _ = monitor.check(stream, at: start + 2)

        var now = start + 2
        while now.timeIntervalSince(start) < 3_600 {
            now += tick
            monitor.hold(at: now)
        }
        // Awake again: the stall clock starts from the wake, not from the last
        // frame an hour ago.
        XCTAssertEqual(monitor.check(stream, at: now + tick), .healthy,
                       "silence while held counted toward a stall")
    }

    // MARK: bounded ScreenCaptureKit calls

    /// A ScreenCaptureKit call that never completes wedged the whole supervisor
    /// loop, stall check included. The deadline has to return anyway.
    func testDeadlineReturnsWhenTheCallNeverCompletes() async {
        let finished = expectation(description: "deadline returned")
        let hang = NeverCompletes()
        Task {
            do {
                _ = try await withCaptureDeadline(0.2, "fake start") {
                    await hang.wait()
                }
                XCTFail("a call that never completed returned a value")
            } catch let error as CaptureDeadlineExpired {
                XCTAssertEqual(error.operation, "fake start")
            } catch {
                XCTFail("unexpected error \(error)")
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 3)
    }

    /// A call that completes after its deadline hands its result to the cleanup
    /// hook, so a stream that started late can be stopped instead of feeding
    /// frames nobody is watching.
    func testLateSuccessReachesTheCleanupHook() async {
        let cleaned = expectation(description: "late result cleaned up")
        let gate = LateGate()
        // Opened from elsewhere, well after the deadline, so a helper that
        // ignores its deadline fails this test instead of hanging it.
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            gate.open()
        }
        do {
            _ = try await withCaptureDeadline(
                0.1, "late start",
                onLateSuccess: { (value: Int) in
                    XCTAssertEqual(value, 7)
                    cleaned.fulfill()
                }
            ) {
                await gate.wait()
                return 7
            }
            XCTFail("returned before the deadline")
        } catch {
            XCTAssertTrue(error is CaptureDeadlineExpired)
        }
        await fulfillment(of: [cleaned], timeout: 3)
    }
}

/// An await that never resumes and ignores cancellation, the way a wedged
/// ScreenCaptureKit completion handler behaves.
private final class NeverCompletes: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { cont in
            lock.withLock { parked.append(cont) }
        }
    }
}

/// An await that resumes only when opened.
private final class LateGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false
    func wait() async {
        await withCheckedContinuation { cont in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiter = cont
                return false
            }
            if resumeNow { cont.resume() }
        }
    }
    func open() {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isOpen = true
            defer { waiter = nil }
            return waiter
        }
        cont?.resume()
    }
}
