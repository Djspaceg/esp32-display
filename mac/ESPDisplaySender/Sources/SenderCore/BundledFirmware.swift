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
