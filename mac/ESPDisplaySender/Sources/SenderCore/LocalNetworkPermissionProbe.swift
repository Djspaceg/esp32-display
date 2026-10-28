import Foundation
import Network

/// Starts the Bonjour browse that requests Local Network permission. This is
/// separate from device discovery: it runs immediately at launch, including
/// LaunchAgent launches, rather than waiting for the sender's capture setup.
final class LocalNetworkPermissionProbe {
    static let serviceType = "_espdisp._udp"
    static let recheckInterval: TimeInterval = 5
    /// `kDNSServiceErr_PolicyDenied`. Kept as the wire value because Network
    /// does not surface the DNS-SD constant to Swift on every SDK.
    static let policyDeniedDNSServiceError: Int32 = -65_570

    enum Observation: Equatable {
        case policyDenied(technicalDetail: String)
        /// A Bonjour browse becoming ready is not proof that the app can send
        /// packets to a local IPv4 address.
        case browserReady
        case deviceAnswered
    }

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "espdisp.local-network-permission")
    private var generation: UInt64 = 0
    private var lastStartedAt = Date.distantPast
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

    static func isLocalNetworkDenied(_ reason: NWPath.UnsatisfiedReason?) -> Bool {
        reason == .localNetworkDenied
    }

    static func shouldRecheck(
        lastStartedAt: Date, now: Date, interval: TimeInterval = recheckInterval
    ) -> Bool {
        now.timeIntervalSince(lastStartedAt) >= interval
    }

    /// Starting this browse is the public Local Network access attempt. It is
    /// safe to restart from the banner's Request Access button after a prompt
    /// was not shown or the permission was changed in System Settings.
    func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    private func startLocked() {
        browser?.cancel()
        generation &+= 1
        let callbackGeneration = generation
        lastStartedAt = Date()
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.generation == callbackGeneration else { return }
            // A nonempty browse is intentionally not proof that packets can
            // reach a device. `FrameSender` reports the actual endpoint path.
            _ = results
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == callbackGeneration else { return }
            switch state {
            case .ready:
                self.onObservation(.browserReady)
            case .waiting(let error), .failed(let error):
                if case .dns(let code) = error,
                   Self.isPolicyDeniedDNSServiceError(Int32(code)) {
                    self.onObservation(
                        .policyDenied(technicalDetail: String(describing: error)))
                }
            default:
                break
            }
        }
        browser.start(queue: queue)
    }

    /// Run a new browse periodically after a denial, and when the foreground
    /// app becomes active, so granting access clears the banner without a
    /// second manual request.
    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            if Self.shouldRecheck(lastStartedAt: self.lastStartedAt, now: Date()) {
                self.startLocked()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.browser?.cancel()
            self?.browser = nil
            self?.generation &+= 1
        }
    }
}
