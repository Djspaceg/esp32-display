import Foundation

/// The three user-facing ways the display sidebar can be ordered.
public enum DeviceListSortOrder: String, CaseIterable, Codable, Hashable, Sendable {
    case alphabetical
    case dateAdded
    case status
}

/// Stable status groups used by the device-list policy.
///
/// Raw values are the display rank: immediately usable devices first, then
/// progressively less available ones.
public enum DeviceListStatus: Int, Codable, Hashable, Sendable {
    case streaming = 0
    case connected = 1
    case paused = 2
    case connectedViaUSB = 3
    case connecting = 4
    case offline = 5
}

/// The policy-only projection needed to order one device.
///
/// Kept independent of the app's live panel model so sorting can be tested
/// without AppKit, SwiftUI, discovery, or a running sender.
public struct DeviceListSortValue: Equatable, Sendable {
    public let displayName: String
    public let stableIdentifier: String
    public let dateAdded: Date
    public let status: DeviceListStatus

    public init(
        displayName: String,
        stableIdentifier: String,
        dateAdded: Date,
        status: DeviceListStatus
    ) {
        self.displayName = displayName
        self.stableIdentifier = stableIdentifier
        self.dateAdded = dateAdded
        self.status = status
    }
}

/// Pure, total ordering for device-list policy values.
public enum DeviceListSorter {
    public static func sorted(
        _ values: [DeviceListSortValue],
        by order: DeviceListSortOrder
    ) -> [DeviceListSortValue] {
        values.sorted {
            areInIncreasingOrder($0, $1, by: order)
        }
    }

    public static func areInIncreasingOrder(
        _ lhs: DeviceListSortValue,
        _ rhs: DeviceListSortValue,
        by order: DeviceListSortOrder
    ) -> Bool {
        switch order {
        case .alphabetical:
            break
        case .dateAdded:
            if lhs.dateAdded != rhs.dateAdded {
                return lhs.dateAdded > rhs.dateAdded
            }
        case .status:
            if lhs.status != rhs.status {
                return lhs.status.rawValue < rhs.status.rawValue
            }
        }
        return compareNameThenIdentifier(lhs, rhs)
    }

    private static func compareNameThenIdentifier(
        _ lhs: DeviceListSortValue,
        _ rhs: DeviceListSortValue
    ) -> Bool {
        let locale = Locale.current
        let lhsName = lhs.displayName.folding(
            options: [.caseInsensitive], locale: locale)
        let rhsName = rhs.displayName.folding(
            options: [.caseInsensitive], locale: locale)
        if lhsName != rhsName {
            let comparison = lhsName.localizedStandardCompare(rhsName)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
        }
        return lhs.stableIdentifier < rhs.stableIdentifier
    }
}
