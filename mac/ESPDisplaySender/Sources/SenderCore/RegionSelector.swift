import AppKit
import SenderProtocol

/// The marquee: an aspect-locked rectangle the user drags and resizes over their
/// screen to choose what the panel shows.
///
/// The window is exactly the rectangle, and **this class moves it, not AppKit**.
/// That combination is deliberate and took three attempts to get right:
///
///  - Letting AppKit drag the window (`isMovableByWindowBackground`) can never
///    reach the top of the screen. AppKit refuses to place any window over the
///    menu bar and pushes it down by the menu bar's height - measured at 33pt,
///    and applied for every style mask, borderless included. The outline could
///    not reach the top even though the captured region could.
///  - A full-screen overlay with the rectangle drawn inside it fixed the
///    position, but swallowed every click on the rest of the screen and could
///    only ever cover one display.
///
/// Handling the drag here sidesteps both. `setFrame` goes through
/// `constrainFrameRect`, which this window declines, so the rectangle reaches the
/// very top; the window is only as big as the rectangle, so everything else on
/// screen stays clickable; and because the frame is in global coordinates it can
/// be dragged onto any display.
///
/// The window is excluded from capture (`sharingType = .none`), or it would
/// photograph its own outline onto the panel.
@MainActor
final class RegionSelector: NSObject {
    /// Called whenever the user moves or resizes the marquee.
    var onChange: ((RegionSpec) -> Void)?
    /// Return pressed, or the rectangle otherwise accepted.
    var onConfirm: (() -> Void)?
    /// Escape pressed: the caller should put back whatever was in force before.
    var onCancel: (() -> Void)?

    /// Readable so tests can assert configuration; only this class sets it.
    private(set) var window: NSWindow?
    /// The region currently framed.
    private(set) var region: RegionSpec?

    private var view: MarqueeView?
    /// True while this class is placing the window, so its own frame changes are
    /// not mistaken for the user dragging.
    private var isApplying = false

    var isVisible: Bool { window?.isVisible ?? false }

    func show(_ region: RegionSpec) {
        _ = makeWindowIfNeeded()
        apply(region)
        // Key, so Return and Escape reach it. Clicking the manager window hands
        // focus back, and the Done button there still works either way.
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    /// Frame a region without the user's involvement - used by the preset
    /// buttons, which change the rectangle from outside.
    func apply(_ region: RegionSpec) {
        guard let screen = DisplayCapture.screen(named: region.display) else { return }
        let window = makeWindowIfNeeded()
        let clamped = region.clamped(to: screen.frame.size)
        self.region = clamped
        isApplying = true
        window.setFrame(
            Self.globalFrame(for: clamped, onScreenWithFrame: screen.frame),
            display: true)
        isApplying = false
        view?.aspect = CGSize(width: clamped.width, height: clamped.height)
        view?.sizeLabel = clamped.sizeDescription
    }

    // MARK: coordinate spaces
    //
    // A region is points down from its display's top-left. An NSWindow frame is
    // points up from the bottom-left of the whole desktop. Both directions are
    // pure and tested, because a flip error here silently frames the wrong strip
    // of screen rather than failing.

    nonisolated static func globalFrame(
        for region: RegionSpec, onScreenWithFrame screenFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: screenFrame.minX + region.x,
            y: screenFrame.maxY - region.y - region.height,
            width: region.width,
            height: region.height)
    }

    nonisolated static func region(
        for frame: CGRect, display: String, screenFrame: CGRect
    ) -> RegionSpec {
        RegionSpec(
            display: display,
            x: frame.minX - screenFrame.minX,
            y: screenFrame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height)
    }

    // MARK: hit zones
    //
    // One classifier answers three questions that must never disagree: what a
    // click does, which cursor is shown, and where the corner brackets are drawn.
    // When these were computed separately the buttons were drawn but not
    // clickable, so they are derived from a single set of rectangles now.

    enum Corner: Equatable { case bottomLeft, bottomRight, topLeft, topRight }
    enum Edge: Equatable { case left, right, top, bottom }

