import Foundation
import SenderProtocol

/// Streaming settings that apply to every panel.
///
/// These were command-line flags only, which made them unreachable in practice:
/// the app normally runs as a LaunchAgent with a fixed argument list, so
/// changing the frame rate meant editing a plist and reloading the agent.
struct SenderSettings: Codable, Equatable {
    /// Capture and send rate. The panel's SPI bus and WiFi link, not the Mac,
    /// set the practical ceiling.
    var fps: Int = 40
    /// Per-chunk pacing sleep in microseconds. Higher means fewer frames
    /// dropped by the device and a lower peak rate.
    var spacingMicros: UInt32 = 200
    /// Let pacing tune itself from the device's reported drop rate.
    var adaptivePacing: Bool = true
    /// How long Identify lights the panel's LED.
    var identifySeconds: Int = 8
    /// When the tile protocol's lossy codec may win (see `TileLossyPolicy`).
    /// Only meaningful for panels advertising tile streaming; band panels
    /// have no lossy codec and ignore it.
    var tileQuality: TileLossyPolicy = .auto

    init(fps: Int = 40, spacingMicros: UInt32 = 200, adaptivePacing: Bool = true,
         identifySeconds: Int = 8, tileQuality: TileLossyPolicy = .auto) {
        self.fps = fps
        self.spacingMicros = spacingMicros
        self.adaptivePacing = adaptivePacing
        self.identifySeconds = identifySeconds
        self.tileQuality = tileQuality
    }

    /// Every field decodes independently with its default as the fallback,
    /// so a settings.json written by an older build (or missing a key by
    /// hand-editing) keeps every field it does have instead of the whole
    /// file failing to decode and silently resetting everything. An
    /// unrecognized tileQuality string also falls back rather than failing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 40
        spacingMicros = try c.decodeIfPresent(UInt32.self, forKey: .spacingMicros) ?? 200
        adaptivePacing = try c.decodeIfPresent(Bool.self, forKey: .adaptivePacing) ?? true
        identifySeconds = try c.decodeIfPresent(Int.self, forKey: .identifySeconds) ?? 8
        let quality = try? c.decodeIfPresent(TileLossyPolicy.self, forKey: .tileQuality)
        tileQuality = quality.flatMap { $0 } ?? .auto
    }

    static let fpsRange = 5...60
    static let spacingRange = FrameSender.spacingRange
    static let identifyRange = DeviceProtocol.identifySecondsRange

    /// Every field forced into range. Applied on load as well as on save, so a
    /// hand-edited file cannot put the sender into a state its own UI could not
    /// have produced.
    var validated: SenderSettings {
        SenderSettings(
            fps: min(max(fps, Self.fpsRange.lowerBound), Self.fpsRange.upperBound),
            spacingMicros: min(
                max(spacingMicros, Self.spacingRange.lowerBound),
                Self.spacingRange.upperBound),
            adaptivePacing: adaptivePacing,
            identifySeconds: min(
                max(identifySeconds, Self.identifyRange.lowerBound),
                Self.identifyRange.upperBound),
            tileQuality: tileQuality)
    }
}

/// Reading and writing the settings file, alongside `PanelStore`.
enum SettingsStore {
    static var defaultURL: URL? {
        PanelStore.defaultURL?
            .deletingLastPathComponent()
            .appendingPathComponent("settings.json")
    }

    /// A missing file is the normal first-run case and reports no failure.
    static func load(from url: URL?) -> (settings: SenderSettings, failure: String?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return (SenderSettings(), nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder.espDisplay.decode(SenderSettings.self, from: data)
            return (decoded.validated, nil)
        } catch {
            return (SenderSettings(), error.localizedDescription)
        }
    }

    static func save(_ settings: SenderSettings, to url: URL) throws {
        let data = try JSONEncoder.espDisplay.encode(settings.validated)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
