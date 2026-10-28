import Foundation
import Network

/// Starts the one Bonjour browse that both requests Local Network permission
/// and proves a device can answer it. This is separate from device discovery:
/// it runs immediately at launch, including LaunchAgent launches, rather than
/// waiting for the sender's capture setup to reach discovery.
final class LocalNetworkPermissionProbe {
    static let serviceType = "_espdisp._udp"
    /// `kDNSServiceErr_PolicyDenied`. Kept as the wire value because Network
    /// does not surface the DNS-SD constant to Swift on every SDK.
    static let policyDeniedDNSServiceError: Int32 = -65_570

    enum Observation: Equatable {
        case policyDenied(technicalDetail: String)
        case authorized
        case deviceAnswered
    }

    private var browser: NWBrowser?
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private let onObservation: (Observation) -> Void

    init(onObservation: @escaping (Observation) -> Void) {
        self.onObservation = onObservation
    }

    static func isPolicyDeniedDNSServiceError(_ code: Int32) -> Bool {
        code == policyDeniedDNSServiceError
    }

    static func isCurrent(_ callbackGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        callbackGeneration == currentGeneration
    }

    static func isPolicyDenied(_ error: NWError) -> Bool {
        guard case .dns(let code) = error else { return false }
        return isPolicyDeniedDNSServiceError(Int32(code))
    }

    /// Starting this browse is the public Local Network access attempt. It is
    /// safe to restart from the banner's Request Access button after a prompt
    /// was not shown or the permission was changed in System Settings.
    func start() {
        browser?.cancel()
        let callbackGeneration = lock.withLock {
            generation &+= 1
            return generation
        }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self,
                  self.isCurrent(callbackGeneration)
            else { return }
            guard !results.isEmpty else { return }
            self.onObservation(.deviceAnswered)
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self,
                  self.isCurrent(callbackGeneration)
            else { return }
            switch state {
            case .ready:
                self.onObservation(.authorized)
            case .waiting(let error), .failed(let error)
                where Self.isPolicyDenied(error):
                self.onObservation(
                    .policyDenied(technicalDetail: String(describing: error)))
            default:
                break
            }
        }
        browser.start(queue: .global())
    }

    func stop() {
        browser?.cancel()
        browser = nil
        lock.withLock { generation &+= 1 }
    }

    private func isCurrent(_ callbackGeneration: UInt64) -> Bool {
        lock.withLock {
            Self.isCurrent(callbackGeneration, currentGeneration: generation)
        }
    }
}
