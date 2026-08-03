import Foundation

/// Lines the panel shows on its status card while no sender is driving it.
///
/// Without this a panel that loses its sender shows only its own name, IP, and
/// signal strength, which tells the user nothing they wanted to know. The panel
/// has no clock and no network of its own, so it cannot fetch anything: the text
/// has to be pushed to it, and the panel stamps its arrival so the card can say
/// how stale it has become.
public enum IdleText {
    public static let version: UInt8 = 1
    public static let maxLines = 4
    /// What fits the 172px-wide portrait panel at the smaller text scale.
    public static let maxLineBytes = 28
    public static let headerBytes = 8

    /// Reduce free-form input to what the panel can actually render.
    ///
    /// The font is a 5x7 ASCII bitmap and the firmware refuses anything outside
    /// printable ASCII, so unrepresentable characters are dropped here rather
    /// than sent and rejected. Empty lines are dropped too: on a four-line
    /// budget a blank line is a wasted one.
    public static func sanitize(_ raw: String) -> [String] {
        let lines = raw.split(whereSeparator: \.isNewline)
            .map(sanitizeLine)
            .filter { !$0.isEmpty }
        return Array(lines.prefix(maxLines))
    }

    private static func sanitizeLine(_ line: some StringProtocol) -> String {
        var out = ""
        for scalar in line.unicodeScalars where (0x20...0x7E).contains(scalar.value) {
            out.unicodeScalars.append(scalar)
            if out.utf8.count == maxLineBytes { break }
        }
        // Leading and trailing spaces are invisible on the panel but still cost
        // characters from the line budget.
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Encode an ETXT packet: ["ETXT"][version][lineCount][reserved x2] then
    /// per line [length][bytes]. An empty array is a valid packet and clears
    /// whatever the panel was showing.
    ///
    /// Returns nil if the lines are not already sanitized, so a caller cannot
    /// send something the firmware will silently discard.
    public static func packet(lines: [String]) -> Data? {
        guard lines.count <= maxLines else { return nil }
        var packet = Data("ETXT".utf8)
        packet.append(version)
        packet.append(UInt8(lines.count))
        packet.append(0)
        packet.append(0)
        for line in lines {
            let bytes = Array(line.utf8)
            guard bytes.count <= maxLineBytes,
                  bytes.allSatisfy({ (0x20...0x7E).contains($0) })
            else { return nil }
            packet.append(UInt8(bytes.count))
            packet.append(contentsOf: bytes)
        }
        return packet
    }
}
