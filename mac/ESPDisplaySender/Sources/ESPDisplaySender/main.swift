import AppKit
import Foundation
import ScreenCaptureKit

// ESPDisplaySender: captures a macOS display (BetterDisplay virtual screen)
// with ScreenCaptureKit, converts to RGB565BE, and streams it over UDP to
// the ESP32-C6 panel. See docs/esp32-wireless-display-plan.md.
//
// Usage:
//   ESPDisplaySender --list-displays
//   ESPDisplaySender --mode test [--host espdisplay.local] [--fps 40]
//   ESPDisplaySender --mode capture --display "Tiny Monitor" [--fps 40]

struct Options {
    var host = "espdisplay.local"
    var port: UInt16 = 5568
    var mode = "capture"
    var displayName = "Tiny Monitor"
    var fps = 40
    var listDisplays = false
    var listWindows = false
    var windowName = ""
    var landscape = false
    var adaptivePacing = true
    var spacingMicros: UInt32 = 200
}

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
        switch arg {
        case "--host": opts.host = value(arg)
        case "--port": opts.port = UInt16(value(arg)) ?? opts.port
        case "--mode": opts.mode = value(arg)
        case "--display": opts.displayName = value(arg)
        case "--fps": opts.fps = Int(value(arg)) ?? opts.fps
        case "--spacing-us": opts.spacingMicros = UInt32(value(arg)) ?? opts.spacingMicros
        case "--list-displays": opts.listDisplays = true
        case "--list-windows": opts.listWindows = true
        case "--window":
            opts.windowName = value(arg)
            opts.mode = "window"
        case "--landscape": opts.landscape = true
        case "--fixed-pacing": opts.adaptivePacing = false
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
                  --host <host>            ESP32 host (default espdisplay.local)
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

setbuf(stdout, nil)  // line-visible logs when redirected to a file

// Establish a window-server connection: window-level capture
// (SCContentFilter(desktopIndependentWindow:)) asserts CGS_REQUIRE_INIT in a
// plain CLI process without one.
_ = NSApplication.shared

let opts = parseOptions()

// Single-instance guard: two senders interleave frame IDs and the receiver
// drops nearly everything (each stream invalidates the other's reassembly).
if !opts.listDisplays && !opts.listWindows {
    let lockFd = open("/tmp/espdisplaysender.lock", O_CREAT | O_RDWR, 0o644)
    if lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
        FileHandle.standardError.write(
            Data("another ESPDisplaySender instance is already running - exiting\n".utf8))
        exit(1)
    }
    // lockFd stays open (and locked) for the process lifetime.
}



