import CryptoKit
import Foundation

/// A `.espdispfw` firmware bundle, read and verified.
///
/// The file is written by `tools/espdisp.py bundle` and travels: the machine that
/// compiled the images is not necessarily the machine that pushes them, and the
/// two may be weeks apart. That makes this the second implementation of a format
/// whose first implementation is already shipping files, so this reader is
/// written to agree with that one rather than to be convenient - see
/// `readingRules` below for the places where agreeing costs something.
///
/// LAYOUT, byte for byte:
///
///     offset 0        "ESPDISPFW2\n"    11 bytes, magic and format generation
///     offset 11       "%010d\n"         11 bytes, manifest length, zero padded
///     offset 22       manifest          UTF-8 JSON object, exactly that many bytes
///     offset 22+len   payloads          raw, concatenated in manifest order: for
///                                       each image its application image, then
///                                       that image's flash parts in listed order
///
/// The fixed 22-byte prefix is what lets a reader reach the manifest without
/// reading two megabytes, and the payloads are byte-identical to arduino-cli's
/// `<sketch>.ino.bin`, so `sha256` in the manifest is the number `shasum -a 256`
/// prints for the compiled file.
///
/// TWO GENERATIONS, AND WHY BOTH ARE READ. Generation 1 carried one application
/// image per chip: right for OTA, where the image goes into an app slot and the
/// bootloader already on the panel boots it, and not enough for a board that has
/// never been flashed, which needs the second-stage bootloader, the partition
/// table and boot_app0 written at their own flash addresses first. Generation 2
/// carries those, with their addresses.
///
/// The generation was bumped rather than extended because a generation-1 reader
/// walks the payload area with `offset == cursor` and then requires
/// `cursor == total`, so any extra payload trips either the contiguity check or
/// the trailing-bytes check. A file the shipped reader would accept could only be
/// had by weakening one of the two checks that catch a truncated or concatenated
/// file. Refusing loudly is better, and the message for it already existed.
///
/// This reader still accepts a generation-1 file, and reports no flash parts for
/// one. Such a file cannot bring up a blank board, but it is a perfectly good
/// OTA payload and whoever holds one may have no way to rebuild it. `format`
/// records which generation was read.
///
/// WHAT THIS CANNOT CHECK. That an image is right for a panel. The hashes prove
/// the file is intact and the `chip` token says who each image is for, but only
/// the panel's own image validation settles it - see
/// `FirmwareUpdateAvailability` for how much of an opinion this side is entitled
/// to.
public struct FirmwareBundle: Equatable, Sendable {
    /// One payload that is written to a fixed flash address over USB, rather than
    /// into an app slot: the bootloader, the partition table, or boot_app0.
    ///
    /// THE ADDRESS COMES FROM THE FILE. It is not a constant here and must not
    /// become one: `boards.txt` puts the bootloader at 0x0 for esp32c6 and
    /// esp32s3 and at 0x1000 for the classic ESP32, so it is per-chip data, and a
    /// reader that assumed would write a bootloader to the wrong address on the
    /// first board with a different map - which the flash would accept and the
    /// chip would then fail to boot.
    public struct FlashPart: Equatable, Sendable {
        /// `bootloader`, `partitions` or `boot_app0`. The vocabulary is
        /// `FirmwareBundle.requiredFlashRoles` plus whatever a later writer adds.
        public let role: String
        /// The flash address this payload is written to.
        public let address: Int
        /// The filename it was taken from, so a user can see what they have.
        public let filename: String
        /// Absolute offset of the payload from the start of the file.
        public let offset: Int
        public let byteCount: Int
        /// Lowercase hex sha256 of the payload, as the writer computed it.
        public let sha256: String
    }

    /// One application image and everything the manifest says about it.
    public struct Image: Equatable, Sendable {
        /// The CLI's board key, e.g. `c6`. For display; `chip` is the identifier.
        public let board: String
        /// The IDF target token, e.g. `esp32c6`. One vocabulary with the panel's
        /// `chip` TXT record and with `tools/espdisp.py BOARDS[*].chip`.
        public let chip: String
        /// The FQBN it was compiled with, so a user can see what they have.
        public let fqbn: String
        /// The image's filename as arduino-cli produced it.
        public let filename: String
        /// Absolute offset of the payload from the start of the file.
        public let offset: Int
        public let byteCount: Int
        /// Lowercase hex sha256 of the payload, as the writer computed it.
        public let sha256: String
        /// The flash address the application image is written to over USB, or nil
        /// for a generation-1 file, which says nothing about flash addresses.
        ///
        /// Carried rather than assumed for the same reason as `FlashPart.address`,
        /// with one more: it is the partition table that decides where the app
        /// lives, and the partition table travels in this same file, so the two
        /// cannot drift apart.
        public let appAddress: Int?
        /// The parts a blank board needs, in the order the writer listed them,
        /// which is also the order they are written. Empty for a generation-1 file.
        public let flashParts: [FlashPart]

