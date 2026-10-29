import AVFoundation
import CoreAudio
import CryptoKit
import Foundation
import Security
import SenderProtocol

/// ESPDisplayAudio.driver's side of the contract, mirrored from
/// mac/AudioDriver/ESPDisplayAudioProtocol.h. A test reads that header and
/// fails if the two disagree.
enum DisplayAudioDriverProtocol {
    static let version = 3
    static let bundleID = "com.resourcefork.espdisplay.audio-driver"
    static let registerSelector = fourCharCode("ESrg")
    static let versionSelector = fourCharCode("ESvr")
    static let pcmSelector = fourCharCode("ESpc")
    static let ownedSelector = fourCharCode("ESow")
    static let sampleRate = 48_000.0
    static let maxReadFrames = 4_800
    static let maxDevices = 8
    static let maxClients = 8
    static let clientTimeoutSeconds = 10.0
    static let minTokenBytes = 32
    static let uidSuffixBytes = 8

    /// Whether `deviceUID` is the driver's device for `uid` under some owner:
    /// `uid`, a dot, and the 16 hex digits of an owner's suffix.
    static func isDeviceUID(_ deviceUID: String, of uid: String) -> Bool {
        guard deviceUID.hasPrefix(uid + ".") else { return false }
        let suffix = deviceUID.dropFirst(uid.count + 1)
        return suffix.count == 2 * uidSuffixBytes
            && suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The UID macOS lists for a display registered as `uid` by the owner of
    /// `token` (see the protocol header).
    static func deviceUID(for uid: String, token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return uid + "." + digest.prefix(uidSuffixBytes)
            .map { String(format: "%02x", $0) }.joined()
    }

    enum Key {
        static let version = "version"
        static let client = "client"
        static let token = "token"
        static let devices = "devices"
        static let uid = "uid"
        static let name = "name"
        static let latency = "latency"
    }

    static func fourCharCode(_ text: String) -> AudioObjectPropertySelector {
        text.utf8.reduce(0) { $0 << 8 | AudioObjectPropertySelector($1) }
    }
}

/// One display's output device as the driver is asked to create it.
struct DisplayAudioDeviceSpec: Equatable, Sendable {
    let uid: String
    let name: String
    /// What the device reports as its output latency, so a video player
    /// delays its picture by about as long as the display's buffer holds the
    /// sound.
    let latencyFrames: Int

    static let uidPrefix = "com.resourcefork.espdisplay.display."

    /// Stable across launches, so macOS remembers the device as the output
    /// the user chose: the board's hardware ID once known, its record name
    /// before that.
    static func uid(hardwareID: String?, serviceName: String) -> String {
        if let hardwareID, !hardwareID.isEmpty { return uidPrefix + hardwareID }
        return uidPrefix + "service." + serviceName
    }

    static func latencyFrames(tuning: AudioRuntimeTuning) -> Int {
        Int((Double(tuning.validated.downlinkTargetMilliseconds)
            * DisplayAudioDriverProtocol.sampleRate / 1_000).rounded())
    }
}

enum DisplayAudioDriverRegistration {
    /// The 'ESrg' dictionary. An empty list removes this client's devices.
    /// `token` is this launch's secret: it owns the devices and reads them.
    static func payload(
        client: String, token: String, devices: [DisplayAudioDeviceSpec]
    ) -> [String: Any] {
        typealias Key = DisplayAudioDriverProtocol.Key
        return [
            Key.version: DisplayAudioDriverProtocol.version,
            Key.client: client,
            Key.token: token,
            Key.devices: devices.prefix(DisplayAudioDriverProtocol.maxDevices).map {
                [Key.uid: $0.uid, Key.name: $0.name, Key.latency: $0.latencyFrames]
            },
        ]
    }
}

enum DisplayAudioDriverAvailability: Equatable, Sendable {
    case ready
    /// Not installed, or installed but coreaudiod has not loaded it yet.
    case absent
    /// Installed from a different build; the app and the driver would
    /// misread each other.
    case incompatible(version: Int?)
}

/// What the app needs from the driver. Injectable so tests can stand in a
/// driver without coreaudiod.
protocol DisplayAudioDriverBridge: AnyObject, Sendable {
    func availability() -> DisplayAudioDriverAvailability
    /// Replaces this process's devices, and is its heartbeat.
    @discardableResult
    func register(_ devices: [DisplayAudioDeviceSpec]) -> Bool
    /// `uid` is the display's registered UID; the bridge finds the device
    /// macOS lists for it under this app's ownership.
    func deviceID(uid: String) -> AudioObjectID?
    /// The UID macOS lists for this app's device for `uid`, as Sound settings
    /// and the device list name it.
    func deviceUID(for uid: String) -> String
    /// Whether a device for `uid` exists under another owner's suffix: one
    /// this app cannot find by its own UID, so it must look for it. Reads the
    /// whole device list; the router checks the list it already has instead.
    func isClaimedElsewhere(uid: String) -> Bool
    /// How many devices the driver holds, for every owner together.
    func deviceCount() -> Int?
    /// Whether this app owns the device, so the Mac's sound routed to it
    /// reaches this app and no one else. Takes no frames.
    func owns(device: AudioObjectID) -> Bool
    /// Interleaved stereo Float32 mixed for the device since the last read.
    func readFrames(device: AudioObjectID) -> Data?
}

/// The real bridge: CoreAudio property calls to the plug-in and its devices.
final class CoreAudioDisplayAudioDriver: DisplayAudioDriverBridge, @unchecked Sendable {
    static let shared = CoreAudioDisplayAudioDriver()

