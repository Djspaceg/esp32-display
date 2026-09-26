import AppKit
import SenderProtocol
import SwiftUI

/// One USB run's state, fed from whatever thread esptool and the serial port
/// report on, published on the main queue in the order it arrived.
///
/// DispatchQueue.main rather than a `Task { @MainActor }` per event: those
/// tasks are not ordered, so a stale "waiting" could land after the
/// "configuring" that followed it and a transcript could read out of order.
final class UsbFlashMonitor: ObservableObject, @unchecked Sendable {
    @Published private(set) var session: UsbFlashSession

    private let lock = NSLock()
    private var pending: UsbFlashSession
    private var started = ProcessInfo.processInfo.systemUptime
    private var publishScheduled = false

    init(flow: UsbFlashSession.Flow) {
        let initial = UsbFlashSession(flow: flow)
        session = initial
        pending = initial
    }

    private var elapsed: Double { ProcessInfo.processInfo.systemUptime - started }

    /// Safe from any thread. Bursts are coalesced into one publish.
    func record(_ event: UsbFlashEvent) {
        let schedule = lock.withLock { () -> Bool in
            pending.apply(event, at: elapsed)
            guard !publishScheduled else { return false }
            publishScheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            // Copied under the lock, published outside it: a subscriber that
            // records from objectWillChange must not find the lock held.
            let snapshot = lock.withLock { () -> UsbFlashSession in
                publishScheduled = false
                return pending
            }
            session = snapshot
        }
    }

    /// Start a new run: the previous transcript and failure are dropped.
    func reset(flow: UsbFlashSession.Flow? = nil) {
        lock.withLock {
            pending = UsbFlashSession(flow: flow ?? pending.flow)
            started = ProcessInfo.processInfo.systemUptime
        }
        publishNow()
    }

    func fail(_ outcome: OperationOutcome) {
        lock.withLock {
            pending.fail(
                title: outcome.title, message: outcome.message,
                nextAction: outcome.nextAction, at: elapsed)
        }
        publishNow()
    }

    /// Main thread only (both callers are views).
    private func publishNow() {
        dispatchPrecondition(condition: .onQueue(.main))
        session = lock.withLock { pending }
    }
}

/// The phase that is running, what it is waiting for, and - when it failed -
/// which step, what was last seen and what to do. The full transcript is
/// behind Details, copyable.
struct UsbFlashStatusView: View {
    let session: UsbFlashSession
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = session.failure {
                failureBlock(failure)
            } else {
                if let fraction = session.phase?.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(session.phase?.title ?? "Starting…")
                    .fontWeight(.medium)
                if let detail = session.phase?.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .waitingForBoard(let wait) = session.phase, let seen = wait.lastSeen {
                    Text("Last seen: \(seen)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            if !session.transcript.entries.isEmpty {
                DisclosureGroup("Details", isExpanded: $showDetails) {
                    transcriptBlock
                }
                .font(.callout)
            }
        }
    }

    private func failureBlock(_ failure: UsbFlashFailure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(failure.title)
                .fontWeight(.medium)
            Text("Failed while: \(failure.step)")
                .font(.callout)
            Text(failure.message)
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if !failure.lastSeen.isEmpty {
                Text("Last seen:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(failure.lastSeen.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Next: \(failure.nextAction)")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textSelection(.enabled)
    }

    private var transcriptBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                Text(session.transcript.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
            Button("Copy Transcript") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.transcript.text, forType: .string)
            }
            .controlSize(.small)
        }
    }
}
