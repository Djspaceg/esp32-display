import AVFoundation
import CoreAudio
import Darwin
import Foundation
import Synchronization

/// Whether this app may record the Mac's sound output: the "System Audio
/// Recording Only" list under Privacy & Security > Screen & System Audio
/// Recording.
enum SystemAudioPermission: Equatable, Sendable {
    case authorized
    case denied
    case notDetermined
    /// No way to ask ahead of time. The tap is opened anyway, and opening it
    /// is what raises the macOS prompt.
    case unknown
}

/// The permission check, injectable so a test can refuse it without touching
/// the real setting.
///
/// macOS has no public call that reads or requests this permission; it only
/// prompts when a tap starts and otherwise hands a refused app silence. So
/// `.system` asks TCC directly through `TCCAccessPreflight` and
/// `TCCAccessRequest`, looked up at run time, which is the only way to tell a
/// refusal from a quiet Mac and say so. If a later macOS drops either symbol,
/// the status reads `.unknown` and the tap's own prompt still works.
struct SystemAudioAccess: Sendable {
    let status: @Sendable () -> SystemAudioPermission
    /// Nil when there is no way to ask before opening the tap.
    let request: (@Sendable (@escaping @Sendable (Bool) -> Void) -> Void)?

    static let system: SystemAudioAccess = {
        guard let tcc = TCCAudioCapture.load() else {
            return SystemAudioAccess(status: { .unknown }, request: nil)
        }
        return SystemAudioAccess(
            status: { tcc.preflight() },
            request: { completion in tcc.request(completion) })
    }()

    /// A compatibility request for a macOS release that cannot expose TCC's
    /// preflight symbols. Opening a real process tap is the same protected
    /// operation the sender performs, so macOS can show its own prompt. It
    /// cannot prove the TCC decision because a refused tap may still yield
    /// silence. The temporary tap is stopped and released immediately.
    static func requestWithProcessTap(completion: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let tap = try CoreAudioProcessTap()
                try tap.start { _ in }
                tap.stop()
            } catch {
                // The caller records that this compatibility path could not
                // verify a decision either way and leaves its recovery action
                // visible.
            }
            completion()
        }
    }
}

/// TCC's own entry points, as `dlsym` finds them. Internal, with raw-pointer
/// construction, so a test can stand in functions that behave as TCC does.
struct TCCAudioCapture: Sendable {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    // @escaping: TCC keeps the block and answers when the user does. A
    // non-escaping block trapped as soon as the call returned.
    private typealias Request = @convention(c) (
        CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void
    ) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private let preflightFunction: Preflight
    private let requestFunction: Request

    static func load() -> TCCAudioCapture? {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC",
            RTLD_NOW),
            let preflight = dlsym(handle, "TCCAccessPreflight"),
            let request = dlsym(handle, "TCCAccessRequest")
        else { return nil }
        return TCCAudioCapture(preflight: preflight, request: request)
    }

    init(preflight: UnsafeMutableRawPointer, request: UnsafeMutableRawPointer) {
        preflightFunction = unsafeBitCast(preflight, to: Preflight.self)
        requestFunction = unsafeBitCast(request, to: Request.self)
    }

    func preflight() -> SystemAudioPermission {
        // 0 granted, 1 denied, 2 not yet asked. Anything else is a read
        // error, which must not look like a revoked permission.
        switch preflightFunction(Self.service, nil) {
        case 0: return .authorized
        case 1: return .denied
        case 2: return .notDetermined
        default: return .unknown
        }
    }

    func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        requestFunction(Self.service, nil) { completion($0) }
    }
}

/// A running source of the Mac's sound. `format` is what `start` delivers:
/// Float32, one or two channels, interleaved or not.
protocol SystemAudioTap: AnyObject {
    var format: AVAudioFormat { get }
    /// `deliver` runs on the realtime IO thread, so it must not allocate,
    /// lock or block.
    func start(
        _ deliver: @escaping (UnsafePointer<AudioBufferList>) -> Void) throws
    func stop()
}

/// Opens the Mac's sound output. Injectable so a test can stand in a known
/// waveform, or a Mac where the tap cannot be created, without recording the
/// real output.
struct SystemAudioCaptureSource: Sendable {
    let open: @Sendable () throws -> SystemAudioTap

    static let system = SystemAudioCaptureSource(open: { try CoreAudioProcessTap() })
}

/// The UID prefix of the private aggregate device each tap runs on. The
/// device catalog hides these: they come and go with every session restart,
/// and a route change is itself a restart, so listing them would loop.
enum SystemAudioTapIdentity {
    static let aggregateUIDPrefix = "com.resourcefork.espdisplay.system-audio-tap."

    static func isOwnAggregate(uid: String) -> Bool {
        uid.hasPrefix(aggregateUIDPrefix)
    }
}

/// A Core Audio process tap on everything the Mac plays, except this app.
///
/// The tap is unmuted, so the Mac's own speakers keep playing exactly as
/// before; it only listens. It runs on a private aggregate device that holds
/// the tap and nothing else, so the IO cycle's input is the tap alone: no
/// real device's inputs can come first in the buffer list, and no headset is
/// switched into its microphone mode. The session rebuilds it when the output
/// route changes.
final class CoreAudioProcessTap: SystemAudioTap {
    let format: AVAudioFormat
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init() throws {
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: Self.ownProcessObjects())
        // Excluding by bundle ID as well covers the window before this
        // process has a CoreAudio process object to name.
        if let bundleID = Bundle.main.bundleIdentifier {
            description.bundleIDs = [bundleID]
        }
        description.name = "ESPDisplaySender device speaker"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try Self.check(
            AudioHardwareCreateProcessTap(description, &tapID),
            "macOS could not create a tap on this Mac's sound")
        self.tapID = tapID

