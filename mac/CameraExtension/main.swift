import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio

private let cameraWidth = 640
private let cameraHeight = 480
private let frameRate: Int32 = 15

@main
final class CameraExtensionMain: NSObject, CMIOExtensionProviderSource {
    private let queue = DispatchQueue(label: "com.espdisplay.camera-extension")
    private let deviceSource = CameraDeviceSource()
    private lazy var provider = CMIOExtensionProvider(source: self, clientQueue: queue)

    override init() {
        super.init()
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Could not register camera device: \(error)")
        }
        CMIOExtensionProvider.startService(provider: provider)
    }

    static func main() {
        _ = CameraExtensionMain()
        dispatchMain()
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerName, .providerManufacturer]
    }

    func providerProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerName) { result.name = "ESPDisplay" }
        if properties.contains(.providerManufacturer) { result.manufacturer = "ESPDisplay" }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}
}

private final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private let format: CMIOExtensionStreamFormat
    private(set) var output: CameraOutputStream!
    private(set) var sink: CameraSinkStream!
    private var outputClientCount = 0
    private var sinkActive = false

    override init() {
        var description: CMVideoFormatDescription?
        precondition(
            CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCVPixelFormatType_32BGRA,
                width: Int32(cameraWidth),
                height: Int32(cameraHeight),
                extensions: nil,
                formatDescriptionOut: &description) == noErr,
            "Could not create camera format description")
        format = CMIOExtensionStreamFormat(
            formatDescription: description!,
            maxFrameDuration: CMTime(value: 1, timescale: frameRate),
            minFrameDuration: CMTime(value: 1, timescale: frameRate),
            validFrameDurations: nil)
        super.init()
        device = CMIOExtensionDevice(
            localizedName: "ESPDisplay XIAOML Camera",
            deviceID: UUID(uuidString: "B3FE8B2B-7A6C-4D4A-BCB8-5AB00B5CA001")!,
            legacyDeviceID: "com.espdisplay.xiaoml-camera",
            source: self)
        output = CameraOutputStream(
            localizedName: "Camera",
            streamID: UUID(uuidString: "9C4D9E56-6F11-4EBB-BD1C-0DAA8E0F8A01")!,
            format: format,
            device: device)
        sink = CameraSinkStream(
            localizedName: "ESPDisplay Input",
            streamID: UUID(uuidString: "9C4D9E56-6F11-4EBB-BD1C-0DAA8E0F8A02")!,
            format: format,
            device: device)
        do {
            try device.addStream(output.stream)
            try device.addStream(sink.stream)
        } catch {
            fatalError("Could not register camera streams: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            result.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) { result.model = "XIAOML Kit" }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func startOutput() {
        outputClientCount += 1
    }

    func stopOutput() {
        outputClientCount = max(0, outputClientCount - 1)
    }

    func startSink(client: CMIOExtensionClient) {
        guard !sinkActive else { return }
        sinkActive = true
        consume(client)
    }

    func stopSink() {
        sinkActive = false
    }

    private func consume(_ client: CMIOExtensionClient) {
        guard sinkActive else { return }
        sink.stream.consumeSampleBuffer(from: client) { [weak self] sample, sequence, _, _, _ in
            guard let self else { return }
            if let sample {
                let hostTime = UInt64(sample.presentationTimeStamp.seconds * Double(NSEC_PER_SEC))
                if self.outputClientCount > 0 {
                    self.output.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: hostTime)
                }
                self.sink.stream.notifyScheduledOutputChanged(
                    CMIOExtensionScheduledOutput(
                        sequenceNumber: sequence,
                        hostTimeInNanoseconds: hostTime))
            }
            self.consume(client)
        }
    }
}

private final class CameraOutputStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let device: CMIOExtensionDevice
    private var activeFormatIndex = 0

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat,
         device: CMIOExtensionDevice) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            result.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            result.frameDuration = CMTime(value: 1, timescale: frameRate)
        }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex, index == 0 {
            activeFormatIndex = index
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        guard let source = device.source as? CameraDeviceSource else {
            fatalError("Unexpected camera device source")
        }
        source.startOutput()
    }

    func stopStream() throws {
        guard let source = device.source as? CameraDeviceSource else {
            fatalError("Unexpected camera device source")
        }
        source.stopOutput()
    }
}

private final class CameraSinkStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let device: CMIOExtensionDevice
    private var client: CMIOExtensionClient?
    private var activeFormatIndex = 0

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat,
         device: CMIOExtensionDevice) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .sink,
            clockType: .hostTime,
            source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount,
         .streamSinkEndOfData]
    }

    func streamProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            result.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            result.frameDuration = CMTime(value: 1, timescale: frameRate)
        }
        if properties.contains(.streamSinkBufferQueueSize) { result.sinkBufferQueueSize = 2 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            result.sinkBuffersRequiredForStartup = 1
        }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex, index == 0 {
            activeFormatIndex = index
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        guard let source = device.source as? CameraDeviceSource, let client else {
            throw NSError(
                domain: "ESPDisplayCamera",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Camera sink client is unavailable."])
        }
        source.startSink(client: client)
    }

    func stopStream() throws {
        guard let source = device.source as? CameraDeviceSource else {
            fatalError("Unexpected camera device source")
        }
        source.stopSink()
    }
}
