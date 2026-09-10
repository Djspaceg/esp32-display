import Foundation
import SenderProtocol

/// The canonical c6, s3, and p4 firmware resources shipped inside the app.
enum BundledFirmware {
    static let catalogResourceName = "manifest"

    enum UpdateIdentityError: Error, LocalizedError, Equatable {
        case conflictingEvidence(
            field: String, live: String, usb: String)

        var errorDescription: String? {
            switch self {
            case .conflictingEvidence(let field, let live, let usb):
                return "Live \(field) identity \(live) conflicts with USB identity \(usb)."
            }
        }
    }

    struct Selection: Equatable {
        let catalogEntry: FirmwareReleaseCatalog.Entry
        let bundle: FirmwareBundle
        let url: URL
    }

    /// How an automatic update image was chosen, which decides whether the
    /// selection may also drive a USB write or only an OTA push.
    enum UpdateResolution: Equatable {
        /// Complete runtime identity matched exactly one catalog entry. This is
        /// the same evidence `flashFirmwareOverUSB` re-verifies, so it stays
        /// safe for both USB and OTA.
        case exact(Selection)
        /// Strict identity was incomplete, but the reported chip uniquely names
        /// one bundled family image and no present family/profile/partition
        /// evidence contradicts it. The write path still re-verifies the exact
        /// target before any USB flash.
        case familyFallback(Selection)

        var selection: Selection {
            switch self {
            case .exact(let selection), .familyFallback(let selection):
                return selection
            }
        }

        /// The canonical family target (`c6`/`s3`/`p4`) the resolver settled on.
        /// Because every bundled artifact serves exactly its own family, this is
        /// also the exact target for image, payload, and flash-plan lookups.
        var canonicalTarget: String { selection.catalogEntry.family }

        /// Whether complete-identity evidence, not a chip-only fallback, backs
        /// this selection.
        var isExact: Bool {
            if case .exact = self { return true }
            return false
        }
    }

    struct UpdateSelection: Equatable {
        let resolution: UpdateResolution
        let identity: FirmwareReleaseCatalog.Identity

        var selection: Selection { resolution.selection }
    }

    struct ReleaseSet: Equatable {
        let catalog: FirmwareReleaseCatalog
        let selections: [String: Selection]

        func select(
            family: String?, chip: String?, profile: String?, partition: String?
        ) throws -> Selection {
            let entry = try catalog.entry(for: .init(
                family: family, chip: chip, profile: profile, partition: partition))
            guard let selection = selections[entry.family] else {
                throw FirmwareReleaseCatalogError.bundleMetadataMismatch(entry.family)
            }
            return selection
        }

        func selectForUpdate(
            live: FirmwareReleaseCatalog.Identity,
            usb: FirmwareReleaseCatalog.Identity?
        ) throws -> UpdateSelection {
            let mergedIdentity = try FirmwareReleaseCatalog.Identity(
                family: mergedFamily(live: live.family, usb: usb?.family),
                chip: mergedChip(live: live.chip, usb: usb?.chip),
                profile: merged(
                    field: "profile", live: live.profile, usb: usb?.profile),
                partition: merged(
                    field: "partition", live: live.partition, usb: usb?.partition))
            let resolution = try resolveUpdate(
                family: mergedIdentity.family,
                chip: mergedIdentity.chip,
                profile: mergedIdentity.profile,
                partition: mergedIdentity.partition)
            return UpdateSelection(
                resolution: resolution,
                identity: canonicalIdentity(
                    from: mergedIdentity,
                    resolution: resolution))
        }

        /// Explicit recovery selection. Callers must present the profile choice
        /// to the user before using this when runtime identity is unavailable.
        func selectForRecovery(family: String, profile: String) throws -> Selection {
            guard let entry = catalog.families[family], entry.profiles.contains(profile),
                  let selection = selections[family]
            else {
                throw FirmwareReleaseCatalogError.profileMismatch(
                    family: family, found: profile)
            }
            return selection
        }

        /// The bundled image a detected chip alone identifies, or nil.
        ///
        /// Pure and evidence-only: it returns a verified selection only when
        /// exactly one catalog entry claims `chip`, so a chip shared by more
        /// than one family never resolves. Every entry in `selections` was
        /// already byte/hash/metadata verified by `load`, so a returned
        /// selection is always a verified one. This is weaker than
        /// `select(...)`, which needs complete family/chip/profile/partition
        /// runtime identity, and than `selectForRecovery(...)`, which needs an
        /// explicit profile choice. Callers decide whether a chip-only match is
        /// enough to preselect a bundled family artifact. The write path still
        /// re-verifies the exact target before any USB flash.
        func selectForUniqueChip(_ chip: String) -> Selection? {
            let matches = selections.values.filter { $0.catalogEntry.chip == chip }
            guard matches.count == 1 else { return nil }
            return matches.first
        }

        /// Legacy family aliases a universal image still answers to, so a board
        /// that reports an old exact target instead of its family is not read as
        /// a contradiction. Canonical `c6`/`s3` and missing/empty are accepted
        /// too. Missing/empty family remains accepted separately.
        private static let universalFamilyAliases: [String: Set<String>] = [
            "c6": ["c6"],
            "p4": ["p4"],
            "s3": ["s3", "s3-085", "s3-154", "s3-175", "s3-185"],
        ]

