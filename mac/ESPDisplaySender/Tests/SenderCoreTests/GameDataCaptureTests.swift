import AppKit
import SenderProtocol
import SwiftUI
import XCTest

@testable import SenderCore

/// Renders the Game data sheet when ESPDISP_UX_CAPTURE_DIR is set: a P4 before
/// its board is read, the same P4 after, with Quake's pak and two WADs, and an
/// S3 whose selection does not fit. The sheet does no USB I/O until Check
/// Board or Write is pressed, so nothing here lists, probes or opens a serial
/// port, and no cache is read.
@MainActor
final class GameDataCaptureTests: XCTestCase {
    func testCaptureGameDataSheetWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["ESPDISP_UX_CAPTURE_DIR"]
        else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let manager = PanelManager(previewPanels: [], savedNetworkNames: [], usbSerialPorts: [])

        func target(_ name: String, chip: String, path: String) -> PanelManager.FirmwareUpdateTarget {
            PanelManager.FirmwareUpdateTarget(
                serviceName: name, displayName: name, hardwareID: "7C:0C:5F:42:39:A4",
                address: nil, chip: chip, firmwareVersion: "2.0.0",
                usbDevice: WifiConfigUI.USBDeviceOption(path: path, isConnected: true),
                usbPathGeneration: 1)
        }
        func identified(
            _ kind: GameStore.Kind, _ name: String, _ bytes: Int, _ sha: String, _ summary: String
        ) -> GameData.Identified {
            GameData.Identified(
                kind: kind, slot: GameData.pakSlot(name) ?? 0, storedName: name,
                byteCount: bytes, sha256: sha, summary: summary)
        }
        let pak = identified(.quakePak, "pak0.pak", QuakePak.sharewareBytes,
                             QuakePak.sharewareSHA256, "Quake shareware pak0.pak")
        let mini = identified(.doomWad, "miniwad.wad", 74_210, String(repeating: "1", count: 64),
                              "IWAD, 312 lumps, Doom II maps")
        let chex = identified(.doomWad, "chex.wad", 12_361_532, String(repeating: "2", count: 64),
                              "IWAD, 1,912 lumps, Doom maps")

        let p4 = target("white-flat-square-4b", chip: "esp32p4", path: "/dev/cu.usbmodem5B901669681")
        var fresh = GameDataSelection(quakeOffered: true)
        fresh.add(pak, source: .cache(URL(fileURLWithPath: "/cache/quake/pak0.pak")))
        fresh.setGameChecked(.quakePak, true)
        try capture(
            GameDataSheet(manager: manager, target: p4, quakeOffered: true, cache: nil,
                          selection: fresh),
            to: output, name: "game-data-p4-not-read")

        var chosen = fresh
        chosen.add(mini, source: .chosen(URL(fileURLWithPath: "/Users/me/Downloads/miniwad.wad")))
        let area = GameStore.Area(
            address: 0xE00000, byteCount: 0x1200000, description: "the quake_pak partition")
        let board = GameStore.Contents.directory(GameStore.Directory(
            areaBytes: area.byteCount, generation: 3,
            entries: [GameStore.Entry(kind: .quakePak, offset: 0, length: pak.byteCount,
                                      name: "pak0.pak", sha256: pak.sha256)]))
        try capture(
            GameDataSheet(manager: manager, target: p4, quakeOffered: true, cache: nil,
                          selection: chosen, board: (area, board)),
            to: output, name: "game-data-p4-read")

        let s3 = target("silver-round", chip: "esp32s3", path: "/dev/cu.usbmodem1312101")
        var tooMuch = GameDataSelection(quakeOffered: true)
        tooMuch.add(pak, source: .cache(URL(fileURLWithPath: "/cache/quake/pak0.pak")))
        tooMuch.add(chex, source: .chosen(URL(fileURLWithPath: "/Users/me/Games/chex.wad")))
        let s3Area = GameStore.Area(
            address: 0x800000, byteCount: 0x1200000,
            description: "the flash past the firmware's 8 MiB")
        try capture(
            GameDataSheet(manager: manager, target: s3, quakeOffered: true, cache: nil,
                          selection: tooMuch,
                          board: (s3Area, .legacy(legacyPak0Bytes: nil))),
            to: output, name: "game-data-s3-does-not-fit")
    }

    private func capture<V: View>(_ view: V, to directory: URL, name: String) throws {
        let size = NSSize(width: 560, height: 760)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        host.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        window.close()
    }
}
