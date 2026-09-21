import Foundation
import Network
import SenderProtocol

/// Discovers display devices by browsing the _espdisp._udp Bonjour service.
/// Every device advertises a unique instance name (espdisplay-XXXX by
/// default, user-settable), so multiple panels coexist with zero
/// configuration and nothing is ever resolved by hardcoded hostname.
final class DeviceBrowser {
    struct Device: Hashable {
        let name: String        // service instance name, e.g. "espdisplay-9050"
        let endpoint: NWEndpoint
        /// What the panel says about itself in its TXT records. `.empty` for a
        /// panel that advertised nothing readable, which must behave exactly as
        /// every panel did before this was parsed.
        let metadata: ServiceMetadata

        init(name: String, endpoint: NWEndpoint, metadata: ServiceMetadata = .empty) {
            self.name = name
            self.endpoint = endpoint
            self.metadata = metadata
        }

        /// The native geometry from this network advertisement, if it supplied
        /// a usable `res=WxH` value. Absence is unknown, not 172x320: callers
        /// must either use identity learned over USB or leave the panel
        /// unstreamed until its size is known.
        var geometry: PanelGeometry? {
            metadata.geometry
        }
    }

    /// One browse result, reduced to the two things this class reads out of it.
    ///
    /// Exists so the results-to-devices mapping can be a pure function:
    /// `NWBrowser.Result` has no public initialiser, so the real type cannot be
    /// built in a test, and without this the only way to reach that logic would
    /// be a live mDNS browse with a real panel on the network.
    struct Advertisement {
        let endpoint: NWEndpoint
        /// nil when the result carried no TXT record at all, which is different
        /// from carrying an empty one.
        let txtRecords: [String: String]?

        init(endpoint: NWEndpoint, txtRecords: [String: String]? = nil) {
            self.endpoint = endpoint
            self.txtRecords = txtRecords
        }
    }

    private var browser: NWBrowser?
    private let onChange: ([Device]) -> Void

    init(onChange: @escaping ([Device]) -> Void) {
        self.onChange = onChange
    }

    /// Turn browse results into devices: drop anything that is not a Bonjour
    /// service, parse the TXT records, and sort by name.
    ///
    /// Pure, and sorted so callback input is deterministic. `PanelManager`
    /// applies the user's remembered sidebar order to owned records.
    static func devices(from advertisements: [Advertisement]) -> [Device] {
        let devices = advertisements.compactMap { advertisement -> Device? in
            guard case .service(let name, _, _, _) = advertisement.endpoint else {
                return nil
            }
            return Device(
                name: name,
                endpoint: advertisement.endpoint,
                // No TXT record and an unreadable one both land on `.empty`, so
                // a panel running firmware older than any of these records is
                // indistinguishable from one running firmware newer than this
                // app understands: both simply say nothing.
                metadata: advertisement.txtRecords.map(ServiceMetadata.init(txtRecords:))
                    ?? .empty)
        }
        return devices.sorted { $0.name < $1.name }
    }

    /// The TXT records on a browse result, or nil if it carried none.
    static func txtRecords(from metadata: NWBrowser.Result.Metadata) -> [String: String]? {
        guard case .bonjour(let record) = metadata else { return nil }
        return record.dictionary
    }

    func start() {
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(
            // bonjourWithTXTRecord, not bonjour: the flag behind it is
            // documented as off by default - "the browser will not
            // automatically query for TXT records"
            // (Network.framework browse_descriptor.h:97, on
            // nw_browse_descriptor_set_include_txt_record) - so with a plain
            // .bonjour descriptor every result's metadata is .none no matter
            // what the panel advertises. Nothing on NWParameters affects this.
            // It costs one TXT query per service, which the same header warns
            // "may increase network traffic"; against that, res, chip and target
            // are the difference between streaming a panel at its own resolution,
            // selecting its exact firmware image, and guessing. All three are
            // needed before a session exists.
            for: .bonjourWithTXTRecord(type: "_espdisp._udp", domain: nil), using: params)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.onChange(Self.devices(from: results.map {
                Advertisement(endpoint: $0.endpoint, txtRecords: Self.txtRecords(from: $0.metadata))
            }))
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
