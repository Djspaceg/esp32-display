import CoreGraphics
import Foundation

/// A rectangle of one display to capture, in the coordinate space
/// ScreenCaptureKit wants for `SCStreamConfiguration.sourceRect`: **points,
/// relative to that display's own top-left corner**.
///
/// That is deliberately not the coordinate space AppKit hands out. `NSScreen`
/// frames are global and bottom-left origin, so anything read from a window
/// frame has to be translated and flipped before it is stored here. Keeping the
/// stored form in ScreenCaptureKit's space means the conversion happens once, at
/// the edge, instead of being re-derived at every use.
///
/// The display is remembered by name so the region can be re-resolved on a later
/// launch, when display IDs have been reissued.
public struct RegionSpec: Codable, Equatable, Sendable {
    /// Name of the display the rectangle belongs to.
    public var display: String
    /// Distance from the display's left edge, in points.
    public var x: Double
    /// Distance from the display's *top* edge, in points.
    public var y: Double
    public var width: Double
    public var height: Double

    public init(
        display: String, x: Double, y: Double, width: Double, height: Double
    ) {
        self.display = display
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// How the region reads in the UI.
    public var sizeDescription: String {
        "\(Int(width.rounded()))x\(Int(height.rounded()))"
    }

    /// True when the rectangle is wider than it is tall, which decides whether
    /// the panel is fed landscape or portrait frames.
    public var isLandscape: Bool { width > height }

    /// The region moved and resized to sit inside a display of `size`, keeping
    /// its shape.
    ///
    /// Applied every time capture starts, because a stored region outlives the
    /// display it was drawn on: resolution changes, rotation, and swapping a
    /// monitor all leave a rectangle that no longer fits. ScreenCaptureKit
    /// silently produces nothing useful for a sourceRect that falls outside the
    /// display, which would look like the panel had simply stopped.
    /// Shrinking is uniform, so the panel's shape survives being clamped.
    ///
    /// Clamping width and height independently distorted the rectangle: a region
    /// wider than the display lost width but kept its height, so it stopped
    /// matching the panel, and the marquee then re-locked its aspect ratio to the
    /// distorted shape. Sliding a rectangle back inside the bounds must only ever
    /// move it, or scale it evenly.
    public func clamped(to size: CGSize) -> RegionSpec {
        guard size.width > 0, size.height > 0, width > 0, height > 0 else {
            return self
        }
        let fit = min(1, min(size.width / width, size.height / height))
        let fittedWidth = max(1, width * fit)
        let fittedHeight = max(1, height * fit)
        return RegionSpec(
            display: display,
            x: min(max(0, x), size.width - fittedWidth),
            y: min(max(0, y), size.height - fittedHeight),
            width: fittedWidth,
            height: fittedHeight)
    }

    public var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
