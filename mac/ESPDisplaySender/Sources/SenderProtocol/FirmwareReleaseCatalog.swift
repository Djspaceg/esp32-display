import CryptoKit
import Foundation

/// Canonical index for the three independently built firmware families.
public struct FirmwareReleaseCatalog: Equatable, Sendable {
    public struct Compatibility: Equatable, Sendable {
        public let flashBytes: [Int]
        public let partitionScheme: String
        public let bootloaderAddress: Int
        public let partitionsAddress: Int
        public let bootApp0Address: Int
        public let appAddress: Int
        public let identityRequired: [String]
    }

    public struct Entry: Equatable, Sendable {
        public let family: String
        public let latestVersion: String
        public let latestBuild: UInt32?
        public let artifact: String
        public let sha256: String
        public let byteCount: Int
        public let revisions: [Revision]
        public let chip: String
        public let profiles: [String]
        public let hardware: [String: [String]]
        public let compatibility: Compatibility
    }

    public struct Revision: Equatable, Sendable, Identifiable {
        public let version: String
        public let build: UInt32?
        public let artifact: String
        public let sha256: String
        public let byteCount: Int

        public var id: String { artifact }
    }

    public struct Identity: Equatable, Sendable {
        public let family: String?
        public let chip: String?
        public let profile: String?
        public let partition: String?

        public init(
            family: String?, chip: String?, profile: String?, partition: String?
        ) {
            self.family = family
            self.chip = chip
            self.profile = profile
            self.partition = partition
        }
    }

    public let schema: Int
    public let generatedAt: String
    public let families: [String: Entry]

    public static let legacySchema = 1
    public static let singleRevisionSchema = 2
    public static let currentSchema = 3
    public static let requiredFamilies = GeneratedBoardCatalog.requiredFamilies
    public static let fileName = "manifest.json"

    public static func read(_ data: Data) throws -> FirmwareReleaseCatalog {
        if let duplicate = FirmwareBundle.firstDuplicateManifestKey(in: data) {
            throw FirmwareReleaseCatalogError.duplicateKey(
                FirmwareBundle.safeManifestKeyDisplay(duplicate))
        }
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw FirmwareReleaseCatalogError.invalidJSON(error.localizedDescription)
        }
        guard let root = decoded as? [String: Any] else {
            throw FirmwareReleaseCatalogError.notAnObject
        }
        try requireKeys(root, exactly: ["schema", "generated_at", "families"], at: "catalog")
        let schema = try integer(root["schema"], at: "catalog.schema")
        guard [legacySchema, singleRevisionSchema, currentSchema].contains(schema) else {
            throw FirmwareReleaseCatalogError.unsupportedSchema(schema)
        }
        let generatedAt = try token(root["generated_at"], at: "catalog.generated_at")
        guard let rawFamilies = root["families"] as? [String: Any],
              Set(rawFamilies.keys) == requiredFamilies
        else { throw FirmwareReleaseCatalogError.incompleteFamilies }

