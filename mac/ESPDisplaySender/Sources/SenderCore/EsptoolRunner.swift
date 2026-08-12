import Foundation
import SenderProtocol

/// Runs one esptool invocation and reports what it says while it says it.
///
/// THE FIRST PROCESS THIS APP HAS EVER SPAWNED. Before this there was no
/// `Process(`, no `executableURL` and no `launchPath` anywhere in Sources/, so the
/// things that are usually assumed are written down here instead:
///
///   - THE APP IS NOT SANDBOXED. There is no entitlements file and no
///     CODE_SIGN_ENTITLEMENTS in the xcodeproj, so spawning a child and opening a
///     tty are both permitted. Under a sandbox neither would be.
///   - WHETHER THE CHILD CAN OPEN THE SERIAL PORT UNDER THIS APP'S SIGNING IS
///     UNVERIFIED. The app itself opens /dev/cu.usbmodem* directly today
///     (WifiConfigUI.openSerial), so the app's own access is established; a child
///     process inheriting that access is the ordinary POSIX behaviour and has not
///     been demonstrated here, because no board was attached while this was
///     written. If it turns out to be refused, the failure surfaces as esptool's
///     own "could not open port" text rather than as something this code hides.
///   - STDOUT AND STDERR GO TO ONE PIPE, deliberately. esptool 5.3.1 prints its
///     deprecation warnings to the normal output stream and still exits 0, so a
///     runner that treated anything on stderr as a failure would fail a working
///     flash. Only the exit status decides, and both streams are kept in the order
///     the tool wrote them so the transcript reads correctly.
///   - PROGRESS REDRAWS WITH A CARRIAGE RETURN, so lines are split on `\r` as well
///     as `\n` (`EsptoolOutput.splitLines`). Splitting on `\n` alone would show
///     nothing until the write finished.
///   - NOTHING HERE TOUCHES THE MAIN ACTOR. The reads happen on a Dispatch queue
///     and the whole thing is awaited, so a multi-minute flash does not stall the
///     window. `onLine` is called on that queue, so callers hop to the main actor
///     themselves - the same shape `FirmwarePusher`'s progress callback has.
///   - CANCELLATION TERMINATES THE CHILD. `Task.cancel()` sends SIGTERM. Whether
///     interrupting a write mid-flash leaves a board bootable is not something
///     this side can promise, which is why the sheet only offers cancellation
///     before the write starts and while the chip is being read.
enum EsptoolRunner {

    /// What a finished run produced.
    struct Outcome: Equatable, Sendable {
        let exitCode: Int32
        /// Everything the tool printed, both streams, in order.
        let output: String

        var succeeded: Bool { exitCode == 0 }
    }

    enum Failure: Error, LocalizedError, Equatable {
        /// The tool could not be started at all, which is a different thing from a
        /// tool that ran and refused.
        case couldNotStart(tool: String, reason: String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .couldNotStart(let tool, let reason):
                return "Could not run \(tool): \(reason)"
            case .cancelled:
                return "Cancelled."
            }
        }
    }

    /// A small lock-guarded box, because the reader runs on a Dispatch queue and
    /// the continuation is resumed from the termination handler on another.
    private final class Box<Value>: @unchecked Sendable {
        private var value: Value
        private let lock = NSLock()

        init(_ value: Value) { self.value = value }

        func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    /// Run it, streaming each complete line to `onLine`.
    static func run(
        _ command: EsptoolCommand,
        onLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Outcome {
        let executable = URL(fileURLWithPath: command.executable)
        guard FileManager.default.isExecutableFile(atPath: command.executable) else {
            throw Failure.couldNotStart(
                tool: command.executable,
                reason: "it is not an executable file on this Mac")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = command.arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // No input. Without this esptool inherits the parent's stdin, and a tool
        // that decided to prompt would then wait forever on a terminal that is not
        // there.
        process.standardInput = FileHandle.nullDevice

        let transcript = Box("")
        let remainder = Box("")
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            transcript.withValue { $0 += text }
            let pending = remainder.withValue { buffer -> String in
                buffer += text
                let split = EsptoolOutput.splitLines(buffer)
                buffer = split.remainder
                return split.lines.joined(separator: "\n")
            }
            for line in pending.split(separator: "\n", omittingEmptySubsequences: false)
            where EsptoolOutput.isStatusWorthy(String(line)) {
                onLine(String(line))
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw Failure.couldNotStart(
                tool: command.executable,
                reason: (error as NSError).localizedDescription)
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }
        } onCancel: {
            // SIGTERM rather than SIGKILL: esptool closes the port on the way out,
            // and a port left open by a killed child is a port the next attempt
            // cannot use.
            process.terminate()
        }

        // Whatever was buffered between the last read and exit. The handler stops
        // being called once the process is gone, so this is not optional.
        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        pipe.fileHandleForReading.readabilityHandler = nil
        if !tail.isEmpty {
            let text = String(decoding: tail, as: UTF8.self)
            transcript.withValue { $0 += text }
            remainder.withValue { $0 += text }
        }
        let last = remainder.withValue { buffer -> String in
            let value = buffer
            buffer = ""
            return value
        }
        // The final chunk may have no terminator at all, so the remainder counts as
        // a line here where mid-stream it would not.
        let split = EsptoolOutput.splitLines(last)
        for line in split.lines + [split.remainder]
        where EsptoolOutput.isStatusWorthy(line) {
            onLine(line)
        }

        if Task.isCancelled { throw Failure.cancelled }
        return Outcome(
            exitCode: process.terminationStatus,
            output: transcript.withValue { $0 })
    }
}
