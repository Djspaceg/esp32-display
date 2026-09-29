import Foundation

/// Which build of a firmware version a board is running: the commit it was
/// compiled from, and whether that tree had uncommitted changes.
///
/// The board reports it as CFGINFO `src=` and mDNS TXT `src`, spelled
/// `<40 hex>` or `<40 hex>-dirty`, from the same git provenance
/// tools/espdisp.py writes into a bundle manifest as `source_commit` and
/// `source_dirty`. That shared origin is what lets a running board be held
/// against the bundles the app carries: `FW_VERSION` only moves at a release, so
/// the version alone cannot tell two builds of 1.5.0 apart.
///
/// Firmware older than the field reports nothing, and a compile outside the tool
/// reports `unknown`; both parse to nil, because neither names a build.
public struct FirmwareSourceIdentity: Equatable, Hashable, Sendable {
    public static let unknownToken = "unknown"
    private static let dirtySuffix = "-dirty"

    /// Forty lowercase hex digits.
    public let commit: String
    public let dirty: Bool

    public init?(commit: String?, dirty: Bool) {
        guard let commit = commit?.lowercased(), Self.isCommit(commit) else {
            return nil
        }
        self.commit = commit
        self.dirty = dirty
    }

    /// Parse what a board reported.
    public init?(reported: String?) {
        guard var value = reported?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        var dirty = false
        if value.hasSuffix(Self.dirtySuffix) {
            dirty = true
            value.removeLast(Self.dirtySuffix.count)
        }
        self.init(commit: value, dirty: dirty)
    }

    /// The identity a bundle was built from, when its manifest recorded one.
    public init?(bundle: FirmwareBundle) {
        self.init(commit: bundle.sourceCommit, dirty: bundle.sourceDirty)
    }

    /// Twelve digits, which is what the rest of the app shows for a commit.
    public var shortCommit: String { String(commit.prefix(12)) }

    /// `f9e04f9fcf9d`, or `f9e04f9fcf9d with uncommitted changes`.
    public var summary: String {
        dirty ? "\(shortCommit) with uncommitted changes" : shortCommit
    }

    /// Whether this is exactly the build in `bundle`.
    ///
    /// A tree with uncommitted changes is never a match, even against a bundle
    /// recording the same commit and the same dirty flag: two dirty trees at one
    /// commit can hold anything, so "same commit, also dirty" proves nothing
    /// about the bytes.
    public func isExactly(_ bundle: FirmwareBundle) -> Bool {
        guard !dirty, let built = FirmwareSourceIdentity(bundle: bundle), !built.dirty
        else { return false }
        return built.commit == commit
    }

    private static func isCommit(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
    }
}
