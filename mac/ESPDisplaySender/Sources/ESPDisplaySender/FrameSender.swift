import Foundation
import Network

/// Sends raw RGB565 (big-endian) frames to the ESP32 over UDP, chunked to
/// match the firmware protocol:
///   packet = [frame_id u16 LE][chunk_index u16 LE][chunk_count u16 LE][1376B payload]
/// 1376 bytes = 4 rows of 172 RGB565 pixels; 80 chunks per frame.
final class FrameSender {
    static let frameBytes = 172 * 320 * 2  // 110_080
    static let chunkPayload = 1376
    static let chunkCount = frameBytes / chunkPayload  // 80

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "espdisp.sender")
    private var frameId: UInt16 = 0
    private let spacingMicros: UInt32

    private(set) var framesSent: UInt64 = 0
    private(set) var sendErrors: UInt64 = 0

    var isReady: Bool {
        connection.state == .ready
    }

    init(host: String, port: UInt16, spacingMicros: UInt32 = 0) {
        self.spacingMicros = spacingMicros
        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: params
        )
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed {
                        resumed = true
                        cont.resume()
                    }
                case .failed(let error):
                    if !resumed {
                        resumed = true
                        cont.resume(throwing: error)
                    } else {
                        FileHandle.standardError.write(
                            Data("UDP connection failed: \(error)\n".utf8))
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Send one full frame. `pixels` must be exactly 110,080 bytes of
    /// big-endian RGB565. The top bit of the chunk_count header field
    /// carries orientation (0 = portrait 172x320, 1 = landscape 320x172).
    /// Synchronous chunking; sends are async on the connection's queue.
    func send(frame pixels: [UInt8], landscape: Bool = false) {
        precondition(pixels.count == Self.frameBytes, "bad frame size \(pixels.count)")
        let id = frameId
        frameId &+= 1
        let countField = UInt16(Self.chunkCount) | (landscape ? 0x8000 : 0)

        for chunk in 0..<Self.chunkCount {
            var packet = Data(capacity: 6 + Self.chunkPayload)
            packet.append(UInt8(id & 0xFF))
            packet.append(UInt8(id >> 8))
            packet.append(UInt8(chunk & 0xFF))
            packet.append(UInt8(chunk >> 8))
            packet.append(UInt8(countField & 0xFF))
            packet.append(UInt8(countField >> 8))
            let start = chunk * Self.chunkPayload
            packet.append(contentsOf: pixels[start..<(start + Self.chunkPayload)])

            connection.send(
                content: packet,
                completion: .contentProcessed { [weak self] error in
                    if error != nil {
                        self?.sendErrors &+= 1
                    }
                })
            // Pace every packet: the ESP32's lwIP UDP receive mailbox is only
            // a handful of packets deep, so an unpaced 80-packet burst is
            // mostly dropped on the device. ~250us/packet = ~20ms/frame,
            // matching the ESP32's ~5.5MB/s ingest ceiling.
            if spacingMicros > 0 {
                usleep(spacingMicros)
            }
        }
        framesSent &+= 1
    }
}
