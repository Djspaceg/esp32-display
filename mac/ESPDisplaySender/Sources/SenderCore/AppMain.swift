import AppKit
import Foundation
import ScreenCaptureKit
import SenderProtocol

// ESPDisplaySender: captures a macOS display (BetterDisplay virtual screen)
// with ScreenCaptureKit, converts to RGB565BE, and streams it over UDP to
// the ESP32-C6 panel. See docs/esp32-wireless-display-plan.md.
//
// Usage:
//   ESPDisplaySender --list-displays
//   ESPDisplaySender --mode test [--host espdisplay.local] [--fps 40]
//   ESPDisplaySender --mode capture --display "Tiny Monitor" [--fps 40]
//
// The bootstrap lives here rather than in the executable's main.swift so the
// whole application layer sits in a library target a test target can import.
// The executable is a one-line shim over ESPDisplaySenderApp.run().

struct Options {
    var host = "espdisplay.local"
    var port: UInt16 = 5568
    var mode = "capture"
    var displayName = "Tiny Monitor"
    var fps = 40
    var listDisplays = false
    var listWindows = false
    var configure = false
    var hostExplicit = false
    var devicesConfig = "~/.config/espdisplay/devices.json"
    var windowName = ""
    var landscape = false
    var adaptivePacing = true
    var spacingMicros: UInt32 = 200
    var background = false
}

/// Parse CommandLine.arguments into Options. Prints usage and exits on
/// --help or any unknown app flag / missing value. AppKit and Xcode may add
/// single-dash NS/Apple user-default pairs; those belong to the framework and
/// are intentionally ignored here.
func parseOptions() -> Options {
    var opts = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        func value(_ flag: String) -> String {
            guard !args.isEmpty else {
                FileHandle.standardError.write(Data("missing value for \(flag)\n".utf8))
                exit(2)
            }
            return args.removeFirst()
        }
        if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
            _ = value(arg)
            continue
        }
        switch arg {
        case "--host":
            opts.host = value(arg)
            opts.hostExplicit = true
        case "--devices-config": opts.devicesConfig = value(arg)
        case "--port": opts.port = UInt16(value(arg)) ?? opts.port
        case "--mode": opts.mode = value(arg)
        case "--display": opts.displayName = value(arg)
        case "--fps": opts.fps = Int(value(arg)) ?? opts.fps
        case "--spacing-us": opts.spacingMicros = UInt32(value(arg)) ?? opts.spacingMicros
        case "--list-displays": opts.listDisplays = true
        case "--list-windows": opts.listWindows = true
        case "--configure": opts.configure = true
        case "--window":
            opts.windowName = value(arg)
            opts.mode = "window"
        case "--landscape": opts.landscape = true
        case "--fixed-pacing": opts.adaptivePacing = false
        case "--background": opts.background = true
        case "--help", "-h":
            print("""
                ESPDisplaySender
                  --list-displays          show capturable displays and exit
                  --mode test|capture|window  test pattern, automatic capture (default),
                                           or a named single window.
                                           Automatic mode follows macOS: it honors a
                                           source picked in Control Center's screen-
                                           sharing picker, otherwise it tracks the
                                           virtual display (Extended Display directly,
                                           Entire Screen via its mirror source), and
                                           re-evaluates every 2s so changes made in
                                           System Settings are picked up on their own.
                                           Send SIGUSR1 to open the picker.
                  --display <name>         display name substring (default "Tiny Monitor")
                  --window <name>          app or window title substring; captures that
                                           window directly, no virtual display needed
                  --list-windows           show capturable windows and exit
                  --configure              device WiFi setup dialog (USB serial)
                  --background             run without showing the manager window
                  --host <host>            skip discovery and stream to one host
                  --devices-config <path>  per-device sources as JSON, keyed by device
                                           name (default ~/.config/espdisplay/devices.json):
                                             {"espdisplay-9050": {"display": "Tiny Monitor"},
                                              "espdisplay-abcd": {"window": "Music"}}
                                           devices with no entry use automatic selection
                  --port <port>            UDP port (default 5568)
                  --fps <n>                target frame rate (default 40)
                  --spacing-us <n>         pacing sleep per chunk in microseconds (default 200;
                                           higher = fewer dropped frames, lower peak fps)
                """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown argument: \(arg)\n".utf8))
            exit(2)
        }
    }
    return opts
}