        /// The part for a role, or nil if this image carries none.
        public func flashPart(role: String) -> FlashPart? {
            flashParts.first { $0.role == role }
        }
    }

    /// One write in a USB flash: an address and the bytes that go there.
    ///
    /// Assembled by `flashPlan(forChip:)` so the decision of what goes where is
    /// made here, against a verified file, rather than in whatever spawns esptool.
    public struct FlashWrite: Equatable, Sendable {
        /// `app`, or the `FlashPart.role` this write came from.
        public let role: String
        public let address: Int
        public let filename: String
        public let sha256: String
        public let payload: Data
    }

    /// The role `flashPlan(forChip:)` gives the application image, which is not a
    /// `FlashPart` in the manifest - it is the OTA payload, and it is carried once.
    public static let appFlashRole = "app"

    public let format: Int
    /// `FW_VERSION` as read out of the sketch the images were built from.
    public let firmwareVersion: String
    /// ISO 8601 UTC, `Z` suffix. Kept as the string the manifest carries rather
    /// than a `Date`: it is shown to a person, and a parse that failed would
    /// throw away information to gain nothing.
    public let builtAt: String
    /// 40 hex characters, or nil when the images were not built from a git
    /// checkout. The writer records JSON null for that case.
    public let sourceCommit: String?
    /// Whether that checkout had uncommitted changes, untracked files included.
    public let sourceDirty: Bool
    /// Which tool wrote the file, e.g. `espdisp.py bundle`.
    public let tool: String
    /// The images, in manifest order, which is also payload order.
    public let images: [Image]
    /// The application payloads, keyed by chip token. Verified against their
    /// hashes.
    public let payloads: [String: Data]
    /// The flash parts, keyed by chip token and then by role. Verified against
    /// their hashes. Empty for a generation-1 file.
    public let flashPayloads: [String: [String: Data]]

    /// The newest generation, which is what a current writer produces.
    public static let magic = Data("ESPDISPFW2\n".utf8)
    /// The `format` field that goes with `magic`.
    public static let format = 2
    /// Generation 1, still read: app images only, no flash parts.
    public static let magicV1 = Data("ESPDISPFW1\n".utf8)
    public static let formatV1 = 1
    /// Which magic means which format. Every magic is the same width, which is
    /// what keeps the manifest at offset 22 for every generation - `headerBytes`
    /// is one number for both, and
    /// `testGenerationOneIsStillReadAndCarriesNoFlashParts` pins it.
    public static let generations: [Data: Int] = [magicV1: formatV1, magic: format]
    public static let lengthDigits = 10
    /// Magic line plus length line. The manifest starts here, always.
    public static let headerBytes = 22
    public static let fileExtension = "espdispfw"

    /// Every manifest key a reader may rely on, and every image key.
    /// Both lists are checked for presence before anything is read out of them,
    /// so one refusal can name all of what is missing at once.
    public static let manifestKeys = [
        "format", "firmware_version", "built_at", "source_commit", "source_dirty",
        "tool", "images",
    ]
    /// Generation 1's image keys, which generation 2 keeps and adds to.
    public static let imageKeys = [
        "board", "chip", "fqbn", "filename", "offset", "bytes", "sha256",
    ]
    public static let imageKeysV2 = imageKeys + ["app_address", "flash_parts"]
    public static let flashPartKeys = [
        "role", "address", "filename", "offset", "bytes", "sha256",
    ]

    /// The three parts a board with nothing on it needs, in write order.
    ///
    /// A generation-2 image must carry all three, and this reader refuses one
    /// that does not: the generation exists so that "this file can bring up a
    /// blank board" is true of every file claiming to be one, and a caller that
    /// had to check role by role would be left answering "maybe". Extra roles are
    /// accepted, so a later writer can add a filesystem image without a bump.
    public static let requiredFlashRoles = ["bootloader", "partitions", "boot_app0"]

    // WHERE THIS READER IS DELIBERATELY STRICT OR DELIBERATELY LOOSE, AND WHY.
    // These are the decisions that keep two implementations in agreement, and
    // every one of them is invisible in the parsing code below.
    //
    // LOOSE ABOUT ENCODING. The manifest is parsed as JSON, not matched as
    /// bytes. `espdisp.py` writes it with `sort_keys=True` and no whitespace, so
    /// today the encoding is canonical - but that is the writer's business, and a
    /// future writer in another language that emits the same object with keys in
    /// another order or spaces after the colons must be readable here. Nothing
    /// below depends on key order, on whitespace, or on the manifest being
    /// re-encodable to the same bytes.
    ///
    // STRICT ABOUT HASH SPELLING. `sha256` is compared as an exact string
    // against a lowercase hex digest, so an uppercase hash is refused. That
    // looks needlessly harsh, and it is on purpose: `espdisp.py` compares the
    // same way, so accepting uppercase here would create files this reader takes
    // and the CLI's own `bundle-info` rejects. One of the two has to define it,
    // and the one already shipping files does.
    //
    // STRICT ABOUT TRAILING BYTES. A file with anything after the last payload
    // is refused, matching the writer, because the only ways to get there are a
    // concatenation, an interrupted overwrite, or a hand edit - and all three
    // mean the file is not what it claims to be.
    //
    // STRICT ABOUT CONTIGUITY. Offsets are absolute, so they can be checked
    // against where each payload must land rather than merely being in range.
    // That is what catches a truncation that happens to leave a valid manifest.

