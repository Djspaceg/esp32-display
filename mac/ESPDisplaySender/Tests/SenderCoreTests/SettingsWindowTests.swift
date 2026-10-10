import AppKit
import Combine
import SwiftUI
import XCTest
@testable import SenderCore
@testable import SenderProtocol

/// The WiFi networks moved off the display pages and into the Settings window.
///
/// Each view is read as the value SwiftUI is handed - every string it carries
/// and every button, with the action that button runs (`ViewReading`) - so a
/// display page, the Add Display sheet and Settings can be checked for which
/// controls they offer, and those controls pressed, without a window, a
/// screen or a board. Serial I/O is off and the networks are in memory, never
/// the Keychain.
@MainActor
final class SettingsWindowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    // MARK: the display page

    /// Every control the display page used to offer for the saved networks -
    /// the picker, Apply, Manage, the preset sheet and its Copy Now - is gone.
    /// What is left reads, and links to Settings.
    func testADisplayPageHasNoWifiEditorOnlyALinkToSettings() {
        let (manager, panel) = makeManager(saved: ["Studio WiFi", "Guest"])
        let page = ViewReading(PanelDetailView(panel: panel, manager: manager))

        // The reading reached the section the controls used to be in.
        XCTAssertTrue(page.strings.contains("Network Connection"))
        XCTAssertTrue(page.strings.contains("WiFi preset"))
        XCTAssertNotNil(page.button("WiFi Settings…"), "the line keeps its link to Settings")
        for gone in ["Apply", "Manage…", "Add…", "Show Presets...", "Copy Now",
                     "Edit Saved Networks…", "Add Network…", "Edit…", "Remove",
                     "Move Up", "Move Down"] {
            XCTAssertNil(page.button(gone), "\"\(gone)\" is still on the display page")
        }
        XCTAssertFalse(page.strings.contains("Saved on this Mac"))
        XCTAssertFalse(
            page.strings.contains("Studio WiFi") || page.strings.contains("Guest"),
            "a saved network is still offered on the display page")
        XCTAssertFalse(page.contains("SwiftUI.SecureField"))
    }

    /// Pressing the page's link asks for the Settings window at WiFi Networks.
    func testTheDisplayPageLinkOpensSettingsAtWifiNetworks() throws {
        let (manager, panel) = makeManager(saved: ["Studio WiFi"])
        let link = try XCTUnwrap(
            ViewReading(PanelDetailView(panel: panel, manager: manager))
                .button("WiFi Settings…"))
        XCTAssertEqual(opened { link.press() }, [.wifiNetworks])
    }

    /// Onboarding only chooses one of the saved networks. Nothing in it types
    /// a network or a password, and it links to Settings to add one.
    func testOnboardingChoosesASavedNetworkAndAddsNoneOfItsOwn() throws {
        for saved in [[], ["Studio WiFi"]] {
            let (manager, _) = makeManager(saved: saved)
            let sheet = ViewReading(AddDeviceSheet(manager: manager))
            XCTAssertTrue(sheet.strings.contains("WiFi"), "the reading missed the WiFi section")
            XCTAssertFalse(sheet.strings.contains("Network name (SSID)"))
            XCTAssertFalse(sheet.strings.contains("Type a network…"))
            XCTAssertFalse(sheet.strings.contains("Open network (no password)"))
            XCTAssertFalse(sheet.contains("SwiftUI.SecureField"))
            let title = saved.isEmpty ? "Add a Network in Settings…" : "WiFi Settings…"
            let link = try XCTUnwrap(sheet.button(title), "no \"\(title)\" link")
            XCTAssertEqual(opened { link.press() }, [.wifiNetworks])
        }
    }

    /// The line says which preset the board is on, from the last copy's read.
    func testThePresetLineSaysWhichSlotTheBoardIsOn() {
        func report(active: Int?, slots: [Int: String]) -> WifiPresetSyncReport {
            WifiPresetSyncReport(
                snapshot: WifiPresetSnapshot(
                    roster: ConfigCommands.WiFiPresetRoster(
                        capacity: 10, validSlots: Set(slots.keys),
                        activeSlot: active, localSelectorAvailable: true),
                    slots: Dictionary(uniqueKeysWithValues: slots.map { slot, ssid in
                        (slot, ConfigCommands.WiFiPresetSlot(
                            slot: slot, ssid: ssid, hasPassword: true,
                            active: slot == active))
                    })),
                omitted: [], unusable: [], commandCount: 0)
        }
        XCTAssertEqual(
            WifiNetworkRows.presetDescription(
                report(active: 3, slots: [1: "Home", 3: "Studio WiFi"]),
                savedNetworkCount: 2),
            "Studio WiFi (slot 3 of 10, at the last USB copy)")
        XCTAssertEqual(
            WifiNetworkRows.presetDescription(
                report(active: nil, slots: [1: "Home"]), savedNetworkCount: 1),
            "None at the last USB copy (joined through its own WiFi setting)")
        XCTAssertEqual(
            WifiNetworkRows.presetDescription(nil, savedNetworkCount: 4),
            "Not read yet (copied when connected by USB)")
        XCTAssertEqual(
            WifiNetworkRows.presetDescription(nil, savedNetworkCount: 0),
            "None saved on this Mac")
    }

    // MARK: the Settings window

    /// The WiFi Networks pane is where a network is added, edited, removed and
    /// moved between slots.
    func testSettingsOwnsAddEditRemoveAndReorder() throws {
        let (manager, _) = makeManager(saved: ["Studio WiFi", "Guest", "Home"])
        let navigation = SettingsNavigation()
        navigation.show(.wifiNetworks)
        let pane = ViewReading(SettingsView(manager: manager, navigation: navigation))

        for control in ["Add Network…", "Edit…", "Move Up", "Move Down", "Remove"] {
            XCTAssertNotNil(pane.button(control), "Settings has no \"\(control)\"")
        }
        // "Slot \(n)", as the localized key the row's label carries.
        XCTAssertTrue(pane.strings.contains("Slot %lld"))
        for section in SettingsPane.allCases {
            XCTAssertTrue(
                pane.strings.contains(section.title),
                "the sidebar does not list \(section.title)")
        }

        // The buttons are the ones that change the shared list: moving the
        // last network up moves it between every board's slots.
        let moves = pane.buttons.filter { $0.title == "Move Up" }
        XCTAssertEqual(moves.count, 3)
        moves[2].press()
        XCTAssertEqual(manager.savedNetworkNames, ["Studio WiFi", "Home", "Guest"])
    }

    /// Settings apply as they are made. Restore Defaults puts back only what
    /// the Streaming pane shows: the display list's order and the saved
    /// networks' order are left alone.
    func testRestoreDefaultsResetsOnlyTheStreamingSettings() throws {
        let (manager, _) = makeManager(saved: ["Studio WiFi", "Guest"])
        manager.updateDeviceListSortOrder(.status)
        manager.moveSavedNetwork("Guest", by: -1)
        manager.updateSettings(SenderSettings(
            fps: 24, spacingMicros: 900, adaptivePacing: false,
            identifySeconds: 3, tileQuality: .aggressive,
            deviceListSortOrder: .status))
        let navigation = SettingsNavigation()
        navigation.show(.streaming)
        let restore = try XCTUnwrap(
            ViewReading(SettingsView(manager: manager, navigation: navigation))
                .button("Restore Defaults"))
        restore.press()

        let defaults = SenderSettings()
        XCTAssertEqual(manager.settings.fps, defaults.fps)
        XCTAssertEqual(manager.settings.spacingMicros, defaults.spacingMicros)
        XCTAssertEqual(manager.settings.adaptivePacing, defaults.adaptivePacing)
        XCTAssertEqual(manager.settings.tileQuality, defaults.tileQuality)
        XCTAssertEqual(manager.settings.identifySeconds, 3)
        XCTAssertEqual(manager.settings.deviceListSortOrder, .status)
        XCTAssertEqual(manager.savedNetworkNames, ["Guest", "Studio WiFi"])
    }

    /// A new password for a network already saved changes no name, and the
    /// Add Display sheet, which reads the credential itself, still redraws.
    func testANewPasswordForASavedNetworkRedrawsItsReaders() {
        let (manager, _) = makeManager(saved: ["Studio WiFi"])
        var redraws = 0
        let watch = manager.objectWillChange.sink { redraws += 1 }
        defer { watch.cancel() }
        XCTAssertNil(manager.saveNetwork(
            ssid: "Studio WiFi", password: "rotated", isOpenNetwork: false))
        XCTAssertGreaterThan(redraws, 0)
        XCTAssertEqual(manager.savedCredential(for: "Studio WiFi")?.password, "rotated")
    }

    /// Every AppKit control in each pane lies within the window's width, at
    /// the window's default size and at its minimum. The Identify stepper
    /// used to be laid out as a whole form row inside the value column, which
    /// put its arrows past the right edge, and at the old 640 pt minimum the
    /// tile-quality segments ran 12 pt past it. Only the horizontal is
    /// checked: the form scrolls, so a control below the fold is no defect.
    ///
    /// The WiFi pane carries a 32-byte open network. Its row buttons are drawn
    /// by SwiftUI rather than AppKit, so whether "Edit…" keeps its width is
    /// not measurable here; that one was checked in the live window.
    func testEveryPaneKeepsItsControlsInsideTheWindow() throws {
        let longName = "Workshop Upstairs Mesh Extender!"
        XCTAssertEqual(longName.utf8.count, 32)
        let (manager, _) = makeManager(saved: ["Studio WiFi"])
        let store = InMemoryWifiCredentials([
            SavedWiFiCredential(ssid: "Studio WiFi", password: "pw"),
            SavedWiFiCredential(ssid: longName, password: "", isOpenNetwork: true),
        ])
        manager.useWifiCredentials(store)
        manager.applySavedNetworkNames(store.names)
        XCTAssertTrue(manager.savedNetworkNames.contains(longName))

        let minimum = SettingsWindowController.minimumContentSize
        for size in [CGSize(width: 720, height: 620), minimum] {
            for pane in SettingsPane.allCases {
                let navigation = SettingsNavigation()
                navigation.show(pane)
                let rect = NSRect(origin: .zero, size: size)
                let host = NSHostingView(rootView: SettingsView(
                    manager: manager, navigation: navigation)
                    .frame(width: size.width, height: size.height))
                host.frame = rect
                let window = NSWindow(
                    contentRect: rect, styleMask: [.borderless],
                    backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
                host.layoutSubtreeIfNeeded()
                var controls: [NSView] = []
                var queue: [NSView] = [host]
                while let view = queue.popLast() {
                    // A hidden scroller has a zero-height frame at -9.
                    if view is NSControl, !(view is NSScroller) { controls.append(view) }
                    queue.append(contentsOf: view.subviews)
                }
                let label = "\(pane.title) at \(Int(size.width))x\(Int(size.height))"
                switch pane {
                case .general:
                    XCTAssertTrue(controls.contains { $0 is NSStepper }, "no stepper on \(label)")
                case .streaming:
                    XCTAssertEqual(
                        controls.filter { $0 is NSSlider }.count, 2, "no sliders on \(label)")
                case .wifiNetworks:
                    break
                }
                for control in controls where control.window != nil {
                    let frame = control.convert(control.bounds, to: host)
                    XCTAssertTrue(
                        frame.minX >= -0.5 && frame.maxX <= host.bounds.maxX + 0.5,
                        "\(type(of: control)) on \(label) lies at \(frame), "
                            + "outside the window's width \(host.bounds.width)")
                }
                window.close()
            }
        }
    }

    func testTheSidebarSearchFindsAPaneByTheSettingsOnIt() {
        let navigation = SettingsNavigation()
        XCTAssertEqual(navigation.visiblePanes, SettingsPane.allCases)
        navigation.query = "password"
        XCTAssertEqual(navigation.visiblePanes, [.wifiNetworks])
        navigation.query = "FPS"
        XCTAssertEqual(navigation.visiblePanes, [.streaming])
        navigation.query = "identify"
        XCTAssertEqual(navigation.visiblePanes, [.general])
        navigation.query = "bluetooth"
        XCTAssertEqual(navigation.visiblePanes, [])
    }

    func testBackAndForwardWalkTheVisitedPanes() {
        let navigation = SettingsNavigation()
        XCTAssertEqual(navigation.pane, .general)
        navigation.show(.streaming)
        navigation.show(.wifiNetworks)
        navigation.show(.wifiNetworks)
        navigation.goBack()
        XCTAssertEqual(navigation.pane, .streaming)
        navigation.goBack()
        XCTAssertEqual(navigation.pane, .general)
        navigation.goBack()
        XCTAssertEqual(navigation.pane, .general)
        navigation.goForward()
        XCTAssertEqual(navigation.pane, .streaming)
        navigation.show(.general)
        XCTAssertTrue(navigation.forwardStack.isEmpty, "a new visit drops the forward history")
    }

    /// The menu's Settings… and the links all go through one notification,
    /// which names the pane.
    func testOpeningSettingsNamesThePane() {
        var received: [[AnyHashable: Any]?] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .espDisplayShowSettings, object: nil, queue: nil
        ) { received.append($0.userInfo) }
        defer { NotificationCenter.default.removeObserver(observer) }
        SettingsPane.open(.wifiNetworks)
        SettingsPane.open()
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0]?["pane"] as? String, "wifiNetworks")
        XCTAssertNil(received[1])
    }

    // MARK: support

    private func makeManager(saved: [String]) -> (PanelManager, PanelSnapshot) {
        let now = Date()
        var panel = PanelSnapshot(serviceName: "desk-panel", displayName: "Desk Panel")
        panel.hardwareID = "020000123456"
        panel.address = "192.168.1.42"
        panel.discovered = true
        panel.lastSeen = now
        panel.lastHeartbeatAt = now
        panel.rssi = -52
        panel.firmwareVersion = "2.0.0"
        panel.controlProtocolVersion = Int(DeviceProtocol.controlProtocolVersion)
        panel.usbPort = "/dev/cu.usbmodem101"
        panel.usbHardwareID = "020000123456"
        let store = InMemoryWifiCredentials(saved.map {
            SavedWiFiCredential(ssid: $0, password: "pw")
        })
        let manager = PanelManager(
            previewPanels: [panel], savedNetworkNames: [], usbSerialPorts: [],
            settings: SenderSettings(wifiPresetOrder: saved))
        manager.serialIODisabled = true
        manager.useWifiCredentials(store)
        manager.applySavedNetworkNames(store.names)
        manager.selectedServiceName = panel.serviceName
        return (manager, panel)
    }

    /// The panes the Settings window was asked to open while `body` ran.
    private func opened(_ body: () -> Void) -> [SettingsPane?] {
        var opened: [SettingsPane?] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .espDisplayShowSettings, object: nil, queue: nil
        ) { note in
            opened.append((note.userInfo?["pane"] as? String)
                .flatMap(SettingsPane.init(rawValue:)))
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        body()
        return opened
    }
}

