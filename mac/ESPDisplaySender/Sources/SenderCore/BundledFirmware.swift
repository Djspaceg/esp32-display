import Foundation
import SenderProtocol

/// The canonical c6, s3, and p4 firmware resources shipped inside the app.
enum BundledFirmware {
    static let catalogResourceName = "manifest"

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
        /// one universal C6/S3 image and no present family/profile/partition
        /// evidence contradicts it. OTA only: the USB write path still demands
        /// exact, current evidence and must not be handed a family target.
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
        /// enough to also fix an exact write target: it is for the universal C6
        /// and S3 families, whose one image serves every carrier, but not for a
        /// compile-fixed carrier like P4, which stays target-gated on complete
        /// identity or an explicit profile even when its artifact is shown.
        func selectForUniqueChip(_ chip: String) -> Selection? {
            let matches = selections.values.filter { $0.catalogEntry.chip == chip }
            guard matches.count == 1 else { return nil }
            return matches.first
        }

        /// Legacy family aliases a universal image still answers to, so a board
        /// that reports an old exact target instead of its family is not read as
        /// a contradiction. Canonical `c6`/`s3` and missing/empty are accepted
        /// too; only the universal families appear here, so P4 never falls back.
        private static let universalFamilyAliases: [String: Set<String>] = [
            "c6": ["c6"],
            "s3": ["s3", "s3-085", "s3-154", "s3-175", "s3-185"],
        ]

        /// Choose the update image for a panel: strict complete-identity
        /// selection first, then a unique-chip universal (C6/S3) fallback only
        /// when no present evidence contradicts it.
        ///
        /// Pure and evidence-only. Strict selection wins whenever it succeeds and
        /// is reported as `.exact`. The fallback exists for the universal
        /// families, whose single image serves every carrier, so a panel that has
        /// not yet reported full runtime identity - the universal-release case
        /// that left the Update Firmware modal disabled - can still be offered its
        /// image over OTA. P4 is compile-fixed to one carrier and never falls
        /// back. Any chip/family/profile/partition contradiction rethrows the
        /// original strict error rather than papering over it with a fallback.
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

        private static func usable(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else { return nil }
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