    /// The process ID alone would be reused by a later launch; the start time
    /// makes a restarted app a new client, so the old one simply expires.
    private let clientID = "ESPDisplaySender.\(getpid()).\(UInt64(Date().timeIntervalSince1970))"
    private let tokenLock = NSLock()
    private var cachedToken: String?

    /// Never leaves this process except to the driver: it is what lets only
    /// this app read the audio the Mac sends to its displays' devices. Kept
    /// in the login Keychain, so a relaunch after a crash is the same owner
    /// at once rather than a stranger for ten seconds, which another process
    /// listing the same display could use to take it. Read on first use, so
    /// a test that never routes never touches the Keychain.
    private var token: String {
        tokenLock.withLock {
            if let cachedToken { return cachedToken }
            let token = DisplayAudioDriverToken.current()
            cachedToken = token
            return token
        }
    }

    func availability() -> DisplayAudioDriverAvailability {
        guard let plugIn = plugInID() else { return .absent }
        var address = Self.address(DisplayAudioDriverProtocol.versionSelector)
        var value: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<CFPropertyList>.size)
        guard AudioObjectGetPropertyData(plugIn, &address, 0, nil, &size, &value) == noErr,
              let number = value?.takeRetainedValue() as? NSNumber
        else { return .incompatible(version: nil) }
        return number.intValue == DisplayAudioDriverProtocol.version
            ? .ready : .incompatible(version: number.intValue)
    }

    func register(_ devices: [DisplayAudioDeviceSpec]) -> Bool {
        guard let plugIn = plugInID() else { return false }
        var address = Self.address(DisplayAudioDriverProtocol.registerSelector)
        let plist = DisplayAudioDriverRegistration.payload(
            client: clientID, token: token, devices: devices) as CFDictionary
        // The property's data is the CFPropertyListRef itself: one pointer.
        var reference = Unmanaged.passUnretained(plist).toOpaque()
        return withExtendedLifetime(plist) {
            AudioObjectSetPropertyData(
                plugIn, &address, 0, nil,
                UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &reference) == noErr
        }
    }

    func deviceUID(for uid: String) -> String {
        DisplayAudioDriverProtocol.deviceUID(for: uid, token: token)
    }

    func deviceCount() -> Int? {
        guard let plugIn = plugInID() else { return nil }
        var address = Self.address(DisplayAudioDriverProtocol.registerSelector)
        var value: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<CFPropertyList>.size)
        guard AudioObjectGetPropertyData(plugIn, &address, 0, nil, &size, &value) == noErr,
              let summary = value?.takeRetainedValue() as? [String: Any],
              let devices = summary[DisplayAudioDriverProtocol.Key.devices] as? [Any]
        else { return nil }
        return devices.count
    }

    func isClaimedElsewhere(uid: String) -> Bool {
        let mine = deviceUID(for: uid)
        return CoreAudioDeviceCatalog.devices().contains {
            $0.option.uid != mine
                && DisplayAudioDriverProtocol.isDeviceUID($0.option.uid, of: uid)
        }
    }

    func deviceID(uid: String) -> AudioObjectID? {
        var address = Self.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = deviceUID(for: uid) as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) {
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    func owns(device: AudioObjectID) -> Bool {
        var address = Self.address(DisplayAudioDriverProtocol.ownedSelector)
        var value: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<CFPropertyList>.size)
        var qualifier = token as CFString
        let status = withUnsafeMutablePointer(to: &qualifier) {
            AudioObjectGetPropertyData(
                device, &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &value)
        }
        guard status == noErr, let number = value?.takeRetainedValue() as? NSNumber
        else { return false }
        return number.intValue == 1
    }

    func readFrames(device: AudioObjectID) -> Data? {
        var address = Self.address(DisplayAudioDriverProtocol.pcmSelector)
        var value: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<CFPropertyList>.size)
        var qualifier = token as CFString
        let status = withUnsafeMutablePointer(to: &qualifier) {
            AudioObjectGetPropertyData(
                device, &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &value)
        }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as? Data
    }

    private func plugInID() -> AudioObjectID? {
        var address = Self.address(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
        var qualifier = DisplayAudioDriverProtocol.bundleID as CFString
        var plugIn = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) {
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), $0, &size, &plugIn)
        }
        guard status == noErr, plugIn != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return plugIn
    }

    private static func address(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
}