        var families = [String: Entry]()
        let expected = GeneratedBoardCatalog.expected
        for family in requiredFamilies.sorted() {
            guard let raw = rawFamilies[family] as? [String: Any] else {
                throw FirmwareReleaseCatalogError.invalidEntry(family)
            }
            var entryKeys: Set<String> = [
                "latest_version", "artifact", "sha256", "bytes", "chip",
                "profiles", "hardware", "compatibility",
            ]
            if schema == singleRevisionSchema { entryKeys.insert("latest_build") }
            if schema == currentSchema { entryKeys.insert("revisions") }
            try requireKeys(raw, exactly: entryKeys, at: family)
            let version = try token(raw["latest_version"], at: "\(family).latest_version")
            guard SemVer(version) != nil,
                  schema != currentSchema || !version.contains("+")
            else {
                throw FirmwareReleaseCatalogError.invalidVersion(family, version)
            }
            let build: UInt32?
            if schema == singleRevisionSchema {
                let value = try integer(raw["latest_build"], at: "\(family).latest_build")
                guard value > 0, let exact = UInt32(exactly: value) else {
                    throw FirmwareReleaseCatalogError.invalidField("\(family).latest_build")
                }
                build = exact
            } else {
                build = nil
            }
            let artifact = try token(raw["artifact"], at: "\(family).artifact")
            guard artifactIsCanonical(
                    artifact, family: family, version: version, build: build),
                  !artifact.hasPrefix("/"), !artifact.split(separator: "/").contains("..")
            else { throw FirmwareReleaseCatalogError.invalidArtifact(family) }
            let digest = try token(raw["sha256"], at: "\(family).sha256")
            guard digest.count == 64,
                  digest.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) })
            else { throw FirmwareReleaseCatalogError.invalidHash(family) }
            let byteCount = try integer(raw["bytes"], at: "\(family).bytes")
            guard byteCount > 0 else { throw FirmwareReleaseCatalogError.invalidSize(family) }
            let latestRevision = Revision(
                version: version, build: build, artifact: artifact,
                sha256: digest, byteCount: byteCount)
            let revisions: [Revision]
            if schema == currentSchema {
                guard let rawRevisions = raw["revisions"] as? [Any],
                      !rawRevisions.isEmpty
                else {
                    throw FirmwareReleaseCatalogError.invalidRevisions(family)
                }
                revisions = try rawRevisions.enumerated().map { index, value in
                    try parseRevision(
                        value, family: family, at: "\(family).revisions[\(index)]")
                }
                guard revisions.first == latestRevision,
                      Set(revisions.map(\.artifact)).count == revisions.count,
                      Set(revisions.map(\.version)).count == revisions.count,
                      zip(revisions, revisions.dropFirst()).allSatisfy({ pair in
                          guard let left = SemVer(pair.0.version),
                                let right = SemVer(pair.1.version)
                          else { return false }
                          return left.isNewer(than: right)
                      })
                else {
                    throw FirmwareReleaseCatalogError.invalidRevisions(family)
                }
            } else {
                revisions = [latestRevision]
            }
            let chip = try token(raw["chip"], at: "\(family).chip")
            let profiles = try tokenList(raw["profiles"], at: "\(family).profiles")
            guard let rawHardware = raw["hardware"] as? [String: Any],
                  Set(rawHardware.keys) == Set(profiles)
            else { throw FirmwareReleaseCatalogError.invalidHardware(family) }
            var hardware = [String: [String]]()
            for profile in profiles {
                hardware[profile] = try tokenList(
                    rawHardware[profile], at: "\(family).hardware.\(profile)")
            }
            let compatibility = try parseCompatibility(raw["compatibility"], family: family)
            guard let required = expected[family], chip == required.chip,
                  profiles == required.profiles,
                  compatibility.flashBytes == required.flashBytes,
                  compatibility.partitionScheme == required.partition,
                  compatibility.bootloaderAddress == required.bootloaderAddress,
                  compatibility.partitionsAddress == 0x8000,
                  compatibility.bootApp0Address == 0xE000,
                  compatibility.appAddress == 0x10000
            else { throw FirmwareReleaseCatalogError.invalidCompatibility(family) }
            families[family] = Entry(
                family: family, latestVersion: version, latestBuild: build,
                artifact: artifact,
                sha256: digest, byteCount: byteCount, revisions: revisions,
                chip: chip,
                profiles: profiles, hardware: hardware,
                compatibility: compatibility)
        }
        return FirmwareReleaseCatalog(
            schema: schema, generatedAt: generatedAt, families: families)
    }

    public static func read(contentsOf url: URL) throws -> FirmwareReleaseCatalog {
        do {
            return try read(Data(contentsOf: url))
        } catch let error as FirmwareReleaseCatalogError {
            throw error
        } catch {
            throw FirmwareReleaseCatalogError.unreadableFile(
                url.lastPathComponent, error.localizedDescription)
        }
    }

    /// Select only from complete independent runtime identity evidence.
    public func entry(for identity: Identity) throws -> Entry {
        guard let family = Self.usable(identity.family),
              let chip = Self.usable(identity.chip),
              let profile = Self.usable(identity.profile),
              let partition = Self.usable(identity.partition)
        else { throw FirmwareReleaseCatalogError.identityIncomplete }
        guard let entry = families[family] else {
            throw FirmwareReleaseCatalogError.unknownFamily(family)
        }
        guard entry.chip == chip else {
            throw FirmwareReleaseCatalogError.chipMismatch(expected: entry.chip, found: chip)
        }
        guard entry.profiles.contains(profile) else {
            throw FirmwareReleaseCatalogError.profileMismatch(family: family, found: profile)
        }
        guard entry.compatibility.partitionScheme == partition else {
            throw FirmwareReleaseCatalogError.partitionMismatch(
                expected: entry.compatibility.partitionScheme, found: partition)
        }
        return entry
    }

    /// Verify the catalog digest/size and all compatibility metadata in one bundle.
    public func bundle(for entry: Entry, data: Data) throws -> FirmwareBundle {
        guard let revision = entry.revisions.first else {
            throw FirmwareReleaseCatalogError.invalidRevisions(entry.family)
        }
        return try bundle(for: revision, in: entry, data: data)
    }

    /// Verify one independently selectable revision against its family contract.
    public func bundle(
        for revision: Revision, in entry: Entry, data: Data
    ) throws -> FirmwareBundle {
        guard data.count == revision.byteCount else {
            throw FirmwareReleaseCatalogError.artifactSizeMismatch(entry.family)
        }
        guard FirmwareBundle.sha256Hex(data) == revision.sha256 else {
            throw FirmwareReleaseCatalogError.artifactHashMismatch(entry.family)
        }
        let bundle = try FirmwareBundle.read(data)
        guard bundle.firmwareVersion == revision.version,
              bundle.firmwareBuild == revision.build,
              bundle.images.count == 1,
              bundle.targets == [entry.family],
              let image = bundle.images.first,
              image.targets == [entry.family],
              image.chip == entry.chip,
              image.profiles == entry.profiles,
              image.flashSizes == entry.compatibility.flashBytes,
              let partition = image.partition,
              image.appAddress == entry.compatibility.appAddress,
              image.flashPart(role: "bootloader")?.address
                == entry.compatibility.bootloaderAddress,
              image.flashPart(role: "partitions")?.address
                == entry.compatibility.partitionsAddress,
              image.flashPart(role: "boot_app0")?.address
                == entry.compatibility.bootApp0Address
        else { throw FirmwareReleaseCatalogError.bundleMetadataMismatch(entry.family) }
        if ["s3", "p4"].contains(entry.family),
           image.flashPart(role: "doom_wad") == nil {
            throw FirmwareReleaseCatalogError.revisionMissingPayload(
                family: entry.family, role: "doom_wad")
        }
        guard partition == entry.compatibility.partitionScheme else {
            throw FirmwareReleaseCatalogError.revisionPartitionMismatch(
                family: entry.family,
                expected: entry.compatibility.partitionScheme,
                found: partition)
        }
        guard bundle.flashPlan(forTarget: entry.family) != nil else {
            throw FirmwareReleaseCatalogError.bundleMetadataMismatch(entry.family)
        }
        return bundle
    }

    private static func parseRevision(
        _ value: Any, family: String, at owner: String
    ) throws -> Revision {
        guard let raw = value as? [String: Any] else {
            throw FirmwareReleaseCatalogError.invalidRevisions(family)
        }
        try requireKeys(
            raw, exactly: ["version", "artifact", "sha256", "bytes"],
            at: owner)
        let version = try token(raw["version"], at: "\(owner).version")
        guard SemVer(version) != nil, !version.contains("+") else {
            throw FirmwareReleaseCatalogError.invalidVersion(family, version)
        }
        let artifact = try token(raw["artifact"], at: "\(owner).artifact")
        guard artifactIsCanonical(
                artifact, family: family, version: version, build: nil),
              !artifact.hasPrefix("/"), !artifact.split(separator: "/").contains("..")
        else { throw FirmwareReleaseCatalogError.invalidArtifact(family) }
        let digest = try token(raw["sha256"], at: "\(owner).sha256")
        guard digest.count == 64,
              digest.allSatisfy({
                  $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0)))
              })
        else { throw FirmwareReleaseCatalogError.invalidHash(family) }
        let byteCount = try integer(raw["bytes"], at: "\(owner).bytes")
        guard byteCount > 0 else {
            throw FirmwareReleaseCatalogError.invalidSize(family)
        }
        return Revision(
            version: version, build: nil, artifact: artifact,
            sha256: digest, byteCount: byteCount)
    }

    private static func parseCompatibility(
        _ value: Any?, family: String
    ) throws -> Compatibility {
        guard let raw = value as? [String: Any] else {
            throw FirmwareReleaseCatalogError.invalidCompatibility(family)
        }
        try requireKeys(
            raw,
            exactly: [
                "flash_bytes", "partition_scheme", "bootloader_address",
                "partitions_address", "boot_app0_address", "app_address",
                "identity_required",
            ],
            at: "\(family).compatibility")
        let required = try tokenList(
            raw["identity_required"], at: "\(family).compatibility.identity_required")
        guard required == ["family", "chip", "profile", "partition"] else {
            throw FirmwareReleaseCatalogError.invalidCompatibility(family)
        }
        return Compatibility(
            flashBytes: try integerList(
                raw["flash_bytes"], at: "\(family).compatibility.flash_bytes"),
            partitionScheme: try token(
                raw["partition_scheme"], at: "\(family).compatibility.partition_scheme"),
            bootloaderAddress: try integer(
                raw["bootloader_address"], at: "\(family).compatibility.bootloader_address"),
            partitionsAddress: try integer(
                raw["partitions_address"], at: "\(family).compatibility.partitions_address"),
            bootApp0Address: try integer(
                raw["boot_app0_address"], at: "\(family).compatibility.boot_app0_address"),
            appAddress: try integer(
                raw["app_address"], at: "\(family).compatibility.app_address"),
            identityRequired: required)
    }

    private static func artifactIsCanonical(
        _ artifact: String, family: String, version: String, build: UInt32?
    ) -> Bool {
        guard let build else {
            return artifact == "\(family)/espdisp-\(family)-\(version).espdispfw"
        }
        let prefix = "\(family)/espdisp-\(family)-\(version)+\(build)"
        guard artifact.hasPrefix(prefix) else { return false }
        let suffix = String(artifact.dropFirst(prefix.count))
        if suffix == ".espdispfw" { return true }
        guard suffix.hasPrefix(".g"), suffix.hasSuffix(".espdispfw") else {
            return false
        }
        let sha = suffix.dropFirst(2).dropLast(".espdispfw".count)
        return sha.count == 7 && sha.allSatisfy {
            $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0)))
        }
    }

    private static func requireKeys(
        _ object: [String: Any], exactly keys: Set<String>, at owner: String
    ) throws {
        guard Set(object.keys) == keys else {
            throw FirmwareReleaseCatalogError.invalidKeys(owner)
        }
    }

    private static func token(_ value: Any?, at owner: String) throws -> String {
        guard let value = value as? String, usable(value) != nil else {
            throw FirmwareReleaseCatalogError.invalidField(owner)
        }
        return value
    }

    private static func usable(_ value: String?) -> String? {
        guard let value, !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return value
    }

    private static func tokenList(_ value: Any?, at owner: String) throws -> [String] {
        guard let raw = value as? [Any], !raw.isEmpty else {
            throw FirmwareReleaseCatalogError.invalidField(owner)
        }
        var result = [String]()
        for item in raw {
            let value = try token(item, at: owner)
            guard !result.contains(value) else {
                throw FirmwareReleaseCatalogError.invalidField(owner)
            }
            result.append(value)
        }
        return result
    }

    private static func integerList(_ value: Any?, at owner: String) throws -> [Int] {
        guard let raw = value as? [Any], !raw.isEmpty else {
            throw FirmwareReleaseCatalogError.invalidField(owner)
        }
        var result = [Int]()
        for item in raw {
            let value = try integer(item, at: owner)
            guard value > 0, !result.contains(value) else {
                throw FirmwareReleaseCatalogError.invalidField(owner)
            }
            result.append(value)
        }
        return result
    }

    private static func integer(_ value: Any?, at owner: String) throws -> Int {
        if let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
            throw FirmwareReleaseCatalogError.invalidField(owner)
        }
        guard let number = value as? NSNumber,
              !CFNumberIsFloatType(number as CFNumber),
              let exact = Int(exactly: number.int64Value)
        else { throw FirmwareReleaseCatalogError.invalidField(owner) }
        return exact
    }

    private struct SemVer {
        let core: [Int]
        let prerelease: [String]

        init?(_ value: String) {
            let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: value, range: NSRange(value.startIndex..., in: value)),
                  match.range == NSRange(value.startIndex..., in: value)
            else { return nil }
            var core = [Int]()
            for index in 1...3 {
                guard let range = Range(match.range(at: index), in: value),
                      let number = Int(value[range])
                else { return nil }
                core.append(number)
            }
            self.core = core
            if let range = Range(match.range(at: 4), in: value) {
                prerelease = value[range].split(separator: ".").map(String.init)
            } else {
                prerelease = []
            }
        }

        func isNewer(than other: SemVer) -> Bool {
            if core != other.core {
                return other.core.lexicographicallyPrecedes(core)
            }
            if prerelease.isEmpty || other.prerelease.isEmpty {
                return prerelease.isEmpty && !other.prerelease.isEmpty
            }
            for (left, right) in zip(prerelease, other.prerelease) {
                if left == right { continue }
                let leftNumber = Int(left)
                let rightNumber = Int(right)
                switch (leftNumber, rightNumber) {
                case let (.some(a), .some(b)): return a > b
                case (.some, .none): return false
                case (.none, .some): return true
                case (.none, .none): return left > right
                }
            }
            return prerelease.count > other.prerelease.count
        }
    }
}