    /// Something the user can drag to resize, as opposed to move.
    enum Handle: Equatable {
        case corner(Corner)
        case edge(Edge)
    }

    enum Zone: Equatable {
        case done
        case cancel
        case handle(Handle)
        /// Anywhere else: a drag here moves the rectangle.
        case interior
    }

    /// How far from a corner still counts as that corner. The drawn brackets use
    /// the same value, so the brackets trace the grab area exactly.
    nonisolated static let cornerZone: CGFloat = 22
    /// The band along each side that resizes rather than moves. Deliberately
    /// narrower than the corner zone: an edge drag is the less common intent, and
    /// a wide band would eat into the area used for moving.
    nonisolated static let edgeBand: CGFloat = 8

    /// Every draggable rectangle, in priority order - corners before edges, so a
    /// corner is never mistaken for the two sides that meet there.
    nonisolated static func zoneRects(
        in bounds: CGRect
    ) -> [(zone: Zone, rect: CGRect)] {
        // Clamped to a third of each side so the zones cannot overlap on a small
        // rectangle, which would make one side unreachable.
        let corner = min(cornerZone, bounds.width / 3, bounds.height / 3)
        let band = min(edgeBand, bounds.width / 3, bounds.height / 3)
        guard corner > 0, band > 0 else { return [] }

        var out: [(zone: Zone, rect: CGRect)] = [
            (.handle(.corner(.bottomLeft)), CGRect(
                x: bounds.minX, y: bounds.minY, width: corner, height: corner)),
            (.handle(.corner(.bottomRight)), CGRect(
                x: bounds.maxX - corner, y: bounds.minY,
                width: corner, height: corner)),
            (.handle(.corner(.topLeft)), CGRect(
                x: bounds.minX, y: bounds.maxY - corner,
                width: corner, height: corner)),
            (.handle(.corner(.topRight)), CGRect(
                x: bounds.maxX - corner, y: bounds.maxY - corner,
                width: corner, height: corner)),
        ]

        // Sides start where the corner zones end, so they never overlap.
        let sideHeight = bounds.height - corner * 2
        if sideHeight > 0 {
            out.append((.handle(.edge(.left)), CGRect(
                x: bounds.minX, y: bounds.minY + corner,
                width: band, height: sideHeight)))
            out.append((.handle(.edge(.right)), CGRect(
                x: bounds.maxX - band, y: bounds.minY + corner,
                width: band, height: sideHeight)))
        }
        let sideWidth = bounds.width - corner * 2
        if sideWidth > 0 {
            out.append((.handle(.edge(.bottom)), CGRect(
                x: bounds.minX + corner, y: bounds.minY,
                width: sideWidth, height: band)))
            out.append((.handle(.edge(.top)), CGRect(
                x: bounds.minX + corner, y: bounds.maxY - band,
                width: sideWidth, height: band)))
        }
        return out
    }

    /// What the point at `p` means. Buttons win over handles, because a click on
    /// Done sitting near an edge must still be Done.
    nonisolated static func zone(at p: CGPoint, in bounds: CGRect) -> Zone {
        if let zones = actionZones(in: bounds) {
            if zones.done.contains(p) { return .done }
            if zones.cancel.contains(p) { return .cancel }
        }
        for entry in zoneRects(in: bounds) where entry.rect.contains(p) {
            return entry.zone
        }
        return .interior
    }

    /// What the pointer should look like at a point.
    ///
    /// Kept as a value rather than an `NSCursor` so it is pure and testable: the
    /// view turns it into a cursor, and nothing else decides.
    enum PointerStyle: Equatable {
        /// Over the interior, which drags the whole rectangle.
        case move
        /// Over a button, where a resize cursor would be a lie.
        case arrow
        case resize(NSCursor.FrameResizePosition)
    }

    nonisolated static func pointerStyle(
        at p: CGPoint, in bounds: CGRect
    ) -> PointerStyle {
        switch zone(at: p, in: bounds) {
        case .done, .cancel: .arrow
        case .handle(let handle): .resize(cursorPosition(for: handle))
        case .interior: .move
        }
    }

