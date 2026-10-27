import CoreGraphics
import Foundation
import SenderProtocol

/// A Mac screen used as a device: an extra monitor (the first is a 0.39-inch
/// micro-OLED on a USB-C video adapter) that shows a capture region the way a
/// board does, drawn by this app into a window covering the whole screen.
///
/// Everything in this file is pure: what is listed, which attached screen a
/// saved device is, where the picture goes and which way up, and what capture
/// must leave out. The window and the capture live in ScreenDeviceCover.swift
/// and ScreenDeviceController.swift.

/// What a screen says it is. Read from CoreGraphics, never from the screen's
/// index or position, which change whenever a cable moves.
struct ScreenIdentity: Codable, Hashable, Sendable {
    var vendor: UInt32
    var model: UInt32
    /// Zero when the screen reports none, which many adapters do.
    var serial: UInt32
    /// The CoreGraphics display UUID. For a screen with no serial macOS derives
    /// it partly from where the screen is attached, so it can change with the port.
    var uuid: String?

    /// Whether two readings are the same physical screen. A serial on both
    /// sides settles it; otherwise only the display UUID can.
    func matches(_ other: ScreenIdentity) -> Bool {
        if serial != 0 || other.serial != 0 {
            return serial == other.serial && vendor == other.vendor && model == other.model
        }
        guard let uuid, let otherUUID = other.uuid, !uuid.isEmpty else { return false }
        return uuid.caseInsensitiveCompare(otherUUID) == .orderedSame
    }

    /// The device's lasting name in this app: the serial triple where there is
    /// a serial, the UUID otherwise.
    var key: String {
        if serial != 0 {
            return String(format: "%08x-%08x-%08x", vendor, model, serial)
        }
        return (uuid ?? String(format: "%08x-%08x", vendor, model)).uppercased()
    }
}

/// One screen attached right now, as the window and the capture need it.
struct AttachedScreen: Equatable, Sendable {
    var displayID: CGDirectDisplayID
    var identity: ScreenIdentity
    /// The macOS name, as System Settings shows it.
    var name: String
    /// The screen's backing pixels: what the cover window draws at.
    var pixelWidth: Int
    var pixelHeight: Int
    /// The screen's frame in AppKit's global coordinates, in points.
    var frame: CGRect
    /// The fastest refresh the screen offers.
    var maximumFPS: Int
    /// The screen carrying the menu bar, which the user is working on.
    var hasMenuBar: Bool

    var sizeDescription: String { "\(pixelWidth)×\(pixelHeight)" }
    /// How the screen is named in the list: its macOS name and resolution.
    var label: String { "\(name) (\(sizeDescription))" }
    var geometry: PanelGeometry { PanelGeometry(width: pixelWidth, height: pixelHeight) }
}

/// A screen the user chose to use as a device, as saved between launches.
struct ScreenDeviceRecord: Codable, Equatable, Sendable {
    var identity: ScreenIdentity
    /// `identity.key` when the device was chosen; kept so a screen re-paired by
    /// a fallback keeps its place in the list and its selection.
    var key: String
    var name: String
    var pixelWidth: Int
    var pixelHeight: Int
    var region: RegionSpec?
    /// Clockwise quarter turns, as on a board.
    var rotation: Int = 0
    var paused: Bool = false

    init(screen: AttachedScreen, region: RegionSpec?) {
        identity = screen.identity
        key = screen.identity.key
        name = screen.name
        pixelWidth = screen.pixelWidth
        pixelHeight = screen.pixelHeight
        self.region = region
    }

    var geometry: PanelGeometry { PanelGeometry(width: pixelWidth, height: pixelHeight) }
    var sizeDescription: String { "\(pixelWidth)×\(pixelHeight)" }
}

/// One row of the list: a device in use, or a screen that could be one.
struct ScreenDeviceEntry: Identifiable, Equatable {
    var key: String
    var name: String
    var sizeDescription: String
    /// Set when the screen is in use as a device.
    var record: ScreenDeviceRecord?
    /// Set when the screen is attached now.
    var screen: AttachedScreen?

