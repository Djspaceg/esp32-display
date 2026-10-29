import Foundation
import SystemExtensions

enum CameraExtensionActivation {
    case installed
    case notInstalled
    case needsUserApproval
    case needsRestart
    case requestInProgress
    case failed(Error)
}

struct CameraExtensionPropertiesSnapshot: Equatable {
    let enabled: Bool
    let awaitingUserApproval: Bool
    let uninstalling: Bool
    let bundleVersion: String

    init(
        enabled: Bool,
        awaitingUserApproval: Bool,
        uninstalling: Bool,
        bundleVersion: String = ""
    ) {
        self.enabled = enabled
        self.awaitingUserApproval = awaitingUserApproval
        self.uninstalling = uninstalling
        self.bundleVersion = bundleVersion
    }
}

/// Activates and inspects the embedded CoreMediaIO system extension. The
/// request object retains neither its delegate nor completion, so this object
/// retains one operation until System Extensions has a terminal answer.
final class CameraExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    static let extensionIdentifier = "com.resourcefork.espdisplay.camera-extension"
    static let extensionBundleName = extensionIdentifier + ".systemextension"
    private static var active: CameraExtensionInstaller?
    private static var waitingForUserApproval = false
    static var isActivationPending: Bool {
        (active?.operation == .activation || active?.operation == .activationAssessment)
            && !waitingForUserApproval
    }
    static var isInspectionPending: Bool {
        active?.operation == .properties
    }
    static var isWaitingForUserApproval: Bool { waitingForUserApproval }

    private enum Operation {
        case activationAssessment
        case activation
        case properties
    }

    private let operation: Operation
    private let completion: (CameraExtensionActivation) -> Void
    private var didFinish = false

    private init(
        operation: Operation,
        completion: @escaping (CameraExtensionActivation) -> Void
    ) {
        self.operation = operation
        self.completion = completion
    }

    static func activate(completion: @escaping (CameraExtensionActivation) -> Void) {
        guard active == nil else {
            completion(.requestInProgress)
            return
        }
        let installer = CameraExtensionInstaller(
            operation: .activationAssessment, completion: completion)
        active = installer
        waitingForUserApproval = false
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = installer
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private static func submitActivation(
        completion: @escaping (CameraExtensionActivation) -> Void
    ) {
        let installer = CameraExtensionInstaller(operation: .activation, completion: completion)
        active = installer
        waitingForUserApproval = false
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = installer
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Queries macOS's System Extensions registry. Unlike virtual-camera
    /// device discovery, this reports an enabled extension before a video app
    /// has opened the camera provider.
    static func inspect(completion: @escaping (CameraExtensionActivation) -> Void) {
        guard active == nil else {
            completion(.requestInProgress)
            return
        }
        let installer = CameraExtensionInstaller(operation: .properties, completion: completion)
        active = installer
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = installer
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    static func activation(
        for properties: [CameraExtensionPropertiesSnapshot]
    ) -> CameraExtensionActivation {
        if properties.contains(where: { $0.enabled && !$0.uninstalling }) {
            return .installed
        }
        if properties.contains(where: \.awaitingUserApproval) {
            return .needsUserApproval
        }
        return .notInstalled
    }

    static func shouldSubmitActivation(
        embeddedVersion: String?,
        properties: [CameraExtensionPropertiesSnapshot]
    ) -> Bool {
        guard let embeddedVersion else { return true }
        return !properties.contains {
            $0.enabled && !$0.uninstalling && $0.bundleVersion == embeddedVersion
        }
    }

    /// `nil` means a real activation request is still needed. Returning
    /// `.installed` completes the request without replacing an already active
    /// copy of the exact embedded version.
    static func activationAfterAssessment(
        embeddedVersion: String?,
        properties: [CameraExtensionPropertiesSnapshot]
    ) -> CameraExtensionActivation? {
        shouldSubmitActivation(
            embeddedVersion: embeddedVersion, properties: properties)
            ? nil : .installed
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        guard operation == .activation else { return }
        Self.waitingForUserApproval = true
        completion(.needsUserApproval)
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        guard operation == .activation else { return }
        switch result {
        case .completed:
            finish(.installed)
        case .willCompleteAfterReboot:
            finish(.needsRestart)
        @unknown default:
            finish(.failed(NSError(
                domain: "CameraExtensionInstaller",
                code: Int(result.rawValue),
                userInfo: [NSLocalizedDescriptionKey:
                    "macOS returned an unknown camera extension activation result."])))
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        finish(.failed(error))
    }

    func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        guard operation != .activation else { return }
        let snapshots = properties.map {
            CameraExtensionPropertiesSnapshot(
                enabled: $0.isEnabled,
                awaitingUserApproval: $0.isAwaitingUserApproval,
                uninstalling: $0.isUninstalling,
                bundleVersion: $0.bundleVersion)
        }
        switch operation {
        case .properties:
            finish(Self.activation(for: snapshots))
        case .activationAssessment:
            if let result = Self.activationAfterAssessment(
                embeddedVersion: Self.embeddedExtensionVersion,
                properties: snapshots)
            {
                finish(result)
            } else {
                handoffToActivationRequest()
            }
        case .activation:
            break
        }
    }

    private static var embeddedExtensionVersion: String? {
        let extensionURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
            .appendingPathComponent(extensionBundleName, isDirectory: true)
        return Bundle(url: extensionURL)?
            .object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    private func handoffToActivationRequest() {
        guard !didFinish else { return }
        didFinish = true
        Self.active = nil
        Self.waitingForUserApproval = false
        Self.submitActivation(completion: completion)
    }

    private func finish(_ result: CameraExtensionActivation) {
        guard !didFinish else { return }
        didFinish = true
        completion(result)
        Self.active = nil
        Self.waitingForUserApproval = false
    }
}
