// Checks an installed ESPDisplayAudio.driver end to end inside coreaudiod,
// without ESPDisplaySender: registers a test device, plays a quiet 440 Hz tone
// into it, and reads the tone back through the driver's PCM property. The
// test device is a virtual output, so nothing is heard, and it is removed on
// exit. Run with: swift mac/AudioDriver/check-driver.swift
import AudioToolbox
import CoreAudio
import CryptoKit
import Foundation

let bundleID = "com.espdisplay.audio-driver"
let testUID = "com.espdisplay.check-driver.\(getpid())"
func code(_ s: String) -> AudioObjectPropertySelector {
    s.utf8.reduce(0) { $0 << 8 | AudioObjectPropertySelector($1) }
}
let register = code("ESrg"), version = code("ESvr"), pcm = code("ESpc")

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
}

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

var translate = address(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
var plugIn = AudioObjectID(kAudioObjectUnknown)
var size = UInt32(MemoryLayout<AudioObjectID>.size)
var bundle = bundleID as CFString
let found = withUnsafeMutablePointer(to: &bundle) { qualifier in
    AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &translate,
        UInt32(MemoryLayout<CFString>.size), qualifier, &size, &plugIn)
}
guard found == noErr, plugIn != kAudioObjectUnknown else {
    fail("the driver is not loaded (status \(found)); is it installed, and was coreaudiod restarted?")
}
print("plug-in object \(plugIn)")

var versionAddress = address(version)
var versionValue: Unmanaged<CFPropertyList>?
size = UInt32(MemoryLayout<CFPropertyList>.size)
guard AudioObjectGetPropertyData(plugIn, &versionAddress, 0, nil, &size, &versionValue) == noErr,
      let number = versionValue?.takeRetainedValue() as? NSNumber
else { fail("the protocol version did not read") }
print("protocol version \(number)")

// This run's secret: it owns the test device, and only it reads the device.
let token = UUID().uuidString + UUID().uuidString
// The UID macOS lists for a display an owner registered (protocol header).
func deviceUID(_ uid: String, _ owner: String) -> String {
    uid + "." + SHA256.hash(data: Data(owner.utf8)).prefix(8)
        .map { String(format: "%02x", $0) }.joined()
}
func send(_ devices: [[String: Any]]) -> OSStatus {
    var registerAddress = address(register)
    let plist = [
        "version": 3, "client": "check-driver.\(getpid())", "token": token,
        "devices": devices,
    ] as CFDictionary
    var reference = Unmanaged.passUnretained(plist).toOpaque()
    return withExtendedLifetime(plist) {
        AudioObjectSetPropertyData(
            plugIn, &registerAddress, 0, nil,
            UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &reference)
    }
}
let registered = send([["uid": testUID, "name": "ESPDisplay driver check", "latency": 0]])
guard registered == noErr else { fail("registration was refused (status \(registered))") }
defer { _ = send([]) }

var device = AudioObjectID(kAudioObjectUnknown)
for _ in 0..<50 where device == kAudioObjectUnknown {
    var uidAddress = address(kAudioHardwarePropertyTranslateUIDToDevice)
    var uid = deviceUID(testUID, token) as CFString
    size = UInt32(MemoryLayout<AudioObjectID>.size)
    _ = withUnsafeMutablePointer(to: &uid) { qualifier in
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &uidAddress,
            UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device)
    }
    if device == kAudioObjectUnknown { Thread.sleep(forTimeInterval: 0.1) }
}
guard device != kAudioObjectUnknown else { fail("the test device never appeared") }
print("test device \(device) appeared")

