import Foundation

/// Per-device source assignment, loaded from a JSON file mapping device
/// names to what each panel should show:
///
///   {
///     "espdisplay-9050": { "display": "Tiny Monitor" },
///     "espdisplay-abcd": { "window": "Music" }
///   }
///
/// Devices without an entry use automatic source selection (the macOS
/// content picker if the user picked something, else default display
/// tracking). If both keys are present, window wins - it's the more
/// specific intent.
public struct SourceSpec: Codable, Equatable {
    public var display: String?
    public var window: String?

    public init(display: String? = nil, window: String? = nil) {
        self.display = display
        self.window = window
    }
}

public enum DeviceSourceConfig {
    public static func parse(_ data: Data) throws -> [String: SourceSpec] {
        try JSONDecoder().decode([String: SourceSpec].self, from: data)
    }
}