    var id: String { Self.tag(for: key) }
    var label: String { "\(name) (\(sizeDescription))" }
    var inUse: Bool { record != nil }

    /// The sidebar selection shares one string with the boards' service names,
    /// so a screen's tag carries a prefix no service name has.
    static let tagPrefix = "screen:"
    static func tag(for key: String) -> String { tagPrefix + key }
    static func key(fromTag tag: String?) -> String? {
        guard let tag, tag.hasPrefix(tagPrefix) else { return nil }
        return String(tag.dropFirst(tagPrefix.count))
    }
}

enum ScreenDeviceListing {
    /// Which attached screen each saved device is, keyed by the record's key.
    ///
    /// Identity first (`ScreenIdentity.matches`). Then, for a screen with no
    /// serial whose UUID moved with its port, the same vendor and model, but
    /// only while that is unambiguous on both sides: one such record left
    /// unpaired and one such screen left unclaimed. Two identical serial-less
    /// screens are never guessed between.
    static func pair(
        _ records: [ScreenDeviceRecord], with attached: [AttachedScreen]
    ) -> [String: AttachedScreen] {
        var paired: [String: AttachedScreen] = [:]
        var claimed = Set<CGDirectDisplayID>()
        for record in records {
            guard let screen = attached.first(where: {
                !claimed.contains($0.displayID) && $0.identity.matches(record.identity)
            }) else { continue }
            paired[record.key] = screen
            claimed.insert(screen.displayID)
        }
        func sameModel(_ a: ScreenIdentity, _ b: ScreenIdentity) -> Bool {
            a.serial == 0 && b.serial == 0 && a.vendor == b.vendor && a.model == b.model
                && (a.vendor != 0 || a.model != 0)
        }
        for record in records where paired[record.key] == nil && record.identity.serial == 0 {
            let rivals = records.filter {
                paired[$0.key] == nil && sameModel($0.identity, record.identity)
            }
            let candidates = attached.filter {
                !claimed.contains($0.displayID) && sameModel($0.identity, record.identity)
            }
            guard rivals.count == 1, candidates.count == 1, let screen = candidates.first
            else { continue }
            paired[record.key] = screen
            claimed.insert(screen.displayID)
        }
        return paired
    }

    /// The list: every device in use, attached or not, then every other
    /// attached screen except the one the user captures from.
    ///
    /// "Captured from" is the screen with the menu bar (where a new region
    /// starts), every screen a device's region is drawn on, and every screen a
    /// board's source names (`capturingFrom`). A screen in use stays listed
    /// whatever it hosts, so it can always be found and stopped.
    static func entries(
        attached: [AttachedScreen], records: [ScreenDeviceRecord],
        capturingFrom: Set<String>
    ) -> [ScreenDeviceEntry] {
        let paired = pair(records, with: attached)
        let inUse = records.map { record in
            ScreenDeviceEntry(
                key: record.key, name: paired[record.key]?.name ?? record.name,
                sizeDescription: paired[record.key]?.sizeDescription ?? record.sizeDescription,
                record: record, screen: paired[record.key])
        }
        let claimed = Set(paired.values.map(\.displayID))
        let hosts = capturingFrom.union(records.compactMap { $0.region?.display })
        let offered = attached
            .filter { !claimed.contains($0.displayID) && !$0.hasMenuBar && !hosts.contains($0.name) }
            .map {
                ScreenDeviceEntry(
                    key: $0.identity.key, name: $0.name, sizeDescription: $0.sizeDescription,
                    record: nil, screen: $0)
            }
        func byName(_ a: ScreenDeviceEntry, _ b: ScreenDeviceEntry) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return inUse.sorted(by: byName) + offered.sorted(by: byName)
    }

    enum CoverDecision: Equatable {
        case cover(AttachedScreen)
        case unplugged
        /// The screen became the one with the menu bar, which is never covered.
        case menuBarScreen
    }

    /// Whether a device's screen is covered now.
    static func coverDecision(for screen: AttachedScreen?) -> CoverDecision {
        guard let screen else { return .unplugged }
        return screen.hasMenuBar ? .menuBarScreen : .cover(screen)
    }
}

