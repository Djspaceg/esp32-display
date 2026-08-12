import Foundation

/// Reading what esptool says, as pure functions over its output.
///
/// The parses here are written to agree with `probe_chip()` in tools/espdisp.py,
/// because the two answer the same question about the same program and a
/// disagreement would mean the CLI and the app choose different firmware for one
/// board.
public enum EsptoolOutput {

    // MARK: - which chip

    /// The IDF chip token esptool reported, e.g. `esp32s3`, or nil if it did not
    /// say.
    ///
    /// BOTH SPELLINGS, and only one of them is live. Measured against the
    /// attached board with esptool 5.3.1, the output was, verbatim:
    ///
    ///     Detecting chip type... ESP32-S3
    ///     Connected to ESP32-S3 on /dev/cu.usbmodem1101:
    ///     Chip type:          ESP32-S3 (QFN56) (revision v0.2)
    ///
    /// so `Detecting chip type...` is what 5.x prints and what this matches on.
    /// `Chip is ESP32-S3` is esptool 4.x's spelling; it appears nowhere in 5.3.1's
    /// output and is kept only because a 4.x esptool.py is still locatable.
    /// UNVERIFIED for 4.x: none is installed here.
    ///
    /// The token is returned as parsed rather than checked against a list of
    /// chips this app knows. Whether an image exists for it is the bundle's
    /// question, and a bundle built for a chip added after this code was written
    /// should still work.
    public static func chipToken(in output: String) -> String? {
        let pattern = "(?:Chip is|Detecting chip type\\.\\.\\.)[ \t]*(ESP32[\\w-]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let tokenRange = Range(match.range(at: 1), in: output)
        else { return nil }
        // Lowercase, then drop everything that is not a letter or a digit, which
        // is how `probe_chip` turns "ESP32-S3" into "esp32s3".
        let token = String(output[tokenRange]).lowercased().filter {
            $0.isASCII && ($0.isLetter || $0.isNumber)
        }
        return token.isEmpty ? nil : token
    }

    /// The MAC esptool printed, in its own `28:84:85:55:55:94` spelling, or nil.
    ///
    /// THE ONLY STABLE IDENTITY A BOARD HAS ON THIS PATH. The tty path is not one:
    /// the same physical board was observed here at /dev/cu.usbmodem1101 and,
    /// after esptool's hard resets, at /dev/cu.usbmodem101. And the ESP32-S3 has
    /// no chip id at all - `chip-id` answers "Warning: ESP32-S3 has no chip ID.
    /// Reading MAC address instead." - so the MAC is what is left.
    ///
    /// Used to tell the user which board was written, not to key anything
    /// persisted: a panel becomes a sidebar entry through discovery, which knows
    /// it by its Bonjour service name.
    public static func macAddress(in output: String) -> String? {
        let pattern = "MAC:[ \t]*((?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let macRange = Range(match.range(at: 1), in: output)
        else { return nil }
        return String(output[macRange]).lowercased()
    }

    // MARK: - progress

    /// A percentage esptool put in a line, 0...100, or nil.
    ///
    /// DELIBERATELY LOOSE, and the reason is that the exact spelling could not be
    /// settled here. esptool 4.x printed `Writing at 0x00010000... (12 %)`; what
    /// 5.3.1 prints while writing has not been observed, and neither of the two
    /// ways of finding out was available: no board is attached to run a write
    /// against, and the 5.3.1 binary is packed (338 readable strings, none of them
    /// containing "esptool"), so the format string cannot be read off disk
    /// either. UNVERIFIED.
    ///
    /// So this looks for a number followed by `%` anywhere in the line, and the
    /// progress UI shows esptool's own last line beside it. If the percentage is
    /// never found the transfer still reports what the tool is saying, which is
    /// the behaviour that does not depend on this guess being right.
    public static func percentage(in line: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "(\\d{1,3})[ \t]*%")
        else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        // The LAST percentage on the line, so a line that names a total and then a
        // position reports the position.
        let matches = regex.matches(in: line, range: range)
        guard let match = matches.last,
              let numberRange = Range(match.range(at: 1), in: line),
              let value = Int(line[numberRange]), (0...100).contains(value)
        else { return nil }
        return value
    }

    /// Whether a line is worth showing as status: esptool prints blank lines and
    /// bare progress redraws, and an empty status area flickering is worse than a
    /// stale one.
    public static func isStatusWorthy(_ line: String) -> Bool {
        !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - what went wrong

    /// The one line of a failed run worth putting in front of a person.
    ///
    /// esptool says what went wrong in a line beginning `A fatal error occurred:`
    /// and then follows it with a `Hint:` and sometimes a stack of parenthesised
    /// detail. Measured, from a probe of a port that was not there:
    ///
    ///     A fatal error occurred: Could not open /dev/cu.usbmodem101, the port
    ///     is busy or doesn't exist.
    ///
    /// That line is preferred when present, because the last line of a failed run
    /// is often the hint rather than the cause. Falling back to the last non-empty
    /// line covers a failure that does not use the phrase at all, and an empty
    /// transcript - a tool that printed nothing - gets nil rather than an empty
    /// string masquerading as a reason.
    ///
    /// Split with `splitLines` rather than with `String.split`, which would compare
    /// Characters and therefore not see the "\r" in a "\r\n" - the bug described
    /// there. One splitter, one behaviour.
    public static func failureSummary(in output: String) -> String? {
        let split = splitLines(output)
        let lines = (split.lines + [split.remainder])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        if let fatal = lines.last(where: { $0.hasPrefix("A fatal error occurred:") }) {
            return fatal
        }
        return lines.last
    }

    // MARK: - line splitting

    /// Split a chunk of streamed output into complete lines plus the remainder.
    ///
    /// BOTH TERMINATORS. Progress redraws in place with a carriage return and no
    /// newline, so a reader that split on `\n` alone would show nothing at all
    /// until a transfer finished and then show one enormous line. `\r\n` counts
    /// once.
    ///
    /// The remainder is returned rather than buffered internally so this stays a
    /// function of its arguments; the runner owns the buffer.
    ///
    /// SCALARS, NOT CHARACTERS, and this is not a style preference - it was a bug,
    /// caught by `testCRLFCountsOnce`. Swift's `Character` is a grapheme cluster and
    /// "\r\n" is ONE of them, equal to neither "\r" nor "\n", so a scan comparing
    /// Characters against both terminators silently matched neither and returned a
    /// whole transcript as one unterminated line. Comparing scalars sees the two
    /// code points that are actually there.
    ///
    /// One known imprecision, left as it is: if a chunk ends with "\r" and the next
    /// one begins with "\n", that pair is read as two breaks rather than one and an
    /// empty line appears between them. `isStatusWorthy` drops it, and holding a
    /// trailing "\r" back would mean a progress redraw was never shown until the
    /// following one arrived.
    public static func splitLines(_ chunk: String) -> (lines: [String], remainder: String) {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        let scalars = chunk.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            index = scalars.index(after: index)
            if scalar == "\n" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
            } else if scalar == "\r" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
                if index < scalars.endIndex, scalars[index] == "\n" {
                    index = scalars.index(after: index)
                }
            } else {
                current.append(scalar)
            }
        }
        return (lines, String(current))
    }
}
