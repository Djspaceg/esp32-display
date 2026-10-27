import AppKit
import SenderProtocol
import SwiftUI

/// The sidebar's Mac screens: devices in use first, then screens that could be.
struct ScreenDeviceSidebarSection: View {
    @ObservedObject var controller: ScreenDeviceController
    /// Screens the boards capture from, passed in so the list follows them.
    let capturingFrom: Set<String>

    var body: some View {
        let entries = controller.entries(capturingFrom: capturingFrom)
        if !entries.isEmpty {
            Section {
                ForEach(entries) { entry in
                    ScreenDeviceRow(entry: entry, status: controller.status(entry.key))
                        .tag(entry.id)
                        .contextMenu {
                            if entry.inUse {
                                Button(entry.record?.paused == true ? "Resume" : "Pause") {
                                    controller.setPaused(
                                        !(entry.record?.paused ?? false), for: entry.key)
                                }
                                Button("Stop Using as a Device") {
                                    controller.stopUsing(entry.key)
                                }
                            } else {
                                Button("Use as a Device") { controller.use(entry.key) }
                                    .disabled(entry.screen == nil)
                            }
                        }
                }
            } header: {
                Text("Mac screens")
            }
        }
    }
}

struct ScreenDeviceRow: View {
    let entry: ScreenDeviceEntry
    let status: ScreenDeviceStatus

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("\(entry.sizeDescription) · \(status.shortText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if status.needsAttention {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Has a problem")
            }
            if status == .paused {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Paused")
            }
        }
        .padding(.vertical, 3)
    }

    private var dotColor: Color {
        switch status {
        case .showing: return .green
        case .notInUse: return .secondary
        case .unplugged, .problem, .starting, .paused: return .orange
        }
    }
}

/// A Mac screen's page: whether it is used as a device, and the same source
/// controls a board has (region, orientation, pause).
struct ScreenDeviceDetailView: View {
    @ObservedObject var controller: ScreenDeviceController
    let key: String
    let capturingFrom: Set<String>

    var body: some View {
        if let entry = controller.entry(key, capturingFrom: capturingFrom) {
            form(entry)
        } else {
            ContentUnavailableView {
                Label("Screen Not Available", systemImage: "rectangle.on.rectangle.slash")
            } description: {
                Text("This screen is no longer connected, carries the menu bar, or a "
                    + "board or a device's region now captures from it.")
            }
        }
    }

    private func form(_ entry: ScreenDeviceEntry) -> some View {
        let status = controller.status(key)
        return Form {
            Section {
                LabeledContent("Screen", value: entry.label)
                LabeledContent("Status") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(status.text)
                            .foregroundStyle(status.needsAttention ? .orange : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("screen-device-status")
                        if status.needsAttention {
                            Button("Copy Message") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(status.text, forType: .string)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                if let screen = entry.screen {
                    LabeledContent("Refresh", value: "Up to \(screen.maximumFPS) fps")
                }
                LabeledContent("Identity", value: identityDescription(entry))
                Toggle("Use as a device", isOn: Binding(
                    get: { entry.inUse },
                    set: { $0 ? controller.use(key) : controller.stopUsing(key) }))
                    .toggleStyle(.switch)
                    .disabled(!entry.inUse && entry.screen == nil)
                    .accessibilityIdentifier("screen-device-use")
            } header: {
                Text("Device")
            } footer: {
                Text("While in use, this screen is covered edge to edge with the chosen "
                    + "region, at its own resolution and refresh rate. The pointer is "
                    + "hidden over it and it never takes focus. It is recognised by its "
                    + "own identity, so it is covered again whenever it is plugged back in. "
                    + "Turn this off to give the screen back.")
            }
            if let record = entry.record {
                sourceSection(record)
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
        .labeledContentStyle(.labelColumn)
        .navigationSubtitle(status.shortText)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let record = entry.record {
                    Button(record.paused ? "Resume" : "Pause") {
                        controller.setPaused(!record.paused, for: key)
                    }
                    .padding(.horizontal, 6)
                    .help(record.paused ? "Resume drawing the region" : "Hold the last picture")
                }
            }
        }
    }

    private func sourceSection(_ record: ScreenDeviceRecord) -> some View {
        Section {
            LabeledContent("Region") {
                HStack(spacing: 8) {
                    Button(controller.choosingRegionFor == key && controller.isChoosingRegion
                        ? "Done" : "Adjust…")
                    {
                        if controller.choosingRegionFor == key && controller.isChoosingRegion {
                            controller.finishChoosingRegion()
                        } else {
                            controller.chooseRegion(for: key)
                        }
                    }
                    .help("Drag an aspect-locked rectangle over another screen to choose "
                        + "what this device shows")
                    if let region = record.region {
                        Text("\(region.sizeDescription) on \(region.display)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            LabeledContent("Orientation") {
                Picker("Orientation", selection: Binding(
                    get: { record.rotation },
                    set: { controller.setRotation($0, for: key) })) {
                    Text("0°").tag(0)
                    Text("90°").tag(1)
                    Text("180°").tag(2)
                    Text("270°").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Turn the picture clockwise to match how the screen is mounted")
            }
            LabeledContent("Streaming") {
                Button(record.paused ? "Resume" : "Pause") {
                    controller.setPaused(!record.paused, for: key)
                }
            }
        } header: {
            Text("Source")
        } footer: {
            Text("The region is scaled to fit the screen with its shape kept, and black "
                + "fills the rest. On a rectangular screen 90° and 270° turn the region on "
                + "its side too, so the picture fills the screen mounted that way. Pause "
                + "holds the last picture.")
        }
    }

    private func identityDescription(_ entry: ScreenDeviceEntry) -> String {
        let identity = entry.record?.identity ?? entry.screen?.identity
        guard let identity else { return "Unknown" }
        var parts = [
            String(format: "vendor %04x", identity.vendor),
            String(format: "model %04x", identity.model),
        ]
        parts.append(identity.serial != 0
            ? String(format: "serial %08x", identity.serial) : "no serial")
        if identity.serial == 0, let uuid = identity.uuid { parts.append(uuid) }
        return parts.joined(separator: ", ")
    }
}