    /// The system cursor for a handle.
    ///
    /// `NSCursor.frameResize(position:directions:)` is the current API for
    /// resizing a rectangular frame and is what supplies the diagonal corner
    /// cursors; the older `resizeLeftRight` and `resizeUpDown` are deprecated in
    /// favour of it, and its header points at `columnResize`/`rowResize` for
    /// dividers instead. Available from macOS 15, and this app targets 26.
    ///
    /// The view is not flipped, so `.top` here is the visual top of the screen and
    /// matches the zone rectangle at `maxY`.
    nonisolated static func cursorPosition(
        for handle: Handle
    ) -> NSCursor.FrameResizePosition {
        switch handle {
        case .corner(.topLeft): .topLeft
        case .corner(.topRight): .topRight
        case .corner(.bottomLeft): .bottomLeft
        case .corner(.bottomRight): .bottomRight
        case .edge(.left): .left
        case .edge(.right): .right
        case .edge(.top): .top
        case .edge(.bottom): .bottom
        }
    }

    /// The point that stays still while a corner is dragged: the opposite corner.
    nonisolated static func anchor(for corner: Corner, in frame: CGRect) -> CGPoint {
        switch corner {
        case .bottomLeft: CGPoint(x: frame.maxX, y: frame.maxY)
        case .bottomRight: CGPoint(x: frame.minX, y: frame.maxY)
        case .topLeft: CGPoint(x: frame.maxX, y: frame.minY)
        case .topRight: CGPoint(x: frame.minX, y: frame.minY)
        }
    }

    /// A resize, locked to the panel's shape.
    ///
    /// The lock is why an edge drag cannot simply move that one side: changing
    /// width alone would break the aspect ratio. Instead the opposite side
    /// anchors and the rectangle grows about the perpendicular centre line, so
    /// dragging the left edge keeps the right edge and the vertical centre still.
    /// That reads as stretching the side you grabbed while the shape holds.
    nonisolated static func resized(
        _ start: CGRect, handle: Handle, towards mouse: CGPoint, aspect: CGSize
    ) -> CGRect {
        let ratio = aspect.height / max(aspect.width, 1)
        // One panel-worth is the floor; below 1x there is nothing to gain.
        let minWidth = Double(min(PixelConvert.width, PixelConvert.height))

        switch handle {
        case .corner(let corner):
            let anchor = anchor(for: corner, in: start)
            let width = max(minWidth, abs(mouse.x - anchor.x))
            let height = width * ratio
            return CGRect(
                x: mouse.x >= anchor.x ? anchor.x : anchor.x - width,
                y: mouse.y >= anchor.y ? anchor.y : anchor.y - height,
                width: width, height: height)

        case .edge(.left), .edge(.right):
            let anchorX = handle == .edge(.left) ? start.maxX : start.minX
            let width = max(minWidth, abs(mouse.x - anchorX))
            let height = width * ratio
            return CGRect(
                x: mouse.x >= anchorX ? anchorX : anchorX - width,
                y: start.midY - height / 2,
                width: width, height: height)

        case .edge(.top), .edge(.bottom):
            let anchorY = handle == .edge(.top) ? start.minY : start.maxY
            // Driven through width, so the ratio is applied in one place only.
            let width = max(minWidth, abs(mouse.y - anchorY) / max(ratio, 0.0001))
            let height = width * ratio
            return CGRect(
                x: start.midX - width / 2,
                y: mouse.y >= anchorY ? anchorY : anchorY - height,
                width: width, height: height)
        }
    }

