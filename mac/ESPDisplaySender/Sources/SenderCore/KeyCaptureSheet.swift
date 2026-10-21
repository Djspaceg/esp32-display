import AppKit
import SenderProtocol
import SwiftUI

/// Which input the key-capture sheet is recording a combination for.
struct KeyCaptureRequest: Identifiable {
    let input: DeviceProtocol.TouchGesture
    let inputLabel: String
    var id: UInt8 { input.rawValue }
}

/// Records one key combination for a custom key-press assignment.
///
/// While it is up, every key-down in this app is taken as the combination
/// rather than acted on - Return, Escape and Command-key shortcuts included,
/// since any of them may be what the user wants a button to press - so it is
/// closed with its buttons. The latest combination pressed is the one saved.
struct KeyCaptureSheet: View {
    let request: KeyCaptureRequest
    let onSave: (KeyCombo) -> Void
    let onCancel: () -> Void

    @State private var combo: KeyCombo?
    @State private var problem: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Record a Key Combination")
                .font(.headline)
            Text("Press the keys this Mac should press when you "
                + "\(request.inputLabel.prefix(1).lowercased() + request.inputLabel.dropFirst()). "
                + "Command, Option, Control and Shift are recorded with the key.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(combo?.label ?? "Waiting for keys\u{2026}")
                .font(.title2.monospaced())
                .foregroundStyle(combo == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .glassCard(cornerRadius: 8)
                .accessibilityLabel(combo.map { "Recorded \($0.label)" } ?? "No keys recorded yet")
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("Pressing it from the device needs Accessibility permission, "
                + "like the media keys.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    if let combo { onSave(combo) }
                }
                .disabled(combo == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear(perform: startRecording)
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            record(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func record(_ event: NSEvent) {
        guard let recorded = KeyCombo.recorded(
            keyCode: event.keyCode, modifiers: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers)
        else {
            problem = "A modifier key on its own cannot be recorded; press it "
                + "together with another key."
            return
        }
        problem = nil
        combo = recorded
    }
}
