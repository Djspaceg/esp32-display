import XCTest

@testable import SenderProtocol

/// Version ordering, which decides whether the app offers an update at all.
final class FirmwareVersionTests: XCTestCase {

    func testOrdersTenAfterNine() {
        // The case this type exists for. String order puts "1.10.0" before
        // "1.9.0", so a lexicographic comparison would call 1.9.0 the newer
        // release and offer a downgrade as an update the first time a minor
        // version reached double digits.
        XCTAssertEqual(FirmwareVersion.compare("1.10.0", to: "1.9.0"), .newer)
        XCTAssertEqual(FirmwareVersion.compare("1.9.0", to: "1.10.0"), .older)
        XCTAssertTrue("1.10.0" < "1.9.0", "the string order this test exists to reject")

        // Same shape at every position, so the numeric comparison is not just
        // right for the minor field.
        XCTAssertEqual(FirmwareVersion.compare("10.0.0", to: "9.9.9"), .newer)
        XCTAssertEqual(FirmwareVersion.compare("1.2.10", to: "1.2.9"), .newer)
        XCTAssertEqual(FirmwareVersion.compare("1.2.100", to: "1.2.99"), .newer)
    }

    func testOrdersTheOrdinaryCases() {
        XCTAssertEqual(FirmwareVersion.compare("1.2.0", to: "1.2.0"), .same)
        XCTAssertEqual(FirmwareVersion.compare("1.3.0", to: "1.2.0"), .newer)
        XCTAssertEqual(FirmwareVersion.compare("1.2.0", to: "1.3.0"), .older)
        XCTAssertEqual(FirmwareVersion.compare("2.0.0", to: "1.99.99"), .newer)
        XCTAssertEqual(FirmwareVersion.compare("1.2.1", to: "1.2.0"), .newer)
        // The version actually in the sketch today, against its neighbours.
        XCTAssertEqual(FirmwareVersion.compare("1.2.0", to: "1.1.0"), .newer)
    }

    func testComparisonIsAntisymmetric() {
        // Not decoration: an ordering that answered `.newer` both ways round
        // would offer an update in both directions, and each individual
        // assertion above would still pass.
        let versions = ["0.0.0", "1", "1.0", "1.2.0", "1.9.0", "1.10.0", "2", "10.0.1"]
        for left in versions {
            for right in versions {
                let forward = FirmwareVersion.compare(left, to: right)
                let backward = FirmwareVersion.compare(right, to: left)
                switch forward {
                case .newer: XCTAssertEqual(backward, .older, "\(left) vs \(right)")
                case .older: XCTAssertEqual(backward, .newer, "\(left) vs \(right)")
                case .same: XCTAssertEqual(backward, .same, "\(left) vs \(right)")
                case .incomparable:
                    XCTAssertEqual(backward, .incomparable, "\(left) vs \(right)")
                }
            }
        }
    }

    func testAShorterVersionIsPaddedWithZeros() {
        // A choice, documented on `compare`: FW_VERSION is three components today
        // and nothing enforces that, so a two-component spelling of the same
        // release must not come out as "cannot compare" - the user would be told
        // two plainly comparable numbers cannot be compared.
        XCTAssertEqual(FirmwareVersion.compare("1.2", to: "1.2.0"), .same)
        XCTAssertEqual(FirmwareVersion.compare("1.2.0", to: "1.2"), .same)
        XCTAssertEqual(FirmwareVersion.compare("1.2.1", to: "1.2"), .newer)
        XCTAssertEqual(FirmwareVersion.compare("1.2", to: "1.2.1"), .older)
        XCTAssertEqual(FirmwareVersion.compare("2", to: "1.9.9"), .newer)
        XCTAssertEqual(FirmwareVersion.compare("1.2.0.0", to: "1.2"), .same)
        XCTAssertEqual(FirmwareVersion.compare("1.2.0.1", to: "1.2"), .newer)
    }

    func testAnythingUnparsableIsIncomparableRatherThanEqual() {
        // Incomparable, never `.same` or `.older`: both of those read as
        // "nothing to offer" and would hide the real situation, which is that
        // something is spelled in a way this build does not understand.
        let bad = [
            "",              // a panel that reported no version at all
            "1.2.0-rc1",     // a pre-release suffix
            "1.2.0+build7",  // build metadata
            "v1.2.0",        // a tag rather than a version
            "1.2.0 ",        // trailing space
            " 1.2.0",        // leading space
            "1..2",          // an empty component
            "1.2.",          // a trailing dot
            ".1.2",          // a leading dot
            "-1.2.0",        // a sign
            "+1.2.0",
            "1.2.x",
            "dev",
            "1,2,0",         // the wrong separator
            "١.٢.٠",         // digits, but not ASCII ones
            "99999999999999999999.0",  // too large for Int, so unparsable
        ]
        for version in bad {
            XCTAssertNil(FirmwareVersion.components(version), "components(\(version))")
            XCTAssertEqual(
                FirmwareVersion.compare(version, to: "1.2.0"), .incomparable, version)
            XCTAssertEqual(
                FirmwareVersion.compare("1.2.0", to: version), .incomparable, version)
        }
        // Including both sides at once, which must not accidentally read as equal.
        XCTAssertEqual(FirmwareVersion.compare("dev", to: "dev"), .incomparable)
        XCTAssertEqual(FirmwareVersion.compare("", to: ""), .incomparable)
    }

    func testComponentsParsesWhatItAccepts() {
        XCTAssertEqual(FirmwareVersion.components("1.2.0"), [1, 2, 0])
        XCTAssertEqual(FirmwareVersion.components("1.10.0"), [1, 10, 0])
        XCTAssertEqual(FirmwareVersion.components("7"), [7])
        XCTAssertEqual(FirmwareVersion.components("0.0.0.0.0"), [0, 0, 0, 0, 0])
        // Leading zeros read numerically. The producer never writes them;
        // refusing them would turn a cosmetic difference into an unparsable
        // version.
        XCTAssertEqual(FirmwareVersion.components("1.02.0"), [1, 2, 0])
        XCTAssertEqual(FirmwareVersion.compare("1.02.0", to: "1.2.0"), .same)
    }
}
