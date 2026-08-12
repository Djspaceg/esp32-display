import Foundation

/// RLE codec for band payloads: PackBits adapted to 16-bit RGB565 pixels.
/// Mirrors the firmware's `rle565` (firmware/display_stream/band_compress.h)
/// byte for byte; both suites assert the wire independently, never through a
/// shared fixture, so a change that breaks interoperability fails a test.
///
/// Encoded stream: a sequence of chunks, each one control byte then data.
///   control 0x00...0x7F: literal run of (control + 1) pixels; the next
///                        2*(control+1) bytes are those pixels verbatim.
///   control 0x80...0xFF: repeat run of (control - 0x80 + 2) copies of the
///                        ONE pixel (2 bytes) that follows.
/// A pixel is two bytes and is never split; the codec treats the pair as
/// opaque, so it works on the wire's big-endian RGB565 without knowing it.
public enum RLE565 {
    /// Largest literal run one control byte can carry, in pixels.
    public static let maxLiteralPixels = 128
    /// Largest repeat run one control byte can carry, in pixels.
    public static let maxRunPixels = 129
    /// Shortest run worth encoding as a repeat.
    public static let minRunPixels = 2

    /// Ceiling on `encode` output for a raw payload size: one control byte
    /// per full-or-partial literal of `maxLiteralPixels`. Mirrors the
    /// firmware's `maxEncodedBytes`, and is what makes "compressed or raw,
    /// whichever is smaller" a bounded decision rather than a hope.
    public static func maxEncodedBytes(rawBytes: Int) -> Int {
        let pixels = rawBytes / 2
        return rawBytes + (pixels + maxLiteralPixels - 1) / maxLiteralPixels
    }

    /// Encode a whole-pixel byte slice. Returns nil for empty or odd-length
    /// input. The output is at most `maxEncodedBytes(rawBytes:)` long; the
    /// caller compares it against the raw length and sends whichever is
    /// smaller.
    public static func encode(_ raw: ArraySlice<UInt8>) -> [UInt8]? {
        let count = raw.count
        guard count > 0, count % 2 == 0 else { return nil }
        let src = Array(raw)
        let pixels = count / 2
        var out = [UInt8]()
        out.reserveCapacity(maxEncodedBytes(rawBytes: count))
        var at = 0  // pixel index
        while at < pixels {
            // Length of the repeat run starting here.
            var run = 1
            while at + run < pixels, run < maxRunPixels,
                  src[(at + run) * 2] == src[at * 2],
                  src[(at + run) * 2 + 1] == src[at * 2 + 1] {
                run += 1
            }
            if run >= minRunPixels {
                out.append(UInt8(0x80 + run - minRunPixels))
                out.append(src[at * 2])
                out.append(src[at * 2 + 1])
                at += run
                continue
            }
            // Literal: scan forward until a repeat begins or the literal fills.
            let start = at
            at += 1
            while at < pixels, at - start < maxLiteralPixels {
                if at + 1 < pixels, src[at * 2] == src[(at + 1) * 2],
                   src[at * 2 + 1] == src[(at + 1) * 2 + 1] {
                    break
                }
                at += 1
            }
            let literal = at - start
            out.append(UInt8(literal - 1))
            out.append(contentsOf: src[(start * 2)..<(at * 2)])
        }
        return out
    }

    /// Decode into exactly `expectedBytes`, or nil.
    ///
    /// Nil for every malformed shape: a chunk that would overrun the expected
    /// size, input that ends mid-chunk, input that ends short, and trailing
    /// bytes past the expected size. The firmware's decoder applies the same
    /// refusals on the receive path; this one exists so the tests can prove
    /// the two agree from this side too.
    public static func decode(_ encoded: [UInt8], expectedBytes: Int) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(expectedBytes)
        var at = 0
        while at < encoded.count {
            let control = Int(encoded[at])
            at += 1
            if control < 0x80 {
                let bytes = (control + 1) * 2
                guard at + bytes <= encoded.count else { return nil }
                guard out.count + bytes <= expectedBytes else { return nil }
                out.append(contentsOf: encoded[at..<(at + bytes)])
                at += bytes
            } else {
                let run = control - 0x80 + minRunPixels
                guard at + 2 <= encoded.count else { return nil }
                guard out.count + run * 2 <= expectedBytes else { return nil }
                let hi = encoded[at]
                let lo = encoded[at + 1]
                at += 2
                for _ in 0..<run {
                    out.append(hi)
                    out.append(lo)
                }
            }
        }
        return out.count == expectedBytes ? out : nil
    }
}