/// Where the picture goes on the screen and which way up.
///
/// The rule is the boards' (`DisplayCapture.streamsLandscape`): the frame is the
/// screen's own shape at 0 and 180 and turned on its side at 90 and 270, where
/// the region turns on its side too, and the frame is drawn turned clockwise by
/// the rotation so up on the Mac is up on the mounted screen.
enum ScreenDeviceGeometry {
    static func normalized(_ rotation: Int) -> Int {
        ((rotation % 4) + 4) % 4
    }

    /// The size of the frames captured for the screen, in pixels.
    static func frameSize(of geometry: PanelGeometry, rotation: Int) -> (width: Int, height: Int) {
        let turned = DisplayCapture.streamsLandscape(
            geometry: geometry, rotation: normalized(rotation))
        return (geometry.frameWidth(landscape: turned), geometry.frameHeight(landscape: turned))
    }

    /// The picture layer for a screen of `points`: its bounds before turning
    /// and the turn, in radians (negative is clockwise on screen).
    static func pictureLayout(screenPoints: CGSize, rotation: Int) -> (bounds: CGSize, angle: CGFloat) {
        let turns = normalized(rotation)
        let bounds = turns % 2 == 0
            ? screenPoints : CGSize(width: screenPoints.height, height: screenPoints.width)
        return (bounds, -CGFloat(turns) * .pi / 2)
    }

    /// Where the region's picture sits in the frame: scaled to fit, its aspect
    /// ratio kept, centred, black elsewhere.
    static func fittedRect(region: CGSize, frame: (width: Int, height: Int)) -> CGRect? {
        DisplayCapture.letterbox(content: region, width: frame.width, height: frame.height)
    }

    /// The region for a new rotation: on rectangular glass a change between an
    /// even and an odd quarter turn turns it on its side, keeping its centre.
    static func region(
        _ region: RegionSpec, for rotation: Int, geometry: PanelGeometry, hostSize: CGSize
    ) -> RegionSpec {
        guard geometry.width != geometry.height,
              region.streamsLandscape(on: geometry) != (normalized(rotation) % 2 != 0)
        else { return region }
        return region.rotated(in: hostSize)
    }

    /// A first region: the screen's own shape for the rotation, as large as
    /// fits, centred on the host.
    static func startingRegion(
        on host: AttachedScreen, geometry: PanelGeometry, rotation: Int
    ) -> RegionSpec {
        // 1x is one screen point per device pixel, as on a board; on a screen
        // that is bigger than the host, so the clamp makes it the largest fit.
        RegionSpec.centered(
            on: host.name, geometry: geometry, scale: 1,
            landscape: DisplayCapture.streamsLandscape(
                geometry: geometry, rotation: normalized(rotation)),
            in: host.frame.size)
    }
}

/// What keeps the picture from feeding back into itself: no capture includes a
/// cover window, and no region is drawn on a covered screen.
enum ScreenDeviceFeedback {
    /// The windows a capture filter leaves out.
    static func windowsToExclude<Window>(
        _ windows: [Window], id: (Window) -> CGWindowID, covers: Set<CGWindowID>
    ) -> [Window] {
        guard !covers.isEmpty else { return [] }
        return windows.filter { covers.contains(id($0)) }
    }

    /// The screen a region may live on when it is dragged to `proposed`: a
    /// covered screen refuses it, so it stays on `current`.
    static func regionHost(
        proposed: String, current: String?, covered: Set<String>
    ) -> String? {
        guard covered.contains(proposed) else { return proposed }
        guard let current, !covered.contains(current) else { return nil }
        return current
    }

    /// The screen a new region starts on: the menu-bar screen unless covered,
    /// else the first screen that is not covered. Nil when every one is.
    static func startingHost(
        attached: [AttachedScreen], covered: Set<String>
    ) -> AttachedScreen? {
        let open = attached.filter { !covered.contains($0.name) }
        return open.first(where: \.hasMenuBar) ?? open.first
    }
}
