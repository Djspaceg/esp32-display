import Foundation
import SenderProtocol

/// What a panel is running, held against the firmware this app carries.
///
/// The Firmware section used to show only `fw=`, which is FW_VERSION and moves
/// only at a release, so it read "1.5.0" for months across every rebuild. The
/// board now also reports the commit it was built from (`FirmwareSourceIdentity`),
/// and a bundled revision records the same thing, so the answer here is which
/// bundled revision - if any - is exactly what is on the board.
///
/// Pure, so each wording is testable: `InstalledFirmwareTests`.
struct InstalledFirmware: Equatable {
    enum Match: Equatable {
        /// The board runs exactly this bundled revision.
        case bundled(BundledRevision)
        /// The board names a clean build, and no bundled revision is it.
        case notBundled
        /// Built from a tree with uncommitted changes, which matches nothing.
        case uncommitted
        /// The firmware predates build reporting, or was compiled outside
        /// tools/espdisp.py and says `unknown`.
        case notReported
        /// The panel reports in but not its version: firmware older than the
        /// version report.
        case legacy
        /// Nothing has been heard from the panel yet.
        case unknown
    }

    struct BundledRevision: Equatable {
        let family: String
        let version: String
        let build: UInt32?
        let builtAt: String
    }

    let version: String?
    let source: FirmwareSourceIdentity?
    let match: Match
    /// The newest bundled revision for this panel's family, when the family is
    /// known and the app carries firmware.
    let latestBundled: BundledRevision?

    /// `1.5.0 · build f9e04f9fcf9d`, or just the version when no build is known.
    var runningText: String {
        guard let version else {
            return match == .legacy ? "Legacy firmware" : "Not reported yet"
        }
        guard let source else { return version }
        return "\(version) · build \(source.summary)"
    }

    /// The one sentence under the running version.
    var matchText: String {
        switch match {
        case .bundled(let revision):
            return "The bundled \(revision.family) \(Self.identity(revision)) release, "
                + "built \(Self.day(revision.builtAt))."
        case .notBundled:
            if let latestBundled {
                return "Not a build this app carries. Bundled: \(latestBundled.family) "
                    + "\(Self.identity(latestBundled)), built \(Self.day(latestBundled.builtAt))."
            }
            return "Not a build this app carries."
        case .uncommitted:
            return "A local build with uncommitted changes, so it cannot be matched "
                + "to a bundled release."
        case .notReported:
            return "This firmware does not report which build it is. Any bundled "
                + "release installed from here does."
        case .legacy:
            return "Firmware this old does not report its version. Any bundled "
                + "release installed from here does."
        case .unknown:
            return "Waiting for the device to report its firmware."
        }
    }

    static func make(
        version: String?,
        source: FirmwareSourceIdentity?,
        family: String?,
        releases: BundledFirmware.ReleaseSet?,
        heardFrom: Bool = true
    ) -> InstalledFirmware {
        let families = canonicalFamilies(family, releases: releases)
        let options = families.flatMap { releases?.revisions(for: $0) ?? [] }
        let latest = families.count == 1
            ? options.lazy.compactMap(\.selection).first.map(revision)
            : nil
        let match: Match
        if version == nil, source == nil {
            match = heardFrom ? .legacy : .unknown
        } else if let source {
            if source.dirty {
                match = .uncommitted
            } else if let hit = options.lazy.compactMap(\.selection)
                .first(where: { source.isExactly($0.bundle) }) {
                match = .bundled(revision(hit))
            } else {
                match = .notBundled
            }
        } else {
            match = .notReported
        }
        return InstalledFirmware(
            version: version, source: source, match: match, latestBundled: latest)
    }

    /// The family a reported target belongs to, or every family when the panel
    /// has not said: a commit is unique, so searching all of them cannot pick
    /// the wrong board's image, and it is only used to say what is installed.
    private static func canonicalFamilies(
        _ family: String?, releases: BundledFirmware.ReleaseSet?
    ) -> [String] {
        if let family, !family.isEmpty {
            for (canonical, aliases) in GeneratedBoardCatalog.universalFamilyAliases
            where aliases.contains(family) {
                return [canonical]
            }
            return [family]
        }
        return releases.map { $0.catalog.families.keys.sorted() } ?? []
    }

    private static func revision(_ selection: BundledFirmware.Selection) -> BundledRevision {
        BundledRevision(
            family: selection.catalogEntry.family,
            version: selection.bundle.firmwareVersion,
            build: selection.bundle.firmwareBuild,
            builtAt: selection.bundle.builtAt)
    }

    private static func identity(_ revision: BundledRevision) -> String {
        revision.build.map { "\(revision.version) (build \($0))" } ?? revision.version
    }

    /// `2026-09-26` out of `2026-09-26T08:43:06Z`; anything else as written.
    private static func day(_ timestamp: String) -> String {
        guard timestamp.count >= 10, timestamp.dropFirst(10).first == "T" else {
            return timestamp
        }
        return String(timestamp.prefix(10))
    }
}

extension PanelManager {
    /// The firmware this copy of the app carries, read and verified once.
    ///
    /// Reading it means hashing every bundled image, which is far too slow to do
    /// per render - the update sheet used to do exactly that on every redraw of
    /// the window behind it. Nothing changes the app's own resources while it
    /// runs, so the first answer stands.
    var bundledFirmware: BundledFirmware.Availability {
        if let cached = bundledFirmwareCache { return cached }
        let loaded = BundledFirmware.load()
        bundledFirmwareCache = loaded
        return loaded
    }

    func installedFirmware(for serviceName: String) -> InstalledFirmware {
        let panel = panels.first { $0.serviceName == serviceName }
        let releases: BundledFirmware.ReleaseSet?
        if case .ready(let set) = bundledFirmware { releases = set } else { releases = nil }
        return InstalledFirmware.make(
            version: panel?.firmwareVersion,
            source: panel?.currentFirmwareSource,
            family: panel?.target,
            releases: releases,
            // An EINF has arrived: uptime is only ever set from one. Not
            // `lastHeartbeatAt`, which the sender stamps as soon as its socket
            // is ready, before the board has said anything.
            heardFrom: (panel?.uptimeSeconds ?? 0) > 0)
    }
}
