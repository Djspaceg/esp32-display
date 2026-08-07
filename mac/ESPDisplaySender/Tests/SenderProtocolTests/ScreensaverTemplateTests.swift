import XCTest
@testable import SenderProtocol

/// The screensaver template engine.
///
/// The panel's card used to be three lines hardcoded in C++, which meant the
/// only choice a user had was "those three lines, plus whatever I push, both".
/// Expressing the built-in card as a template makes it something they can edit
/// instead of something they can only add to.
final class ScreensaverTemplateTests: XCTestCase {

    private func expand(
        _ template: String, values: ScreensaverTemplate.Values = .example
    ) -> ScreensaverTemplate.Expansion {
        ScreensaverTemplate.expand(template, values: values)
    }

    // MARK: substitution

    func testEveryAdvertisedTokenSubstitutes() {
        for token in ScreensaverTemplate.tokens {
            let result = expand(token.placeholder)

            XCTAssertEqual(
                result.lines, [token.example],
                "\(token.placeholder) did not substitute")
            XCTAssertTrue(result.unknownTokens.isEmpty)
        }
    }

    func testTokensMixWithTheUsersOwnText() {
        let values = ScreensaverTemplate.Values(name: "kitchen", rssi: "-52 dBm")

        let result = expand("panel: {name}\nsignal {rssi} ok", values: values)

        XCTAssertEqual(result.lines, ["panel: kitchen", "signal -52 dBm ok"])
    }

    func testSeveralTokensOnOneLine() {
        let values = ScreensaverTemplate.Values(name: "a", address: "10.0.0.2")

        XCTAssertEqual(expand("{name} @ {address}", values: values).lines,
                       ["a @ 10.0.0.2"])
    }

    func testTokenNamesAreCaseAndSpaceInsensitive() {
        let values = ScreensaverTemplate.Values(name: "kitchen")

        XCTAssertEqual(expand("{NAME}", values: values).lines, ["kitchen"])
        XCTAssertEqual(expand("{ name }", values: values).lines, ["kitchen"])
    }

    /// The standard template has to reproduce the card the firmware draws by
    /// itself, or "Use Default" would quietly change what the panel shows.
    func testStandardTemplateIsTheFirmwareCard() {
        let values = ScreensaverTemplate.Values(
            name: "blakes-teeny-touch", address: "192.168.1.69", rssi: "-59 dBm")

        let result = expand(ScreensaverTemplate.standard, values: values)

        XCTAssertEqual(
            result.lines, ["blakes-teeny-touch", "192.168.1.69", "wifi -59 dBm"])
    }

    // MARK: unknown tokens

    /// Left as written rather than blanked: a blank would leave the user
    /// staring at a gap on a panel across the room with nothing to explain it.
    func testUnknownTokenIsKeptVerbatimAndReported() {
        let result = expand("{nmae}")

        XCTAssertEqual(result.lines, ["{nmae}"])
        XCTAssertEqual(result.unknownTokens, ["nmae"])
    }

    func testUnknownTokensAreReportedOnceEachInOrder() {
        let result = expand("{b} {a} {b}")

        XCTAssertEqual(result.unknownTokens, ["b", "a"])
    }

    func testKnownAndUnknownTokensCoexist() {
        let values = ScreensaverTemplate.Values(name: "kitchen")

        let result = expand("{name} {nope}", values: values)

        XCTAssertEqual(result.lines, ["kitchen {nope}"])
        XCTAssertEqual(result.unknownTokens, ["nope"])
    }

    // MARK: literal braces and malformed input

    func testDoubledBraceIsALiteralBrace() {
        XCTAssertEqual(expand("{{name}").lines, ["{name}"])
        XCTAssertTrue(expand("{{name}").unknownTokens.isEmpty)
    }

    func testUnclosedBraceIsLiteralText() {
        let result = expand("100% {name")

        XCTAssertEqual(result.lines, ["100% {name"])
        XCTAssertTrue(result.unknownTokens.isEmpty)
    }

    func testStrayClosingBraceIsLiteralText() {
        XCTAssertEqual(expand("a} b").lines, ["a} b"])
    }

    func testEmptyBracesAreReportedRatherThanCrashing() {
        let result = expand("{}")

        XCTAssertEqual(result.lines, ["{}"])
        XCTAssertEqual(result.unknownTokens, [""])
    }

    func testTemplateWithoutTokensIsPassedThrough() {
        XCTAssertEqual(expand("just words").lines, ["just words"])
    }

    // MARK: the panel's budget

    /// A token whose value is not known yet collapses its line away, rather
    /// than spending one of four lines on a label with nothing after it.
    func testLineOfOnlyAnUnknownValueIsDropped() {
        let values = ScreensaverTemplate.Values(name: "kitchen", address: "")

        let result = expand("{name}\n{address}", values: values)

        XCTAssertEqual(result.lines, ["kitchen"])
    }

    func testExpansionIsHeldToThePanelLineLimit() {
        let result = expand(String(repeating: "line\n", count: 12))

        XCTAssertEqual(result.lines.count, IdleText.maxLines)
    }

    /// Truncation happens after substitution, so a short template with a long
    /// value is still cut to something the firmware will accept.
    func testLongValuesAreTruncatedToThePanelWidth() {
        let values = ScreensaverTemplate.Values(name: String(repeating: "x", count: 90))

        let result = expand("{name}", values: values)

        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0].utf8.count, IdleText.maxLineBytes)
    }

    /// Everything that survives expansion must be encodable, or the sender
    /// would build a packet the firmware rejects outright.
    func testExpandedLinesAlwaysMakeAValidPacket() {
        let values = ScreensaverTemplate.Values(name: "café ☕ kitchen")

        let result = expand("{name}\n{{literal}}\n{bogus}", values: values)

        XCTAssertNotNil(IdleText.packet(lines: result.lines))
    }

    // MARK: emptiness

    func testWhitespaceOnlyTemplateCountsAsEmpty() {
        XCTAssertTrue(ScreensaverTemplate.isEmpty(""))
        XCTAssertTrue(ScreensaverTemplate.isEmpty("  \n\t "))
        XCTAssertFalse(ScreensaverTemplate.isEmpty("{name}"))
    }

    func testEmptyTemplateProducesNoLines() {
        XCTAssertEqual(expand("").lines, [])
        XCTAssertEqual(expand("   \n  ").lines, [])
    }
}