func readPCM(as reader: String? = token) -> (OSStatus, [Float]) {
    var pcmAddress = address(pcm)
    var value: Unmanaged<CFPropertyList>?
    var size = UInt32(MemoryLayout<CFPropertyList>.size)
    var status: OSStatus
    if let reader {
        var qualifier = reader as CFString
        status = withUnsafeMutablePointer(to: &qualifier) {
            AudioObjectGetPropertyData(
                device, &pcmAddress, UInt32(MemoryLayout<CFString>.size), $0, &size, &value)
        }
    } else {
        status = AudioObjectGetPropertyData(device, &pcmAddress, 0, nil, &size, &value)
    }
    guard status == noErr, let data = value?.takeRetainedValue() as? Data else {
        return (status, [])
    }
    return (status, data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
}

// A tone at -20 dBFS, played through an output unit pinned to the test device.
var description = AudioComponentDescription(
    componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0,
    componentFlagsMask: 0)
guard let component = AudioComponentFindNext(nil, &description) else { fail("no HAL output unit") }
var unit: AudioUnit?
guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else {
    fail("the output unit did not open")
}
var target = device
AudioUnitSetProperty(
    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &target,
    UInt32(MemoryLayout<AudioObjectID>.size))
var format = AudioStreamBasicDescription(
    mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
    mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32,
    mReserved: 0)
AudioUnitSetProperty(
    unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format,
    UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
final class Phase { var value = 0.0 }
let phase = Phase()
var callback = AURenderCallbackStruct(
    inputProc: { context, _, _, _, frames, list in
        let phase = Unmanaged<Phase>.fromOpaque(context).takeUnretainedValue()
        let buffers = UnsafeMutableAudioBufferListPointer(list!)
        let samples = buffers[0].mData!.assumingMemoryBound(to: Float.self)
        for frame in 0..<Int(frames) {
            let value = Float(0.1 * sin(phase.value))
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
            phase.value += 2 * .pi * 440 / 48_000
        }
        return noErr
    },
    inputProcRefCon: Unmanaged.passUnretained(phase).toOpaque())
AudioUnitSetProperty(
    unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
    UInt32(MemoryLayout<AURenderCallbackStruct>.size))
guard AudioUnitInitialize(unit) == noErr, AudioOutputUnitStart(unit) == noErr else {
    fail("the tone did not start")
}

_ = readPCM()
var samples = [Float]()
let deadline = Date().addingTimeInterval(1)
while Date() < deadline {
    samples += readPCM().1
    Thread.sleep(forTimeInterval: 0.01)
}
// The read is private to the token that registered the device.
let (anonymous, _) = readPCM(as: nil)
let (wrong, _) = readPCM(as: UUID().uuidString + UUID().uuidString)
print("read without a token: status \(anonymous); with another token: status \(wrong)")
guard anonymous != noErr, wrong != noErr else {
    fail("the device's audio could be read without its owner's token")
}

// A second client listing the same display gets no access to it and cannot
// rename it, inside the real coreaudiod.
let otherToken = UUID().uuidString + UUID().uuidString
var otherAddress = address(register)
let other = [
    "version": 3, "client": "check-driver.other.\(getpid())", "token": otherToken,
    "devices": [["uid": testUID, "name": "Taken over", "latency": 0]],
] as CFDictionary
var otherReference = Unmanaged.passUnretained(other).toOpaque()
let otherStatus: OSStatus = withExtendedLifetime(other) {
    AudioObjectSetPropertyData(
        plugIn, &otherAddress, 0, nil,
        UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &otherReference)
}
guard otherStatus == noErr else {
    fail("the second client's registration was refused (status \(otherStatus)), "
        + "so the check below would prove nothing")
}
Thread.sleep(forTimeInterval: 0.3)
let (stolen, _) = readPCM(as: otherToken)
var nameAddress = address(kAudioObjectPropertyName)
var nameValue: Unmanaged<CFString>?
size = UInt32(MemoryLayout<CFString>.size)
let nameStatus = AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &size, &nameValue)
guard nameStatus == noErr, let name = nameValue?.takeRetainedValue() as String? else {
    fail("the test device's name did not read (status \(nameStatus))")
}

func owns(_ reader: String) -> Bool? {
    var ownedAddress = address(code("ESow"))
    var value: Unmanaged<CFPropertyList>?
    var size = UInt32(MemoryLayout<CFPropertyList>.size)
    var qualifier = reader as CFString
    let status = withUnsafeMutablePointer(to: &qualifier) {
        AudioObjectGetPropertyData(
            device, &ownedAddress, UInt32(MemoryLayout<CFString>.size), $0, &size, &value)
    }
    guard status == noErr, let number = value?.takeRetainedValue() as? NSNumber else {
        return nil
    }
    return number.intValue == 1
}
let mine = owns(token), theirs = owns(otherToken)
print("second client: read status \(stolen), name \"\(name)\", "
    + "ESow mine \(String(describing: mine)) theirs \(String(describing: theirs))")
let goodbye = [
    "version": 3, "client": "check-driver.other.\(getpid())", "token": otherToken,
    "devices": [[String: Any]](),
] as CFDictionary
var goodbyeReference = Unmanaged.passUnretained(goodbye).toOpaque()
_ = withExtendedLifetime(goodbye) {
    AudioObjectSetPropertyData(
        plugIn, &otherAddress, 0, nil,
        UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &goodbyeReference)
}
guard stolen != noErr, name == "ESPDisplay driver check" else {
    fail("a second client listing the same display could read or rename it")
}
guard mine == true, theirs == false else {
    fail("'ESow' did not report this run as the owner and the second client as not")
}
AudioOutputUnitStop(unit)
AudioComponentInstanceDispose(unit)

let frames = samples.count / 2
let peak = samples.map(abs).max() ?? 0
let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(max(1, samples.count)))
print("read \(frames) frames in 1 s, peak \(peak), rms \(rms)")
guard frames > 40_000 else { fail("expected about 48000 frames a second, read \(frames)") }
guard abs(peak - 0.1) < 0.01, abs(rms - 0.0707) < 0.01 else {
    fail("the tone did not come back at its level")
}
print("PASS: the driver carries audio from a CoreAudio client to its PCM property")
