import AppKit
import Foundation
import Security
import SenderProtocol

struct SavedWiFiCredential: Equatable {
    let ssid: String
    let password: String
}

/// App-managed WiFi credentials. Passwords never enter panel persistence or
/// UserDefaults; each SSID is a generic-password item in the login Keychain.
enum WifiCredentialStore {
    private static let service = "com.espdisplay.sender.wifi"

    static func savedNetworkNames() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return []
        }
        let items: [[String: Any]]
        if let many = result as? [[String: Any]] {
            items = many
        } else if let one = result as? [String: Any] {
            items = [one]
        } else {
            return []
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func credential(for ssid: String) -> SavedWiFiCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ssid,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8)
        else { return nil }
        return SavedWiFiCredential(ssid: ssid, password: password)
    }

    @discardableResult
    static func save(ssid: String, password: String) -> Bool {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ssid,
        ]
        let values: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
        ]
        let updated = SecItemUpdate(identity as CFDictionary, values as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }

        var item = identity
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

/// WiFi and device-name configuration over the board's USB serial protocol.
enum WifiConfigUI {
    enum CommandResult {
        case success(String)
        case failure(String)
    }

    private final class DialogCoordinator: NSObject {
        let portPopup: NSPopUpButton
        let savedPopup: NSPopUpButton
        let ssidField: NSTextField
        let passField: NSSecureTextField
        let openCheck: NSButton
        let nameField: NSTextField
        var deviceName = ""
        var deviceSSID = ""

        init(
            portPopup: NSPopUpButton,
            savedPopup: NSPopUpButton,
            ssidField: NSTextField,
            passField: NSSecureTextField,
            openCheck: NSButton,
            nameField: NSTextField
        ) {
            self.portPopup = portPopup
            self.savedPopup = savedPopup
            self.ssidField = ssidField
            self.passField = passField
            self.openCheck = openCheck
            self.nameField = nameField
        }

        var selectedPort: String {
            portPopup.titleOfSelectedItem ?? ""
        }

        @objc func portChanged(_ sender: NSPopUpButton) {
            reloadDevice()
        }

        @objc func savedNetworkChanged(_ sender: NSPopUpButton) {
            guard sender.indexOfSelectedItem > 0,
                  let ssid = sender.titleOfSelectedItem,
                  let credential = WifiCredentialStore.credential(for: ssid)
            else { return }
            ssidField.stringValue = credential.ssid
            passField.stringValue = credential.password
            openCheck.state = credential.password.isEmpty ? .on : .off
        }

        func reloadDevice() {
            guard !selectedPort.isEmpty,
                  case .success(let info) = WifiConfigUI.sendCommand(
                    "CFGSHOW", port: selectedPort, timeout: 3)
            else { return }
            deviceSSID = ConfigCommands.decodeField("ssid64=", from: info) ?? ""
            deviceName = ConfigCommands.decodeField("name64=", from: info) ?? ""
            nameField.stringValue = deviceName
            if savedPopup.indexOfSelectedItem == 0 {
                ssidField.stringValue = deviceSSID
                passField.stringValue = ""
                openCheck.state = .off
            }
        }

        func selectSavedNetwork(_ ssid: String) {
            guard savedPopup.itemTitles.contains(ssid) else { return }
            savedPopup.selectItem(withTitle: ssid)
            savedNetworkChanged(savedPopup)
        }
    }

    // MARK: serial

