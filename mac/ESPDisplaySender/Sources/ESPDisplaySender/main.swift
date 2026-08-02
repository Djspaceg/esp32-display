import Foundation

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
    var spacingMicros: UInt32 = 150
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
        case "--help", "-h":
            print("""
                ESPDisplaySender
                  --list-displays          show capturable displays and exit
                  --mode test|capture      test pattern or screen capture (default capture)
                  --display <name>         display name substring (default "Tiny Monitor")
                  --host <host>            ESP32 host (default espdisplay.local)
                  --port <port>            UDP port (default 5568)
                  --fps <n>                target frame rate (default 40)
                  --spacing-us <n>         pacing sleep per 8 chunks (default 150)
                """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown argument: \(arg)\n".utf8))
            exit(2)
        }
    }
    return opts
}

let opts = parseOptions()

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
                                 spacingMicros: opts.spacingMicros)
        print("connecting to \(opts.host):\(opts.port) ...")
        try await sender.start()
        print("UDP ready")

        var lastReport = Date()
        var lastCount: UInt64 = 0
        func reportProgress(_ label: String, _ count: UInt64) {
            let now = Date()
            let dt = now.timeIntervalSince(lastReport)
            if dt >= 5 {
                let fps = Double(count - lastCount) / dt
                print(String(format: "%@: %.1f fps (%llu total, %llu send errors)",
                             label, fps, count, sender.sendErrors))
                lastReport = now
                lastCount = count
            }
        }

        switch opts.mode {
        case "test":
            print("test pattern at \(opts.fps) fps -> \(opts.host)")
            var frame = [UInt8](repeating: 0, count: FrameSender.frameBytes)
            var tick = 0
            let interval = 1.0 / Double(opts.fps)
            while true {
                let t0 = Date()
                TestPattern.frame(tick: tick, into: &frame)
                sender.send(frame: frame)
                tick += 1
                reportProgress("sent", sender.framesSent)
                let elapsed = Date().timeIntervalSince(t0)
                if elapsed < interval {
                    try await Task.sleep(nanoseconds: UInt64((interval - elapsed) * 1e9))
                }
            }

        case "capture":
            guard let display = try await DisplayCapture.findDisplay(named: opts.displayName)
            else {
                FileHandle.standardError.write(
                    Data("no display matching \"\(opts.displayName)\" - try --list-displays\n".utf8))
                exit(1)
            }
            let name = DisplayCapture.name(for: display.displayID) ?? "?"
            print("capturing \"\(name)\" (\(display.width)x\(display.height)) at \(opts.fps) fps")

            let capture = DisplayCapture { rgb565 in
                sender.send(frame: rgb565)
            }
            try await capture.start(display: display, fps: opts.fps)
            print("capture running - Ctrl-C to stop")
            while true {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                reportProgress("streamed", sender.framesSent)
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