/// A SwiftUI view read as a value: the strings it carries, the types it is
/// built from, and its buttons with their actions.
///
/// SwiftUI only builds its accessibility tree for an assistive client, so an
/// offscreen render cannot be asked what controls it shows. The view value
/// itself can: containers keep their content, a `Button` keeps its label and
/// action, and `ForEach` exposes its data and content. This app's own views
/// are expanded through `body`, which outside a window reads every `@State` as
/// its initial value. Classes - the manager above all - are not walked into,
/// so nothing it holds is mistaken for something the view shows; the one
/// exception is the storage behind a localized `Text`.
@MainActor
struct ViewReading {
    struct PressableButton {
        let title: String
        let press: @MainActor () -> Void
    }

    private(set) var strings: [String] = []
    private(set) var buttons: [PressableButton] = []
    private(set) var typeNames: [String] = []

    init(_ root: Any) {
        visit(root, depth: 0)
    }

    func button(_ title: String) -> PressableButton? {
        buttons.first { $0.title == title }
    }

    func contains(_ typePrefix: String) -> Bool {
        typeNames.contains { $0.hasPrefix(typePrefix) }
    }

    private mutating func visit(_ value: Any, depth: Int) {
        guard depth < 400 else { return }
        if let string = value as? String {
            strings.append(string)
            return
        }
        let mirror = Mirror(reflecting: value)
        let typeName = String(reflecting: type(of: value))
        // A localized `Text` keeps its key in a class of its own; that one
        // class is the exception.
        if mirror.displayStyle == .class, !typeName.contains("TextStorage") { return }
        typeNames.append(typeName)
        if typeName.hasPrefix("SwiftUI.Button<"), let pressable = Self.pressable(mirror) {
            buttons.append(pressable)
        }
        if let each = value as? ReadableForEach {
            for element in each.readContents { visit(element, depth: depth + 1) }
        }
        // An app view is read through what it draws. Its stored properties
        // are what it was handed, which its body shows already.
        if typeName.hasPrefix("SenderCore."), let view = value as? any View,
           let body = Self.body(of: view) {
            visit(body, depth: depth + 1)
            return
        }
        for child in mirror.children { visit(child.value, depth: depth + 1) }
    }

    private static func body<V: View>(of view: V) -> Any? {
        V.Body.self == Never.self ? nil : view.body
    }

    private static func pressable(_ button: Mirror) -> PressableButton? {
        guard let label = button.children.first(where: { $0.label == "label" })?.value,
              let action = button.children.first(where: { $0.label == "action" })?.value,
              let closure = Mirror(reflecting: action).children.first?.value
                as? @MainActor () -> Void,
              let title = ViewReading(label).strings.first
        else { return nil }
        return PressableButton(title: title, press: closure)
    }
}

private protocol ReadableForEach {
    var readContents: [Any] { get }
}

extension ForEach: ReadableForEach {
    fileprivate var readContents: [Any] { data.map { content($0) } }
}