    /// Where the Done and Cancel buttons sit inside the rectangle, or nil when it
    /// is too small to hold them.
    ///
    /// Shared by drawing and hit testing so the two cannot disagree - a button
    /// drawn in one place and clickable in another is worse than no button.
    nonisolated static func actionZones(
        in bounds: CGRect
    ) -> (done: CGRect, cancel: CGRect)? {
        let height: CGFloat = 22
        let width: CGFloat = 82
        let gap: CGFloat = 6
        let total = width * 2 + gap
        guard bounds.width >= total + 16, bounds.height >= height + 40 else {
            return nil
        }
        let y = bounds.minY + 10
        let left = bounds.midX - total / 2
        return (
            done: CGRect(x: left, y: y, width: width, height: height),
            cancel: CGRect(x: left + width + gap, y: y, width: width, height: height)
        )
    }

    private func makeWindowIfNeeded() -> NSWindow {
        if let window { return window }
        let window = MarqueeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 172, height: 320),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Every move is ours, through setFrame, so AppKit must not also drag it.
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.level = .floating
        window.sharingType = .none
        // Without this the view's tracking area gets no mouseMoved, so the cursor
        // would only change when crossing into the window rather than when moving
        // from the interior onto a handle.
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let view = MarqueeView(frame: NSRect(x: 0, y: 0, width: 172, height: 320))
        view.onDragTo = { [weak self] frame in self?.userMoved(to: frame) }
        view.onConfirm = { [weak self] in self?.onConfirm?() }
        view.onCancel = { [weak self] in self?.onCancel?() }
        view.currentFrame = { [weak self] in self?.window?.frame ?? .zero }
        window.contentView = view
        self.view = view
        self.window = window
        return window
    }

    /// The user dragged or resized. Place the window, re-home the region to
    /// whichever display now holds it, and report.
    private func userMoved(to proposed: CGRect) {
        guard !isApplying, let window else { return }

        // Whichever screen holds the rectangle's centre owns it, so dragging onto
        // a second display simply re-homes the region there instead of leaving an
        // out-of-bounds rectangle on the old one.
        let centre = CGPoint(x: proposed.midX, y: proposed.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(centre) })
            ?? NSScreen.main,
            let id = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
            let name = DisplayCapture.currentName(for: id)
        else { return }

        let raw = Self.region(
            for: proposed, display: name, screenFrame: screen.frame)
        let clamped = raw.clamped(to: screen.frame.size)
        region = clamped

        // Only the clamped rectangle can be captured, so the outline is snapped
        // to it rather than left hanging over an edge showing something that is
        // not what gets sent.
        isApplying = true
        window.setFrame(
            Self.globalFrame(for: clamped, onScreenWithFrame: screen.frame),
            display: true)
        isApplying = false

        view?.aspect = CGSize(width: clamped.width, height: clamped.height)
        view?.sizeLabel = clamped.sizeDescription
        onChange?(clamped)
    }
}

/// A window that goes exactly where it is put.
///
/// AppKit's default `constrainFrameRect` refuses to let a window cover the menu
/// bar and pushes it down instead. The menu bar strip is a perfectly reasonable
/// thing to capture, so the constraint is declined.
private final class MarqueeWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Borderless windows do not accept key events by default, and Return and
    /// Escape have to reach the marquee.
    override var canBecomeKey: Bool { true }
}

/// Draws the rectangle and turns mouse and key events into requests to move it.
///
/// The view is the whole window, so the rectangle is simply its bounds. Grab
/// zones sit *inside* the corners, which keeps the window exactly the size of the
/// region - anything larger would block clicks on screen for no reason.
private final class MarqueeView: NSView {
    private static let bracketThickness: CGFloat = 4
    private static let lineWidth: CGFloat = 2

