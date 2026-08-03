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
        let port: String
        let savedPopup: NSPopUpButton
        let ssidField: NSTextField
        let passField: NSSecureTextField
        let openCheck: NSButton
        var deviceSSID = ""

        init(
            port: String,
            savedPopup: NSPopUpButton,
            ssidField: NSTextField,
            passField: NSSecureTextField,
            openCheck: NSButton
        ) {
            self.port = port
            self.savedPopup = savedPopup
            self.ssidField = ssidField
            self.passField = passField
            self.openCheck = openCheck
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
            guard case .success(let info) = WifiConfigUI.sendCommand(
                "CFGSHOW", port: port, timeout: 3)
            else { return }
            deviceSSID = ConfigCommands.decodeField("ssid64=", from: info) ?? ""
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

    static func renameDevice(
        currentName: String,
        newName: String,
        preferredPort: String? = nil
    ) -> String? {
        let normalized = normalizedDeviceName(newName)
        guard !normalized.isEmpty else {
            alert(style: .warning, title: "Invalid name",
                  text: "Use letters, numbers, spaces, underscores, or dashes.")
            return nil
        }
        guard let port = matchingPort(
            for: currentName,
            preferredPort: preferredPort)
        else { return nil }
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

    static func applySavedNetwork(
        _ ssid: String,
        currentName: String,
        preferredPort: String? = nil
    ) -> Bool {
        guard let credential = WifiCredentialStore.credential(for: ssid) else {
            alert(style: .warning, title: "Credential not found",
                  text: "Add \"\(ssid)\" again to store it in Keychain.")
            return false
        }
        guard let port = matchingPort(
            for: currentName,
            preferredPort: preferredPort)
        else { return false }
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

    private static func matchingPort(
        for currentName: String?,
        preferredPort: String? = nil
    ) -> String? {
        let expectedName = currentName?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let preferredPort,
           !preferredPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return validate(
                port: preferredPort,
                expectedName: expectedName,
                assignment: true)
        }

        let ports = candidatePorts()
        guard !ports.isEmpty else {
            alert(style: .warning, title: "No device found",
                  text: "Connect the display board to this Mac with a USB cable, then try again.")
            return nil
        }
        if ports.count == 1 {
            return validate(
                port: ports[0],
                expectedName: expectedName,
                assignment: false)
        }
        guard let expectedName, !expectedName.isEmpty else {
            alert(style: .warning, title: "Select a USB device",
                  text: "More than one USB serial device is connected. Select a display in the manager and assign its USB device under Connection.")
            return nil
        }

        let matches = ports.filter { port in
            guard case .success(let info) = sendCommand(
                "CFGSHOW", port: port, timeout: 2)
            else { return false }
            return ConfigCommands.decodeField("name64=", from: info) == expectedName
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            alert(style: .warning, title: "USB device is ambiguous",
                  text: "More than one USB device reports the name \"\(expectedName)\". Assign the correct port under Connection before changing the display.")
            return nil
        }
        alert(style: .warning, title: "Display not found",
              text: "No connected USB device reports the name \"\(expectedName)\". Assign its port under Connection, or reconnect the display and try again.")
        return nil
    }

    private static func validate(
        port: String,
        expectedName: String?,
        assignment: Bool
    ) -> String? {
        switch sendCommand("CFGSHOW", port: port, timeout: 3) {
        case .success(let info):
            // Choosing a concrete port is the user's explicit identity override.
            // CFGSHOW still proves that the path speaks our configuration protocol.
            if assignment { return port }
            guard let expectedName, !expectedName.isEmpty else { return port }
            let reportedName = ConfigCommands.decodeField("name64=", from: info) ?? ""
            guard reportedName == expectedName else {
                alert(style: .warning, title: "USB device mismatch",
                      text: "The connected USB device at \(port) reports \"\(reportedName)\", not \"\(expectedName)\". Assign the correct port under Connection before changing the display.")
                return nil
            }
            return port
        case .failure(let reason):
            let title = assignment ? "Assigned USB device unavailable" : "USB device unavailable"
            alert(style: .warning, title: title,
                  text: "Could not verify \(port): \(reason)")
            return nil
        }
    }

    // MARK: dialog

    static func run(
        currentName: String? = nil,
        preferredPort: String? = nil,
        preferredSSID: String? = nil
    ) {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.accessory)
        }
        NSApp.activate(ignoringOtherApps: true)

        guard let port = matchingPort(
            for: currentName,
            preferredPort: preferredPort)
        else { return }

        let alert = NSAlert()
        alert.messageText = "Configure WiFi"
        alert.informativeText = "Saves network settings to the selected display over USB. Passwords you enter are kept in your login Keychain. The display restarts after a change and streaming reconnects automatically."
        alert.addButton(withTitle: "Save to Display")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 340
        let savedPopup = NSPopUpButton(frame: NSRect(x: 0, y: 106, width: width, height: 26))
        savedPopup.addItem(withTitle: "Custom network…")
        savedPopup.addItems(withTitles: WifiCredentialStore.savedNetworkNames())

        let ssidField = NSTextField(frame: NSRect(x: 0, y: 72, width: width, height: 24))
        ssidField.placeholderString = "Network name (SSID)"
        let passField = NSSecureTextField(frame: NSRect(x: 0, y: 38, width: width, height: 24))
        passField.placeholderString = "Password (blank = keep current)"
        let openCheck = NSButton(checkboxWithTitle: "Open network (no password)",
                                 target: nil, action: nil)
        openCheck.frame = NSRect(x: 0, y: 10, width: width, height: 20)

        let coordinator = DialogCoordinator(
            port: port, savedPopup: savedPopup,
            ssidField: ssidField, passField: passField,
            openCheck: openCheck)
        savedPopup.target = coordinator
        savedPopup.action = #selector(DialogCoordinator.savedNetworkChanged(_:))
        coordinator.reloadDevice()
        if let preferredSSID { coordinator.selectSavedNetwork(preferredSSID) }

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 142))
        [savedPopup, ssidField, passField, openCheck].forEach(accessory.addSubview)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = ssidField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

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
                       text: "The display is already configured for \"\(ssid)\".")
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
                    : " The display was configured, but Keychain storage failed."
            case .openNetwork:
                keychainNote = WifiCredentialStore.save(ssid: ssid, password: "")
                    ? " The open network is saved in Keychain."
                    : " The display was configured, but Keychain storage failed."
            case .keepCurrent:
                break
            }
            let kept = passwordChange == .keepCurrent ? " (keeping the display password)" : ""
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