/// The app's driver token in the login Keychain.
enum DisplayAudioDriverToken {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.resourcefork.espdisplay.audio-driver",
        kSecAttrAccount as String: "owner-token",
    ]

    enum Lookup: Equatable {
        case found(String)
        /// Nothing saved, or something that is not a token: make one.
        case notFound
        /// Locked, refused or failing: use a token for this launch only and
        /// leave whatever is saved alone.
        case unavailable
    }

    static func lookup() -> Lookup {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        switch SecItemCopyMatching(request as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data,
                  let token = String(data: data, encoding: .utf8),
                  token.utf8.count >= DisplayAudioDriverProtocol.minTokenBytes
            else { return .notFound }
            return .found(token)
        case errSecItemNotFound:
            return .notFound
        default:
            return .unavailable
        }
    }

    /// Only a token that is truly missing is replaced; a Keychain that will
    /// not answer never costs the saved one.
    static func resolve(
        _ lookup: Lookup, fresh: () -> String, save: (String) -> Void
    ) -> String {
        switch lookup {
        case .found(let token):
            return token
        case .notFound:
            let token = fresh()
            save(token)
            return token
        case .unavailable:
            return fresh()
        }
    }

    static func current() -> String {
        resolve(lookup(), fresh: fresh, save: save)
    }

    static func fresh() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString + UUID().uuidString
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func save(_ token: String) {
        let data = Data(token.utf8)
        let updated = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecItemNotFound else { return }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }
}

/// What macOS plays to a display's own output device, read from the driver.
///
/// Stands in for the process tap behind the same `SystemAudioTap` interface,
/// so the session's ring, converter, drift correction and silence fill are the
/// ones the tap already uses. The driver is polled every 10 ms; while nothing
/// plays to the device there is nothing to read, and the session's own
/// silence fill keeps the display's audio running.
final class DisplayAudioDeviceTap: SystemAudioTap, @unchecked Sendable {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: DisplayAudioDriverProtocol.sampleRate,
        channels: 2, interleaved: true)!

    private let bridge: DisplayAudioDriverBridge
    private let device: AudioObjectID
    private let queue = DispatchQueue(label: "espdisp.audio.driver-read")
    private var timer: DispatchSourceTimer?
    static let pollMilliseconds = 10

    private static let claimed = NSError(
        domain: "ESPDisplaySender.Audio",
        code: 6,
        userInfo: [NSLocalizedDescriptionKey:
            "the device's output belongs to another app on this Mac."])

    init(bridge: DisplayAudioDriverBridge, uid: String) throws {
        guard let device = bridge.deviceID(uid: uid) else {
            if bridge.isClaimedElsewhere(uid: uid) { throw Self.claimed }
            throw NSError(
                domain: "ESPDisplaySender.Audio",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey:
                    "the device's output has not appeared in macOS yet."])
        }
        guard bridge.owns(device: device) else { throw Self.claimed }
        self.bridge = bridge
        self.device = device
    }

    deinit { stop() }

    func start(_ deliver: @escaping (UnsafePointer<AudioBufferList>) -> Void) throws {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(), repeating: .milliseconds(Self.pollMilliseconds),
            leeway: .milliseconds(2))
        let bridge = bridge
        let device = device
        timer.setEventHandler {
            guard var data = bridge.readFrames(device: device), !data.isEmpty else { return }
            let count = data.count - data.count % 8
            guard count > 0 else { return }
            data.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(count),
                        mData: bytes.baseAddress))
                deliver(&list)
            }
        }
        self.timer = timer
        timer.resume()
    }

    /// Returns once no read is in flight, so nothing is delivered after it.
    func stop() {
        guard let timer else { return }
        timer.cancel()
        self.timer = nil
        queue.sync {}
    }
}

extension SystemAudioCaptureSource {
    static func displayDevice(
        uid: String, bridge: DisplayAudioDriverBridge = CoreAudioDisplayAudioDriver.shared
    ) -> SystemAudioCaptureSource {
        SystemAudioCaptureSource(open: { try DisplayAudioDeviceTap(bridge: bridge, uid: uid) })
    }
}

extension SystemAudioAccess {
    /// A display's own output device needs no recording permission: macOS
    /// hands its sound to the driver because the user sent it there.
    static let notRequired = SystemAudioAccess(status: { .authorized }, request: nil)
}
