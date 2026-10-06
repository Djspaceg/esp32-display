import Darwin
import Foundation
import Network
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// The 4C sequence: a running app stopped talking to a board that was reset
/// and reflashed many times, and only a relaunch brought it back. Each test
/// here is one way a session could give up on a panel for good.
final class SessionRecoveryTests: XCTestCase {

    // MARK: a panel that resets at the same address

    /// A board between reset and listening refuses datagrams. The receive
    /// loop stops on any receive error, so if the refusal reached it the link
    /// would go on pinging a board it could no longer hear. On loopback it
    /// does not, and did not before the fix either; this keeps it that way.
    func testALinkHearsAPanelThatResetAtTheSameAddress() async throws {
        let panel = ResettingPanel()
        try panel.powerOn()
        let sender = FrameSender(endpoint: .hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: panel.port)!))
        defer {
            sender.stop()
            panel.powerOff()
        }
        try await sender.start(timeoutSeconds: 2)
        let heardFirst = await eventually(within: 5) { sender.deviceRepliesReceived > 0 }
        XCTAssertTrue(heardFirst, "the panel never answered at all")

        // Reset: the port refuses. A command goes out straight away, rather
        // than waiting up to two seconds for the next keepalive.
        panel.powerOff()
        sender.identify(seconds: 1)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Back at the same address and port.
        let before = sender.deviceRepliesReceived
        try panel.powerOn()
        sender.identify(seconds: 1)
        let heardAgain = await eventually(within: 5) {
            sender.deviceRepliesReceived > before
        }
        XCTAssertTrue(
            heardAgain,
            "the panel came back at the same address and answered, but the link "
                + "never read another reply")
    }

    /// A reconnect that cannot resolve the panel used to cancel the working
    /// link first and leave nothing behind: no socket at all, even though the
    /// board had come back at the address that link was still pointed at.
    func testAReconnectThatCannotResolveKeepsTheWorkingLink() async throws {
        let panel = ResettingPanel()
        try panel.powerOn()
        let sender = FrameSender(endpoint: .hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: panel.port)!))
        defer {
            sender.stop()
            panel.powerOff()
        }
        try await sender.start(timeoutSeconds: 2)
        let heardFirst = await eventually(within: 5) { sender.deviceRepliesReceived > 0 }
        XCTAssertTrue(heardFirst, "the panel never answered at all")

        // The name stops resolving (a Bonjour type nothing advertises).
        sender.endpointOverrideForTesting = .service(
            name: "absent-\(UUID().uuidString)", type: "_espdisptest._udp",
            domain: "local.", interface: nil)
        do {
            try await sender.start(timeoutSeconds: 0.5)
            XCTFail("an unadvertised service resolved")
        } catch {}

        let before = sender.deviceRepliesReceived
        let stillHeard = await eventually(within: 3) {
            sender.deviceRepliesReceived > before
        }
        XCTAssertTrue(
            stillHeard,
            "a reconnect that could not resolve the panel took down the link that "
                + "was still reaching it")
    }

    // MARK: a session whose capture has not started

    /// The link was watched only from inside the capture watchdog. A session
    /// still looking for its source (a followed window that is not open, or
    /// ScreenCaptureKit not answering) never reconnected, so a board reset in
    /// that state was lost until the app was relaunched.
    func testASilentLinkIsReopenedWhileCaptureHasNoSource() async throws {
        let panel = ResettingPanel()
        try panel.powerOn()
        let sender = FrameSender(endpoint: .hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: panel.port)!))
        let session = DeviceSession(
            name: "recovery-test", sender: sender,
            source: .window("A window that is not open"), picker: nil, fps: 30,
            linkTiming: LinkSupervisor.Timing(
                reconnectAfterSilence: 1, reconnectSpacing: 1, checkInterval: 0.1))
        // Capture never finds its source.
        session.captureLoopOverrideForTesting = { [weak session] in
            while let session, !session.isStopped {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        let running = Task { await session.run() }
        defer {
            session.stop()
            panel.powerOff()
        }

        let heardFirst = await eventually(within: 5) { sender.deviceRepliesReceived > 0 }
        XCTAssertTrue(heardFirst, "the panel never answered at all")
        let firstSocket = try XCTUnwrap(panel.lastSourcePort)

        // The board goes quiet. Only a reopened link, which arrives from a new
        // local port, shows the session noticed.
        panel.answering = false
        let reopened = await eventually(within: 6) {
            panel.sourcePorts.contains { $0 != firstSocket }
        }
        XCTAssertTrue(
            reopened,
            "the link went silent and the session never reconnected, because "
                + "capture had not started")

        // And once it answers again, the reopened link hears it.
        let before = sender.deviceRepliesReceived
        panel.answering = true
        let heardAgain = await eventually(within: 6) {
            sender.deviceRepliesReceived > before
        }
        XCTAssertTrue(heardAgain, "the panel answered again but was not heard")

        session.stop()
        _ = await running.value
    }

    /// Reconnects now run on their own task, so one can still be under way
    /// when the session stops. Stopping has to win.
    func testAStoppedLinkIsNeverReopened() async {
        let sender = FrameSender(host: "127.0.0.1", port: 5568)
        sender.stop()
        do {
            try await sender.start(timeoutSeconds: 1)
            XCTFail("a stopped sender opened a new link")
        } catch {}
    }

    // MARK: a session that was retired

    /// Discovery reports changes only. A session retired as unreachable was
    /// relaunched only by a later change to the browse results, so a board
    /// that came back inside the cooldown, and stayed listed, was never tried
    /// again.
    func testARetiredNameIsRetriedWithoutWaitingForDiscovery() {
        let registry = SessionRegistry(retryCooldown: 0.5)
        let due = expectation(description: "retry due")
        registry.onRetryDue = { name in
            XCTAssertEqual(name, "big-round")
            due.fulfill()
        }

        registry.retire("big-round")
        XCTAssertTrue(registry.shouldSkip("big-round"), "retried inside the cooldown")

        wait(for: [due], timeout: 3)
        XCTAssertFalse(
            registry.shouldSkip("big-round"),
            "the retry was announced but the name is still being skipped")
    }

    /// A name that got a live session again in the meantime needs no retry.
    func testNoRetryForANameThatIsRunningAgain() {
        let registry = SessionRegistry(retryCooldown: 0.1)
        let due = expectation(description: "retry due")
        due.isInverted = true
        registry.onRetryDue = { _ in due.fulfill() }

        registry.retire("big-round")
        registry.add(
            DeviceSession(
                name: "big-round", sender: FrameSender(host: "127.0.0.1", port: 5568),
                source: .auto(defaultDisplay: ""), picker: nil, fps: 30))

        wait(for: [due], timeout: 0.5)
    }

    // MARK: the decisions

    /// A reconnect runs on the link task while the watchdog decides whether
    /// to park. Parking on silence alone parked after every Mac wake, before
    /// the reconnect already under way had a chance to succeed.
    func testParkingWaitsForAReconnectToFinishWithoutHelping() {
        var step = DeviceSession.parkDecision(
            silentFor: 3_600, reconnectInFlight: true,
            reconnectsFinished: 7, waitingSince: nil)
        XCTAssertFalse(step.park, "parked before any reconnect was tried")
        step = DeviceSession.parkDecision(
            silentFor: 3_601, reconnectInFlight: true,
            reconnectsFinished: 7, waitingSince: step.waitingSince)
        XCTAssertFalse(step.park, "parked while the reconnect was still under way")
        step = DeviceSession.parkDecision(
            silentFor: 3_620, reconnectInFlight: false,
            reconnectsFinished: 8, waitingSince: step.waitingSince)
        XCTAssertTrue(step.park, "a finished reconnect that did not help must park")
    }

    func testAReconnectThatHelpsClearsTheWait() {
        let waiting = DeviceSession.parkDecision(
            silentFor: 40, reconnectInFlight: true,
            reconnectsFinished: 1, waitingSince: nil)
        let after = DeviceSession.parkDecision(
            silentFor: 0.1, reconnectInFlight: false,
            reconnectsFinished: 2, waitingSince: waiting.waitingSince)
        XCTAssertFalse(after.park)
        XCTAssertNil(after.waitingSince)
    }

    /// Kept through a run of resets, but not for days: the address may have
    /// gone to another board by then.
    func testAKeptLinkIsDroppedOnlyAfterLongSilence() {
        XCTAssertFalse(FrameSender.shouldDropKeptLink(silentFor: nil))
        XCTAssertFalse(FrameSender.shouldDropKeptLink(silentFor: 25 * 60))
        XCTAssertTrue(FrameSender.shouldDropKeptLink(silentFor: 31 * 60))
    }

    func testAClockSetBackwardsAllowsAReconnect() {
        var link = LinkSupervisor()
        XCTAssertTrue(link.shouldReconnect(heartbeatAge: 30, now: 1_000))
        XCTAssertTrue(link.shouldReconnect(heartbeatAge: 30, now: 500))
    }

    func testReconnectWaitsForSilence() {
        var link = LinkSupervisor()
        XCTAssertFalse(link.shouldReconnect(heartbeatAge: nil, now: 100))
        XCTAssertFalse(link.shouldReconnect(heartbeatAge: 2, now: 100))
        XCTAssertFalse(link.shouldReconnect(heartbeatAge: 10, now: 100))
        XCTAssertTrue(link.shouldReconnect(heartbeatAge: 11, now: 100))
    }

    /// A reconnect that cannot reach the panel must not be retried in a tight
    /// loop, and one that keeps failing must keep being retried.
    func testReconnectsAreSpacedButNeverStop() {
        var link = LinkSupervisor()
        XCTAssertTrue(link.shouldReconnect(heartbeatAge: 30, now: 100))
        XCTAssertFalse(link.shouldReconnect(heartbeatAge: 32, now: 102))
        XCTAssertFalse(link.shouldReconnect(heartbeatAge: 45, now: 115))
        XCTAssertTrue(link.shouldReconnect(heartbeatAge: 46, now: 116))
        XCTAssertTrue(link.shouldReconnect(heartbeatAge: 3_600, now: 3_700))
    }
}

