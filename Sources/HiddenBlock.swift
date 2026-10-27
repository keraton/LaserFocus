import Foundation

/// Data LaserFocus keeps inside a Markdown file without it being part of the text:
/// HTML comment blocks at the very end of the file, which Markdown viewers don't render.
///
///     <!-- laserfocus:annotations
///     [...]
///     -->
enum HiddenBlock {
    /// Removes the block called `name` from the end of `text`, returning the remaining text
    /// and the block's contents (nil when the file has no such block).
    static func extract(_ name: String, from text: String) -> (body: String, contents: String?) {
        let pattern = "\\n<!-- laserfocus:" + NSRegularExpression.escapedPattern(for: name)
            + "\\n([\\s\\S]*?)\\n-->\\n?\\z"
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return (text, nil)
        }
        return (ns.substring(to: match.range.location), ns.substring(with: match.range(at: 1)))
    }

    /// Appends a block called `name` holding JSON `contents` to the end of `body`.
    static func append(_ name: String, contents: String, to body: String) -> String {
        // "-->" would end the HTML comment early; in JSON it can only appear inside strings.
        let safe = contents.replacingOccurrences(of: "-->", with: "--\\u003e")
        let separator = body.hasSuffix("\n") ? "" : "\n"
        return body + separator + "\n<!-- laserfocus:\(name)\n" + safe + "\n-->\n"
    }
}

extension HiddenBlock {
    /// Encodes `value` as compact JSON, except that the array under `key` gets one element
    /// per line. Two Macs adding to the list then usually merge cleanly in git.
    static func json<T: Encodable, Element: Encodable>(_ value: T, emptied: T, key: String, elements: [Element],
                                                     encoder: JSONEncoder) -> String? {
        guard let shell = try? encoder.encode(emptied), let text = String(data: shell, encoding: .utf8) else { return nil }
        var lines: [String] = []
        for element in elements {
            guard let data = try? encoder.encode(element), let line = String(data: data, encoding: .utf8) else { return nil }
            lines.append(line)
        }
        let empty = "\"\(key)\":[]"
        guard !lines.isEmpty, text.contains(empty) else {
            return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
        }
        return text.replacingOccurrences(of: empty, with: "\n\"\(key)\":[\n" + lines.joined(separator: ",\n") + "\n]\n")
    }
}

/// Counts used by the status line and the writing plan.
enum TextStats {
    static func words(in text: String) -> Int {
        let ns = text as NSString
        var count = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }

    /// Blocks of prose separated by blank lines, ignoring headings and code blocks.
    static func paragraphs(in text: String) -> Int {
        var count = 0
        var inFence = false
        var previousWasProse = false
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                previousWasProse = false
                return
            }
            let isProse = !inFence && !trimmed.isEmpty && !trimmed.hasPrefix("#")
            if isProse && !previousWasProse { count += 1 }
            previousWasProse = isProse
        }
        return count
    }
}
