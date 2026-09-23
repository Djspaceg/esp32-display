import Foundation
import SenderProtocol

enum AudioSessionReconciliation: Equatable {
    case keep
    case remove
    case install(AudioStreamDescriptor)
}

enum AudioSessionReconciler {
    static func decide(
        current: AudioStreamDescriptor?,
        advertisement: AudioAdvertisement
    ) -> AudioSessionReconciliation {
        switch advertisement {
        case .unknown:
            return .keep
        case .unavailable:
            return current == nil ? .keep : .remove
        case .available(let descriptor):
            return descriptor == current ? .keep : .install(descriptor)
        }
    }
}

struct PanelPeerAddressSnapshot: Equatable, Sendable {
    let address: String?
    let generation: UInt64
}

/// One locked address generation shared by video reconnection and audio.
final class PanelPeerAddress: @unchecked Sendable {
    private let lock = NSLock()
    private var address: String?
    private var generation: UInt64 = 0

    func publish(_ address: String?) {
        lock.withLock {
            self.address = address
            generation &+= 1
        }
    }

    var snapshot: PanelPeerAddressSnapshot {
        lock.withLock {
            PanelPeerAddressSnapshot(address: address, generation: generation)
        }
    }
}

/// Thread-safe wrapper around the pure rolling budget. Audio records first;
/// the video sender asks how much spacing remains for each datagram.
final class PanelRadioBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var policy: AudioFirstRadioBudget

    init(tuning: AudioRuntimeTuning = AudioRuntimeTuning()) {
        policy = AudioFirstRadioBudget(tuning: tuning)
    }

    func update(tuning: AudioRuntimeTuning) {
        lock.withLock {
            policy.update(tuning: tuning)
        }
    }

    func recordAudioDatagram(bytes: Int, nowNanos: UInt64) {
        lock.withLock {
            policy.recordAudioDatagram(bytes: bytes, nowNanos: nowNanos)
        }
    }

    func videoSpacingNanos(
        baseSpacingMicros: UInt32,
        packetBytes: Int,
        nowNanos: UInt64
    ) -> UInt64 {
        lock.withLock {
            policy.videoSpacingNanos(
                baseSpacingMicros: baseSpacingMicros,
                packetBytes: packetBytes,
                nowNanos: nowNanos)
        }
    }
}