        do {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var stream = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(
                AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &stream),
                "macOS did not report the format of this Mac's sound")
            guard stream.mFormatID == kAudioFormatLinearPCM,
                  stream.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  stream.mBitsPerChannel == 32,
                  (1...2).contains(stream.mChannelsPerFrame),
                  let format = AVAudioFormat(streamDescription: &stream)
            else {
                throw Self.failure(
                    "this Mac's sound arrives in a format other than 32-bit "
                        + "float mono or stereo")
            }
            self.format = format

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "ESPDisplaySender device speaker",
                kAudioAggregateDeviceUIDKey:
                    SystemAudioTapIdentity.aggregateUIDPrefix + UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            var aggregateID = AudioObjectID(kAudioObjectUnknown)
            try Self.check(
                AudioHardwareCreateAggregateDevice(
                    aggregate as CFDictionary, &aggregateID),
                "macOS could not open a device to read this Mac's sound")
            self.aggregateID = aggregateID
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            self.tapID = AudioObjectID(kAudioObjectUnknown)
            throw error
        }
    }

    deinit {
        stop()
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    func start(
        _ deliver: @escaping (UnsafePointer<AudioBufferList>) -> Void
    ) throws {
        stop()
        var procID: AudioDeviceIOProcID?
        try Self.check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) {
                _, input, _, _, _ in
                deliver(input)
            },
            "macOS could not start reading this Mac's sound")
        guard let procID else {
            throw Self.failure("macOS could not start reading this Mac's sound")
        }
        self.procID = procID
        do {
            try Self.check(
                AudioDeviceStart(aggregateID, procID),
                "macOS could not start reading this Mac's sound")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        self.procID = nil
    }

    private static func ownProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr, object != AudioObjectID(kAudioObjectUnknown)
        else { return [] }
        return [object]
    }

    private static func check(_ status: OSStatus, _ message: String) throws {
        guard status != noErr else { return }
        throw failure("\(message) (CoreAudio error \(status)).")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(
            domain: "ESPDisplaySender.Audio",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Writes one tap IO cycle into the capture ring from the realtime thread:
/// split into ring-sized slots, and deinterleaved through scratch allocated
/// up front, so the IO thread never allocates.
///
/// The layout is read from the buffer list itself, not from the tap's
/// reported format, so one interleaved buffer and one buffer per channel both
/// work. Any other shape is not the tap's: it is skipped and counted.
final class SystemAudioRingWriter: @unchecked Sendable {
    private let lease: AudioCaptureRingCallbackLease
    private let channels: Int
    private let slotFrames: Int
    private let scratchZero: UnsafeMutablePointer<Float>
    private let scratchOne: UnsafeMutablePointer<Float>
    private let skippedLists = Atomic<UInt64>(0)

    init(
        lease: AudioCaptureRingCallbackLease,
        channels: Int,
        slotFrames: Int
    ) {
        self.lease = lease
        self.channels = channels
        self.slotFrames = max(1, slotFrames)
        scratchZero = .allocate(capacity: self.slotFrames)
        scratchOne = .allocate(capacity: self.slotFrames)
    }

    deinit {
        scratchZero.deallocate()
        scratchOne.deallocate()
    }

    /// IO cycles whose buffer list was not shaped like the tap's.
    var skipped: UInt64 { skippedLists.load(ordering: .relaxed) }

    func write(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: list))
        if buffers.count == 1, Int(buffers[0].mNumberChannels) == channels,
           let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
            writeInterleaved(
                data, frames: Int(buffers[0].mDataByteSize) / (channels * 4))
            return
        }
        if buffers.count == channels,
           buffers.allSatisfy({ $0.mNumberChannels == 1 && $0.mData != nil }),
           let zero = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
            let one = channels > 1
                ? buffers[1].mData?.assumingMemoryBound(to: Float.self)
                : nil
            let frames = Int(buffers[0].mDataByteSize) / 4
            var offset = 0
            while offset < frames {
                let count = min(slotFrames, frames - offset)
                _ = lease.write(
                    channelZero: zero + offset,
                    channelOne: one.map { $0 + offset },
                    frameCount: UInt32(count))
                offset += count
            }
            return
        }
        skippedLists.add(1, ordering: .relaxed)
    }

    private func writeInterleaved(_ data: UnsafeMutablePointer<Float>, frames: Int) {
        let stride = channels
        var offset = 0
        while offset < frames {
            let count = min(slotFrames, frames - offset)
            let base = data + offset * stride
            for frame in 0..<count {
                scratchZero[frame] = base[frame * stride]
                scratchOne[frame] = base[frame * stride + stride - 1]
            }
            _ = lease.write(
                channelZero: scratchZero,
                channelOne: channels > 1 ? scratchOne : nil,
                frameCount: UInt32(count))
            offset += count
        }
    }
}
