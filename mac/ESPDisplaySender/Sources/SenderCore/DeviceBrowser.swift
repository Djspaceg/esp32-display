import Foundation
import Network

/// Discovers display devices by browsing the _espdisp._udp Bonjour service.
/// Every device advertises a unique instance name (espdisplay-XXXX by
/// default, user-settable), so multiple panels coexist with zero
/// configuration and nothing is ever resolved by hardcoded hostname.
final class DeviceBrowser {
    struct Device: Hashable {
        let name: String        // service instance name, e.g. "espdisplay-9050"
        let endpoint: NWEndpoint
    }

    private var browser: NWBrowser?
    private let onChange: ([Device]) -> Void

    init(onChange: @escaping ([Device]) -> Void) {
        self.onChange = onChange
    }

    func start() {
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjour(type: "_espdisp._udp", domain: nil), using: params)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let devices = results.compactMap { result -> Device? in
                guard case .service(let name, _, _, _) = result.endpoint else {
                    return nil
                }
                return Device(name: name, endpoint: result.endpoint)
            }
            self?.onChange(devices.sorted { $0.name < $1.name })
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                FileHandle.standardError.write(
                    Data("device browser failed: \(error) - restarting\n".utf8))
                // NWBrowser can fail on network transitions; restart it.
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.start()
                }
            }
        }
        browser.start(queue: .global())
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
