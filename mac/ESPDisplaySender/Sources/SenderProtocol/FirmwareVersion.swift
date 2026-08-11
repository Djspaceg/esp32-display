import Foundation

/// Comparison of the firmware version strings the panel and a bundle report.
///
/// Its own type rather than a `<` on strings, because string order gets this
/// wrong in the one way that matters: "1.10.0" sorts before "1.9.0", so a
/// lexicographic comparison would offer a downgrade as an update the first time
/// a minor version reached double digits. The numbers here come from
/// `FW_VERSION` in the sketch, and nothing stops that from being "1.10.0".
public enum FirmwareVersion {
    /// How two versions relate, with "cannot say" as a first-class answer.
    ///
    /// Four cases rather than the three of a `Comparable`, because a version
    /// this code cannot parse must not collapse into `same` or `older` - both
    /// would read as "nothing to offer" and hide the real problem, which is that
    /// something is spelled in a way this build does not understand.
    public enum Comparison: Equatable, Sendable {
        case older
        case same
        case newer
        case incomparable
    }

    /// Split a dotted numeric version into its components.
    ///
    /// Deliberately narrow: one or more all-ASCII-digit components separated by
    /// single dots, nothing else. No "v" prefix, no "-beta" suffix, no build
    /// metadata, no empty component, no sign, no whitespace. Anything wider would
    /// have to invent an ordering for the part it accepted, and inventing one is
    /// how a downgrade gets offered as an upgrade.
    ///
    /// Two things are left to `Int(_:)` rather than checked here, because it
    /// already refuses both and a second check for either could not be held
    /// accountable by a test: a component too large to hold, and an empty
    /// component ("1..2", "1.2."), for which `Int("")` is nil. What is NOT left
    /// to it is the digit check, which is what rejects the signs and separators
    /// `Int(_:)` would otherwise accept.
    ///
    /// Leading zeros are accepted and read numerically ("1.02.0" == "1.2.0").
    /// The producer never writes them; accepting them costs nothing and refusing
    /// them would turn a cosmetic difference into an incomparable version.
    public static func components(_ version: String) -> [Int]? {
        guard !version.isEmpty else { return nil }
        let fields = version.split(separator: ".", omittingEmptySubsequences: false)
        var parsed = [Int]()
        parsed.reserveCapacity(fields.count)
        for field in fields {
            guard field.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(field)
            else { return nil }
            parsed.append(value)
        }
        return parsed
    }

    /// Compare `version` against `other`, numerically, component by component.
    ///
    /// A shorter version is compared as though the missing components were zero,
    /// so "1.2" and "1.2.0" are the same release and "1.2.1" is newer than "1.2".
    /// That is a choice, and this is why: `FW_VERSION` is three components today
    /// and nothing enforces that, so a two-component spelling of the same release
    /// is a plausible future. Calling those incomparable would mean refusing to
    /// compare a bundle against a panel over a formatting difference, and the
    /// user would be told the versions cannot be compared while looking at two
    /// numbers that plainly can.
    public static func compare(_ version: String, to other: String) -> Comparison {
        guard let left = components(version), let right = components(other) else {
            return .incomparable
        }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b ? .newer : .older }
        }
        return .same
    }
}
