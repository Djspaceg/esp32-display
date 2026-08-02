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
        case "--landscape": opts.landscape = true
        case "--fixed-pacing": opts.adaptivePacing = false
        case "--help", "-h":
            print("""
                ESPDisplaySender
                  --list-displays          show capturable displays and exit
                  --mode test|capture      test pattern or screen capture (default capture)
                  --display <name>         display name substring (default "Tiny Monitor")
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

let opts = parseOptions()

// Single-instance guard: two senders interleave frame IDs and the receiver
// drops nearly everything (each stream invalidates the other's reassembly).
if !opts.listDisplays {
    let lockFd = open("/tmp/espdisplaysender.lock", O_CREAT | O_RDWR, 0o644)
    if lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) != 0 {
        FileHandle.standardError.write(
            Data("another ESPDisplaySender instance is already running - exiting\n".utf8))
        exit(1)
    }
    // lockFd stays open (and locked) for the process lifetime.
}

let semaphore = DispatchSemaphore(value: 0)

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
                print(String(
                    format: "%@: %.1f fps (%llu total, %llu send errors) | device: "
                        + "shown=%u dropped=%u heap=%u hb=%@ pacing=%uus",
                    label, fps, count, sender.sendErrors,
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
            let uuidCachePath = "/tmp/espdisplaysender-display-uuid"
            var knownUUID = try? String(
                contentsOfFile: uuidCachePath, encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            var announced = false
            var lastReconnectAt = Date.distantPast
            while true {
                guard let resolved = await DisplayCapture.resolve(
                    named: opts.displayName, knownUUID: knownUUID)
                else {
                    if !announced {
                        print("waiting for display \"\(opts.displayName)\" ...")
                        announced = true
                    }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                announced = false
                if let uuid = resolved.targetUUID, uuid != knownUUID {
                    knownUUID = uuid
                    try? uuid.write(toFile: uuidCachePath, atomically: true, encoding: .utf8)
                }
                let display = resolved.display
                let name = DisplayCapture.name(for: display.displayID) ?? "?"
                let shape = (display.displayID, display.width, display.height,
                             resolved.viaMirror)
                print("capturing \"\(name)\" (\(display.width)x\(display.height)) at "
                    + "\(opts.fps) fps\(resolved.viaMirror ? " [mirror source]" : "")")

                let capture = DisplayCapture { rgb565, landscape in
                    sender.send(frame: rgb565, landscape: landscape)
                }
                do {
                    try await capture.start(display: display, fps: opts.fps)
                } catch {
                    FileHandle.standardError.write(Data("capture start failed: \(error), retrying\n".utf8))
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }

                // Watchdog: poll for death, reconfiguration, silent stalls,
                // and a blackholed network path. 2s cadence keeps the gap
                // between a macOS display operation and our reattach short.
                while true {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    reportProgress("streamed", sender.framesSent)

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
                    let current = await DisplayCapture.resolve(
                        named: opts.displayName, knownUUID: knownUUID)
                    if current == nil
                        || (current!.display.displayID, current!.display.width,
                            current!.display.height, current!.viaMirror) != shape
                    {
                        print("display configuration changed - restarting capture")
                        break
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

        default:
            FileHandle.standardError.write(Data("unknown mode \(opts.mode)\n".utf8))
            exit(2)
        }
    } catch {
        FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
        exit(1)
    }
}

semaphore.wait()