Task {
    do {
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

        let sender = FrameSender(host: opts.host, port: opts.port,
                                 spacingMicros: opts.spacingMicros,
                                 adaptivePacing: opts.adaptivePacing)
        print("connecting to \(opts.host):\(opts.port) ...")
        // mDNS resolution fails while the ESP32 is booting or off the
        // network; keep retrying instead of dying.
        while true {
            do {
                try await sender.start()
                break
            } catch {
                print("connect failed (\(error.localizedDescription)) - retrying in 5s")
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }

        var lastReport = Date()
        var lastCount: UInt64 = 0
        func reportProgress(_ label: String, _ count: UInt64) {
            let now = Date()
            let dt = now.timeIntervalSince(lastReport)
            if dt >= 5 {
                let fps = Double(count - lastCount) / dt
                let stats = sender.deviceStats
                let hb = sender.heartbeatAge.map { String(format: "%.0fs ago", $0) } ?? "never"
                let diffPct = sender.bandsConsidered > 0
                    ? Double(sender.bandsSent) * 100 / Double(sender.bandsConsidered) : 0
                print(String(
                    format: "%@: %.1f fps (%llu total, %llu send errors, diff %.0f%%) | device: "
                        + "shown=%u dropped=%u heap=%u hb=%@ pacing=%uus",
                    label, fps, count, sender.sendErrors, diffPct,
                    stats.shown, stats.dropped, stats.heap, hb, sender.spacingMicros))
                lastReport = now
                lastCount = count
            }
        }

        switch opts.mode {
        case "test":
            print("test pattern at \(opts.fps) fps -> \(opts.host)"
                + (opts.landscape ? " (landscape)" : ""))
            var frame = [UInt8](repeating: 0, count: FrameSender.frameBytes)
            var tick = 0
            let interval = 1.0 / Double(opts.fps)
            while true {
                let t0 = Date()
                TestPattern.frame(tick: tick, landscape: opts.landscape, into: &frame)
                sender.send(frame: frame, landscape: opts.landscape)
                tick += 1
                reportProgress("sent", sender.framesSent)
                let elapsed = Date().timeIntervalSince(t0)
                if elapsed < interval {
                    try await Task.sleep(nanoseconds: UInt64((interval - elapsed) * 1e9))
                }
            }

        case "capture":
            // Fail fast with a clear message if screen capture permission is
            // missing - otherwise the retry loop below would mask it as
            // "waiting for display" forever.
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false)
            } catch {
                let msg = "cannot enumerate displays - grant Screen Recording permission "
                    + "in System Settings > Privacy & Security (\(error.localizedDescription))\n"
                FileHandle.standardError.write(Data(msg.utf8))
                exit(1)
            }

            // Outer loop restarts capture whenever the display disappears,
            // changes shape, or resolves to a different capture source
            // (e.g. becomes a mirror target). Display reconfiguration kills
            // the SCStream *silently* - no delegate error fires - so we poll
            // and compare. Identity is anchored on the display's UUID, which
            // survives every reconfiguration; it's cached to disk so even a
            // sender restart mid-mirror re-finds the display.
            // Source priority, re-evaluated continuously so the stream
            // follows whatever macOS is doing without any command:
            //   1. The user's explicit pick in macOS's content picker
            //      (Control Center / menu bar). This covers the mirroring
            //      dialog's "Window or App" case, which tears the virtual
            //      display down entirely, and can be changed at any time.
            //   2. Automatic virtual-display tracking: "Extended Display"
            //      leaves an independently capturable display, "Entire
            //      Screen" leaves a mirror-set member we traverse to its
            //      source.
            let picker = PickerSource()
            picker.activate()
            print("macOS content picker active - pick or change the source any time from "
                + "the screen-sharing icon in the menu bar (or send SIGUSR1 to open it)")

            let sigSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            sigSource.setEventHandler { picker.present() }
            sigSource.resume()
            signal(SIGUSR1, SIG_IGN)

            let uuidCachePath = "/tmp/espdisplaysender-display-uuid"
            var knownUUID = try? String(
                contentsOfFile: uuidCachePath, encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            var announced = false
            var lastReconnectAt = Date.distantPast
            var pickerFailures = 0

            while true {
                let capture = DisplayCapture { rgb565, landscape in
                    sender.submit(frame: rgb565, landscape: landscape)
                }
                // Any picker activity (new pick, re-pick, or clear) bumps the
                // generation; comparing against this baseline detects a user
                // choice in either direction - display -> picked source and
                // picked source -> re-picked.
                let baselinePickerGen = picker.generation
                var displayShape: (CGDirectDisplayID, Int, Int, Bool)?

                if let selection = picker.current {
                    do {
                        try await capture.start(contentFilter: selection.filter, fps: opts.fps)
                        pickerFailures = 0
                        announced = false
                        print("capturing \(picker.describe(selection.filter)) "
                            + "from picker selection at \(opts.fps) fps")
                    } catch {
                        // A picked window that closed would otherwise wedge
                        // us here; after a few tries fall back to automatic
                        // display tracking rather than freeze.
                        pickerFailures += 1
                        FileHandle.standardError.write(
                            Data("picker source failed: \(error.localizedDescription)\n".utf8))
                        if pickerFailures >= 3 {
                            picker.clearSelection()
                            pickerFailures = 0
                        }
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        continue
                    }
                } else if let resolved = await DisplayCapture.resolve(
                    named: opts.displayName, knownUUID: knownUUID)
                {
                    if let uuid = resolved.targetUUID, uuid != knownUUID {
                        knownUUID = uuid
                        try? uuid.write(toFile: uuidCachePath, atomically: true, encoding: .utf8)
                    }
                    let display = resolved.display
                    displayShape = (display.displayID, display.width, display.height,
                                    resolved.viaMirror)
                    do {
                        try await capture.start(display: display, fps: opts.fps)
                        announced = false
                        let name = DisplayCapture.name(for: display.displayID) ?? "?"
                        print("capturing \"\(name)\" (\(display.width)x\(display.height)) at "
                            + "\(opts.fps) fps\(resolved.viaMirror ? " [mirror source]" : "")")
                    } catch {
                        FileHandle.standardError.write(
                            Data("capture start failed: \(error.localizedDescription), retrying\n".utf8))
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        continue
                    }
                } else {
                    if !announced {
                        print("no source available: \"\(opts.displayName)\" isn't a capturable "
                            + "display and nothing is picked. Set the display to Extended "
                            + "Display or Entire Screen, or pick a window/app from the "
                            + "menu bar screen-sharing icon.")
                        announced = true
                    }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }

                // Watchdog: poll for death, reconfiguration, silent stalls,
                // a user source change, and a blackholed network path. 2s
                // cadence keeps the gap after a macOS display operation short.
                while true {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    reportProgress("streamed", sender.framesSent)

                    if picker.generation != baselinePickerGen {
                        print("source selection changed - switching")
                        break
                    }
                    if capture.stopped {
                        print("capture stream died - restarting")
                        break
                    }
                    // Sleep/wake can kill the stream without firing the
                    // delegate; a healthy stream emits status samples even
                    // when the screen is static.
                    if Date().timeIntervalSince(capture.lastSampleAt) > 30 {
                        print("no capture samples for 30s - restarting capture")
                        break
                    }
                    // Only relevant while tracking a display; a picked source
                    // is independent of display topology.
                    if let shape = displayShape {
                        let current = await DisplayCapture.resolve(
                            named: opts.displayName, knownUUID: knownUUID)
                        if current == nil
                            || (current!.display.displayID, current!.display.width,
                                current!.display.height, current!.viaMirror) != shape
                        {
                            print("display configuration changed - restarting capture")
                            break
                        }
                    }
                    // Device heartbeats stop when the ESP32 rebooted onto a
                    // new address or dropped off WiFi; re-resolving heals it.
                    // (Firmware only learns our reply address after our first
                    // packet, so a nil age right after connect is normal -
                    // the 2s keepalive pings bootstrap it.)
                    if let age = sender.heartbeatAge, age > 10,
                        Date().timeIntervalSince(lastReconnectAt) > 15
                    {
                        print(String(format: "no device heartbeat for %.0fs", age))
                        lastReconnectAt = Date()
                        await sender.reconnect()
                    }
                }
                await capture.stop()
            }

        case "window":
            guard !opts.windowName.isEmpty else {
                FileHandle.standardError.write(
                    Data("window mode needs --window <name> - try --list-windows\n".utf8))
                exit(2)
            }
            // Window capture bypasses the virtual display entirely - it
            // follows the app's window even when occluded, moved between
            // displays, or when no virtual display exists at all.
            var announced = false
            var lastReconnectAt = Date.distantPast
            while true {
                guard let window = await DisplayCapture.findWindow(matching: opts.windowName)
                else {
                    if !announced {
                        print("waiting for a window matching \"\(opts.windowName)\" ...")
                        announced = true
                    }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                announced = false
                let app = window.owningApplication?.applicationName ?? "?"
                let title = window.title ?? ""
                let windowID = window.windowID
                let wasLandscape = window.frame.width > window.frame.height
                print("capturing window [\(windowID)] \(app): \"\(title)\" "
                    + "(\(Int(window.frame.width))x\(Int(window.frame.height))) at \(opts.fps) fps")

                let capture = DisplayCapture { rgb565, landscape in
                    sender.submit(frame: rgb565, landscape: landscape)
                }
                do {
                    try await capture.start(window: window, fps: opts.fps)
                } catch {
                    FileHandle.standardError.write(
                        Data("window capture start failed: \(error), retrying\n".utf8))
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }

                while true {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    reportProgress("streamed", sender.framesSent)
                    if capture.stopped {
                        print("window capture died - restarting")
                        break
                    }
                    if Date().timeIntervalSince(capture.lastSampleAt) > 30 {
                        print("no capture samples for 30s - restarting capture")
                        break
                    }
                    // Window closed, or resized across the aspect boundary
                    // (orientation is baked into the stream config).
                    let current = await DisplayCapture.findWindow(matching: opts.windowName)
                    if current == nil || current!.windowID != windowID {
                        print("window changed or closed - restarting capture")
                        break
                    }
                    if (current!.frame.width > current!.frame.height) != wasLandscape {
                        print("window aspect flipped - restarting capture")
                        break
                    }
                    if let age = sender.heartbeatAge, age > 10,
                        Date().timeIntervalSince(lastReconnectAt) > 15
                    {
                        print(String(format: "no device heartbeat for %.0fs", age))
                        lastReconnectAt = Date()
                        await sender.reconnect()
                    }
                }
                await capture.stop()
            }

        default:
            FileHandle.standardError.write(Data("unknown mode \(opts.mode)\n".utf8))
            exit(2)
        }
    } catch {
        FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
        exit(1)
    }
}

// Keep the main run loop alive and serviced (instead of blocking on a
// semaphore): AppKit UI like the content picker needs it, and it drains the
// main dispatch queue - the SIGUSR1 handler is scheduled there and could
// never fire while the main thread was parked in a semaphore wait.
RunLoop.main.run()