    // MARK: - reading

    /// Read and fully verify a bundle. Throws `FirmwareBundleError`.
    ///
    /// Everything checkable without a panel is checked here, including the sha256
    /// of every payload, because this runs at the moment a user hands the app a
    /// file and it is the last chance to say "this file is damaged" rather than
    /// "the panel rejected the image after two megabytes".
    public static func read(_ data: Data) throws -> FirmwareBundle {
        // A `Data` that came from a slice does not start at index 0, and reading
        // this file is all absolute offsets. Everything below is relative to
        // `base` for that reason; indexing from 0 would trap on a sliced input.
        let base = data.startIndex
        let total = data.count

        guard total >= headerBytes else { throw FirmwareBundleError.tooShort(bytes: total) }
        let opening = Data(data[base..<(base + magic.count)])
        guard let generation = generations[opening] else {
            if opening.starts(with: Data("ESPDISPFW".utf8)) {
                // A generation this build does not know. Name both, so someone
                // holding a newer file knows it is the app that is behind.
                throw FirmwareBundleError.unsupportedGeneration(
                    found: printable(opening, trimmed: true),
                    supported: generations.keys
                        .map { printable($0, trimmed: true) }
                        .sorted()
                        .joined(separator: " and "))
            }
            throw FirmwareBundleError.notABundle
        }

        // The length line is a fixed 11-byte slice, so its width needs no check:
        // what has to be checked is that it ends in the newline and that the ten
        // characters before it are ASCII digits. Both are load-bearing. Without
        // the newline check a file whose manifest starts one byte early would be
        // read with every offset in it one byte out. Without the digit check
        // `Int(_:)` would accept a signed field: "+000000350" would be read as
        // 350 - a file espdisp.py refuses and this would take - and "-000000350"
        // would be read as -350, which makes the manifest range run backwards.
        let lineRange = (base + magic.count)..<(base + headerBytes)
        let line = String(decoding: data[lineRange], as: UTF8.self)
        let digits = String(line.dropLast())
        guard line.hasSuffix("\n"),
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let manifestBytes = Int(digits)
        else { throw FirmwareBundleError.malformedLengthLine(found: printable(data[lineRange])) }

        let manifestEnd = headerBytes + manifestBytes
        guard manifestEnd <= total else {
            throw FirmwareBundleError.truncatedManifest(
                claimed: manifestBytes, available: total - headerBytes)
        }
        let manifest = try decodeManifest(data[(base + headerBytes)..<(base + manifestEnd)])

        let missing = manifestKeys.filter { manifest[$0] == nil }
        guard missing.isEmpty else {
            throw FirmwareBundleError.manifestMissingKeys(missing)
        }
        // The magic and the manifest's own `format` are two statements of the same
        // fact, so a file where they disagree is self-contradictory whichever one
        // is right. Believing either would mean reading one generation's body as
        // another's, so neither is believed.
        let format = try integer(manifest["format"], key: "format", where: "the manifest")
        guard format == generation else {
            throw FirmwareBundleError.unsupportedFormat(found: format, supported: generation)
        }
        guard let rawImages = manifest["images"] as? [Any], !rawImages.isEmpty else {
            throw FirmwareBundleError.noImages
        }

        var images = [Image]()
        var payloads = [String: Data]()
        var flashPayloads = [String: [String: Data]]()
        var cursor = manifestEnd
        let keysForGeneration = generation == formatV1 ? imageKeys : imageKeysV2
        for (index, rawImage) in rawImages.enumerated() {
            let where_ = "image \(index)"
            guard let entry = rawImage as? [String: Any] else {
                throw FirmwareBundleError.imageNotAnObject(index: index)
            }
            let absent = keysForGeneration.filter { entry[$0] == nil }
            guard absent.isEmpty else {
                throw FirmwareBundleError.imageMissingKeys(index: index, keys: absent)
            }
            let chip = try string(entry["chip"], key: "chip", where: where_)
            let offset = try integer(entry["offset"], key: "offset", where: where_)
            let byteCount = try integer(entry["bytes"], key: "bytes", where: where_)
            guard offset >= 0, byteCount > 0 else {
                throw FirmwareBundleError.nonsensicalExtent(
                    index: index, chip: chip, offset: offset, bytes: byteCount)
            }
            guard offset == cursor else {
                throw FirmwareBundleError.notContiguous(
                    index: index, chip: chip, offset: offset, expected: cursor)
            }
            guard offset + byteCount <= total else {
                throw FirmwareBundleError.pastEndOfFile(
                    index: index, chip: chip, end: offset + byteCount, fileBytes: total)
            }
            guard payloads[chip] == nil else {
                throw FirmwareBundleError.duplicateChip(chip)
            }
            let expected = try string(entry["sha256"], key: "sha256", where: where_)
            let payload = Data(data[(base + offset)..<(base + offset + byteCount)])
            let digest = sha256Hex(payload)
            guard digest == expected else {
                throw FirmwareBundleError.hashMismatch(
                    index: index, chip: chip, expected: expected, actual: digest)
            }
            payloads[chip] = payload
            cursor += byteCount

            // GENERATION 2: the parts a board with nothing on it needs. The same
            // four checks the application image just went through - extent,
            // contiguity, end of file, hash - applied again, written out rather
            // than shared so each refusal can name the role. A bootloader
            // mismatch reported as "image 1 (esp32s3)" would send someone looking
            // at the wrong payload.
            var parts = [FlashPart]()
            var roles = [String: Data]()
            var appAddress: Int?
            if generation != formatV1 {
                let address = try integer(entry["app_address"], key: "app_address",
                                          where: where_)
                guard address >= 0 else {
                    throw FirmwareBundleError.nonsensicalFlashAddress(
                        chip: chip, role: Self.appFlashRole, address: address)
                }
                appAddress = address
                guard let rawParts = entry["flash_parts"] as? [Any], !rawParts.isEmpty else {
                    throw FirmwareBundleError.noFlashParts(index: index, chip: chip)
                }
                var writes = [(address: address, role: Self.appFlashRole)]
                for (partIndex, rawPart) in rawParts.enumerated() {
                    guard let part = rawPart as? [String: Any] else {
                        throw FirmwareBundleError.flashPartNotAnObject(
                            index: index, partIndex: partIndex)
                    }
                    let missingPartKeys = flashPartKeys.filter { part[$0] == nil }
                    guard missingPartKeys.isEmpty else {
                        throw FirmwareBundleError.flashPartMissingKeys(
                            index: index, partIndex: partIndex, keys: missingPartKeys)
                    }
                    let partWhere = "image \(index) flash part \(partIndex)"
                    let role = try string(part["role"], key: "role", where: partWhere)
                    guard !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw FirmwareBundleError.flashPartHasNoRole(
                            index: index, partIndex: partIndex)
                    }
                    guard roles[role] == nil else {
                        throw FirmwareBundleError.duplicateFlashRole(chip: chip, role: role)
                    }
                    let partAddress = try integer(part["address"], key: "address",
                                                  where: partWhere)
                    guard partAddress >= 0 else {
                        throw FirmwareBundleError.nonsensicalFlashAddress(
                            chip: chip, role: role, address: partAddress)
                    }
                    let partOffset = try integer(part["offset"], key: "offset",
                                                 where: partWhere)
                    let partBytes = try integer(part["bytes"], key: "bytes", where: partWhere)
                    guard partOffset >= 0, partBytes > 0 else {
                        throw FirmwareBundleError.flashPartNonsensicalExtent(
                            chip: chip, role: role, offset: partOffset, bytes: partBytes)
                    }
                    guard partOffset == cursor else {
                        throw FirmwareBundleError.flashPartNotContiguous(
                            chip: chip, role: role, offset: partOffset, expected: cursor)
                    }
                    guard partOffset + partBytes <= total else {
                        throw FirmwareBundleError.flashPartPastEndOfFile(
                            chip: chip, role: role, end: partOffset + partBytes,
                            fileBytes: total)
                    }
                    let partExpected = try string(part["sha256"], key: "sha256",
                                                  where: partWhere)
                    let partPayload = Data(
                        data[(base + partOffset)..<(base + partOffset + partBytes)])
                    let partDigest = sha256Hex(partPayload)
                    guard partDigest == partExpected else {
                        throw FirmwareBundleError.flashPartHashMismatch(
                            chip: chip, role: role, expected: partExpected,
                            actual: partDigest)
                    }
                    parts.append(FlashPart(
                        role: role,
                        address: partAddress,
                        filename: try string(part["filename"], key: "filename",
                                             where: partWhere),
                        offset: partOffset,
                        byteCount: partBytes,
                        sha256: partExpected))
                    roles[role] = partPayload
                    writes.append((address: partAddress, role: role))
                    cursor += partBytes
                }
                let missingRoles = requiredFlashRoles.filter { roles[$0] == nil }
                guard missingRoles.isEmpty else {
                    throw FirmwareBundleError.missingFlashRoles(
                        chip: chip, roles: missingRoles)
                }
                // Two payloads claiming one flash address is a contradiction, not
                // a preference: only whichever went last would survive the write.
                var claimed = [Int: String]()
                for write in writes {
                    if let first = claimed[write.address] {
                        throw FirmwareBundleError.conflictingFlashAddresses(
                            chip: chip, address: write.address, first: first,
                            second: write.role)
                    }
                    claimed[write.address] = write.role
                }
                flashPayloads[chip] = roles
            }

            images.append(Image(
                board: try string(entry["board"], key: "board", where: where_),
                chip: chip,
                fqbn: try string(entry["fqbn"], key: "fqbn", where: where_),
                filename: try string(entry["filename"], key: "filename", where: where_),
                offset: offset,
                byteCount: byteCount,
                sha256: expected,
                appAddress: appAddress,
                flashParts: parts))
        }
        guard cursor == total else {
            throw FirmwareBundleError.trailingBytes(total - cursor)
        }

