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

extension EsptoolRunner {

    /// Process-group signalling and reaping, as seams so the kill escalation
    /// can be driven by a test without a process to kill.
    struct Signals: Sendable {
        /// Send a signal to a whole process group; false when there is none.
        var signalGroup: @Sendable (pid_t, Int32) -> Bool
        /// Whether anything in the group is still alive.
        var groupAlive: @Sendable (pid_t) -> Bool
        /// Reap the leader if it has exited, without blocking: its exit code,
        /// negative for a signal, or nil while it runs.
        var reap: @Sendable (pid_t) -> Int32?
        var sleep: @Sendable (Double) -> Void
        var now: @Sendable () -> Double

        static let live = Signals(
            signalGroup: { pid, signal in Darwin.killpg(pid, signal) == 0 || errno != ESRCH },
            groupAlive: { pid in Darwin.killpg(pid, 0) == 0 || errno == EPERM },
            reap: { pid in
                var status: Int32 = 0
                guard waitpid(pid, &status, WNOHANG) == pid else { return nil }
                return EsptoolRunner.exitCode(fromWaitStatus: status)
            },
            sleep: { seconds in usleep(useconds_t(seconds * 1_000_000)) },
            now: { ProcessInfo.processInfo.systemUptime })
    }

    /// `waitpid`'s status as a code: the exit status, or minus the signal.
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : -signal
    }

    /// One esptool left running for as long as it takes, for `UsbRescuer`.
    ///
    /// NOT `run` above, for two reasons measured with the CLI rescue first.
    /// esptool runs on a PSEUDO-TERMINAL, not a pipe: it is Python, Python
    /// line-buffers only a tty, and "Connected to" is printed without a flush,
    /// so through a pipe it could sit unread past the connect timeout. And it
    /// runs in ITS OWN SESSION: the bundled esptool is a PyInstaller bootloader
    /// whose child is the real esptool, and only a signal to the whole process
    /// group reaches that child. `Process` offers neither, so this is
    /// posix_spawn. Nothing else about spawning differs: no stdin, one output
    /// stream, and only the descriptors named here are inherited.
    final class WaitingProcess: @unchecked Sendable {
        let pid: pid_t
        private var fd: Int32?
        private let signals: Signals
        /// The write end of the watchdog pipe; closing it stops the group.
        private var watchdogFD: Int32?
        private(set) var exitCode: Int32?
        /// kill() has run to the end: nothing is signalled again, because the
        /// pid of a reaped leader may by now belong to someone else.
        private var finished = false

        enum Failure: Error, LocalizedError {
            case couldNotStart(String)
            var errorDescription: String? {
                if case .couldNotStart(let reason) = self { return "Could not start esptool: \(reason)" }
                return nil
            }
        }

        /// Test seam: a process some other code started, or none at all.
        init(pid: pid_t, fd: Int32?, signals: Signals) {
            self.pid = pid
            self.fd = fd
            self.signals = signals
        }

        convenience init(
            _ command: EsptoolCommand, environment: [String: String],
            directory: String, signals: Signals = .live
        ) throws {
            guard FileManager.default.isExecutableFile(atPath: command.executable) else {
                throw Failure.couldNotStart("\(command.executable) is not an executable file")
            }
            var master: Int32 = -1
            var slave: Int32 = -1
            guard openpty(&master, &slave, nil, nil, nil) == 0 else {
                throw Failure.couldNotStart("no pseudo-terminal: \(String(cString: strerror(errno)))")
            }
            defer { close(slave) }
            var watchdog: [Int32] = [-1, -1]
            guard pipe(&watchdog) == 0 else {
                close(master)
                throw Failure.couldNotStart("no watchdog pipe: \(String(cString: strerror(errno)))")
            }
            defer { close(watchdog[0]) }
            // Only this object holds the write end: a child the app spawns
            // later must not keep it open, or the app exiting would not show.
            _ = fcntl(watchdog[1], F_SETFD, FD_CLOEXEC)

            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, slave, 1)
            posix_spawn_file_actions_adddup2(&actions, slave, 2)
            posix_spawn_file_actions_adddup2(&actions, watchdog[0], 3)
            posix_spawn_file_actions_addchdir(&actions, directory)

            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            // SETSID: its own session and process group, led by the child.
            // CLOEXEC_DEFAULT: none of the app's sockets or open serial ports
            // leak into esptool. The signal mask and dispositions are reset
            // so an ignored SIGTERM in the app is not inherited.
            posix_spawnattr_setflags(&attributes, Int16(
                POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                    | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
            var noSignals = sigset_t()
            sigemptyset(&noSignals)
            posix_spawnattr_setsigmask(&attributes, &noSignals)
            var everySignal = sigset_t()
            sigfillset(&everySignal)
            posix_spawnattr_setsigdefault(&attributes, &everySignal)

            let argv = (["/bin/sh", "-c", Self.watchdogScript, "esptool-watchdog",
                         command.executable] + command.arguments).map { strdup($0) }
            let envp = environment.map { strdup("\($0.key)=\($0.value)") }
            defer {
                argv.forEach { free($0) }
                envp.forEach { free($0) }
            }
            var pid: pid_t = 0
            let result = (argv + [nil]).withUnsafeBufferPointer { argvPointer in
                (envp + [nil]).withUnsafeBufferPointer { envpPointer in
                    posix_spawn(&pid, "/bin/sh", &actions, &attributes,
                                argvPointer.baseAddress, envpPointer.baseAddress)
                }
            }
            guard result == 0 else {
                close(master)
                close(watchdog[1])
                throw Failure.couldNotStart(String(cString: strerror(result)))
            }
            _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
            _ = fcntl(master, F_SETFD, FD_CLOEXEC)
            self.init(pid: pid, fd: master, signals: signals)
            watchdogFD = watchdog[1]
        }

        /// The wrapper esptool runs under, as the leader of its process group.
        ///
        /// kill() is not enough on its own: an app that quits or crashes never
        /// calls it, and a pty that is not a controlling terminal (posix_spawn
        /// cannot make it one) hangs nobody up when it closes. So a watcher in
        /// the group reads a pipe only this app holds open. When the app goes,
        /// however it goes, the read ends and the watcher hangs up the whole
        /// group - otherwise an esptool that retries forever would keep
        /// opening its link's port, and write whatever board turned up there.
        /// The watcher's input is fd 3 explicitly: an asynchronous list in a
        /// non-interactive shell otherwise reads /dev/null and would fire at
        /// once. esptool's own exit status is passed through.
        static let watchdogScript = """
            "$@" </dev/null 3<&- &
            tool=$!
            (read -r _ <&3; kill -HUP 0) &
            watch=$!
            exec 3<&-
            wait "$tool"
            code=$?
            kill "$watch" 2>/dev/null
            exit "$code"
            """

        /// Everything written since the last call, without blocking.
        func read() -> String {
            guard let fd else { return "" }
            var text = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                // EAGAIN: nothing more for now. EIO: the other side closed.
                guard count > 0 else { break }
                text.append(buffer, count: count)
            }
            return String(decoding: text, as: UTF8.self)
        }

        /// The exit code once esptool has exited, else nil.
        func poll() -> Int32? {
            if exitCode == nil, pid > 0 { exitCode = signals.reap(pid) }
            return exitCode
        }

        /// Stop the whole esptool process tree and wait for it to go.
        ///
        /// SIGTERM first, which the PyInstaller bootloader forwards and which
        /// lets it remove its extraction directory; SIGKILL to the group only
        /// if anything is still alive after `grace`. Safe to call twice.
        func kill(grace: Double = 5) {
            guard !finished else { return }
            finished = true
            if pid > 0 {
                for signal in [SIGTERM, SIGKILL] {
                    guard signals.signalGroup(pid, signal) else { break }
                    let deadline = signals.now() + grace
                    while signals.now() < deadline {
                        _ = poll()
                        if !signals.groupAlive(pid) { break }
                        signals.sleep(0.05)
                    }
                    if !signals.groupAlive(pid) { break }
                }
                // Reaped, not left a zombie: bounded, like the CLI's wait(5).
                let deadline = signals.now() + grace
                while poll() == nil, signals.now() < deadline { signals.sleep(0.05) }
            }
            closeDescriptors()
        }

        private func closeDescriptors() {
            if let fd {
                close(fd)
                self.fd = nil
            }
            if let watchdogFD {
                close(watchdogFD)
                self.watchdogFD = nil
            }
        }

        /// Close every descriptor without signalling anything, which is what
        /// the app exiting does. Only the tests call this.
        func abandon() {
            closeDescriptors()
        }

        deinit {
            kill(grace: 1)
        }
    }
}