    static func candidatePorts() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return entries.filter {
            $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.usbserial")
        }.sorted().map { "/dev/" + $0 }
    }

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

    static func sendCommand(
        _ command: String, port: String, timeout: TimeInterval = 6
    ) -> CommandResult {
        guard let fd = openSerial(port) else {
            return .failure("could not open \(port)")
        }
        defer { close(fd) }

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
                for response in buffer.split(separator: "\n", omittingEmptySubsequences: true) {
                    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
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

    static func setWifi(ssid: String, password: String, port: String) -> CommandResult {
        sendCommand(
            ConfigCommands.setWifi(ssid: ssid, password: .set(password)),
            port: port)
    }

    static func normalizedDeviceName(_ input: String) -> String {
        var output = ""
        for scalar in input.lowercased().unicodeScalars {
            let value = scalar.value
            if (97...122).contains(value) || (48...57).contains(value) || value == 45 {
                output.unicodeScalars.append(scalar)
            } else if value == 32 || value == 95 {
                output.append("-")
            }
            if output.utf8.count == 32 { break }
        }
        return output
    }

    // MARK: direct manager actions

    static func renameDevice(currentName: String, newName: String) -> String? {
        let normalized = normalizedDeviceName(newName)
        guard !normalized.isEmpty else {
            alert(style: .warning, title: "Invalid name",
                  text: "Use letters, numbers, spaces, underscores, or dashes.")
            return nil
        }
        guard let port = matchingPort(for: currentName) else { return nil }
        switch sendCommand(ConfigCommands.setName(normalized), port: port) {
        case .success:
            alert(style: .informational, title: "Name saved",
                  text: "The display is restarting as \"\(normalized)\". Streaming reconnects automatically.")
            return normalized
        case .failure(let reason):
            alert(style: .critical, title: "Rename failed", text: reason)
            return nil
        }
    }

    static func applySavedNetwork(_ ssid: String, currentName: String) -> Bool {
        guard let credential = WifiCredentialStore.credential(for: ssid) else {
            alert(style: .warning, title: "Credential not found",
                  text: "Add \"\(ssid)\" again to store it in Keychain.")
            return false
        }
        guard let port = matchingPort(for: currentName) else { return false }
        let change: ConfigCommands.PasswordChange = credential.password.isEmpty
            ? .openNetwork : .set(credential.password)
        switch sendCommand(
            ConfigCommands.setWifi(ssid: credential.ssid, password: change), port: port)
        {
        case .success:
            alert(style: .informational, title: "WiFi saved",
                  text: "The display is restarting and joining \"\(ssid)\". Streaming reconnects automatically.")
            return true
        case .failure(let reason):
            alert(style: .critical, title: "Configuration failed", text: reason)
            return false
        }
    }

    private static func matchingPort(for currentName: String) -> String? {
        let ports = candidatePorts()
        guard !ports.isEmpty else {
            alert(style: .warning, title: "No device found",
                  text: "Connect the display board to this Mac with a USB cable, then try again.")
            return nil
        }
        if ports.count == 1 { return ports[0] }
        for port in ports {
            guard case .success(let info) = sendCommand("CFGSHOW", port: port, timeout: 2)
            else { continue }
            if ConfigCommands.decodeField("name64=", from: info) == currentName {
                return port
            }
        }
        alert(style: .warning, title: "Display not found",
              text: "Multiple USB serial devices are connected, but none reports the name \"\(currentName)\".")
        return nil
    }

    private static func waitForPort(named name: String, timeout: TimeInterval) -> String? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            for port in candidatePorts() {
                guard case .success(let info) = sendCommand("CFGSHOW", port: port, timeout: 1)
                else { continue }
                if ConfigCommands.decodeField("name64=", from: info) == name {
                    return port
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    // MARK: dialog

    static func run(initialName: String? = nil, preferredSSID: String? = nil) {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.accessory)
        }
        NSApp.activate(ignoringOtherApps: true)

        let ports = candidatePorts()
        guard !ports.isEmpty else {
            alert(style: .warning, title: "No device found",
                  text: "Connect the display board to this Mac with a USB cable, then open this again.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Configure Display"
        alert.informativeText = "Saves settings over USB. WiFi passwords you enter are kept in your login Keychain. The board restarts after a change and streaming reconnects automatically."
        alert.addButton(withTitle: "Save to Device")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 340
        let portPopup = NSPopUpButton(frame: NSRect(x: 0, y: 170, width: width, height: 26))
        portPopup.addItems(withTitles: ports)

        let savedPopup = NSPopUpButton(frame: NSRect(x: 0, y: 136, width: width, height: 26))
        savedPopup.addItem(withTitle: "Custom network…")
        savedPopup.addItems(withTitles: WifiCredentialStore.savedNetworkNames())

        let ssidField = NSTextField(frame: NSRect(x: 0, y: 102, width: width, height: 24))
        ssidField.placeholderString = "Network name (SSID)"
        let passField = NSSecureTextField(frame: NSRect(x: 0, y: 68, width: width, height: 24))
        passField.placeholderString = "Password (blank = keep current)"
        let openCheck = NSButton(checkboxWithTitle: "Open network (no password)",
                                 target: nil, action: nil)
        openCheck.frame = NSRect(x: 0, y: 40, width: width, height: 20)
        let nameField = NSTextField(frame: NSRect(x: 0, y: 6, width: width, height: 24))
        nameField.placeholderString = "Device name (a-z, 0-9, dashes)"
        nameField.stringValue = initialName ?? ""

        let coordinator = DialogCoordinator(
            portPopup: portPopup, savedPopup: savedPopup,
            ssidField: ssidField, passField: passField,
            openCheck: openCheck, nameField: nameField)
        portPopup.target = coordinator
        portPopup.action = #selector(DialogCoordinator.portChanged(_:))
        savedPopup.target = coordinator
        savedPopup.action = #selector(DialogCoordinator.savedNetworkChanged(_:))
        coordinator.reloadDevice()
        if let preferredSSID { coordinator.selectSavedNetwork(preferredSSID) }

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        [portPopup, savedPopup, ssidField, passField, openCheck, nameField]
            .forEach(accessory.addSubview)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = passField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var port = coordinator.selectedPort
        let newName = normalizedDeviceName(nameField.stringValue)
        let renaming = !newName.isEmpty && newName != coordinator.deviceName
        if renaming {
            if case .failure(let reason) = sendCommand(
                ConfigCommands.setName(newName), port: port)
            {
                self.alert(style: .critical, title: "Rename failed", text: reason)
                return
            }
            let wifiUnchanged = ssidField.stringValue.trimmingCharacters(in: .whitespaces)
                    == coordinator.deviceSSID
                && passField.stringValue.isEmpty && openCheck.state == .off
            if wifiUnchanged {
                self.alert(style: .informational, title: "Renamed",
                           text: "The display is restarting as \"\(newName)\".")
                return
            }
            guard let reconnectedPort = waitForPort(named: newName, timeout: 15) else {
                self.alert(style: .critical, title: "WiFi not saved",
                           text: "The name was saved, but the USB serial port did not return after restart. Open Configure Display again to save WiFi.")
                return
            }
            port = reconnectedPort
        }

        let ssid = ssidField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !ssid.isEmpty, ssid.utf8.count <= 32 else {
            self.alert(style: .warning, title: "Invalid SSID",
                       text: "The network name must be 1–32 bytes.")
            return
        }

        let typedPassword = passField.stringValue
        let passwordChange: ConfigCommands.PasswordChange
        if openCheck.state == .on {
            passwordChange = .openNetwork
        } else if typedPassword.isEmpty {
            passwordChange = .keepCurrent
        } else {
            passwordChange = .set(typedPassword)
        }

        if ssid == coordinator.deviceSSID, passwordChange == .keepCurrent,
           !coordinator.deviceSSID.isEmpty
        {
            self.alert(style: .informational, title: "No changes",
                       text: "Already configured for \"\(ssid)\" as \"\(coordinator.deviceName)\".")
            return
        }

        switch sendCommand(
            ConfigCommands.setWifi(ssid: ssid, password: passwordChange), port: port)
        {
        case .success:
            var keychainNote = ""
            switch passwordChange {
            case .set(let password):
                keychainNote = WifiCredentialStore.save(ssid: ssid, password: password)
                    ? " The credential is saved in Keychain."
                    : " The board was configured, but Keychain storage failed."
            case .openNetwork:
                keychainNote = WifiCredentialStore.save(ssid: ssid, password: "")
                    ? " The open network is saved in Keychain."
                    : " The board was configured, but Keychain storage failed."
            case .keepCurrent:
                break
            }
            let kept = passwordChange == .keepCurrent ? " (keeping the device password)" : ""
            self.alert(style: .informational, title: "Saved",
                       text: "The display is restarting and joining \"\(ssid)\"\(kept).\(keychainNote)")
        case .failure(let reason):
            self.alert(style: .critical, title: "Configuration failed", text: reason)
        }
    }

    private static func alert(style: NSAlert.Style, title: String, text: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

/// Handles Finder double-clicks when this process is used without the manager.
final class ReopenDelegate: NSObject, NSApplicationDelegate {
    private var dialogShowing = false

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        guard !dialogShowing else { return false }
        dialogShowing = true
        WifiConfigUI.run()
        dialogShowing = false
        return false
    }
}
