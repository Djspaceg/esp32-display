import Foundation
import SystemExtensions

/// Activates the embedded CoreMediaIO system extension. The request object
/// retains neither its delegate nor completion, so this object retains one
/// operation until System Extensions has a terminal answer.
final class CameraExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    static let extensionIdentifier = "com.espdisplay.camera-extension"
    private static var active: CameraExtensionInstaller?

    private let completion: (Result<Void, Error>) -> Void
    private var reportedApproval = false

    private init(completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
    }

    static func activate(completion: @escaping (Result<Void, Error>) -> Void) {
        let installer = CameraExtensionInstaller(completion: completion)
        active = installer
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = installer
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        guard !reportedApproval else { return }
        reportedApproval = true
        completion(.success(()))
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        finish(.success(()))
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        if !reportedApproval { completion(result) }
        Self.active = nil
    }
}