        return FirmwareBundle(
            format: format,
            firmwareVersion: try string(
                manifest["firmware_version"], key: "firmware_version", where: "the manifest"),
            builtAt: try string(manifest["built_at"], key: "built_at", where: "the manifest"),
            // JSON null is a real answer here - it means "not built from a git
            // checkout" - so it is read as nil rather than refused. Any other
            // non-string is refused, because it would be a writer bug worth
            // seeing rather than missing provenance.
            sourceCommit: manifest["source_commit"] is NSNull
                ? nil
                : try string(
                    manifest["source_commit"], key: "source_commit", where: "the manifest"),
            // Provenance only: nothing acts on it, so anything that is not a
            // JSON true reads as false rather than refusing an otherwise good
            // file over a field that decides nothing.
            sourceDirty: (manifest["source_dirty"] as? Bool) ?? false,
            tool: try string(manifest["tool"], key: "tool", where: "the manifest"),
            images: images,
            payloads: payloads,
            flashPayloads: flashPayloads)
    }

    /// Read a bundle from a file. The user picks the path, so a filesystem
    /// failure is reported in the same shape as a bad file rather than as a
    /// Foundation error the UI would have to translate separately.
    public static func read(contentsOf url: URL) throws -> FirmwareBundle {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FirmwareBundleError.unreadableFile(
                path: url.path, reason: error.localizedDescription)
        }
        return try read(data)
    }

    /// The image for a chip token, or nil if this bundle carries none.
    public func image(forChip chip: String) -> Image? {
        images.first { $0.chip == chip }
    }

    /// The verified payload for a chip token, or nil if this bundle carries none.
    ///
    /// This is the OTA payload and it is unchanged by generation 2: a
    /// generation-1 file still answers it, which is why reading both generations
    /// costs the update path nothing.
    public func payload(forChip chip: String) -> Data? {
        payloads[chip]
    }

    /// A verified flash part's bytes, or nil if this bundle carries none for that
    /// chip and role.
    public func flashPayload(forChip chip: String, role: String) -> Data? {
        flashPayloads[chip]?[role]
    }

    /// Everything that has to be written, in ascending flash address order, to
    /// bring a board of this chip up from nothing - or nil if this bundle cannot.
    ///
    /// Nil rather than an empty array, and nil for every generation-1 file: "there
    /// is nothing to write" and "this file cannot do that" are different answers,
    /// and only one of them should ever reach a board.
    ///
    /// ASCENDING ADDRESS ORDER, which for this repo's two boards comes out as
    /// bootloader 0x0, partitions 0x8000, boot_app0 0xe000, app 0x10000 - the same
    /// order the core's own upload recipe uses (platform.txt:346). The order is
    /// derived from the addresses in the file rather than from the roles, so a
    /// board whose map differs still gets a sensible sequence.
    public func flashPlan(forChip chip: String) -> [FlashWrite]? {
        guard let image = image(forChip: chip),
              let appAddress = image.appAddress,
              let appPayload = payloads[chip],
              !image.flashParts.isEmpty
        else { return nil }
        guard Self.requiredFlashRoles.allSatisfy({ image.flashPart(role: $0) != nil })
        else { return nil }
        var writes = [FlashWrite(
            role: Self.appFlashRole, address: appAddress, filename: image.filename,
            sha256: image.sha256, payload: appPayload)]
        for part in image.flashParts {
            guard let payload = flashPayload(forChip: chip, role: part.role) else { return nil }
            writes.append(FlashWrite(
                role: part.role, address: part.address, filename: part.filename,
                sha256: part.sha256, payload: payload))
        }
        // A stable sort on the address, so two roles at one address - which `read`
        // refuses, and which therefore cannot reach here - would at least keep
        // manifest order rather than depending on the sort's internals.
        return writes.enumerated()
            .sorted { ($0.element.address, $0.offset) < ($1.element.address, $1.offset) }
            .map(\.element)
    }

    /// Whether this bundle can bring a board of this chip up from nothing.
    public func canFlashBlankDevice(chip: String) -> Bool {
        flashPlan(forChip: chip) != nil
    }

    /// Chip tokens this bundle can serve, sorted so a message reads the same way
    /// twice. `--board c6` alone writes a one-image bundle, which is a normal
    /// file, so this can legitimately be shorter than the boards that exist.
    public var chips: [String] {
        images.map(\.chip).sorted()
    }

    // MARK: - update availability

    /// What this bundle can offer a panel.
    ///
    /// `chip` is the panel's `chip` TXT record: nil when the panel never sent one
    /// (firmware older than the record), or `ServiceMetadata.unknownChip` when it
    /// sent one it could not fill in. `panelVersion` is the version from EINF,
    /// which is authoritative and session-bound - not the `fw` TXT record, which
    /// can be a stale cache entry.
    public func availability(
        forChip chip: String?, panelVersion: String
    ) -> FirmwareUpdateAvailability {
        // Chip first, and unknown chip before missing image. A panel whose chip
        // is unknown has no image that is definitely wrong for it, and saying
        // "this bundle has nothing for your panel" would be claiming to know
        // something this code does not - the same three-valued stance
        // `classify_ota_target` takes in tools/espdisp.py, where only a definite
        // contradiction refuses.
        guard let chip, chip != ServiceMetadata.unknownChip, !chip.isEmpty else {
            return .chipUnknown(bundleChips: chips)
        }
        guard let image = image(forChip: chip) else {
            return .noImageForChip(chip: chip, bundleChips: chips)
        }
        switch FirmwareVersion.compare(firmwareVersion, to: panelVersion) {
        case .newer:
            return .updateAvailable(
                image: image, bundleVersion: firmwareVersion, panelVersion: panelVersion)
        case .same:
            return .upToDate(image: image, version: firmwareVersion)
        case .older:
            return .bundleIsOlder(
                image: image, bundleVersion: firmwareVersion, panelVersion: panelVersion)
        case .incomparable:
            return .versionsIncomparable(
                image: image, bundleVersion: firmwareVersion, panelVersion: panelVersion)
        }
    }

    // MARK: - helpers

    /// Lowercase hex sha256, the spelling the manifest uses.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func decodeManifest(_ slice: Data) throws -> [String: Any] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(slice), options: [])
        } catch {
            throw FirmwareBundleError.manifestNotJSON(error.localizedDescription)
        }
        guard let manifest = object as? [String: Any] else {
            throw FirmwareBundleError.manifestNotAnObject
        }
        return manifest
    }

    private static func string(_ value: Any?, key: String, where owner: String) throws -> String {
        guard let text = value as? String else {
            throw FirmwareBundleError.fieldHasWrongType(
                where: owner, key: key, wanted: "a string")
        }
        return text
    }

    /// A JSON number read as an integer, with `true`/`false` and any number
    /// written as a float excluded.
    ///
    /// The BOOLEAN exclusion is load-bearing rather than pedantic:
    /// `JSONSerialization` hands back an `NSNumber` for a JSON boolean too, and
    /// `NSNumber(true) as? Int` is 1, so a manifest with `"offset": true` would
    /// otherwise be read as offset 1 and then refused for not being contiguous - a
    /// message pointing at the wrong problem. `espdisp.py` excludes bool here for
    /// the same reason.
    ///
    /// THE FLOAT EXCLUSION IS WHY THIS IS NOT JUST `as? Int`. That bridges an
    /// integral `NSNumber(double:)` straight through, so the app accepted
    /// `"offset": 372.0` and `"offset": 1e3` while `espdisp.py`'s
    /// `isinstance(offset, int)` refuses both - `json.loads` makes them floats.
    /// A file this reader takes and the CLI's own `bundle-info` rejects is exactly
    /// the asymmetry the sha256 spelling is strict about avoiding, and it ran the
    /// wrong way round. `CFNumberIsFloatType` is the check that lines up with
    /// Python's, because it asks how the number was WRITTEN rather than what it
    /// happens to equal.
    ///
    /// No file in existence hits it: the only writer is `json.dumps` over Python
    /// ints. That is an argument for fixing it while it costs nothing, not for
    /// leaving it.
    private static func integer(_ value: Any?, key: String, where owner: String) throws -> Int {
        func wrongType() -> FirmwareBundleError {
            FirmwareBundleError.fieldHasWrongType(
                where: owner, key: key, wanted: "a whole number")
        }
        if let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
            throw wrongType()
        }
        guard let number = value as? NSNumber else { throw wrongType() }
        // Checked before the value is read: a float type is refused whatever it
        // equals, so 372.0 goes the same way as 372.5 and for the same reason.
        if CFNumberIsFloatType(number as CFNumber) { throw wrongType() }
        guard let exact = Int(exactly: number.int64Value) else { throw wrongType() }
        return exact
    }

    /// Bytes as something safe to put in a message: a control character or an
    /// invalid sequence in a file that is not a bundle must not garble the error.
    ///
    /// `trimmed` is for the magic line, whose terminating newline is framing
    /// rather than part of the generation's name - "ESPDISPFW9" is what a person
    /// would call it. Off elsewhere, because for the length line the presence or
    /// absence of that newline is exactly what went wrong.
    private static func printable(_ bytes: Data, trimmed: Bool = false) -> String {
        var text = String(decoding: bytes, as: UTF8.self)
        if trimmed { text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return text
            .map { $0.isASCII && !$0.isNewline && !$0.isWhitespace ? String($0) : "." }
            .joined()
    }
}

