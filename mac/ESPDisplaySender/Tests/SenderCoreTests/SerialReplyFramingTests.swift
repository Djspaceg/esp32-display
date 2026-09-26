import XCTest
import Darwin
@testable import SenderCore
@testable import SenderProtocol

/// A board that has been printing while nobody had its port open flushes that
/// backlog the moment the port opens, and the backlog ends wherever the board's
/// transmit buffer overflowed - mid-line. Its reply is then appended to that
/// partial line. Measured on the Waveshare ESP32-S3-LCD-1.9 at
/// /dev/cu.usbmodem1312201 (firmware 1.5.0): after about a minute unread, the
/// first CFGSHOW came back as
///
///     ...frames=1001 dropped=212 partial=0 packets=9512 badlen=0 drawerr=0 heap=12151CFGINFO ssid64=...
///
/// and every later CFGSHOW, with nothing buffered, came back clean. These tests
/// replay those bytes through a pseudo-terminal, so what is exercised is the
/// app's own open/write/read loop, not a copy of it.
final class SerialReplyFramingTests: XCTestCase {

    static let reply = "CFGINFO ssid64= name64=ZXNwZGlzcGxheS01Yjk0 id=1cdbd47b5b94 "
        + "connected=0 ip=0.0.0.0 rssi=0 flip=0 rot=0 mirrorx=0 autorot=1 auto=0 "
        + "effective=0 motion=1 bl=high blfixed=0 bllow=24 blhigh=128 blidle=10 "
        + "blsurvey=255 pwr=on board=st7789-190 profile=st7789-190 target=s3 "
        + "chip=esp32s3 partition=universal-8m-doom-ota bat=-1 ota=off ssid= "
        + "caps=000051ef bllevel=128 fw=1.5.0"

    /// The tail of the measured backlog, verbatim, ending where the board's
    /// buffer overflowed.
    static let truncatedBacklog =
        "motion: raw=8285,355,-1113 candidate=-1 auto=0 effective=0 mode=flip-only\n"
        + "frames=910 dropped=209 partial=0 packets=9280 badlen=0 drawerr=0 heap=121516 rssi=-55\n"
        + "tiledraw: 19 passes, 0 calls, 0 gateblocked | per pass: 6656 us total = spin 0 + gather 0 + queue 0 + bar 0\n"
        + "motion: raw=8273,376,-1138 candidate=-1 auto=0 effective=0 mode=flip-only\n"
        + "frames=1001 dropped=212 partial=0 packets=9512 badlen=0 drawerr=0 heap=12151"

    func testSendCommandFindsAReplyGluedToATruncatedBacklogLine() throws {
        let board = try FakeSerialBoard(onCommand: { command in
            command == "CFGSHOW" ? Self.truncatedBacklog + Self.reply + "\n" : nil
        })
        defer { board.stop() }

        let started = Date()
        let result = WifiConfigUI.sendCommand("CFGSHOW", port: board.path, timeout: 3)
        guard case .success(let line) = result else {
            return XCTFail("CFGSHOW got no reply after \(Date().timeIntervalSince(started))s: \(result)")
        }
        XCTAssertEqual(line, Self.reply)
    }

    /// The settle loop's own probe: this is what never matched after a flash.
    func testProbeIdentifiesTheBoardBehindABacklog() throws {
        let board = try FakeSerialBoard(onCommand: { command in
            command == "CFGSHOW" ? Self.truncatedBacklog + Self.reply + "\n" : nil
        })
        defer { board.stop() }

        let existing = UsbOnboarder.probeExistingFirmware(port: board.path)
        XCTAssertEqual(existing, .answered(name: "espdisplay-5b94", hardwareID: "1cdbd47b5b94"))
        XCTAssertTrue(UsbOnboarder.matchesExpectedHardwareID(
            existing, expectedHardwareID: "1C:DB:D4:7B:5B:94"))
    }

    /// A CFGERR glued the same way is still a refusal, not a silence.
    func testSendCommandReportsAGluedRefusal() throws {
        let board = try FakeSerialBoard(onCommand: { _ in
            Self.truncatedBacklog + "CFGERR unknown command\n"
        })
        defer { board.stop() }

        let result = WifiConfigUI.sendCommand("CFGNOPE", port: board.path, timeout: 3)
        guard case .failure(let reason) = result else {
            return XCTFail("a refusal was reported as \(result)")
        }
        XCTAssertEqual(reason, "CFGERR unknown command")
    }
}

