import SenderAudioRT

/// Owns the C ring. Tap closures capture a separate lease, so deinit can wait
/// until no dispatched callback or entered writer can still reach the pointer.
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

    func makeCallbackLease() -> AudioCaptureRingCallbackLease {
        AudioCaptureRingCallbackLease(ring: ring)
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

/// The tap closure owns this lease from installation until every dispatched
/// invocation has returned. Releasing it is an atomic operation; destruction
/// remains the owner's responsibility after the quiesce barrier.
final class AudioCaptureRingCallbackLease: @unchecked Sendable {
    private let ring: OpaquePointer

    fileprivate init(ring: OpaquePointer) {
        self.ring = ring
        ESPAudioCaptureRingRetainCallback(ring)
    }

    deinit {
        ESPAudioCaptureRingReleaseCallback(ring)
    }

    func write(
        channelZero: UnsafePointer<Float>,
        channelOne: UnsafePointer<Float>?,
        frameCount: UInt32
    ) -> Bool {
        ESPAudioCaptureRingWrite(
            ring, channelZero, channelOne, frameCount)
    }
}