/// Why a file is not a bundle this app can use.
///
/// One case per way a file can be wrong, with a message written for the person
/// holding the file, because by the time this is thrown the file came from
/// somewhere else: "invalid bundle" would not tell them whether to re-copy it,
/// rebuild it, or go and ask whoever sent it.
public enum FirmwareBundleError: Error, LocalizedError, Equatable {
    case unreadableFile(path: String, reason: String)
    case tooShort(bytes: Int)
    case notABundle
    case unsupportedGeneration(found: String, supported: String)
    case malformedLengthLine(found: String)
    case truncatedManifest(claimed: Int, available: Int)
    case manifestNotJSON(String)
    case manifestNotAnObject
    case manifestMissingKeys([String])
    case unsupportedFormat(found: Int, supported: Int)
    case noImages
    case imageNotAnObject(index: Int)
    case imageMissingKeys(index: Int, keys: [String])
    case fieldHasWrongType(where: String, key: String, wanted: String)
    case nonsensicalExtent(index: Int, chip: String, offset: Int, bytes: Int)
    case notContiguous(index: Int, chip: String, offset: Int, expected: Int)
    case pastEndOfFile(index: Int, chip: String, end: Int, fileBytes: Int)
    case duplicateChip(String)
    case hashMismatch(index: Int, chip: String, expected: String, actual: String)
    case trailingBytes(Int)
    // Generation 2's flash parts. One case per way one can be wrong, for the same
    // reason as above and one more: these are written to absolute flash addresses
    // on a board that has nothing working on it, so "which part" and "what
    // address" are the two things a person needs told.
    case noFlashParts(index: Int, chip: String)
    case flashPartNotAnObject(index: Int, partIndex: Int)
    case flashPartMissingKeys(index: Int, partIndex: Int, keys: [String])
    case flashPartHasNoRole(index: Int, partIndex: Int)
    case duplicateFlashRole(chip: String, role: String)
    case missingFlashRoles(chip: String, roles: [String])
    case nonsensicalFlashAddress(chip: String, role: String, address: Int)
    case conflictingFlashAddresses(chip: String, address: Int, first: String, second: String)
    case flashPartNonsensicalExtent(chip: String, role: String, offset: Int, bytes: Int)
    case flashPartNotContiguous(chip: String, role: String, offset: Int, expected: Int)
    case flashPartPastEndOfFile(chip: String, role: String, end: Int, fileBytes: Int)
    case flashPartHashMismatch(chip: String, role: String, expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let path, let reason):
            return "Could not read \(path): \(reason)"
        case .tooShort(let bytes):
            return "This is not a firmware bundle: \(bytes) bytes is shorter than the "
                + "\(FirmwareBundle.headerBytes)-byte header."
        case .notABundle:
            return "This is not a firmware bundle: it does not start with the "
                + "ESPDISPFW2 magic."
        case .unsupportedGeneration(let found, let supported):
            return "This bundle is generation \(found); this app reads \(supported). "
                + "A newer version of the app can open it."
        case .malformedLengthLine(let found):
            return "The bundle's manifest length is not "
                + "\(FirmwareBundle.lengthDigits) digits and a newline: \(found)"
        case .truncatedManifest(let claimed, let available):
            return "The bundle claims a \(claimed)-byte manifest but only \(available) "
                + "bytes follow the header. The file is truncated."
        case .manifestNotJSON(let reason):
            return "The bundle's manifest is not valid UTF-8 JSON: \(reason)"
        case .manifestNotAnObject:
            return "The bundle's manifest is not a JSON object."
        case .manifestMissingKeys(let keys):
            return "The bundle's manifest is missing \(keys.joined(separator: ", "))."
        case .unsupportedFormat(let found, let supported):
            return "The bundle's manifest says format \(found), but its magic line "
                + "means format \(supported). The file contradicts itself."
        case .noImages:
            return "The bundle's manifest lists no images."
        case .imageNotAnObject(let index):
            return "Image \(index) in the bundle's manifest is not a JSON object."
        case .imageMissingKeys(let index, let keys):
            return "Image \(index) in the bundle's manifest is missing "
                + "\(keys.joined(separator: ", "))."
        case .fieldHasWrongType(let owner, let key, let wanted):
            return "\(key) in \(owner) is not \(wanted)."
        case .nonsensicalExtent(let index, let chip, let offset, let bytes):
            return "Image \(index) (\(chip)) has a nonsensical offset/bytes pair: "
                + "\(offset)/\(bytes)."
        case .notContiguous(let index, let chip, let offset, let expected):
            return "Image \(index) (\(chip)) is listed at offset \(offset), but the "
                + "images must run contiguously from \(expected) in listed order."
        case .pastEndOfFile(let index, let chip, let end, let fileBytes):
            return "Image \(index) (\(chip)) runs to offset \(end), past the end of a "
                + "\(fileBytes)-byte file."
        case .duplicateChip(let chip):
            return "The bundle lists \(chip) twice, so there is no way to tell which "
                + "image to push."
        case .hashMismatch(let index, let chip, let expected, let actual):
            return "Image \(index) (\(chip)) hash mismatch: the manifest says sha256 "
                + "\(expected.prefix(16)), the image hashes to \(actual.prefix(16)). "
                + "The file is damaged or was edited."
        case .trailingBytes(let count):
            return "The bundle has \(count) bytes trailing after the last payload."
        case .noFlashParts(let index, let chip):
            return "Image \(index) (\(chip)) lists no flash parts, but this bundle "
                + "claims to be one that can set up a new board. Rebuild it."
        case .flashPartNotAnObject(let index, let partIndex):
            return "Flash part \(partIndex) of image \(index) is not a JSON object."
        case .flashPartMissingKeys(let index, let partIndex, let keys):
            return "Flash part \(partIndex) of image \(index) is missing "
                + "\(keys.joined(separator: ", "))."
        case .flashPartHasNoRole(let index, let partIndex):
            return "Flash part \(partIndex) of image \(index) does not say what it is, "
                + "so there is no way to know what it does."
        case .duplicateFlashRole(let chip, let role):
            return "The \(chip) image lists its \(role) twice, so there is no way to "
                + "tell which one to write."
        case .missingFlashRoles(let chip, let roles):
            return "The \(chip) image has no \(roles.joined(separator: ", ")), so it "
                + "cannot set up a board that has never been flashed."
        case .nonsensicalFlashAddress(let chip, let role, let address):
            return "The \(chip) image puts its \(role) at flash address \(address), "
                + "which is not a place on the chip."
        case .conflictingFlashAddresses(let chip, let address, let first, let second):
            return "The \(chip) image writes both \(first) and \(second) to flash "
                + "address 0x\(String(address, radix: 16)); only one of them could "
                + "survive."
        case .flashPartNonsensicalExtent(let chip, let role, let offset, let bytes):
            return "The \(chip) \(role) has a nonsensical offset/bytes pair: "
                + "\(offset)/\(bytes)."
        case .flashPartNotContiguous(let chip, let role, let offset, let expected):
            return "The \(chip) \(role) is listed at offset \(offset), but the "
                + "payloads must run contiguously from \(expected) in listed order."
        case .flashPartPastEndOfFile(let chip, let role, let end, let fileBytes):
            return "The \(chip) \(role) runs to offset \(end), past the end of a "
                + "\(fileBytes)-byte file."
        case .flashPartHashMismatch(let chip, let role, let expected, let actual):
            return "The \(chip) \(role) hash mismatch: the manifest says sha256 "
                + "\(expected.prefix(16)), it hashes to \(actual.prefix(16)). The "
                + "file is damaged or was edited."
        }
    }
}

