import AVFoundation
import CoreGraphics
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import ImageIO
import SenderProtocol

/// Reassembles one ECAM JPEG at a time. Frames are deliberately newest-wins:
/// UDP may drop a fragment, and waiting for an old incomplete picture adds
/// latency without making it usable.
struct CameraFrameAssembler {
    private var frameID: UInt16?
    private var resolution: CameraProtocol.Resolution?
    private var fragments: [Data?] = []

    mutating func append(_ fragment: CameraProtocol.Fragment) -> (Data, CameraProtocol.Resolution)? {
        if frameID != fragment.frameID || resolution != fragment.resolution
            || fragments.count != Int(fragment.count)
        {
            frameID = fragment.frameID
            resolution = fragment.resolution
            fragments = Array(repeating: nil, count: Int(fragment.count))
        }
        fragments[Int(fragment.index)] = fragment.payload
        guard fragments.allSatisfy({ $0 != nil }), let resolution else { return nil }
        let jpeg = fragments.reduce(into: Data()) { data, piece in data.append(piece!) }
        fragments = []
        return (jpeg, resolution)
    }
}

/// The selected device's camera image, kept outside PanelSnapshot so a live
/// feed does not redraw the sidebar or every form row for every JPEG.
@MainActor
final class CameraPreview: ObservableObject {
    struct Frame: Equatable {
        let image: CGImage
        let resolution: CameraProtocol.Resolution
        let sequence: UInt64

        static func == (lhs: Frame, rhs: Frame) -> Bool {
            lhs.sequence == rhs.sequence
        }
    }

    @Published private(set) var serviceName: String?
    @Published private(set) var frame: Frame?
    private var sequence: UInt64 = 0

    func focus(on serviceName: String?) {
        guard self.serviceName != serviceName else { return }
        self.serviceName = serviceName
        frame = nil
    }

    func accept(jpeg: Data, resolution: CameraProtocol.Resolution, from serviceName: String) {
        guard self.serviceName == serviceName,
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return }
        sequence &+= 1
        frame = Frame(image: image, resolution: resolution, sequence: sequence)
    }

    func clear() {
        frame = nil
    }
}

/// The app owns the WiFi camera connection and pushes each complete frame into
/// the embedded extension's CoreMediaIO sink stream. The extension forwards
/// that sink to its normal source stream, so no local listener or network
/// permission is needed for the app-to-extension handoff.
final class CameraExtensionBridge {
    static let shared = CameraExtensionBridge()
    private static let deviceName = "ESPDisplay XIAOML Camera"

    private let queue = DispatchQueue(label: "espdisplay.camera-extension")
    private let formatDescription: CMVideoFormatDescription
    private var deviceID: CMIODeviceID?
    private var sinkStream: CMIOStreamID?
    private var sinkQueue: CMSimpleQueue?

    private init() {
        var description: CMVideoFormatDescription?
        precondition(
            CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCVPixelFormatType_32BGRA,
                width: 640,
                height: 480,
                extensions: nil,
                formatDescriptionOut: &description) == noErr,
            "Could not create camera sink format")
        formatDescription = description!
    }

    func forward(jpeg: Data, resolution: CameraProtocol.Resolution) {
        queue.async {
            guard self.connectSinkIfNeeded() else { return }
            self.enqueue(jpeg)
        }
    }

    private func connectSinkIfNeeded() -> Bool {
        if sinkQueue != nil { return true }
        guard let device = cameraDevice(), let sink = sinkStream(in: device) else {
            return false
        }

        var queue: Unmanaged<CMSimpleQueue>?
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = CMIOStreamCopyBufferQueue(
            sink,
            { _, _, refcon in
                guard let refcon else { return }
                let bridge = Unmanaged<CameraExtensionBridge>
                    .fromOpaque(refcon).takeUnretainedValue()
                bridge.queue.async {}
            },
            refcon,
            &queue)
        guard status == noErr, let queue else { return false }
        let sinkQueue = queue.takeRetainedValue()
        guard CMIODeviceStartStream(device, sink) == noErr else { return false }
        deviceID = device
        sinkStream = sink
        self.sinkQueue = sinkQueue
        return true
    }

    private func cameraDevice() -> CMIODeviceID? {
        let captureDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified).devices
        guard let captureDevice = captureDevices.first(where: {
            $0.localizedName == Self.deviceName
        }) else { return nil }
        return cmioDevice(uniqueID: captureDevice.uniqueID)
    }

    private func cmioDevice(uniqueID: String) -> CMIODeviceID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return nil }
        var devices = [CMIOObjectID](
            repeating: CMIOObjectID(kCMIOObjectUnknown),
            count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == noErr
        else { return nil }
        for device in devices {
            address.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)
            var uid: CFString = "" as NSString
            var uidSize: UInt32 = 0
            guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &uidSize) == noErr,
                  CMIOObjectGetPropertyData(
                    device, &address, 0, nil, uidSize, &used, &uid) == noErr
            else { continue }
            if uid as String == uniqueID { return device }
        }
        return nil
    }

    private func sinkStream(in device: CMIODeviceID) -> CMIOStreamID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr
        else { return nil }
        var streams = [CMIOStreamID](
            repeating: CMIOStreamID(kCMIOObjectUnknown),
            count: Int(size) / MemoryLayout<CMIOStreamID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            device, &address, 0, nil, size, &used, &streams) == noErr
        else { return nil }
        for stream in streams {
            address.mSelector = CMIOObjectPropertySelector(kCMIOStreamPropertyDirection)
            var direction: UInt32 = 0
            guard CMIOObjectGetPropertyData(
                stream, &address, 0, nil,
                UInt32(MemoryLayout<UInt32>.size), &used, &direction) == noErr
            else { continue }
            if direction == 1 { return stream }
        }
        return nil
    }

    private func enqueue(_ jpeg: Data) {
        guard let sinkQueue,
              CMSimpleQueueGetCount(sinkQueue) < CMSimpleQueueGetCapacity(sinkQueue),
              let imageSource = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer) == kCVReturnSuccess,
            let pixelBuffer
        else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: 640,
            height: 480,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 640, height: 480))

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 15),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sample) == noErr,
            let sample
        else { return }
        let retainedSample = UnsafeMutableRawPointer(Unmanaged.passRetained(sample).toOpaque())
        if CMSimpleQueueEnqueue(sinkQueue, element: retainedSample) != noErr {
            Unmanaged<CMSampleBuffer>.fromOpaque(retainedSample).release()
        }
    }
}
