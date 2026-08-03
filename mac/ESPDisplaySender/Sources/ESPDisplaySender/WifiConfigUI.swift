import AppKit
import Foundation

/// WiFi configuration for the board over USB serial - a small native dialog
/// that talks the firmware's CFGWIFI protocol, so credentials change without
/// reflashing. Reached by double-clicking the app while the streaming agent
/// is already running, or explicitly with --configure.
enum WifiConfigUI {

    enum CommandResult {
        case success(String)
        case failure(String)
    }

    // MARK: serial

    /// USB CDC serial ports that look like an attached board.
    static func candidatePorts() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return entries.filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 }
    }

    /// Open a serial port at 115200 8N1, non-blocking reads.
    private static func openSerial(_ path: String) -> Int32? {
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        var tty = termios()
        guard tcgetattr(fd, &tty) == 0 else {
            close(fd)
            return nil
        }
        cfmakeraw(&tty)
        cfsetspeed(&tty, speed_t(B115200))
        tty.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(fd, TCSANOW, &tty)
        return fd
    }

    /// Send one command line and collect the response line that starts with
    /// a CFG prefix, with a timeout. The firmware also chatters stats on the
    /// same port, so unrelated lines are skipped.
    static func sendCommand(_ command: String, port: String,
                            timeout: TimeInterval = 6) -> CommandResult {
        guard let fd = openSerial(port) else {
            return .failure("could not open \(port)")
        }
        defer { close(fd) }

        // Drain anything buffered so we don't parse stale output.
        var scratch = [UInt8](repeating: 0, count: 4096)
        _ = read(fd, &scratch, scratch.count)

        let line = command + "\n"
        let wrote = line.withCString { write(fd, $0, strlen($0)) }
        guard wrote > 0 else { return .failure("write to \(port) failed") }

        var buffer = ""
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            let n = read(fd, &scratch, scratch.count)
            if n > 0 {
                buffer += String(decoding: scratch[0..<n], as: UTF8.self)
                for respLine in buffer.split(separator: "\n", omittingEmptySubsequences: true) {
                    let trimmed = respLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("CFGOK") || trimmed.hasPrefix("CFGINFO") {
                        return .success(trimmed)
                    }
                    if trimmed.hasPrefix("CFGERR") {
                        return .failure(trimmed)
                    }
                }
            } else {
                usleep(50_000)
            }
        }
        return .failure("no response from the device (is display_stream flashed?)")
    }

    /// Save new WiFi credentials to the board via the CFGWIFI command.
    /// SSID and password travel base64-encoded so any characters survive
    /// the space-delimited serial line. The board reboots on success.
    static func setWifi(ssid: String, password: String, port: String) -> CommandResult {
        let b64Ssid = Data(ssid.utf8).base64EncodedString()
        let b64Pass = Data(password.utf8).base64EncodedString()
        return sendCommand("CFGWIFI \(b64Ssid) \(b64Pass)", port: port)
    }

    // MARK: dialog

    /// Present the configuration dialog. Blocks until dismissed; call from
    /// the main thread before any run loop takes over.
    static func run() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)

        let ports = candidatePorts()
        guard !ports.isEmpty else {
            alert(style: .warning, title: "No device found",
                  text: "Connect the display board to this Mac with a USB cable, "
                    + "then open this again.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Configure Display WiFi"
        alert.informativeText = "Saves new WiFi credentials to the board over USB. "
            + "The board restarts onto the new network; streaming reconnects on its own."
        alert.addButton(withTitle: "Save to Device")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 300
        let portPopup = NSPopUpButton(frame: NSRect(x: 0, y: 106, width: width, height: 26))
        portPopup.addItems(withTitles: ports)
        let ssidField = NSTextField(frame: NSRect(x: 0, y: 72, width: width, height: 24))
        ssidField.placeholderString = "Network name (SSID)"
        let passField = NSSecureTextField(frame: NSRect(x: 0, y: 38, width: width, height: 24))
        passField.placeholderString = "Password (empty for open network)"
        let nameField = NSTextField(frame: NSRect(x: 0, y: 4, width: width, height: 24))
        nameField.placeholderString = "Device name (a-z, 0-9, dashes)"

        // Prefill from the device. Values travel base64-encoded because
        // SSIDs can contain spaces, which a space-delimited line can't
        // carry raw.
        var deviceName = ""
        if case .success(let info) = sendCommand("CFGSHOW", port: ports[0], timeout: 3) {
            func field(_ key: String) -> String? {
                guard let range = info.range(of: key) else { return nil }
                let b64 = String(info[range.upperBound...].prefix(while: { $0 != " " }))
                guard let data = Data(base64Encoded: b64) else { return nil }
                return String(data: data, encoding: .utf8)
            }
            ssidField.stringValue = field("ssid64=") ?? ""
            deviceName = field("name64=") ?? ""
            nameField.stringValue = deviceName
        }

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 136))
        accessory.addSubview(portPopup)
        accessory.addSubview(ssidField)
        accessory.addSubview(passField)
        accessory.addSubview(nameField)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = ssidField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Name changed? Apply it first (its own save + reboot). Kept
        // separate from CFGWIFI so either can change independently.
        let newName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if !newName.isEmpty, newName != deviceName {
            let port = portPopup.titleOfSelectedItem ?? ports[0]
            let b64 = Data(newName.utf8).base64EncodedString()
            if case .failure(let why) = sendCommand("CFGNAME \(b64)", port: port) {
                self.alert(style: .critical, title: "Rename failed", text: why)
                return
            }
            // Device is rebooting; give it a moment before any WiFi write.
            if ssidField.stringValue.isEmpty { 
                self.alert(style: .informational, title: "Renamed",
                           text: "The device is restarting as \"\(newName)\".")
                return
            }
            Thread.sleep(forTimeInterval: 8)
        }

        let ssid = ssidField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !ssid.isEmpty, ssid.utf8.count <= 32 else {
            self.alert(style: .warning, title: "Invalid SSID",
                       text: "The network name must be 1-32 bytes.")
            return
        }
        let port = portPopup.titleOfSelectedItem ?? ports[0]

        switch setWifi(ssid: ssid, password: passField.stringValue, port: port) {
        case .success:
            self.alert(style: .informational, title: "Saved",
                       text: "The board is restarting and joining \"\(ssid)\". "
                        + "The panel shows dark teal once it's connected.")
        case .failure(let why):
            self.alert(style: .critical, title: "Configuration failed", text: why)
        }
    }

    private static func alert(style: NSAlert.Style, title: String, text: String) {
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

/// Answers Finder double-clicks on the already-running app. LaunchServices
/// never starts a second process for a running app bundle - it sends the
/// existing instance a "reopen" event (and shows "the application is not
/// open anymore" if nobody answers it). We answer with the device WiFi
/// configuration dialog: double-click the app -> configure the board.
/// Streaming continues in the background while the dialog is up.
final class ReopenDelegate: NSObject, NSApplicationDelegate {
    private var dialogShowing = false

    /// Answer a Finder double-click on the running app with the WiFi
    /// configuration dialog, showing at most one dialog at a time.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        guard !dialogShowing else { return false }
        dialogShowing = true
        WifiConfigUI.run()
        dialogShowing = false
        return false
    }
}