/// What a bundle can do for one panel.
///
/// Six cases, and the point of the type is that they are six rather than two. An
/// "is there an update" boolean would have to answer false for a bundle that is
/// older than the panel, for a bundle with no image for this chip, and for a
/// panel whose chip could not be determined - three situations a user would want
/// told apart, and one of them (the older bundle) is a thing they may well want
/// to do deliberately after a bad release.
public enum FirmwareUpdateAvailability: Equatable, Sendable {
    /// The bundle has an image for this panel and it is newer.
    case updateAvailable(image: FirmwareBundle.Image, bundleVersion: String, panelVersion: String)
    /// The bundle has an image for this panel and it is the same version. Not an
    /// error: it is the answer to "did I already do this".
    case upToDate(image: FirmwareBundle.Image, version: String)
    /// The bundle has an image for this panel and it is OLDER. Offered as a
    /// downgrade, never quietly as an update - the user has to be told which
    /// direction they are moving.
    case bundleIsOlder(image: FirmwareBundle.Image, bundleVersion: String, panelVersion: String)
    /// There is an image, but at least one of the two versions cannot be read as
    /// a dotted number, so which is newer is not knowable. Distinct from
    /// `upToDate` on purpose: this is "I cannot say", not "nothing to do".
    case versionsIncomparable(
        image: FirmwareBundle.Image, bundleVersion: String, panelVersion: String)
    /// The panel named its chip and this bundle has no image for it. A definite
    /// contradiction, and the only case here that is genuinely the wrong file.
    case noImageForChip(chip: String, bundleChips: [String])
    /// The panel did not name its chip, or named it as `unknown`. Not a
    /// contradiction, so not a refusal on the file's account - there is simply no
    /// way to choose an image.
    case chipUnknown(bundleChips: [String])

    /// The image this outcome refers to, if any. `nil` only when no image could
    /// be chosen at all.
    public var image: FirmwareBundle.Image? {
        switch self {
        case .updateAvailable(let image, _, _), .upToDate(let image, _),
             .bundleIsOlder(let image, _, _), .versionsIncomparable(let image, _, _):
            return image
        case .noImageForChip, .chipUnknown:
            return nil
        }
    }

    /// Whether pushing this image would move the panel forward. Deliberately
    /// false for every other case, including the downgrade - a downgrade is
    /// offered through its own case so nothing can reach it by accident.
    public var isUpdate: Bool {
        if case .updateAvailable = self { return true }
        return false
    }
}
