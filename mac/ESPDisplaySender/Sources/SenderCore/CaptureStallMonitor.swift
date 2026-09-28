import Foundation

/// What a running capture stream exposes for the stall monitor to judge it by.
protocol CaptureFrameSource: AnyObject {
    /// Usable frames converted and handed on since this stream started.
    var framesCaptured: UInt64 { get }
    /// Last time any sample at all arrived, frame or status-only. Not used for
    /// the verdict; the session logs it so a stall can be told apart from a
    /// stream that went fully quiet.
    var lastSampleAt: Date { get }
}

extension DisplayCapture: CaptureFrameSource {}

/// Decides when a capture stream that is still nominally running has stopped
/// delivering, and should be restarted.
///
/// Judged by real frames, not by samples. The watchdog used to key off
/// `lastSampleAt`, which idle, blank and suspended status samples keep fresh,
/// so a stream that had stopped producing pixels but still sent status samples
/// was never restarted - a panel showed a days-old picture while the app called
/// it Online.
///
/// Frames alone cannot tell a stalled stream from an unchanging screen: both
/// deliver nothing. So a long silence triggers a *probe* restart. A healthy
/// fresh stream hands back its first frame at once, which proves the screen was
/// merely static and costs nothing visible; a restarted stream that delivers no
/// frame at all is a real failure, and only then is the user told. Each probe
/// that proves the screen static doubles the wait before the next, up to
/// `maxStallAfter`, so a region that sits still all day is not rebuilt every
/// minute; any frame from ordinary use resets it.
struct CaptureStallMonitor {
    enum Verdict: Equatable {
        case healthy
        /// The reported failure no longer applies: frames are arriving again,
        /// or the session stopped being live, so nothing is being retried.
        case recovered
        /// Restart the stream. `failing` is true once a restart has already
        /// failed to bring frames back, so the session should say so.
        case restart(failing: Bool)
    }

    /// How long a live stream may go without a frame before it is probed.
    static let stallAfter: TimeInterval = 60
    /// Ceiling on that wait after successive probes found only a static screen.
    static let maxStallAfter: TimeInterval = 300
    /// How long a stream restarted because of a stall has to produce its first
    /// frame. A fresh stream delivers one immediately, even for static content.
    static let firstFrameGrace: TimeInterval = 10
    /// Ceiling on the retry backoff while restarts keep failing, so a source
    /// that stays broken is retried about every two minutes, not in a tight loop.
    static let maxRetryInterval: TimeInterval = 120

    /// Restarts in a row that brought no frame back.
    private(set) var failedRestarts = 0
    var isFailing: Bool { failedRestarts > 0 }

    private var streamStartedAt: Date
    private var lastProgressAt: Date
    private var framesSeen: UInt64 = 0
    /// The current stream has to prove itself with a first frame: it replaced
    /// one that stalled, or a failure is being reported.
    private var onProbation = false
    private var restartRequested = false
    /// Whether the current stream replaced one purely as a probe (no failure).
    private var probing = false
    /// Current silence allowance, grown by probes that found a static screen.
    private(set) var currentStallAfter = CaptureStallMonitor.stallAfter

    init(now: Date = Date()) {
        streamStartedAt = now
        lastProgressAt = now
    }

    /// A new stream has just started. Its frame counter starts from zero.
    mutating func streamStarted(at now: Date) {
        streamStartedAt = now
        lastProgressAt = now
        framesSeen = 0
        onProbation = restartRequested || isFailing
        probing = restartRequested && !isFailing
        restartRequested = false
    }

    /// The session is not live (display asleep, user paused), so silence
    /// proves nothing. Restarts the clocks rather than pausing them, so waking
    /// gives the stream the full window again.
    mutating func hold(at now: Date) {
        streamStartedAt = now
        lastProgressAt = now
    }

    /// Judge the stream. `live` false means silence is expected (the display
    /// is asleep, the screen locked, the panel paused) and only holds.
    mutating func check(
        _ source: CaptureFrameSource, at now: Date, live: Bool = true
    ) -> Verdict {
        let frames = source.framesCaptured
        guard live else {
            // Frames seen while held still count once live again.
            hold(at: now)
            // Nothing is retrying while held, so a "still retrying" failure
            // must not sit on screen through a night of display sleep. The
            // stream stays on probation, so if it is still broken once live
            // again the failure comes back after the first-frame grace.
            guard isFailing else { return .healthy }
            failedRestarts = 0
            onProbation = true
            return .recovered
        }
        if frames != framesSeen {
            // The first frame of a probe stream proves only that the screen
            // was static, so the next probe waits longer. Anything else is
            // ordinary activity, which resets the wait.
            let provedStatic = probing && framesSeen == 0 && frames <= 2
            currentStallAfter = provedStatic
                ? min(currentStallAfter * 2, Self.maxStallAfter)
                : Self.stallAfter
            probing = false
            framesSeen = frames
            lastProgressAt = now
            onProbation = false
            guard isFailing else { return .healthy }
            failedRestarts = 0
            return .recovered
        }
        if onProbation {
            guard now.timeIntervalSince(streamStartedAt) >= retryDelay else {
                return .healthy
            }
            failedRestarts += 1
            restartRequested = true
            return .restart(failing: true)
        }
        guard now.timeIntervalSince(lastProgressAt) >= currentStallAfter else {
            return .healthy
        }
        restartRequested = true
        return .restart(failing: false)
    }

    /// How long the current probation stream gets: the first-frame grace at
    /// first, doubling with each failed restart up to the ceiling.
    private var retryDelay: TimeInterval {
        let doublings = Double(min(failedRestarts, 8))
        return min(Self.firstFrameGrace * pow(2, doublings), Self.maxRetryInterval)
    }
}

/// A ScreenCaptureKit call that did not complete in time.
struct CaptureDeadlineExpired: Error, LocalizedError {
    let operation: String
    var errorDescription: String? { "\(operation) did not complete" }
}

/// Run an async call, giving up on it after `seconds`.
///
/// The supervisor loop awaits ScreenCaptureKit at every step - shareable
/// content, starting, stopping and reconfiguring streams - and none of those
/// awaits had a bound. One that never completed wedged the loop for good, and
/// with it the stall check that is supposed to notice capture has stopped.
///
/// Cancelling a task does not unblock a ScreenCaptureKit completion handler,
/// and a task group waits for its children, so the deadline races the call
/// through a one-shot continuation instead. The abandoned call keeps running;
/// if it later succeeds, `onLateSuccess` gets the result, so something it
/// started (a stream) can be shut down rather than left running unobserved.
func withCaptureDeadline<T>(
    _ seconds: TimeInterval, _ operation: String,
    onLateSuccess: ((T) -> Void)? = nil,
    _ body: @escaping () async throws -> T
) async throws -> T {
    let once = OneShot()
    return try await withCheckedThrowingContinuation { continuation in
        let timer = Task {
            // Cancelled when the call finishes first, which ends the sleep early.
            guard (try? await Task.sleep(
                nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))) != nil,
                once.claim()
            else { return }
            continuation.resume(throwing: CaptureDeadlineExpired(operation: operation))
        }
        Task {
            do {
                let value = try await body()
                if once.claim() {
                    timer.cancel()
                    continuation.resume(returning: value)
                } else {
                    onLateSuccess?(value)
                }
            } catch {
                if once.claim() {
                    timer.cancel()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Lets exactly one of two racing tasks resume a continuation.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True for the first caller only.
    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
