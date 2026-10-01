import AVFoundation
import CoreAudio
import Darwin
import XCTest

@testable import SenderCore
@testable import SenderProtocol

final class SnapshotLog: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots = [PanelAudioSnapshot]()

    func append(_ snapshot: PanelAudioSnapshot) {
        lock.withLock { snapshots.append(snapshot) }
    }

    var all: [PanelAudioSnapshot] { lock.withLock { snapshots } }
    var last: PanelAudioSnapshot? { all.last }

    func waitFor(
        timeoutSeconds: Double = 2,
        _ predicate: (PanelAudioSnapshot) -> Bool
    ) -> PanelAudioSnapshot? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            if let match = all.last(where: predicate) { return match }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        return nil
    }
}

/// A UDP socket on 127.0.0.1 standing in for the panel's audio port. It
/// remembers who last sent to it, so it can answer with uplink packets the
/// way the firmware does after `claimPeer`.
final class LoopbackPanel: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var peer: sockaddr_in?
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        self.fd = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    func receive(timeoutSeconds: Int) -> Data? {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 2_048)
        var from = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
            }
        }
        guard count > 0 else { return nil }
        lock.withLock { peer = from }
        return Data(buffer.prefix(count))
    }

    /// Downlink PCM until `timeoutSeconds`, decoded, in arrival order.
    func receiveDownlink(
        timeoutSeconds: Double, until done: ([AudioProtocol.PCM]) -> Bool
    ) -> [AudioProtocol.PCM] {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var packets = [AudioProtocol.PCM]()
        while Date() < deadline, !done(packets) {
            guard let datagram = receive(timeoutSeconds: 1),
                  case .pcm(let pcm)? = try? AudioProtocol.decode(datagram),
                  pcm.kind == .pcmDownlink
            else { continue }
            packets.append(pcm)
        }
        return packets
    }

    /// Answer the last sender, as the panel answers the Mac it claimed.
    @discardableResult
    func send(_ data: Data) -> Bool {
        guard var to = lock.withLock({ peer }) else { return false }
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        fd, bytes.baseAddress, bytes.count, 0, $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == data.count
    }

    func close() { Darwin.close(fd) }
}

/// Little-endian PCM16 payload samples.
func pcm16Samples(_ data: Data) -> [Int16] {
    let bytes = [UInt8](data)
    return stride(from: 0, to: bytes.count - 1, by: 2).map {
        Int16(bitPattern: UInt16(bytes[$0]) | (UInt16(bytes[$0 + 1]) << 8))
    }
}

/// A tap that delivers a constant level per channel (`levels[channel]`),
/// every 10 ms, from its own thread, through the same `AudioBufferList` path
/// the real tap uses. Distinct levels show a swapped or duplicated channel.
/// No real audio is recorded.
final class ConstantSystemAudioTap: SystemAudioTap, @unchecked Sendable {
    let format: AVAudioFormat
    let levels: [Float]
    private let lock = NSLock()
    private var thread: Thread?
    private var running = false
    private(set) var started = 0

    /// Seconds between IO cycles; each cycle carries that much audio.
    let cycleSeconds: Double

    init(
        levels: [Float], sampleRate: Double, interleaved: Bool,
        cycleSeconds: Double = 0.01
    ) {
        self.levels = levels
        self.cycleSeconds = cycleSeconds
        let channels = UInt32(levels.count)
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: channels, interleaved: interleaved)!
    }

    func start(_ deliver: @escaping (UnsafePointer<AudioBufferList>) -> Void) throws {
        let frames = AVAudioFrameCount(format.sampleRate * cycleSeconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for (bufferIndex, audio) in list.enumerated() {
            let samples = Int(audio.mDataByteSize) / 4
            let pointer = audio.mData!.assumingMemoryBound(to: Float.self)
            for index in 0..<samples {
                pointer[index] = format.isInterleaved
                    ? levels[index % levels.count]
                    : levels[bufferIndex]
            }
        }
        lock.withLock {
            running = true
            started += 1
        }
        let cycle = cycleSeconds
        let thread = Thread { [weak self] in
            // Paced against the clock, so cycles do not drift slow.
            var next = Date()
            while self?.isRunning == true {
                deliver(buffer.audioBufferList)
                next = next.addingTimeInterval(cycle)
                Thread.sleep(until: next)
            }
        }
        self.thread = thread
        thread.start()
    }

    private var isRunning: Bool { lock.withLock { running } }

    func stop() { lock.withLock { running = false } }
}

/// Records what the session hands the display-microphone sink.
final class RecordingUplinkSink: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = [Float]()

    var sink: PanelUplinkSink {
        PanelUplinkSink(deliver: { [self] samples, _ in
            lock.withLock { self.samples.append(contentsOf: samples) }
        })
    }

    var received: [Float] { lock.withLock { samples } }
}

/// A tap that opens and starts but never delivers an IO cycle, as an idle or
/// misbehaving aggregate might.
final class QuietSystemAudioTap: SystemAudioTap, @unchecked Sendable {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
        channels: 2, interleaved: false)!

    func start(_ deliver: @escaping (UnsafePointer<AudioBufferList>) -> Void) throws {}
    func stop() {}
}
