import SenderAudioRT

/// Owns the C ring for as long as either the session or an installed tap
/// closure can reach it. A callback captures this object, never the raw pointer.
final class AudioCaptureRingLifetime: @unchecked Sendable {
    private let ring: OpaquePointer
    private let onDestroy: (() -> Void)?

    init?(
        slotCount: UInt32,
        maximumFrames: UInt32,
        channels: UInt32,
        onDestroy: (() -> Void)? = nil
    ) {
        guard let ring = ESPAudioCaptureRingCreate(
            slotCount, maximumFrames, channels)
        else { return nil }
        self.ring = ring
        self.onDestroy = onDestroy
    }

    deinit {
        ESPAudioCaptureRingSetAccepting(ring, false)
        ESPAudioCaptureRingQuiesce(ring)
        ESPAudioCaptureRingDestroy(ring)
        onDestroy?()
    }

    func setAccepting(_ accepting: Bool) {
        ESPAudioCaptureRingSetAccepting(ring, accepting)
    }

    func write(
        channelZero: UnsafePointer<Float>,
        channelOne: UnsafePointer<Float>?,
        frameCount: UInt32
    ) -> Bool {
        ESPAudioCaptureRingWrite(
            ring, channelZero, channelOne, frameCount)
    }

    func read(
        channelZero: UnsafeMutablePointer<Float>,
        channelOne: UnsafeMutablePointer<Float>?,
        frameCapacity: UInt32,
        frameCount: UnsafeMutablePointer<UInt32>
    ) -> Bool {
        ESPAudioCaptureRingRead(
            ring,
            channelZero,
            channelOne,
            frameCapacity,
            frameCount)
    }

    var dropped: UInt64 {
        ESPAudioCaptureRingDropped(ring)
    }
}
