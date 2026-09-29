import AppKit
import SenderProtocol
import SwiftUI

/// What a firmware sheet's floating footer says under its buttons: the run's
/// progress while it runs, or why it stopped.
///
/// In the footer rather than in the form because the form scrolls and the
/// footer does not. A progress bar and a failure that sat at the bottom of the
/// form were below the fold on every sheet with a bundle loaded, so a finished
/// update's failure was not seen until the sheet was closed - and the sheet was
/// only closed because nothing seemed to be happening.
enum FlashFooterStatus: Equatable {
    case progress(fraction: Double?, title: String, detail: String?)
    case failure(
        title: String, step: String?, message: String,
        lastSeen: [String], nextAction: String?)

    /// A USB run: its failure when it has one, else its phase.
    static func usb(_ session: UsbFlashSession) -> FlashFooterStatus {
        if let failure = session.failure {
            return .failure(
                title: failure.title, step: failure.step, message: failure.message,
                lastSeen: failure.lastSeen, nextAction: failure.nextAction)
        }
        var detail = session.phase?.detail
        if case .waitingForBoard(let wait) = session.phase, let seen = wait.lastSeen {
            detail = [detail, "Last seen: \(seen)"].compactMap { $0 }.joined(separator: "\n")
        }
        return .progress(
            fraction: session.phase?.fraction,
            title: session.phase?.title ?? "Starting…",
            detail: detail)
    }

    static func failure(_ outcome: OperationOutcome) -> FlashFooterStatus {
        .failure(
            title: outcome.title, step: nil, message: outcome.message,
            lastSeen: [], nextAction: outcome.nextAction)
    }
}

struct FlashStatusFooterView: View {
    let status: FlashFooterStatus

    var body: some View {
        switch status {
        case .progress(let fraction, let title, let detail):
            VStack(alignment: .leading, spacing: 5) {
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 0)
                    if let fraction {
                        Text("\(Int((fraction * 100).rounded(.down)))%")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        case .failure(let title, let step, let message, let lastSeen, let nextAction):
            // Scrolls within a cap rather than growing without one, so a long
            // esptool complaint cannot push the buttons off the sheet.
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    Label(title, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                    if let step {
                        Text("Failed while: \(step)")
                            .font(.caption)
                    }
                    Text(message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if !lastSeen.isEmpty {
                        Text(lastSeen.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let nextAction {
                        Text("Next: \(nextAction)")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A USB run's transcript, for the form: everything esptool and the serial
/// port said, selectable and copyable. The footer has the summary.
struct UsbFlashTranscriptView: View {
    let session: UsbFlashSession

    var body: some View {
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
