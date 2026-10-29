import Darwin
import Foundation
import Network

/// Starts the Bonjour browse that requests Local Network permission. This is
/// separate from device discovery: it runs immediately at launch, including
/// LaunchAgent launches, rather than waiting for the sender's capture setup.
final class LocalNetworkPermissionProbe {
    static let serviceType = "_espdisp._udp"
    /// A private unicast address used only to ask Network.framework whether
    /// Local Network policy permits a UDP path. It is deliberately not a
    /// subnet broadcast address and no datagram is sent to it.
    static let unicastProbeHost = "192.168.254.254"
    static let recheckInterval: TimeInterval = 5
    /// `kDNSServiceErr_PolicyDenied`. Kept as the wire value because Network
    /// does not surface the DNS-SD constant to Swift on every SDK.
    static let policyDeniedDNSServiceError: Int32 = -65_570

    enum Observation: Equatable {
        case policyDenied(technicalDetail: String)
        /// A Bonjour browse becoming ready is not proof that the app can send
        /// packets to a local IPv4 address.
        case browserReady
        /// A FrameSender unicast device path is satisfied. This is the
        /// positive Local Network signal; multicast mDNS readiness is not.
        case unicastPathReady
        case deviceAnswered
    }

    private var browser: NWBrowser?
    private var accessConnection: NWConnection?
    private var unicastPathConnection: NWConnection?
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

    /// Network.framework can expose a Local Network block as a policy path,
    /// DNS-SD PolicyDenied, or a UDP "No route to host" error. The latter
    /// matters for known devices whose sender never needs Bonjour again.
    static func isLocalNetworkDenied(_ error: NWError) -> Bool {
        switch error {
        case .dns(let code):
            return isPolicyDeniedDNSServiceError(Int32(code))
        case .posix(let code):
            return code.rawValue == EHOSTUNREACH
        default:
            return false
        }
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
        accessConnection?.cancel()
        unicastPathConnection?.cancel()
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
                if Self.isLocalNetworkDenied(error) {
                    self.onObservation(
                        .policyDenied(technicalDetail: String(describing: error)))
                }
            default:
                break
            }
        }
        browser.start(queue: queue)
        startAccessConnection(callbackGeneration: callbackGeneration)
        startUnicastPathProbe(callbackGeneration: callbackGeneration)
    }

    /// A standard PTR query for this app's Bonjour service. It is a real,
    /// harmless local datagram rather than an invented packet sent to a board.
    private static let mdnsQuery = Data([
        0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0,
        8, 95, 101, 115, 112, 100, 105, 115, 112,
        4, 95, 117, 100, 112,
        5, 108, 111, 99, 97, 108, 0,
        0, 12, 0, 1,
    ])

    /// Browsing alone can become ready when device UDP paths are prohibited.
    /// Sending the usual mDNS lookup makes the permission request explicit at
    /// launch, including a LaunchAgent launch, without touching a board. Its
    /// ready state deliberately does not clear guidance: build 628.1 showed
    /// it could be ready while device unicast paths were still prohibited.
    private func startAccessConnection(callbackGeneration: UInt64) {
        let connection = NWConnection(
            host: "224.0.0.251", port: 5_353, using: .udp)
        accessConnection = connection
        connection.pathUpdateHandler = { [weak self] path in
            guard let self, self.generation == callbackGeneration else { return }
            if Self.isLocalNetworkDenied(path.unsatisfiedReason) {
                self.onObservation(.policyDenied(technicalDetail: "mDNS path: \(path)"))
            }
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == callbackGeneration else { return }
            switch state {
            case .waiting(let error), .failed(let error):
                if Self.isLocalNetworkDenied(error) {
                    self.onObservation(
                        .policyDenied(technicalDetail: String(describing: error)))
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        connection.send(content: Self.mdnsQuery, completion: .contentProcessed { _ in })
    }

    /// Local Network permission applies to packets sent to private unicast
    /// addresses, not just Bonjour multicast. A UDP path does not require a
    /// device response, so it gives the checklist a live access result even
    /// while every device is booting or connected only over USB.
    private func startUnicastPathProbe(callbackGeneration: UInt64) {
        let connection = NWConnection(
            host: NWEndpoint.Host(Self.unicastProbeHost), port: 9, using: .udp)
        unicastPathConnection = connection
        connection.pathUpdateHandler = { [weak self] path in
            guard let self, self.generation == callbackGeneration else { return }
            if path.status == .satisfied {
                self.onObservation(.unicastPathReady)
            } else if path.status == .unsatisfied,
                      Self.isLocalNetworkDenied(path.unsatisfiedReason)
            {
                self.onObservation(.policyDenied(technicalDetail: "unicast path: \(path)"))
            }
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == callbackGeneration else { return }
            switch state {
            case .waiting(let error), .failed(let error):
                if Self.isLocalNetworkDenied(error) {
                    self.onObservation(
                        .policyDenied(technicalDetail: "unicast probe: \(error)"))
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
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
            self?.accessConnection?.cancel()
            self?.accessConnection = nil
            self?.unicastPathConnection?.cancel()
            self?.unicastPathConnection = nil
            self?.generation &+= 1
        }
    }
}