/// Poll until `condition` holds or `seconds` pass.
private func eventually(
    within seconds: TimeInterval, _ condition: () -> Bool
) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// A panel on loopback: answers every datagram with a heartbeat, heartbeats
/// its last sender four times a second, and can be switched off and back on
/// at the same port, the way a board resets and returns at the same IP.
private final class ResettingPanel: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var finished: DispatchSemaphore?
    private var _answering = true
    private var _sourcePorts: [UInt16] = []
    private(set) var port: UInt16 = 0

    /// Whether it replies. Off drops everything without refusing it.
    var answering: Bool {
        get { lock.withLock { _answering } }
        set { lock.withLock { _answering = newValue } }
    }

    /// The local port of every datagram received, oldest first.
    var sourcePorts: [UInt16] { lock.withLock { _sourcePorts } }
    var lastSourcePort: UInt16? { sourcePorts.last }

    private static let heartbeat: Data = {
        var packet = Data("EHB1".utf8)
        for value: UInt32 in [1, 0, 0, 1, 100_000] {
            withUnsafeBytes(of: value.littleEndian) { packet.append(contentsOf: $0) }
        }
        return packet
    }()

    func powerOn() throws {
        let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(
            socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(socketFD)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        port = UInt16(bigEndian: actual.sin_port)
        let done = DispatchSemaphore(value: 0)
        lock.withLock {
            running = true
            finished = done
        }
        Thread.detachNewThread { [self] in
            serve(socketFD)
            done.signal()
        }
    }

    /// Close the port and wait until it is closed, so what follows sees it refuse.
    func powerOff() {
        let done: DispatchSemaphore? = lock.withLock {
            running = false
            defer { finished = nil }
            return finished
        }
        done?.wait()
    }

    private func serve(_ socketFD: Int32) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var lastSender: sockaddr_in?
        var lastBeat = Date.distantPast
        while lock.withLock({ running }) {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(socketFD, &buffer, buffer.count, 0, $0, &length)
                }
            }
            let answering = lock.withLock { () -> Bool in
                if count > 0 { _sourcePorts.append(UInt16(bigEndian: from.sin_port)) }
                return _answering
            }
            if count > 0 {
                lastSender = from
                if answering { send(to: from, on: socketFD) }
            }
            if answering, let target = lastSender, Date().timeIntervalSince(lastBeat) > 0.25 {
                send(to: target, on: socketFD)
                lastBeat = Date()
            }
        }
        close(socketFD)
    }

    private func send(to target: sockaddr_in, on socketFD: Int32) {
        var target = target
        Self.heartbeat.withUnsafeBytes { bytes in
            _ = withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        socketFD, bytes.baseAddress, bytes.count, 0, $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