/// Owns the objects that must outlive `run()`'s scope. NSApplication holds its
/// delegate unowned, and as function locals ARC would be free to release these
/// straight after their last use - which is the assignment itself. As top-level
/// globals (their previous home) they lived for the whole process; this keeps
/// that guarantee now that the bootstrap is a function body.
@MainActor
private enum RetainedComponents {
    static var managerWindow: ManagerWindowController?
    static var applicationDelegate: ESPDisplayApplicationDelegate?
}

/// Process entry point. The executable target's main.swift calls this and
/// nothing else.
public enum ESPDisplaySenderApp {
    public static func run() {
        setbuf(stdout, nil)  // line-visible logs when redirected to a file

        // Establish a window-server connection: window-level capture
        // (SCContentFilter(desktopIndependentWindow:)) asserts CGS_REQUIRE_INIT
        // in a plain CLI process without one.
        _ = NSApplication.shared

        // Xcode's Canvas injects the preview view into this process. Keep the
        // AppKit event loop alive, but skip the sender's lock, persistence,
        // discovery, capture, serial, and Keychain startup paths while previews
        // are running.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
            exit(0)
        }

        let opts = parseOptions()
        let launchedInBackground = opts.background
            || ProcessInfo.processInfo.environment["ESPDISP_AGENT"] != nil

        if opts.configure {
            // Standalone invocation: no manager window exists to show the
            // result in, so present it modally.
            MainActor.assumeIsolated {
                WifiConfigUI.presentOutcome(WifiConfigUI.run())
            }
            exit(0)
        }