        /// Choose the update image for a panel: strict complete-identity
        /// selection first, then a unique-chip family fallback only
        /// when no present evidence contradicts it.
        ///
        /// Pure and evidence-only. Strict selection wins whenever it succeeds and
        /// is reported as `.exact`. The fallback exists for any chip that maps
        /// to exactly one bundled family, so a panel that has not yet reported
        /// full runtime identity can still preselect its shipped family image.
        /// Any chip/family/profile/partition contradiction rethrows the original
        /// strict error rather than papering over it with a fallback.
        func resolveUpdate(
            family: String?, chip: String?, profile: String?, partition: String?
        ) throws -> UpdateResolution {
            do {
                return .exact(try select(
                    family: family, chip: chip, profile: profile, partition: partition))
            } catch let strictError {
                guard let chip = Self.usable(chip),
                      let selection = selectForUniqueChip(chip),
                      let accepted = Self.universalFamilyAliases[
                        selection.catalogEntry.family]
                else { throw strictError }
                let entry = selection.catalogEntry
                if let family = Self.usable(family), !accepted.contains(family) {
                    throw strictError
                }
                if let profile = Self.usable(profile),
                   !entry.profiles.contains(profile) {
                    throw strictError
                }
                if let partition = Self.usable(partition),
                   partition != entry.compatibility.partitionScheme {
                    throw strictError
                }
                return .familyFallback(selection)
            }
        }

        private func canonicalIdentity(
            from mergedIdentity: FirmwareReleaseCatalog.Identity,
            resolution: UpdateResolution
        ) -> FirmwareReleaseCatalog.Identity {
            guard case .familyFallback(let selection) = resolution else {
                return mergedIdentity
            }
            return .init(
                family: selection.catalogEntry.family,
                chip: mergedIdentity.chip ?? selection.catalogEntry.chip,
                profile: mergedIdentity.profile,
                partition: mergedIdentity.partition)
        }

        private func merged(
            field: String, live: String?, usb: String?
        ) throws -> String? {
            let live = Self.usable(live)
            let usb = Self.usable(usb)
            if let live, let usb, live != usb {
                throw UpdateIdentityError.conflictingEvidence(
                    field: field, live: live, usb: usb)
            }
            return live ?? usb
        }

        private func mergedFamily(live: String?, usb: String?) throws -> String? {
            let live = Self.usable(live)
            let usb = Self.usable(usb)
            if let live, let usb {
                let liveCanonical = Self.canonicalFamily(live)
                let usbCanonical = Self.canonicalFamily(usb)
                if liveCanonical != usbCanonical {
                    throw UpdateIdentityError.conflictingEvidence(
                        field: "family", live: live, usb: usb)
                }
                return liveCanonical
            }
            return live ?? usb
        }

        private func mergedChip(live: String?, usb: String?) throws -> String? {
            let live = usableChip(live)
            let usb = usableChip(usb)
            if let live, let usb, live != usb {
                throw UpdateIdentityError.conflictingEvidence(
                    field: "chip", live: live, usb: usb)
            }
            return live ?? usb
        }

        private static func usable(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else { return nil }
            return value
        }

        private static func canonicalFamily(_ value: String) -> String {
            for (family, aliases) in universalFamilyAliases where aliases.contains(value) {
                return family
            }
            return value
        }

        private func usableChip(_ value: String?) -> String? {
            guard let value = Self.usable(value), value != ServiceMetadata.unknownChip else {
                return nil
            }
            return value
        }
    }

    enum Availability: Equatable {
        case none
        case unreadable(path: String, reason: String)
        case ready(ReleaseSet)
    }

    static func catalogURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: catalogResourceName, withExtension: "json")
    }

    static func load(in bundle: Bundle = .main) -> Availability {
        guard let catalogURL = catalogURL(in: bundle) else { return .none }
        do {
            let catalog = try FirmwareReleaseCatalog.read(contentsOf: catalogURL)
            guard let resourceURL = bundle.resourceURL else { return .none }
            let files = try FileManager.default.contentsOfDirectory(
                at: resourceURL, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
            let firmwareFiles = files.filter {
                $0.pathExtension == FirmwareBundle.fileExtension
            }
            let expectedNames = Set(catalog.families.values.map {
                URL(fileURLWithPath: $0.artifact).lastPathComponent
            })
            guard firmwareFiles.count == expectedNames.count,
                  Set(firmwareFiles.map(\.lastPathComponent)) == expectedNames
            else {
                return .unreadable(
                    path: catalogURL.lastPathComponent,
                    reason: "embedded firmware resources do not exactly match the catalog")
            }

            var selections = [String: Selection]()
            for entry in catalog.families.values {
                let name = URL(fileURLWithPath: entry.artifact).lastPathComponent
                guard let url = firmwareFiles.first(where: { $0.lastPathComponent == name })
                else {
                    return .unreadable(path: name, reason: "catalog artifact is missing")
                }
                let data = try Data(contentsOf: url)
                let firmware = try catalog.bundle(for: entry, data: data)
                guard selections.updateValue(
                    Selection(catalogEntry: entry, bundle: firmware, url: url),
                    forKey: entry.family) == nil
                else {
                    return .unreadable(path: name, reason: "duplicate family resource")
                }
            }
            return .ready(ReleaseSet(catalog: catalog, selections: selections))
        } catch {
            return .unreadable(
                path: catalogURL.lastPathComponent,
                reason: error.localizedDescription)
        }
    }
}
