import Foundation

/// When a panel's streaming telemetry may next reach the views.
///
/// Audio snapshots arrive four or more times a second and the heartbeat once a
/// second; every write to `PanelManager.panels` re-renders the whole window, so
/// a panel's telemetry is held and written at most once per `interval`, with a
/// trailing write so the latest values are never lost. An urgent offer (a state
/// change the user should see at once) writes immediately and cancels the
/// write scheduled before it.
struct PanelUpdateThrottle {
    static let interval: TimeInterval = 0.5

    enum Decision: Equatable {
        /// Write now; call `wrote` if anything was written.
        case flushNow
        /// Schedule one write for then; when it fires, `claim` it first.
        case flushAt(Date, generation: Int)
        /// A write is already scheduled and will carry this offer.
        case coalesced
    }

    private var lastWrite: [String: Date] = [:]
    /// The generation of the write scheduled for a panel, if any.
    private var scheduled: [String: Int] = [:]
    private var generations: [String: Int] = [:]

    mutating func offer(_ name: String, now: Date, urgent: Bool) -> Decision {
        if urgent {
            scheduled[name] = nil
            generations[name, default: 0] += 1
            return .flushNow
        }
        if scheduled[name] != nil { return .coalesced }
        guard let last = lastWrite[name],
              now.timeIntervalSince(last) < Self.interval
        else { return .flushNow }
        let generation = generations[name, default: 0]
        scheduled[name] = generation
        return .flushAt(last.addingTimeInterval(Self.interval), generation: generation)
    }

    /// True if the scheduled write of `generation` is still the current one;
    /// a later urgent write makes it stale.
    mutating func claim(_ name: String, generation: Int) -> Bool {
        guard scheduled[name] == generation else { return false }
        scheduled[name] = nil
        return true
    }

    mutating func wrote(_ name: String, at now: Date) {
        lastWrite[name] = now
    }

    mutating func forget(_ name: String) {
        lastWrite[name] = nil
        scheduled[name] = nil
        generations[name, default: 0] += 1
    }
}
