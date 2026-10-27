import AppKit
import CoreVideo
import QuartzCore

/// The window that turns a Mac screen into a device's glass, behind a protocol
/// so the controller's tests can count covers without putting a window on the
/// screen of whoever runs them.
@MainActor
protocol ScreenCoverPresenting: AnyObject {
    /// Cover a screen, or follow it to a new frame or rotation.
    func cover(_ screen: AttachedScreen, rotation: Int)
    /// Draw one frame. Called on the main actor, newest frame only.
    func present(_ frame: CVPixelBuffer)
    /// Black, for a source that is not there.
    func clear()
    /// Take the window away for good.
    func remove()
    /// Put the window back on top if something has ordered it out.
    func reassert()
}

/// A borderless panel over one whole screen, at the screen's native pixels.
///
/// It never activates the app and never takes focus: a non-activating panel
/// that refuses key and main, ordered front with `orderFrontRegardless`. It sits
/// at screen-saver level so it stays above every window on that screen (menu
/// bar and Dock included) and joins every Space. It is left out of screen
/// capture (`sharingType`, and `DisplayCapture.excludedWindowIDs` for
/// ScreenCaptureKit), so no picture can feed back into itself.
@MainActor
final class ScreenDeviceCover: ScreenCoverPresenting {
    private var window: ScreenCoverWindow?
    private let pictureLayer = CALayer()
    private var covered: AttachedScreen?
    /// The frame on screen. Held, not just its surface, so ScreenCaptureKit
    /// does not reuse the surface while it is still being shown.
    private var shownFrame: CVPixelBuffer?
    private var screenObserver: NSObjectProtocol?
    /// Told when the window has landed on a screen other than the one it
    /// covers: macOS moves windows off a screen that is unplugged, and a
    /// full-screen black window on the screen being worked on must never stay.
    var onDisplaced: (() -> Void)?

    init() {
        pictureLayer.backgroundColor = NSColor.black.cgColor
        pictureLayer.contentsGravity = .resizeAspect
        // No implicit animation: frames, turns and moves land at once.
        pictureLayer.actions = [
            "contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
            "transform": NSNull(), "contentsScale": NSNull(),
        ]
    }

    func cover(_ screen: AttachedScreen, rotation: Int) {
        let window = makeWindowIfNeeded()
        covered = screen
        window.setFrame(screen.frame, display: false)
        let scale = screen.frame.width > 0
            ? CGFloat(screen.pixelWidth) / screen.frame.width : 1
        let layout = ScreenDeviceGeometry.pictureLayout(
            screenPoints: screen.frame.size, rotation: rotation)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pictureLayer.contentsScale = scale
        pictureLayer.bounds = CGRect(origin: .zero, size: layout.bounds)
        pictureLayer.position = CGPoint(x: screen.frame.width / 2, y: screen.frame.height / 2)
        pictureLayer.setAffineTransform(CGAffineTransform(rotationAngle: layout.angle))
        CATransaction.commit()
        DisplayCapture.excludedWindowIDs.withLock {
            _ = $0.insert(CGWindowID(window.windowNumber))
        }
        displaced = false
        showIfOnItsScreen(reportingDisplacement: false)
    }

    /// Set once the window has been found off its screen, so nothing orders it
    /// back in until the screen is covered afresh.
    private var displaced = false

    /// Order the window in only while its screen is attached, and take it out
    /// again if AppKit put it anywhere else.
    ///
    /// Found by the watchdog, the displacement is reported so the cover is
    /// started afresh; found while covering, it is not, so a screen AppKit
    /// will not place the window on cannot loop.
    private func showIfOnItsScreen(reportingDisplacement: Bool) {
        guard let window, let covered, !displaced,
            NSScreen.screens.contains(where: { Self.displayID(of: $0) == covered.displayID })
        else { return }
        window.orderFrontRegardless()
        if let screen = window.screen, Self.displayID(of: screen) != covered.displayID {
            displaced = true
            window.orderOut(nil)
            if reportingDisplacement { onDisplaced?() }
        }
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    func present(_ frame: CVPixelBuffer) {
        guard let surface = CVPixelBufferGetIOSurface(frame)?.takeUnretainedValue() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pictureLayer.contents = surface
        CATransaction.commit()
        shownFrame = frame
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pictureLayer.contents = nil
        CATransaction.commit()
        shownFrame = nil
    }

    func remove() {
        ScreenCoverCursor.show()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        guard let window else { return }
        let id = CGWindowID(window.windowNumber)
        window.orderOut(nil)
        window.close()
        self.window = nil
        covered = nil
        pictureLayer.contents = nil
        shownFrame = nil
        DisplayCapture.excludedWindowIDs.withLock { _ = $0.remove(id) }
    }

    func reassert() {
        guard let window, !window.isVisible else { return }
        showIfOnItsScreen(reportingDisplacement: true)
    }

    private func makeWindowIfNeeded() -> ScreenCoverWindow {
        if let window { return window }
        let window = ScreenCoverWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
        ]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.animationBehavior = .none
        window.isExcludedFromWindowsMenu = true
        window.becomesKeyOnlyIfNeeded = true
        window.sharingType = .none
        // Mouse events are taken rather than passed through, so the pointer can
        // be hidden over the window and a click lands on nothing behind it.
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true

        let view = ScreenCoverView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.addSublayer(pictureLayer)
        window.contentView = view

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStillOnItsScreen() }
        }
        self.window = window
        return window
    }

    private func checkStillOnItsScreen() {
        guard let window, let covered, window.isVisible else { return }
        guard window.screen.flatMap(Self.displayID(of:)) != covered.displayID else { return }
        displaced = true
        window.orderOut(nil)
        onDisplaced?()
    }
}

/// Never key, never main, and placed exactly where it is put: AppKit would
/// otherwise push a window off the menu bar.
final class ScreenCoverWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Black, with the pointer hidden while it is over the screen.
///
/// A tracking area that is active whatever app is frontmost, because this app
/// is never the active one while its covers are up: the invisible cursor is
/// set on entry and on every move, and the arrow put back on exit.
private final class ScreenCoverView: NSView {
    private var tracking: NSTrackingArea?

    static let invisibleCursor: NSCursor = {
        // Drawn with nothing: every pixel transparent.
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in true }
        return NSCursor(image: image, hotSpot: .zero)
    }()

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved,
                      .cursorUpdate],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.invisibleCursor)
    }

    override func cursorUpdate(with event: NSEvent) { hide() }
    override func mouseEntered(with event: NSEvent) { hide() }
    override func mouseMoved(with event: NSEvent) { hide() }
    override func mouseExited(with event: NSEvent) {
        ScreenCoverCursor.show()
        NSCursor.arrow.set()
    }

    private func hide() {
        Self.invisibleCursor.set()
        ScreenCoverCursor.hide()
    }
}

/// The window server's own hide and show, balanced: an app that is not active
/// may have its cursor image ignored, so the pointer is also hidden outright
/// while it is over a cover, and shown again on leaving it or on the cover
/// going away.
@MainActor
enum ScreenCoverCursor {
    private static var hidden = false

    static func hide() {
        guard !hidden else { return }
        hidden = true
        CGDisplayHideCursor(CGMainDisplayID())
    }

    static func show() {
        guard hidden else { return }
        hidden = false
        CGDisplayShowCursor(CGMainDisplayID())
    }
}