        // Single-instance guard: two senders interleave frame IDs and the
        // receiver drops nearly everything (each stream invalidates the
        // other's reassembly).
        if !opts.listDisplays && !opts.listWindows {
            let lockFd = open("/tmp/espdisplaysender.lock", O_CREAT | O_RDWR, 0o644)
            if lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
                // The primary process owns the manager. Ask it to show its
                // window, then leave without creating a second frame stream.
                if !launchedInBackground {
                    // The primary may still be installing its observer
                    // immediately after acquiring the lock. Repeat the
                    // idempotent request across that short startup window
                    // instead of losing the open action.
                    for _ in 0..<5 {
                        DistributedNotificationCenter.default().post(
                            name: .espDisplayShowManager, object: nil)
                        usleep(200_000)
                    }
                } else {
                    FileHandle.standardError.write(
                        Data("another ESPDisplaySender instance is already running - exiting\n".utf8))
                }
                // Lock contention means the requested service already exists,
                // not that this process crashed. A successful exit prevents
                // launchd's abnormal-exit policy from creating a respawn loop.
                exit(0)
            }
            // lockFd stays open (and locked) for the process lifetime.
        }

        let panelManager = MainActor.assumeIsolated {
            let manager = PanelManager()
            let window = ManagerWindowController(manager: manager)
            let delegate = ESPDisplayApplicationDelegate(
                managerWindow: window,
                manager: manager,
                showAtLaunch: !launchedInBackground && !opts.listDisplays
                    && !opts.listWindows)
            NSApplication.shared.delegate = delegate
            RetainedComponents.managerWindow = window
            RetainedComponents.applicationDelegate = delegate
            return manager
        }

        Task {
            do {
                try await runSender(opts: opts, panelManager: panelManager)
            } catch {
                FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
                exit(1)
            }
        }

        // Run the full AppKit event loop. The delegate shows the manager for an
        // explicit app launch and keeps login/background launches invisible.
        // Closing the manager returns to accessory mode without interrupting
        // capture.
        NSApplication.shared.run()
    }

    private static func runSender(
        opts: Options, panelManager: PanelManager
    ) async throws {
        if opts.listDisplays {
            let displays = try await DisplayCapture.listDisplays()
            print("Capturable displays:")
            for d in displays {
                print("  [\(d.id)] \"\(d.name)\" \(d.width)x\(d.height)")
            }
            exit(0)
        }
        if opts.listWindows {
            let windows = try await DisplayCapture.listWindows()
            print("Capturable windows:")
            for w in windows.sorted(by: { $0.app < $1.app }) {
                print("  [\(w.id)] \(w.app): \"\(w.title)\" \(w.width)x\(w.height)")
            }
            exit(0)
        }

        // Sessions register here; backlight sync fans out to all of them.
        let registry = SessionRegistry()
        // Panels follow the Mac's display state - not their own content
        // activity. Screensaver and system sleep both count, so a panel goes
        // dark exactly when the Mac's own screens do.
        let workspaceNC = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.willSleepNotification,
        ] {
            workspaceNC.addObserver(forName: name, object: nil, queue: .main) { _ in
                print("Mac sleeping (\(name.rawValue)) - sending devices to sleep")
                registry.all.forEach { $0.sendDisplaySleep() }
            }
        }
        for name: NSNotification.Name in [
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didWakeNotification,
        ] {
            workspaceNC.addObserver(forName: name, object: nil, queue: .main) { _ in
                print("Mac waking (\(name.rawValue)) - waking devices")
                registry.all.forEach {
                    $0.sendDisplayWake()
                    $0.forceKeyframe()
                }
            }
        }

        // Single device for test/window modes: explicit --host wins,
        // otherwise the first discovered _espdisp._udp service.
        func makeSingleSender() async -> FrameSender {
            if opts.hostExplicit {
                return FrameSender(host: opts.host, port: opts.port,
                                   spacingMicros: opts.spacingMicros,
                                   adaptivePacing: opts.adaptivePacing)
            }
            print("discovering devices (_espdisp._udp) ...")
            while true {
                if let device = await discoverFirstDevice(timeoutSeconds: 8) {
                    print("using device \"\(device.name)\"")
                    return FrameSender(endpoint: device.endpoint,
                                       spacingMicros: opts.spacingMicros,
                                       adaptivePacing: opts.adaptivePacing)
                }
                print("no devices found yet - still browsing ...")
            }
        }

        switch opts.mode {
        case "test":
            let sender = await makeSingleSender()
            while true {
                do {
                    try await sender.start()
                    break
                } catch {
                    print("connect failed (\(error.localizedDescription)) - retrying in 5s")
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
            print("test pattern at \(opts.fps) fps" + (opts.landscape ? " (landscape)" : ""))
            var frame = [UInt8](repeating: 0, count: FrameSender.frameBytes)
            var tick = 0
            var lastReport = Date()
            var lastCount: UInt64 = 0
            let interval = 1.0 / Double(opts.fps)
            while true {
                let t0 = Date()
                TestPattern.frame(tick: tick, landscape: opts.landscape, into: &frame)
                sender.send(frame: frame, landscape: opts.landscape)
                tick += 1
                if Date().timeIntervalSince(lastReport) >= 5 {
                    let fps = Double(sender.framesSent - lastCount)
                        / Date().timeIntervalSince(lastReport)
                    let stats = sender.deviceStats
                    print(String(format: "sent: %.1f fps | device: shown=%u dropped=%u pacing=%uus",
                                 fps, stats.shown, stats.dropped, sender.spacingMicros))
                    lastReport = Date()
                    lastCount = sender.framesSent
                }
                let elapsed = Date().timeIntervalSince(t0)
                if elapsed < interval {
                    try await Task.sleep(nanoseconds: UInt64((interval - elapsed) * 1e9))
                }
            }

        case "capture":
            // Keep the manager, discovery, telemetry, and device controls
            // alive when Screen Recording permission is unavailable. A newly
            // signed app may need macOS approval again; capture sessions keep
            // retrying and become usable after the next permitted launch.
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false)
                await MainActor.run { panelManager.resolve(.screenRecording) }
            } catch {
                let message = "screen capture is unavailable - allow ESPDisplaySender in "
                    + "System Settings > Privacy & Security > Screen & System Audio Recording "
                    + "to resume streaming (\(error.localizedDescription))\n"
                FileHandle.standardError.write(Data(message.utf8))
                // Without this the window shows panels that are online and
                // idle with no indication that macOS is blocking capture.
                await MainActor.run {
                    panelManager.report(.screenRecording, detail:
                        "Allow ESPDisplaySender under System Settings > Privacy & Security > "
                        + "Screen & System Audio Recording, then relaunch. Displays stay "
                        + "connected and controllable, but no picture can be sent "
                        + "(\(error.localizedDescription)).")
                }
            }

            // One supervised session per device. Source priority within a
            // session (see DeviceSession): explicit per-device config entry
            // (window or display), else the user's picker selection, else
            // automatic virtual-display tracking.
            let picker = PickerSource()
            picker.activate()
            await MainActor.run { panelManager.attachPicker(picker) }
            print("macOS content picker active - pick or change the source any time from "
                + "the screen-sharing icon in the menu bar (or send SIGUSR1 to open it)")

            let sigSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            sigSource.setEventHandler { picker.present() }
            sigSource.resume()
            signal(SIGUSR1, SIG_IGN)

            // Optional per-device sources: {"espdisplay-9050": {"display":
            // "Tiny Monitor"}, "espdisplay-abcd": {"window": "Music"}}.
            var sourceConfig: [String: SourceSpec] = [:]
            let configPath = (opts.devicesConfig as NSString).expandingTildeInPath
            if let data = FileManager.default.contents(atPath: configPath) {
                do {
                    sourceConfig = try DeviceSourceConfig.parse(data)
                    print("device sources from \(configPath): "
                        + "\(sourceConfig.keys.sorted().joined(separator: ", "))")
                } catch {
                    FileHandle.standardError.write(
                        Data("ignoring malformed \(configPath): \(error.localizedDescription)\n".utf8))
                    // The user edited this file expecting it to take effect;
                    // silently falling back to automatic sources looks like the
                    // app ignoring them for no reason.
                    await MainActor.run {
                        panelManager.report(.deviceConfig, detail:
                            "\(configPath) could not be read, so every display is using "
                            + "automatic source selection: \(error.localizedDescription)")
                    }
                }
            }
            let savedSources = await MainActor.run { panelManager.persistedSources() }
            let namedSources = savedSources.filter { $0.value != .automatic }
            if !namedSources.isEmpty {
                print("saved per-display sources: "
                    + namedSources.keys.sorted().joined(separator: ", "))
            }
            func sourceFor(_ name: String) -> DeviceSession.Source {
                // The manager's own record wins. It is what the picker writes,
                // so a source chosen in the window is still in effect after a
                // restart. devices.json remains supported for panels the UI has
                // never been told about, and as a hand-written default.
                if let saved = savedSources[name], saved != .automatic {
                    return saved.sessionSource(defaultDisplay: opts.displayName)
                }
                if let spec = sourceConfig[name] {
                    if let w = spec.window { return .window(w) }
                    if let d = spec.display { return .display(d) }
                }
                return .auto(defaultDisplay: opts.displayName)
            }
            func launchSession(name: String, sender: FrameSender) {
                let session = DeviceSession(
                    name: name, sender: sender, source: sourceFor(name),
                    picker: picker, fps: opts.fps,
                    onStatus: { status in
                        Task { @MainActor in panelManager.update(status) }
                    })
                registry.add(session)
                Task { @MainActor in panelManager.register(session) }
                Task {
                    // run() only returns if the device never became
                    // reachable; retire it so the browser can retry later
                    // instead of spinning on an mDNS ghost.
                    if await session.run() == false {
                        registry.retire(name)
                        await MainActor.run { panelManager.retire(name) }
                    }
                }
            }

            if opts.hostExplicit {
                launchSession(
                    name: "device",
                    sender: FrameSender(
                        host: opts.host, port: opts.port,
                        spacingMicros: opts.spacingMicros,
                        adaptivePacing: opts.adaptivePacing,
                        onDeviceEvent: { event in
                            Task { @MainActor in
                                panelManager.update(event, for: "device")
                            }
                        }))
            } else {
                // Discovery: every _espdisp._udp service gets a session as
                // it appears. Disappearance is deliberately NOT fatal - mDNS
                // flaps during network transitions, and sessions already
                // self-heal through unreachable devices.
                print("discovering devices (_espdisp._udp) - sessions start as panels appear")
                let browser = DeviceBrowser { devices in
                    Task { @MainActor in panelManager.noteDiscovery(devices) }
                    for device in devices where !registry.shouldSkip(device.name) {
                        print("discovered device \"\(device.name)\"")
                        launchSession(
                            name: device.name,
                            sender: FrameSender(
                                endpoint: device.endpoint,
                                spacingMicros: opts.spacingMicros,
                                adaptivePacing: opts.adaptivePacing,
                                onDeviceEvent: { event in
                                    Task { @MainActor in
                                        panelManager.update(event, for: device.name)
                                    }
                                }))
                    }
                }
                browser.start()
                // Park forever; `browser` stays retained by this scope.
                while true {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                }
            }
            while true {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }

        case "window":
            guard !opts.windowName.isEmpty else {
                FileHandle.standardError.write(
                    Data("window mode needs --window <name> - try --list-windows\n".utf8))
                exit(2)
            }
            // Window capture bypasses the virtual display entirely - it
            // follows the app's window even when occluded, moved between
            // displays, or when no virtual display exists at all. Runs as a
            // single DeviceSession with a window source.
            let sender = await makeSingleSender()
            let session = DeviceSession(
                name: "device", sender: sender,
                source: .window(opts.windowName), picker: nil, fps: opts.fps)
            registry.add(session)
            await session.run()

        default:
            FileHandle.standardError.write(Data("unknown mode \(opts.mode)\n".utf8))
            exit(2)
        }
    }
}