public enum FirmwareReleaseCatalogError: Error, LocalizedError, Equatable {
    case unreadableFile(String, String)
    case invalidJSON(String)
    case duplicateKey(String)
    case notAnObject
    case unsupportedSchema(Int)
    case invalidKeys(String)
    case invalidField(String)
    case incompleteFamilies
    case invalidEntry(String)
    case invalidVersion(String, String)
    case invalidArtifact(String)
    case invalidHash(String)
    case invalidSize(String)
    case invalidRevisions(String)
    case invalidHardware(String)
    case invalidCompatibility(String)
    case identityIncomplete
    case unknownFamily(String)
    case chipMismatch(expected: String, found: String)
    case profileMismatch(family: String, found: String)
    case partitionMismatch(expected: String, found: String)
    case artifactSizeMismatch(String)
    case artifactHashMismatch(String)
    case bundleMetadataMismatch(String)
    case revisionPartitionMismatch(family: String, expected: String, found: String)
    case revisionMissingPayload(family: String, role: String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let path, let reason): return "Cannot read \(path): \(reason)"
        case .invalidJSON(let reason): return "Release catalog is not valid JSON: \(reason)"
        case .duplicateKey(let key): return "Release catalog contains duplicate key \(key)."
        case .notAnObject: return "Release catalog is not a JSON object."
        case .unsupportedSchema(let schema): return "Unsupported release catalog schema \(schema)."
        case .invalidKeys(let owner): return "Release catalog has invalid keys at \(owner)."
        case .invalidField(let field): return "Release catalog has an invalid \(field) field."
        case .incompleteFamilies: return "Release catalog must contain exactly c6, s3, and p4."
        case .invalidEntry(let family): return "Release catalog entry \(family) is not an object."
        case .invalidVersion(let family, let value): return "\(family) has invalid version \(value)."
        case .invalidArtifact(let family): return "\(family) has a non-canonical artifact path."
        case .invalidHash(let family): return "\(family) has an invalid SHA-256."
        case .invalidSize(let family): return "\(family) has an invalid byte count."
        case .invalidRevisions(let family):
            return "\(family) must carry unique shipping revisions, newest first."
        case .invalidHardware(let family): return "\(family) has incomplete hardware mappings."
        case .invalidCompatibility(let family): return "\(family) has invalid compatibility metadata."
        case .identityIncomplete: return "Family, chip, profile, and partition identity are required."
        case .unknownFamily(let family): return "No release exists for family \(family)."
        case .chipMismatch(let expected, let found): return "Chip \(found) does not match \(expected)."
        case .profileMismatch(let family, let found): return "Profile \(found) is not valid for \(family)."
        case .partitionMismatch(let expected, let found): return "Partition \(found) does not match \(expected)."
        case .artifactSizeMismatch(let family): return "\(family) artifact byte count does not match the catalog."
        case .artifactHashMismatch(let family): return "\(family) artifact hash does not match the catalog."
        case .bundleMetadataMismatch(let family): return "\(family) bundle metadata does not match the catalog."
        case .revisionPartitionMismatch(let family, let expected, let found):
            return "\(family) revision uses partition layout \(found); current validation requires \(expected)."
        case .revisionMissingPayload(let family, let role):
            if role == "doom_wad" {
                return "\(family) revision is missing the required Doom WAD (doom_wad) payload."
            }
            return "\(family) revision does not carry the required \(role) payload."
        }
    }
}
