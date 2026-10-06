import Foundation

/// Decides when a session re-resolves and reopens its link to the panel.
///
/// Kept apart from capture on purpose. The link used to be watched only from
/// inside the capture watchdog, so a session whose capture had not started -
/// a followed window that was not open, a source ScreenCaptureKit would not
/// hand over - never reconnected at all. A board that reset during that time
/// was lost until the app was relaunched.
struct LinkSupervisor {
    struct Timing: Equatable {
        /// Heartbeat silence after which the link is reopened.
        var reconnectAfterSilence: TimeInterval = 10
        /// The least time between two reconnect attempts. A reconnect that
        /// cannot resolve the panel takes up to eight seconds on its own.
        var reconnectSpacing: TimeInterval = 15
        /// How often the link is looked at.
        var checkInterval: TimeInterval = 2

        static let standard = Timing()
    }

    let timing: Timing
    private var lastAttemptAt: TimeInterval?

    init(timing: Timing = .standard) {
        self.timing = timing
    }

    /// Whether to reconnect now, recording the attempt when it says yes.
    ///
    /// - Parameters:
    ///   - heartbeatAge: `FrameSender.heartbeatAge`. A reconnect refreshes it,
    ///     so the spacing below is what paces attempts against a panel that
    ///     stays away. Nil means the link has never been up, which the connect
    ///     retries in `DeviceSession.run()` own.
    ///   - now: wall-clock seconds, like `heartbeatAge`, so time asleep counts
    ///     toward the spacing. A clock set backwards allows an attempt rather
    ///     than holding them off.
    mutating func shouldReconnect(heartbeatAge: TimeInterval?, now: TimeInterval) -> Bool {
        guard let heartbeatAge, heartbeatAge > timing.reconnectAfterSilence else { return false }
        if let lastAttemptAt, now >= lastAttemptAt,
            now - lastAttemptAt <= timing.reconnectSpacing
        { return false }
        lastAttemptAt = now
        return true
    }
}