    /// Asks for a new global frame. The selector decides what actually happens.
    var onDragTo: ((CGRect) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    /// The window's current global frame, supplied by the selector.
    var currentFrame: (() -> CGRect)?

    var aspect: CGSize = CGSize(width: 172, height: 320)
    var sizeLabel: String = "" {
        didSet { needsDisplay = true }
    }

    private enum Grab {
        case move
        case resize(RegionSelector.Handle)
    }

    private var grab: Grab?
    private var dragStartMouse: CGPoint = .zero
    private var dragStartFrame: CGRect = .zero
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        // Global mouse position, because the window moves out from under a
        // window-relative coordinate mid-drag.
        dragStartMouse = NSEvent.mouseLocation
        dragStartFrame = currentFrame?() ?? .zero

        switch RegionSelector.zone(at: local, in: bounds) {
        case .done:
            grab = nil
            onConfirm?()
        case .cancel:
            grab = nil
            onCancel?()
        case .handle(let handle):
            grab = .resize(handle)
        case .interior:
            grab = .move
            Self.move.dragging.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab else { return }
        let mouse = NSEvent.mouseLocation
        switch grab {
        case .move:
            let delta = CGPoint(
                x: mouse.x - dragStartMouse.x, y: mouse.y - dragStartMouse.y)
            onDragTo?(dragStartFrame.offsetBy(dx: delta.x, dy: delta.y))
        case .resize(let handle):
            onDragTo?(RegionSelector.resized(
                dragStartFrame, handle: handle, towards: mouse, aspect: aspect))
        }
    }

    // MARK: cursors

    /// A tracking area rather than cursor rectangles, because the interior is not
    /// a rectangle - it is the bounds minus eight handle bands minus two buttons.
    /// Decomposing that into non-overlapping cursor rects is fiddly and would let
    /// the pointer and the click drift apart; asking the classifier per point
    /// cannot.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved,
                      .cursorUpdate],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    /// Sent when the pointer enters the area.
    override func cursorUpdate(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// Sent as it moves within the area - `cursorUpdate` alone only fires at the
    /// boundary, which would leave the wrong cursor showing after crossing from
    /// the interior onto a handle.
    override func mouseMoved(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    private func applyCursor(at point: CGPoint) {
        // Not during a drag: the pointer regularly leaves the rectangle while
        // resizing, and the cursor should stay as the handle that is in hand.
        guard grab == nil else { return }
        Self.cursor(for: RegionSelector.pointerStyle(at: point, in: bounds)).set()
    }

    private static func cursor(for style: RegionSelector.PointerStyle) -> NSCursor {
        switch style {
        case .arrow: NSCursor.arrow
        case .move: move.atRest
        case .resize(let position):
            NSCursor.frameResize(position: position, directions: .all)
        }
    }

    /// The interior's cursor, and its counterpart while actually dragging.
    ///
    /// The system move cursor has no grabbed variant, so with the real artwork
    /// both are the same. The hand fallback does have one, and open-then-closed is
    /// the long-standing way macOS shows something being carried.
    private struct MoveCursors {
        let atRest: NSCursor
        let dragging: NSCursor
    }

    /// The four-way move cursor.
    ///
    /// `NSCursor` has no public four-way cursor, and the private `_moveCursor`
    /// exists in the runtime but raises when called - and `responds(to:)` returns
    /// true for it, so guarding on that is not enough to make it safe. The system
    /// ships the artwork on disk instead, so it is loaded from there, falling back
    /// to the open hand and fist should that undocumented path ever move.
    ///
    /// Its hotspot is the centre of a 24x24 image, so the question of whether
    /// `hotSpot` is measured from the top or the bottom does not arise.
    private static let move: MoveCursors = {
        let directory = "/System/Library/Frameworks/ApplicationServices.framework"
            + "/Frameworks/HIServices.framework/Versions/A/Resources/cursors/move"
        guard let image = NSImage(contentsOfFile: "\(directory)/cursor.pdf") else {
            return MoveCursors(atRest: .openHand, dragging: .closedHand)
        }
        let info = NSDictionary(contentsOfFile: "\(directory)/info.plist")
        let hotSpot = CGPoint(
            x: (info?["hotx"] as? NSNumber)?.doubleValue ?? image.size.width / 2,
            y: (info?["hoty"] as? NSNumber)?.doubleValue ?? image.size.height / 2)
        let cursor = NSCursor(image: image, hotSpot: hotSpot)
        return MoveCursors(atRest: cursor, dragging: cursor)
    }()

    /// The zones are proportional to the rectangle, so resizing moves them.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        grab = nil
        // Released: back to whatever is under the pointer now, which after a
        // resize is often a different handle than the one just let go of.
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()          // Escape
        case 36, 76: onConfirm?()     // Return, keypad Enter
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor

        // A wash over the whole rectangle, kept just barely above invisible.
        //
        // This is not decoration. A borderless, non-opaque window receives no
        // clicks where its pixels are fully transparent, so an empty interior
        // made the middle of the marquee un-draggable and only its drawn border
        // responded. 1% is imperceptible but still lands on a non-zero alpha in
        // the backing store, which is all the window server needs; taking it to
        // zero would make the centre stop accepting clicks again.
        accent.withAlphaComponent(0.01).setFill()
        bounds.fill()

        // A dark hairline inside the accent stroke, so the outline reads over
        // light and dark content alike.
        NSColor.black.withAlphaComponent(0.5).setStroke()
        let inner = NSBezierPath(rect: bounds.insetBy(
            dx: Self.lineWidth, dy: Self.lineWidth))
        inner.lineWidth = 1
        inner.stroke()

        accent.setStroke()
        let border = NSBezierPath(
            rect: bounds.insetBy(dx: Self.lineWidth / 2, dy: Self.lineWidth / 2))
        border.lineWidth = Self.lineWidth
        border.stroke()

        drawCornerBrackets(accent)
        drawSizeLabel()
        drawActions()
    }

    /// Thick L-shaped brackets sitting flush with the rectangle's edge, directly
    /// over the border and twice its thickness.
    ///
    /// Overlapping the border is deliberate: the brackets thicken the corners of
    /// the same line rather than forming a second, inset line, which is what
    /// makes them read as grabbable corners instead of extra ornament. What made
    /// them invisible originally was thickness alone - at the border's own weight
    /// they added a single point in an identical colour.
    ///
    /// The arm length is the corner grab size, clamped exactly as the hit zones
    /// are, so each bracket traces the two outer sides of the square that
    /// actually responds to a corner drag.
    private func drawCornerBrackets(_ accent: NSColor) {
        accent.setFill()
        let thickness = Self.bracketThickness
        let length = min(
            RegionSelector.cornerZone, bounds.width / 3, bounds.height / 3)

        for corner in [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.minX, y: bounds.maxY),
            CGPoint(x: bounds.maxX, y: bounds.maxY),
        ] {
            let atLeft = corner.x == bounds.minX
            let atBottom = corner.y == bounds.minY
            // Horizontal arm, growing inward from the corner.
            NSRect(
                x: atLeft ? corner.x : corner.x - length,
                y: atBottom ? corner.y : corner.y - thickness,
                width: length, height: thickness).fill()
            // Vertical arm.
            NSRect(
                x: atLeft ? corner.x : corner.x - thickness,
                y: atBottom ? corner.y : corner.y - length,
                width: thickness, height: length).fill()
        }
    }

    private func drawSizeLabel() {
        guard !sizeLabel.isEmpty else { return }
        let string = NSAttributedString(string: sizeLabel, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white,
        ])
        let size = string.size()
        guard size.width + 12 <= bounds.width else { return }
        let badge = NSRect(
            x: bounds.midX - size.width / 2 - 6,
            y: bounds.maxY - size.height - 12,
            width: size.width + 12, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        string.draw(at: NSPoint(x: badge.minX + 6, y: badge.minY + 2))
    }

    /// Real buttons, from the same geometry `mouseDown` hit-tests.
    private func drawActions() {
        guard let zones = RegionSelector.actionZones(in: bounds) else { return }
        drawButton("Done  ⏎", in: zones.done, prominent: true)
        drawButton("Cancel  ⎋", in: zones.cancel, prominent: false)
    }

    private func drawButton(_ title: String, in rect: CGRect, prominent: Bool) {
        let background = prominent
            ? NSColor.controlAccentColor.withAlphaComponent(0.95)
            : NSColor.black.withAlphaComponent(0.7)
        background.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        let edge = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        edge.lineWidth = 1
        edge.stroke()

        let string = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = string.size()
        string.draw(at: NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2))
    }
}
