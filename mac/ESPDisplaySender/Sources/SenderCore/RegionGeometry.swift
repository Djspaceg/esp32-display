import CoreGraphics
import Foundation
import SenderProtocol

extension RegionSpec {
    /// Multipliers the UI offers as presets.
    ///
    /// 1x is the panel's own pixel size, so the capture is sent untouched -
    /// every point on screen becomes exactly one pixel on the panel. Higher
    /// multipliers frame more of the screen and let ScreenCaptureKit scale it
    /// down, trading sharpness for coverage.
    static let scalePresets = [1, 2, 3]

    /// The compiled-in panel size at a multiplier, in points.
    ///
    /// `PixelConvert.width`/`height` is 172x320, the size the firmware and this
    /// app have always shared. It is the FALLBACK now rather than the truth: a
    /// panel advertises `res=WxH` in its mDNS TXT records and
    /// `panelSize(geometry:scale:landscape:)` is what the UI calls. This overload
    /// is what "the panel did not say" resolves to, which is the honest answer for
    /// firmware older than the record, for a `res` that
    /// `PanelGeometry.isStreamable` refused, and for a hand-specified `--host`
    /// where there is no discovery at all.
    static func panelSize(scale: Int, landscape: Bool) -> CGSize {
        let short = Double(PixelConvert.width * scale)
        let long = Double(PixelConvert.height * scale)
        return landscape
            ? CGSize(width: long, height: short)
            : CGSize(width: short, height: long)
    }

    /// The panel's own geometry at a multiplier, in points.
    ///
    /// A nil geometry is a real answer - the panel has not said, or said something
    /// implausible - and falls back to the compiled-in size rather than guessing.
    /// Optional rather than two call sites at every caller, because every caller
    /// has the same fallback and spelling it out five times invites one of them to
    /// differ.
    ///
    /// Square panels (width == height) return the same size regardless of
    /// `landscape`, which is correct: isLandscape (width > height on the
    /// region) will always be false for a square.
    static func panelSize(
        geometry: PanelGeometry?, scale: Int, landscape: Bool
    ) -> CGSize {
        guard let geometry else {
            return panelSize(scale: scale, landscape: landscape)
        }
        let short = Double(geometry.width * scale)
        let long = Double(geometry.height * scale)
        if geometry.width == geometry.height {
            return CGSize(width: short, height: long)
        }
        return landscape
            ? CGSize(width: long, height: short)
            : CGSize(width: short, height: long)
    }

    /// A panel-shaped region at `scale`, centred on a display of `displaySize`.
    ///
    /// Centred because the selector has to appear somewhere the user will
    /// actually see it; a rectangle placed at the origin lands under the menu
    /// bar in the corner of the screen.
    static func centered(
        on display: String, geometry: PanelGeometry?, scale: Int, landscape: Bool,
        in displaySize: CGSize
    ) -> RegionSpec {
        let size = panelSize(geometry: geometry, scale: scale, landscape: landscape)
        let spec = RegionSpec(
            display: display,
            x: (displaySize.width - size.width) / 2,
            y: (displaySize.height - size.height) / 2,
            width: size.width,
            height: size.height)
        return spec.clamped(to: displaySize)
    }

    /// This region resized to a multiplier, keeping its centre where it is.
    ///
    /// Keeping the centre is what makes the preset buttons feel like a zoom
    /// rather than a jump: whatever the user had framed stays framed.
    func scaled(
        to scale: Int, geometry: PanelGeometry?, in displaySize: CGSize
    ) -> RegionSpec {
        let size = Self.panelSize(
            geometry: geometry, scale: scale, landscape: isLandscape)
        let centerX = x + width / 2
        let centerY = y + height / 2
        let resized = RegionSpec(
            display: display,
            x: centerX - size.width / 2,
            y: centerY - size.height / 2,
            width: size.width,
            height: size.height)
        return resized.clamped(to: displaySize)
    }

    /// This region turned on its side, keeping its centre.
    func rotated(in displaySize: CGSize) -> RegionSpec {
        let centerX = x + width / 2
        let centerY = y + height / 2
        let swapped = RegionSpec(
            display: display,
            x: centerX - height / 2,
            y: centerY - width / 2,
            width: height,
            height: width)
        return swapped.clamped(to: displaySize)
    }

    /// Which preset this region currently matches, if any, so the UI can show
    /// the active one. Compared with a tolerance because a drag lands on
    /// fractional points.
    func matchingScale(geometry: PanelGeometry?) -> Int? {
        Self.scalePresets.first { scale in
            let size = Self.panelSize(
                geometry: geometry, scale: scale, landscape: isLandscape)
            return abs(size.width - width) < 1 && abs(size.height - height) < 1
        }
    }
}
