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
/// tracking). When more than one key is present the most specific intent wins:
/// region, then window, then display.
///
/// Every field is optional, so a file written before any given field existed
/// still decodes, and a nil field is omitted on the way back out.
public struct SourceSpec: Codable, Equatable {
    public var display: String?
    public var window: String?
    /// A rectangle of one display, drawn with the region selector.
    public var region: RegionSpec?

    public init(
        display: String? = nil, window: String? = nil, region: RegionSpec? = nil
    ) {
        self.display = display
        self.window = window
        self.region = region
    }
}

public enum DeviceSourceConfig {
    public static func parse(_ data: Data) throws -> [String: SourceSpec] {
        try JSONDecoder().decode([String: SourceSpec].self, from: data)
    }
}
