import AVFoundation
import Foundation
import SystemExtensions

enum CameraExtensionActivation {
    case installed
    case needsUserApproval
    case failed(Error)
}

/// Activates the embedded CoreMediaIO system extension. The request object
/// retains neither its delegate nor completion, so this object retains one
/// operation until System Extensions has a terminal answer.
final class CameraExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    static let extensionIdentifier = "com.espdisplay.camera-extension"
    private static var active: CameraExtensionInstaller?

    private let completion: (CameraExtensionActivation) -> Void

    private init(completion: @escaping (CameraExtensionActivation) -> Void) {
        self.completion = completion
    }

    static func activate(completion: @escaping (CameraExtensionActivation) -> Void) {
        let installer = CameraExtensionInstaller(completion: completion)
        active = installer
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = installer
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// The extension publishes this virtual camera when activation has
    /// completed. Discovery does not request access to a physical camera.
    static var isInstalled: Bool {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified).devices.contains {
                $0.localizedName == CameraExtensionBridge.deviceName
            }
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        completion(.needsUserApproval)
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        finish(.installed)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        finish(.failed(error))
    }

    private func finish(_ result: CameraExtensionActivation) {
        completion(result)
        Self.active = nil
    }
}
