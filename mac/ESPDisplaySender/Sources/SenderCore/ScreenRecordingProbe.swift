import AppKit
import CoreGraphics
import Foundation
import OSLog

/// Minimal diagnostic bundle for separating the system's Screen Recording
/// behavior from ESPDisplaySender's normal capture, networking and permission
/// setup. It is compiled only into the separately installed probe app.
enum ScreenRecordingProbeApp {
    @MainActor private static var controller: Controller?
    private static let logger = Logger(
        subsystem: "com.resourcefork.espdisplay.srprobe", category: "screen-recording")

    static func run() {
        MainActor.assumeIsolated {
            if requestsAccessOnLaunch(arguments: CommandLine.arguments) {
                // `open -g` starts this diagnostic without bringing it forward.
                // Keep it windowless and accessory-only so the request itself
                // is the only thing a person sees.
                NSApplication.shared.setActivationPolicy(.accessory)
                requestAccessOnLaunch()
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                    NSApplication.shared.terminate(nil)
                }
                NSApplication.shared.run()
                return
            }
            let controller = Controller()
            Self.controller = controller
            NSApplication.shared.setActivationPolicy(.regular)
            controller.show()
            NSApplication.shared.run()
        }
    }

    static func requestsAccessOnLaunch(arguments: [String]) -> Bool {
        arguments.contains("--request-on-launch")
    }

    @MainActor
    private static func requestAccessOnLaunch() {
        let before = CGPreflightScreenCaptureAccess()
        let requested = CGRequestScreenCaptureAccess()
        let after = CGPreflightScreenCaptureAccess()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let record = "\(timestamp) CGPreflightScreenCaptureAccess before=\(before) "
            + "CGRequestScreenCaptureAccess returned=\(requested) "
            + "CGPreflightScreenCaptureAccess after=\(after)"
        logger.notice("\(record, privacy: .public)")
        appendToLog(record)
    }

    private static func appendToLog(_ record: String) {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        let logURL = logsDirectory.appendingPathComponent("ScreenRecordingProbe.log")
        do {
            try FileManager.default.createDirectory(
                at: logsDirectory, withIntermediateDirectories: true)
            let data = Data((record + "\n").utf8)
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: logURL, options: .atomic)
            }
        } catch {
            logger.error(
                "Could not write ScreenRecordingProbe.log: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    private final class Controller: NSObject {
        private let status = NSTextField(labelWithString: "")
        private var window: NSWindow?

        func show() {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 190),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false)
            window.title = "Screen Recording Probe"
            window.isReleasedWhenClosed = false

            let explanation = NSTextField(
                wrappingLabelWithString:
                    "This diagnostic app has one action: request Screen Recording access. "
                    + "It does not capture, discover devices, access the Keychain, or start "
                    + "the camera extension.")
            explanation.maximumNumberOfLines = 0

            status.stringValue = currentStatus()
            status.lineBreakMode = .byWordWrapping
            status.maximumNumberOfLines = 0

            let request = NSButton(
                title: "Request Screen Recording Access",
                target: self,
                action: #selector(requestScreenRecordingAccess))
            request.bezelStyle = .rounded

            let stack = NSStackView(views: [explanation, status, request])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 14
            stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
            window.contentView = stack
            self.window = window
            window.center()
            window.makeKeyAndOrderFront(nil)
        }

        @objc private func requestScreenRecordingAccess() {
            let wasAllowed = CGPreflightScreenCaptureAccess()
            let requested = CGRequestScreenCaptureAccess()
            let isAllowed = CGPreflightScreenCaptureAccess()
            status.stringValue =
                "Before request: \(wasAllowed ? "Allowed" : "Not allowed")\n"
                + "CGRequestScreenCaptureAccess returned: \(requested)\n"
                + "After request: \(isAllowed ? "Allowed" : "Not allowed")"
        }

        private func currentStatus() -> String {
            "Current CGPreflightScreenCaptureAccess: "
                + (CGPreflightScreenCaptureAccess() ? "Allowed" : "Not allowed")
        }
    }
}
