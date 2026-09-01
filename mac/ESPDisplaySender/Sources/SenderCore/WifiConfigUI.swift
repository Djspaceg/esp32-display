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

    /// Why a configuration action could not proceed, as data rather than a
    /// modal. Keeping the reason separate from its presentation is what lets
    /// the port-selection rules below be tested without hardware.
    struct ConfigFailure: Error, Equatable {
        var title: String
        var message: String
    }

    /// Stable identity returned by CFGSHOW for one board.
    struct USBIdentity: Equatable, Sendable {
        var name: String
        var hardwareID: String?
    }

    /// A serial transport plus the device identity shown in pickers.
    struct USBDeviceOption: Identifiable, Equatable, Sendable {
        var id: String { path }

        /// Stable picker value for post-setup assignment. A configured board is
        /// selected by hardware ID; path-only devices retain a transport key.
        var selectionID: String {
            hardwareID.map { "hardware:\($0)" } ?? "path:\(path)"
        }

        var path: String
        var name: String?
        var hardwareID: String?
        var isConnected: Bool

        init(
            path: String,
            name: String? = nil,
            hardwareID: String? = nil,
            isConnected: Bool = true
        ) {
            self.path = path
            self.name = name
            self.hardwareID = ConfigCommands.canonicalHardwareID(hardwareID)
            self.isConnected = isConnected
        }

        var displayName: String {
            if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return name
            }
            if let hardwareID {
                return "ESP32-" + hardwareID.suffix(4).uppercased()
            }
            return (path as NSString).lastPathComponent
        }
    }

    /// What a serial port reported when asked to identify itself.
    enum PortProbe: Equatable, Sendable {
        case identified(USBIdentity)
        /// The port could not be verified, with the reason to show the user.
        case unavailable(String)

        /// Compatibility shorthand for name-only fixtures and older firmware.
        static func named(_ name: String) -> PortProbe {
            .identified(USBIdentity(name: name, hardwareID: nil))
        }
    }

    /// A message worth showing after a configuration change went through.
    struct Confirmation: Equatable {
        var title: String
        var message: String
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

    // MARK: port selection

    /// Decide which serial port a configuration command should be sent to.
    ///
    /// The serial path is transport, not identity. Current firmware is matched
    /// by its station-MAC hardware ID, including after macOS assigns a different
    /// `/dev/cu.*` path. Name matching remains the fallback for older firmware
    /// whose CFGSHOW reply predates the ID field.
    static func selectPort(
        expectedName: String?,
        expectedHardwareID: String? = nil,
        preferredPort: String?,
        availablePorts: [String],
        probe: (String, TimeInterval) -> PortProbe
    ) -> Result<String, ConfigFailure> {
        let expectedName = expectedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedHardwareID = ConfigCommands.canonicalHardwareID(expectedHardwareID)
        let trimmedPreferredPort = preferredPort?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let preferredPort = trimmedPreferredPort?.isEmpty == false
            ? trimmedPreferredPort : nil
        let availablePorts = Array(NSOrderedSet(array: availablePorts)) as? [String]
            ?? availablePorts
        var answers: [String: PortProbe] = [:]

        func checked(_ port: String, timeout: TimeInterval) -> PortProbe {
            if let answer = answers[port] { return answer }
            let answer = probe(port, timeout)
            answers[port] = answer
            return answer
        }

        func identityMatches(_ identity: USBIdentity) -> Bool {
            if let expectedHardwareID {
                if let actual = ConfigCommands.canonicalHardwareID(identity.hardwareID) {
                    return actual == expectedHardwareID
                }
                guard let expectedName, !expectedName.isEmpty else { return false }
                return identity.name == expectedName
            }
            guard let expectedName, !expectedName.isEmpty else { return true }
            return identity.name == expectedName
        }

        var preferredFailure: String?
        var preferredMismatch = false
        if let preferredPort {
            switch checked(preferredPort, timeout: 3) {
            case .identified(let identity):
                // A legacy assignment with no stable ID remains an explicit
                // override. Once an ID is known, the ID is authoritative.
                if expectedHardwareID == nil || identityMatches(identity) {
                    return .success(preferredPort)
                }
                preferredMismatch = true
            case .unavailable(let reason):
                preferredFailure = reason
            }
        }

        let candidates = availablePorts.filter { $0 != preferredPort }
        if candidates.isEmpty {
            if let preferredPort, let preferredFailure {
                return .failure(ConfigFailure(
                    title: "Assigned USB device unavailable",
                    message: "Could not verify \(preferredPort): \(preferredFailure)"))
            }
            if preferredMismatch, let preferredPort {
                return .failure(ConfigFailure(
                    title: "Assigned USB device mismatch",
                    message: "The device at \(preferredPort) is not the saved hardware device."))
            }
            return .failure(ConfigFailure(
                title: "No device found",
                message: "Connect the display board to this Mac with a USB cable, then try again."))
        }

        if preferredPort == nil, expectedHardwareID == nil,
           expectedName?.isEmpty != false, candidates.count > 1 {
            return .failure(ConfigFailure(
                title: "Select a USB device",
                message: "More than one USB serial device is connected. Select a display in the manager and assign its USB device under Connection."))
        }

        let timeout: TimeInterval = preferredPort == nil && candidates.count == 1 ? 3 : 2
        let identified = candidates.compactMap { port -> (String, USBIdentity)? in
            guard case .identified(let identity) = checked(port, timeout: timeout)
            else { return nil }
            return (port, identity)
        }
        let matching = identified.filter { identityMatches($0.1) }
        if matching.count == 1 { return .success(matching[0].0) }
        if matching.count > 1 {
            if let expectedHardwareID {
                return .failure(ConfigFailure(
                    title: "USB device is ambiguous",
                    message: "More than one USB device reports hardware ID \"\(expectedHardwareID)\". Assign the correct device under Connection before changing the display."))
            }
            return .failure(ConfigFailure(
                title: "USB device is ambiguous",
                message: "More than one USB device reports the name \"\(expectedName ?? "")\". Assign the correct port under Connection before changing the display."))
        }

        if preferredPort == nil, candidates.count == 1,
           let identity = identified.first?.1,
           let expectedName, !expectedName.isEmpty,
           expectedHardwareID == nil {
            return .failure(ConfigFailure(
                title: "USB device mismatch",
                message: "The connected USB device at \(candidates[0]) reports \"\(identity.name)\", not \"\(expectedName)\". Assign the correct port under Connection before changing the display."))
        }
        if preferredPort == nil, candidates.count == 1,
           case .unavailable(let reason) = checked(candidates[0], timeout: timeout) {
            return .failure(ConfigFailure(
                title: "USB device unavailable",
                message: "Could not verify \(candidates[0]): \(reason)"))
        }

        if let expectedHardwareID {
            return .failure(ConfigFailure(
                title: "Display not found",
                message: "No connected USB device reports hardware ID \"\(expectedHardwareID)\". Reconnect the display and try again."))
        }
        return .failure(ConfigFailure(
            title: "Display not found",
            message: "No connected USB device reports the name \"\(expectedName ?? "")\". Assign its port under Connection, or reconnect the display and try again."))
    }

    // MARK: direct manager actions

    /// Rename the display over USB. Returns the name that was actually applied,
    /// which is the normalised form of `newName`.
    static func renameDevice(
        currentName: String,
        newName: String,
        preferredPort: String? = nil,
        expectedHardwareID: String? = nil
    ) -> Result<String, ConfigFailure> {
        let normalized = normalizedDeviceName(newName)
        guard !normalized.isEmpty else {
            return .failure(ConfigFailure(
                title: "Invalid name",
                message: "Use letters, numbers, spaces, underscores, or dashes."))
        }
        let port: String
        switch matchingPort(
            for: currentName, expectedHardwareID: expectedHardwareID,
            preferredPort: preferredPort)
        {
        case .success(let resolved): port = resolved
        case .failure(let failure): return .failure(failure)
        }
        switch sendCommand(ConfigCommands.setName(normalized), port: port) {
        case .success:
            return .success(normalized)
        case .failure(let reason):
            return .failure(ConfigFailure(title: "Rename failed", message: reason))
        }
    }

    static func applySavedNetwork(
        _ ssid: String,
        currentName: String,
        preferredPort: String? = nil,
        expectedHardwareID: String? = nil
    ) -> Result<Void, ConfigFailure> {
        guard let credential = WifiCredentialStore.credential(for: ssid) else {
            return .failure(ConfigFailure(
                title: "Credential not found",
                message: "Add \"\(ssid)\" again to store it in Keychain."))
        }
        let port: String
        switch matchingPort(
            for: currentName, expectedHardwareID: expectedHardwareID,
            preferredPort: preferredPort)
        {
        case .success(let resolved): port = resolved
        case .failure(let failure): return .failure(failure)
        }
        let change: ConfigCommands.PasswordChange = credential.password.isEmpty
            ? .openNetwork : .set(credential.password)
        switch sendCommand(
            ConfigCommands.setWifi(ssid: credential.ssid, password: change), port: port)
        {
        case .success:
            return .success(())
        case .failure(let reason):
            return .failure(ConfigFailure(title: "Configuration failed", message: reason))
        }
    }

    /// Set a panel's OTA password over USB. The panel restarts on success -
    /// see the `CFGOTAPW` handler in display_stream.ino - so the caller
    /// should not expect an immediate second command to reach the same
    /// session.
    static func setOTAPassword(
        _ password: String,
        currentName: String,
        preferredPort: String? = nil,
        expectedHardwareID: String? = nil
    ) -> Result<Void, ConfigFailure> {
        let port: String
        switch matchingPort(
            for: currentName, expectedHardwareID: expectedHardwareID,
            preferredPort: preferredPort)
        {
        case .success(let resolved): port = resolved
        case .failure(let failure): return .failure(failure)
        }
        switch sendCommand(ConfigCommands.setOTAPassword(password), port: port, timeout: 10) {
        case .success:
            return .success(())
        case .failure(let reason):
            return .failure(ConfigFailure(title: "Setting OTA password failed", message: reason))
        }
    }

    /// Clear a panel's stored OTA password over USB, turning OTA back off.
    /// The panel restarts on success, same as `setOTAPassword`.
    static func clearOTAPassword(
        currentName: String,
        preferredPort: String? = nil,
        expectedHardwareID: String? = nil
    ) -> Result<Void, ConfigFailure> {
        let port: String
        switch matchingPort(
            for: currentName, expectedHardwareID: expectedHardwareID,
            preferredPort: preferredPort)
        {
        case .success(let resolved): port = resolved
        case .failure(let failure): return .failure(failure)
        }
        switch sendCommand(ConfigCommands.clearOTAPassword, port: port, timeout: 10) {
        case .success:
            return .success(())
        case .failure(let reason):
            return .failure(ConfigFailure(title: "Clearing OTA password failed", message: reason))
        }
    }

    private static func matchingPort(
        for currentName: String?,
        expectedHardwareID: String? = nil,
        preferredPort: String? = nil
    ) -> Result<String, ConfigFailure> {
        selectPort(
            expectedName: currentName,
            expectedHardwareID: expectedHardwareID,
            preferredPort: preferredPort,
            availablePorts: candidatePorts(),
            probe: probePort)
    }

    /// Ask the device over USB which network it is actually joined to, for
    /// preselecting the "Saved WiFi" picker against reality rather than
    /// against nothing - `CFGSHOW` is the only place the firmware reports
    /// this: EINF's telemetry carries the `wifiConnected` flag but never the
    /// SSID string, so this always needs a live serial port.
    ///
    /// Returns nil on any failure (no port, wrong device, no reply) rather
    /// than surfacing an error: this is read-only background information for
    /// a picker default, not a user-initiated action, so a board that is
    /// merely unreachable over USB right now should leave the picker exactly
    /// as it already was instead of raising an alert.
    static func currentSSID(
        currentName: String?,
        expectedHardwareID: String? = nil,
        preferredPort: String? = nil
    ) -> String? {
        guard case .success(let port) = matchingPort(
            for: currentName, expectedHardwareID: expectedHardwareID,
            preferredPort: preferredPort)
        else { return nil }
        guard case .success(let info) = sendCommand("CFGSHOW", port: port, timeout: 3)
        else { return nil }
        let ssid = ConfigCommands.decodeField("ssid64=", from: info)
        // The firmware always emits the field, but an empty string (never
        // configured) is not a network name worth offering as a selection.
        return ssid?.isEmpty == false ? ssid : nil
    }

    /// Ask a port to identify itself. CFGSHOW answering at all is what proves
    /// the path speaks our configuration protocol.
    static func probePort(_ port: String, timeout: TimeInterval) -> PortProbe {
        switch sendCommand("CFGSHOW", port: port, timeout: timeout) {
        case .success(let info):
            return .identified(USBIdentity(
                name: ConfigCommands.decodeField("name64=", from: info) ?? "",
                hardwareID: ConfigCommands.hardwareID(from: info)))
        case .failure(let reason):
            return .unavailable(reason)
        }
    }

    // MARK: dialog

    /// Show the WiFi configuration dialog. Returns the confirmation to show on
    /// success, or nil when the user cancelled. Nothing here presents its own
    /// alert, so the manager can report the outcome the same way it reports
    /// every other action.
    static func run(
        currentName: String? = nil,
        expectedHardwareID: String? = nil,
        preferredPort: String? = nil,
        preferredSSID: String? = nil
    ) -> Result<Confirmation?, ConfigFailure> {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.accessory)
        }
        NSApp.activate(ignoringOtherApps: true)

        let port: String
        switch matchingPort(
            for: currentName, expectedHardwareID: expectedHardwareID,
            preferredPort: preferredPort)
        {
        case .success(let resolved): port = resolved
        case .failure(let failure): return .failure(failure)
        }

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

        guard alert.runModal() == .alertFirstButtonReturn else { return .success(nil) }

        let ssid = ssidField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !ssid.isEmpty, ssid.utf8.count <= 32 else {
            return .failure(ConfigFailure(
                title: "Invalid SSID",
                message: "The network name must be 1–32 bytes."))
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
            return .success(Confirmation(
                title: "No changes",
                message: "The display is already configured for \"\(ssid)\"."))
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
            return .success(Confirmation(
                title: "Saved",
                message: "The display is restarting and joining \"\(ssid)\"\(kept)."
                    + keychainNote))
        case .failure(let reason):
            return .failure(ConfigFailure(
                title: "Configuration failed", message: reason))
        }
    }

    /// Present an outcome as a modal alert. Only for the standalone path, where
    /// the process runs the configuration dialog with no manager window to show
    /// the result in.
    static func presentOutcome(_ result: Result<Confirmation?, ConfigFailure>) {
        switch result {
        case .success(let confirmation):
            guard let confirmation else { return }
            alert(style: .informational, title: confirmation.title,
                  text: confirmation.message)
        case .failure(let failure):
            alert(style: .warning, title: failure.title, text: failure.message)
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
        // No manager window exists on this path, so this is the one place that
        // still presents a configuration outcome as a modal alert.
        WifiConfigUI.presentOutcome(WifiConfigUI.run())
        dialogShowing = false
        return false
    }
}
