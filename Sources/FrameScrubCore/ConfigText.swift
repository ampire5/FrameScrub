import Foundation

/// Index of the `#` that starts a comment: at line start or after whitespace (so `C#` in a path is kept).
func commentStart(in line: String) -> String.Index? {
    var previous: Character?
    for i in line.indices {
        if line[i] == "#", previous?.isWhitespace ?? true { return i }
        previous = line[i]
    }
    return nil
}

/// Shortest text for a number: `100`, `0.3`, `2.5`.
func formatNumber(_ value: Double) -> String {
    value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
}

/// Edits framescrub.conf / input.conf text in place: the user's comments, blank lines, order and
/// unknown lines are kept; only the lines for the given keys (or key chords) change.
public enum ConfigText {
    public static let header = "# FrameScrub settings. Preferences edits values in place and keeps your comments."

    /// For each pair, rewrites the first active `key=value` line with that key (an inline comment is
    /// kept) or appends the line if the key has none. Commented-out lines never count.
    public static func setting(_ values: [(key: String, value: String)], in text: String) -> String {
        var lines = text.isEmpty ? [header, ""] : text.components(separatedBy: "\n")
        for (key, value) in values {
            let line = "\(key)=\(value)"
            if let i = lines.firstIndex(where: { configKey(of: $0) == key }) {
                lines[i] = line + trailingComment(of: lines[i])
            } else {
                append(line, to: &lines)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Rewrites the first active line bound to each chord (inline comment kept) or appends it.
    public static func settingBindings(_ bindings: [(chord: KeyChord, command: String)], in text: String) -> String {
        var lines = text.isEmpty ? [""] : text.components(separatedBy: "\n")
        for (chord, command) in bindings {
            let line = "\(chord) \(command)"
            if let i = lines.firstIndex(where: { boundChord(of: $0) == chord }) {
                lines[i] = line + trailingComment(of: lines[i])
            } else {
                append(line, to: &lines)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Removes every active line bound to one of `chords`.
    public static func removingBindings(for chords: Set<KeyChord>, in text: String) -> String {
        removingBindings(where: { chords.contains($0) }, in: text)
    }

    /// Removes every active line whose chord satisfies `matches` (Preferences → Reset to defaults).
    public static func removingBindings(where matches: (KeyChord) -> Bool, in text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { line in boundChord(of: line).map { !matches($0) } ?? true }
            .joined(separator: "\n")
    }

    static func containsKey(_ key: String, in text: String) -> Bool {
        text.components(separatedBy: "\n").contains { configKey(of: $0) == key }
    }

    private static func configKey(of line: String) -> String? {
        let content = stripComment(line)
        guard let equals = content.firstIndex(of: "=") else { return nil }
        return content[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func boundChord(of line: String) -> KeyChord? {
        let content = stripComment(line)
        guard let first = content.split(whereSeparator: \.isWhitespace).first else { return nil }
        return KeyChord.parse(String(first))
    }

    private static func trailingComment(of line: String) -> String {
        commentStart(in: line).map { " " + String(line[$0...]) } ?? ""
    }

    /// Appends before the final empty element so a trailing newline stays the last character.
    private static func append(_ line: String, to lines: inout [String]) {
        if lines.last == "" { lines.insert(line, at: lines.count - 1) } else { lines.append(line) }
    }
}
