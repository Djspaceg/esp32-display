import XCTest

@testable import SenderProtocol

final class DeviceListSortingTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func item(
        _ name: String,
        id: String,
        seconds: TimeInterval = 0,
        status: DeviceListStatus = .offline
    ) -> DeviceListSortValue {
        DeviceListSortValue(
            displayName: name,
            stableIdentifier: id,
            dateAdded: baseDate.addingTimeInterval(seconds),
            status: status)
    }

    private func ids(
        _ values: [DeviceListSortValue],
        order: DeviceListSortOrder
    ) -> [String] {
        DeviceListSorter.sorted(values, by: order).map(\.stableIdentifier)
    }

    func testAlphabeticalOrderUsesLocalizedNaturalComparison() {
        let values = [
            item("Panel 10", id: "ten"),
            item("panel 2", id: "two"),
            item("Panel 1", id: "one"),
        ]

        XCTAssertEqual(
            ids(values, order: .alphabetical),
            ["one", "two", "ten"])
    }

    func testAlphabeticalOrderIsCaseInsensitiveAndHandlesCanonicalDiacritics() {
        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        let values = [
            item("alpha", id: "case-z"),
            item("Alpha", id: "case-a"),
            item(decomposed, id: "accent-z"),
            item(composed, id: "accent-a"),
        ]

        let sorted = ids(values, order: .alphabetical)

        XCTAssertLessThan(
            try XCTUnwrap(sorted.firstIndex(of: "case-a")),
            try XCTUnwrap(sorted.firstIndex(of: "case-z")))
        XCTAssertLessThan(
            try XCTUnwrap(sorted.firstIndex(of: "accent-a")),
            try XCTUnwrap(sorted.firstIndex(of: "accent-z")))
    }

    func testDateAddedOrdersNewestFirstThenAlphabetically() {
        let values = [
            item("Zulu", id: "old", seconds: 10),
            item("Beta", id: "new-b", seconds: 30),
            item("Alpha", id: "new-a", seconds: 30),
            item("Middle", id: "middle", seconds: 20),
        ]

        XCTAssertEqual(
            ids(values, order: .dateAdded),
            ["new-a", "new-b", "middle", "old"])
    }

    func testStatusOrderUsesStableRankAndAlphabeticalSubsort() {
        let values = [
            item("Zulu offline", id: "offline", status: .offline),
            item("Zulu connected", id: "connected-z", status: .connected),
            item("Alpha connected", id: "connected-a", status: .connected),
            item("Paused", id: "paused", status: .paused),
            item("Connecting", id: "connecting", status: .connecting),
            item("Streaming", id: "streaming", status: .streaming),
        ]

        XCTAssertEqual(
            ids(values, order: .status),
            [
                "streaming",
                "connected-a", "connected-z",
                "paused",
                "connecting",
                "offline",
            ])
    }

    func testAllOrdersUseStableIdentifierAsFinalTieBreaker() {
        let values = [
            item("Same", id: "z", seconds: 10, status: .connected),
            item("same", id: "a", seconds: 10, status: .connected),
        ]

        for order in DeviceListSortOrder.allCases {
            XCTAssertEqual(ids(values, order: order), ["a", "z"], "\(order)")
            XCTAssertEqual(ids(values.reversed(), order: order), ["a", "z"], "\(order)")
        }
    }

    func testEmptyAndSingleElementListsAreUnchanged() {
        for order in DeviceListSortOrder.allCases {
            XCTAssertEqual(ids([], order: order), [])
            XCTAssertEqual(
                ids([item("Only", id: "only")], order: order),
                ["only"])
        }
    }
}
