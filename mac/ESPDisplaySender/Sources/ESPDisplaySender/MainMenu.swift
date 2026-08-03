import AppKit

/// The application's main menu, built in code.
///
/// This app has no MainMenu.xib and does not use the SwiftUI `App` lifecycle,
/// so AppKit never synthesizes the standard menu bar for it. The Edit menu is
/// not cosmetic: AppKit delivers ⌘X/⌘C/⌘V/⌘A as menu key equivalents and
/// NSTextField does not implement them itself, so without those items the
/// rename field and the USB WiFi SSID/password fields cannot be pasted into.
///
/// The sender runs as an LSUIElement agent, so this is installed the first
/// time the manager window is shown, next to the switch to `.regular`
/// activation policy. Closing the window returns to accessory mode and macOS
/// hides the menu bar again.
@MainActor
final class MainMenuController: NSObject {
    private static let helpURL =
        URL(string: "https://github.com/Djspaceg/esp32-display#readme")!

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }

    func installIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()
        for submenu in [appMenu(), fileMenu(), editMenu(), windowMenu(), helpMenu()] {
            // The menu bar shows each submenu's own title; the wrapping item
            // in the top-level menu carries no title of its own.
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }

    private func appMenu() -> NSMenu {
        let menu = NSMenu(title: appName)
        menu.addItem(withTitle: "About \(appName)",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        let services = NSMenu(title: "Services")
        let servicesItem = menu.addItem(
            withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(.separator())

        menu.addItem(withTitle: "Hide \(appName)",
                     action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(appName)",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func fileMenu() -> NSMenu {
        // Nothing here opens or saves documents; the manager is a single
        // window, so Close is the whole File menu.
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "Close",
                     action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        // undo:/redo: are responder-chain actions with no Swift-visible
        // declaration to build a #selector from.
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(
            withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut",
                     action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy",
                     action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste",
                     action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Delete",
                     action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All",
                     action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        let emoji = menu.addItem(
            withTitle: "Emoji & Symbols",
            action: #selector(NSApplication.orderFrontCharacterPalette(_:)),
            keyEquivalent: " ")
        emoji.keyEquivalentModifierMask = [.command, .control]
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom",
                     action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front",
                     action: #selector(NSApplication.arrangeInFront(_:)),
                     keyEquivalent: "")
        // Lets AppKit append and maintain the open-window list itself.
        NSApp.windowsMenu = menu
        return menu
    }

    private func helpMenu() -> NSMenu {
        // There is no compiled help book, so Help opens the project's README
        // rather than failing to find one.
        let menu = NSMenu(title: "Help")
        let item = menu.addItem(withTitle: "\(appName) Help",
                                action: #selector(openHelp(_:)), keyEquivalent: "?")
        item.target = self
        NSApp.helpMenu = menu
        return menu
    }

    @objc private func openHelp(_ sender: Any?) {
        NSWorkspace.shared.open(Self.helpURL)
    }
}