/// Builds packed band packets: several band records per datagram, each raw or
/// RLE-compressed, for panels advertising `Capabilities.compressedBands`.
///
/// Wire layout (mirrors firmware/display_stream/band_protocol.h, "Packed band
/// packets"):
///   [frame_id u16 LE][first_band | 0x8000 u16 LE][dirty_count u16 LE,
///    bit 15 = landscape]
///   then per record:
///     [band u16 LE, bits 15..10 zero][len u16 LE, bit 15 = compressed]
///     [len & 0x7FFF payload bytes]
///
/// Records carry their own band index because dirty bands are usually
/// scattered; requiring consecutive bands would put most changed bands alone
/// in their own datagram and waste the packing. The receiver cross-checks
/// first_band against the first record.
public enum BandPacker {
    /// Whole-datagram budget for a packed packet, header included. Larger
    /// than `PanelGeometry.maxPacketBytes` deliberately: that constant
    /// derives band geometry and cannot move without changing every panel's
    /// wire format, whereas this one only bounds a datagram no old peer ever
    /// sees. 1472 = the conservative 1500-byte Ethernet MTU minus IP+UDP.
    public static let maxPacketBytes = 1472
    /// Per-record header: [band u16][len u16].
    public static let recordHeaderBytes = 4
    /// band_index bit 15 in the packet header: this packet is packed.
    public static let bandIndexPackedFlag: UInt16 = 0x8000
    /// len bit 15 in a record header: the payload is RLE-compressed.
    public static let recordCompressedFlag: UInt16 = 0x8000

    /// One band ready for packing: its index and the cheaper of its two
    /// encodings.
    struct PreparedBand {
        let band: Int
        let compressed: Bool
        let payload: [UInt8]
    }

    /// Build the datagrams that carry `dirty` bands of `pixels`.
    ///
    /// Each band is RLE-encoded and sent compressed only when that is
    /// strictly smaller than raw, so a band of noise costs its raw size plus
    /// the 4-byte record header and nothing more. Bands are packed greedily
    /// in index order: a record that no longer fits closes the packet and
    /// opens the next.
    public static func packets(
        frameId: UInt16, dirty: [Int], pixels: [UInt8],
        geometry: PanelGeometry, landscape: Bool
    ) -> [Data] {
        let headerBytes = PanelGeometry.headerBytes
        var packets = [Data]()
        var current: [PreparedBand] = []
        var currentBytes = headerBytes

        func flush() {
            guard let first = current.first else { return }
            var packet = BandProtocol.packetHeader(
                frameId: frameId, band: first.band | Int(bandIndexPackedFlag),
                dirtyCount: dirty.count, landscape: landscape)
            for record in current {
                let lenField = UInt16(record.payload.count)
                    | (record.compressed ? recordCompressedFlag : 0)
                packet.append(UInt8(record.band & 0xFF))
                packet.append(UInt8(record.band >> 8))
                packet.append(UInt8(lenField & 0xFF))
                packet.append(UInt8(lenField >> 8))
                packet.append(contentsOf: record.payload)
            }
            packets.append(packet)
            current.removeAll(keepingCapacity: true)
            currentBytes = headerBytes
        }

        for band in dirty {
            let start = geometry.bandOffset(index: band, landscape: landscape)
            let rawLen = geometry.bandPayloadBytes(index: band, landscape: landscape)
            let raw = pixels[start..<(start + rawLen)]
            let encoded = RLE565.encode(raw)
            let prepared: PreparedBand
            if let encoded, encoded.count < rawLen {
                prepared = PreparedBand(band: band, compressed: true, payload: encoded)
            } else {
                prepared = PreparedBand(band: band, compressed: false, payload: Array(raw))
            }
            let recordBytes = recordHeaderBytes + prepared.payload.count
            if currentBytes + recordBytes > maxPacketBytes {
                flush()
            }
            current.append(prepared)
            currentBytes += recordBytes
        }
        flush()
        return packets
    }
}