extension SerialReplyFramingTests {
    /// Older firmware ends replies with println's "\r\n", which is one Swift
    /// Character equal to neither terminator.
    func testACRLFTerminatedRefusalIsReadAtOnce() throws {
        let board = try FakeSerialBoard(onCommand: { _ in
            "CFGERR name has no hostname-safe characters\r\n"
        })
        defer { board.stop() }
        let started = Date()
        let result = WifiConfigUI.sendCommand("CFGNAME Pz8/", port: board.path, timeout: 3)
        guard case .failure(let reason) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(reason, "CFGERR name has no hostname-safe characters")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testAReplySplitAcrossReadsIsReturnedWhole() throws {
        let board = try FakeSerialBoard(chunked: { _ in
            ["motion: raw=1,2,3\nframes=1 heap=121", "516\nCFGINFO name64=eA== id=1cdb",
             "d47b5b94 fw=1.5.0\r\n"]
        })
        defer { board.stop() }
        let result = WifiConfigUI.sendCommand("CFGSHOW", port: board.path, timeout: 3)
        guard case .success(let line) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(line, "CFGINFO name64=eA== id=1cdbd47b5b94 fw=1.5.0")
    }

    /// Older firmware cut long CFGSHOW replies at 256 bytes, newline included;
    /// the identity is in the first hundred and is still taken.
    func testAReplyWhoseNewlineNeverComesIsTakenOnceThePortIsQuiet() throws {
        let board = try FakeSerialBoard(onCommand: { _ in
            "CFGINFO ssid64= name64=ZXNwZGlzcGxheS01Yjk0 id=1cdbd47b5b94 connected=0"
        })
        defer { board.stop() }
        let started = Date()
        let existing = UsbOnboarder.probeExistingFirmware(port: board.path)
        XCTAssertEqual(existing, .answered(name: "espdisplay-5b94", hardwareID: "1cdbd47b5b94"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    /// A CFGINFO left unread by a racing CFGSHOW is not a setting command's reply.
    func testASettingCommandWaitsPastAStaleCFGINFO() throws {
        let board = try FakeSerialBoard(chunked: { _ in
            ["CFGINFO name64=eA== id=1cdbd47b5b94\n", "CFGOK saved \"Cafe\", restarting\n"]
        })
        defer { board.stop() }
        let result = WifiConfigUI.sendCommand(
            "CFGWIFI Q2FmZQ==", port: board.path, timeout: 3, acceptInfo: false)
        guard case .success(let line) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(line, "CFGOK saved \"Cafe\", restarting")
    }

    /// The live transcript path redacts: the password never reaches the log.
    func testTheSentLineIsRedactedInTheTranscript() throws {
        let board = try FakeSerialBoard(onCommand: { _ in "CFGOK saved\n" })
        defer { board.stop() }
        let logged = LockedLines()
        let command = ConfigCommands.setWifi(ssid: "Cafe", password: .set("hunter22"))
        _ = WifiConfigUI.sendCommand(command, port: board.path, timeout: 3) { _, text in
            logged.append(text)
        }
        XCTAssertEqual(logged.lines.first, "\(board.path): CFGWIFI Q2FmZQ== <hidden>")
        XCTAssertFalse(logged.lines.joined().contains(Data("hunter22".utf8).base64EncodedString()))
    }
}

final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) { lock.withLock { stored.append(line) } }
    var lines: [String] { lock.withLock { stored } }
}

/// The far end of a pseudo-terminal, answering each line written to the near
/// end. The near end's path stands in for /dev/cu.usbmodem*.
final class FakeSerialBoard: @unchecked Sendable {
    let path: String
    private let primary: Int32
    private let keepAlive: Int32
    private let lock = NSLock()
    private var stopped = false
    private let thread: Thread

    convenience init(onCommand: @escaping @Sendable (String) -> String?) throws {
        try self.init(chunked: { onCommand($0).map { [$0] } })
    }

    /// Each answer is written as these chunks, 100 ms apart - one reply arriving
    /// across several reads.
    init(chunked onCommand: @escaping @Sendable (String) -> [String]?) throws {
        let primary = posix_openpt(O_RDWR | O_NOCTTY)
        guard primary >= 0, grantpt(primary) == 0, unlockpt(primary) == 0,
              let name = ptsname(primary)
        else { throw NSError(domain: "FakeSerialBoard", code: Int(errno)) }
        let path = String(cString: name)
        // Held open so each close by the code under test is not a hangup.
        let keepAlive = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard keepAlive >= 0 else { throw NSError(domain: "FakeSerialBoard", code: Int(errno)) }
        var tty = termios()
        tcgetattr(keepAlive, &tty)
        cfmakeraw(&tty)
        tcsetattr(keepAlive, TCSANOW, &tty)
        let flags = fcntl(primary, F_GETFL)
        _ = fcntl(primary, F_SETFL, flags | O_NONBLOCK)
        self.path = path
        self.primary = primary
        self.keepAlive = keepAlive
        var pending = ""
        var stoppedFlag: () -> Bool = { false }
        self.thread = Thread {
            var scratch = [UInt8](repeating: 0, count: 1024)
            while !stoppedFlag() {
                let n = read(primary, &scratch, scratch.count)
                guard n > 0 else { usleep(5_000); continue }
                pending += String(decoding: scratch[0..<n], as: UTF8.self)
                while let newline = pending.firstIndex(of: "\n") {
                    let line = String(pending[..<newline])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    pending = String(pending[pending.index(after: newline)...])
                    for (index, chunk) in (onCommand(line) ?? []).enumerated() {
                        if index > 0 { usleep(100_000) }
                        _ = chunk.withCString { write(primary, $0, strlen($0)) }
                    }
                }
            }
        }
        stoppedFlag = { [unowned self] in self.lock.withLock { self.stopped } }
        thread.start()
    }

    func stop() {
        lock.withLock { stopped = true }
        usleep(20_000)
        close(keepAlive)
        close(primary)
    }
}
