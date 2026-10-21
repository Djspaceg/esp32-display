import Foundation

/// The template behind a panel's screensaver card.
///
/// The panel shows this card whenever no sender is driving it. The firmware used
/// to hardcode three lines - name, address, signal - which was the only thing it
/// could do, since it has no clock, no storage for text, and no idea what the
/// user cares about. The app's default card is now a template instead (see
/// `standard`), so the default and a user's own card go through the same code
/// path and the user can keep, reorder, reword, or drop any part of it.
///
/// Tokens are wrapped in braces - `{name}` - which is the convention most people
/// have already met in other templating systems, and both brace characters are
/// printable ASCII, so an unrecognised token still renders literally on the
/// panel rather than turning into a blank. A literal brace is written `{{`.
///
/// Substitution happens on the Mac, not the panel: the Mac is the only side that
/// knows these values, and the panel stamps arrival time so its card can say how
/// stale the text has become.
public enum ScreensaverTemplate {

    /// A substitutable value, with the wording the settings UI shows for it.
    public struct Token: Identifiable, Hashable, Sendable {
        public let name: String
        public let summary: String
        public let example: String

        public var id: String { name }
        /// How the token is written in a template.
        public var placeholder: String { "{\(name)}" }
    }

    /// Every token a template may use, in the order the UI lists them.
    public static let tokens: [Token] = [
        Token(name: "name", summary: "Device name", example: "blakes-teeny-touch"),
        Token(name: "address", summary: "IP address", example: "192.168.1.69"),
        Token(name: "signal", summary: "Signal strength in words", example: "Good"),
        Token(name: "rssi", summary: "Signal strength in dBm", example: "-59 dBm"),
        Token(name: "version", summary: "Firmware version", example: "1.1.0"),
        Token(name: "uptime", summary: "How long the device has been up", example: "10m"),
    ]

    /// The app's default card. A panel that was never given a template of its
    /// own is given this one when it connects, and the editor shows it in place
    /// of a blank, so "what it shows by default" and "what you can edit" are the
    /// same thing.
    public static let standard = "{name}\n{address}\n{signal} wifi ({rssi})\nup for {uptime}"

    /// What the tokens stand for, for one panel at one moment.
    ///
    /// Every field is a plain string, already formatted, because the panel font
    /// has no notion of anything else. An empty string means "not known yet",
    /// which drops the line if no token on it produced anything.
    public struct Values: Sendable, Equatable {
        public var name: String
        public var address: String
        public var signal: String
        public var rssi: String
        public var version: String
        public var uptime: String

        public init(
            name: String = "",
            address: String = "",
            signal: String = "",
            rssi: String = "",
            version: String = "",
            uptime: String = ""
        ) {
            self.name = name
            self.address = address
            self.signal = signal
            self.rssi = rssi
            self.version = version
            self.uptime = uptime
        }

        /// Stand-in values for previewing a template before a panel has
        /// reported anything.
        public static var example: Values {
            var values = Values()
            for token in tokens {
                values[token.name] = token.example
            }
            return values
        }

        subscript(tokenName: String) -> String? {
            get {
                switch tokenName {
                case "name": return name
                case "address": return address
                case "signal": return signal
                case "rssi": return rssi
                case "version": return version
                case "uptime": return uptime
                default: return nil
                }
            }
            set {
                guard let newValue else { return }
                switch tokenName {
                case "name": name = newValue
                case "address": address = newValue
                case "signal": signal = newValue
                case "rssi": rssi = newValue
                case "version": version = newValue
                case "uptime": uptime = newValue
                default: break
                }
            }
        }
    }

    /// The result of filling in a template.
    public struct Expansion: Equatable, Sendable {
        /// Panel-ready lines: substituted, then reduced to what the firmware
        /// will accept.
        public let lines: [String]
        /// Tokens that matched nothing, in the order first seen and without
        /// duplicates. Surfaced so a typo is reported rather than silently
        /// printed on a panel across the room.
        public let unknownTokens: [String]

        public init(lines: [String], unknownTokens: [String]) {
            self.lines = lines
            self.unknownTokens = unknownTokens
        }
    }

    /// Fill in a template and reduce it to lines the panel can render.
    ///
    /// An unrecognised token is left exactly as written rather than blanked:
    /// blanking it would leave the user staring at a panel with a missing word
    /// and nothing to explain why. A line whose tokens all came out empty is
    /// dropped, words around them included: "wifi ()" with no signal known
    /// says nothing.
    public static func expand(_ template: String, values: Values) -> Expansion {
        var unknown: [String] = []
        var kept: [String] = []
        for line in template.split(
            omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        {
            let result = expandLine(line, values: values, unknown: &unknown)
            if result.tokens > 0 && result.filled == 0 { continue }
            kept.append(result.text)
        }
        return Expansion(
            lines: IdleText.sanitize(kept.joined(separator: "\n")),
            unknownTokens: unknown)
    }

    /// One line of a template, with how many tokens it held and how many of
    /// those produced text. An unknown token counts as filled, since it is
    /// kept as written.
    private static func expandLine(
        _ line: Substring, values: Values, unknown: inout [String]
    ) -> (text: String, tokens: Int, filled: Int) {
        var substituted = ""
        var tokens = 0
        var filled = 0

        var rest = line
        while let open = rest.firstIndex(of: "{") {
            substituted += rest[rest.startIndex..<open]
            let afterOpen = rest.index(after: open)

            // "{{" is an escaped literal brace.
            if afterOpen < rest.endIndex, rest[afterOpen] == "{" {
                substituted += "{"
                rest = rest[rest.index(after: afterOpen)...]
                continue
            }
            // An unclosed brace is literal text, not the start of a token.
            guard let close = rest[afterOpen...].firstIndex(of: "}") else {
                substituted += rest[open...]
                rest = rest[rest.endIndex...]
                break
            }

            let rawName = rest[afterOpen..<close]
            let name = rawName.trimmingCharacters(in: .whitespaces).lowercased()
            tokens += 1
            if let value = values[name] {
                substituted += value
                if !value.isEmpty { filled += 1 }
            } else {
                substituted += "{\(rawName)}"
                filled += 1
                if !unknown.contains(String(rawName)) { unknown.append(String(rawName)) }
            }
            rest = rest[rest.index(after: close)...]
        }
        substituted += rest
        return (substituted, tokens, filled)
    }

    /// Whether a template asks for anything at all. A template of only
    /// whitespace was never really set.
    public static func isEmpty(_ template: String) -> Bool {
        template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The template in effect for a stored one: the stored text, or `standard`
    /// when it is blank.
    public static func effective(_ template: String) -> String {
        isEmpty(template) ? standard : template
    }
}
