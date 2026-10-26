import AppKit

/// Applies live Markdown highlighting (and optional grammar colors) to a text storage.
/// Only attributes are changed, never characters, so the file on disk stays plain Markdown.
final class MarkdownStyler {
    private let grammar = GrammarTagger()

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are constant, so a failure here is a programming error.
        return try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private let fenceRegex = regex("^[ \\t]*(```|~~~).*$")
    private let headingRegex = regex("^(#{1,6})[ \\t]+.*$")
    private let quoteRegex = regex("^[ \\t]*>.*$")
    private let listRegex = regex("^[ \\t]*([-*+]|\\d+[.)])[ \\t]+")
    private let ruleRegex = regex("^[ \\t]*([-*_])([ \\t]*\\1){2,}[ \\t]*$")
    private let boldRegex = regex("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private let italicRegex = regex("(?<![*_\\w])([*_])(?=[^\\s*_])(.+?)(?<=[^\\s*_])\\1(?![*_\\w])")
    private let strikeRegex = regex("~~(?=\\S)(.+?)(?<=\\S)~~")
    private let codeRegex = regex("(`+)(?!`)(.+?)(?<!`)\\1(?!`)")
    private let linkRegex = regex("!?\\[([^\\]\\n]+)\\]\\(([^)\\n]+)\\)")

    func style(_ storage: NSTextStorage, range requested: NSRange, settings: Settings) {
        let string = storage.string
        let ns = string as NSString
        guard ns.length > 0 else { return }
        let range = ns.paragraphRange(for: NSIntersectionRange(requested, NSRange(location: 0, length: ns.length)))
        let palette = settings.palette
        let font = settings.baseFont()
        let mono = settings.monoFont(size: font.pointSize * 0.9)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.35
        paragraph.paragraphSpacing = font.pointSize * 0.4

        storage.setAttributes([
            .font: font,
            .foregroundColor: palette.text,
            .paragraphStyle: paragraph,
        ], range: range)

        let fences = fencedBlocks(in: string)

        if settings.grammarColors {
            for (tokenRange, role) in grammar.roles(in: string, range: range) {
                storage.addAttribute(.foregroundColor, value: color(for: role, palette: palette), range: tokenRange)
            }
        }

        // Block-level rules, line by line.
        headingRegex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let m = match, !self.isInside(m.range, fences) else { return }
            let level = m.range(at: 1).length
            let scale: [CGFloat] = [1.7, 1.45, 1.25, 1.12, 1.05, 1.0]
            let headingFont = NSFontManager.shared.convert(
                NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale[level - 1]) ?? font,
                toHaveTrait: .boldFontMask)
            storage.addAttribute(.font, value: headingFont, range: m.range)
            storage.addAttribute(.foregroundColor, value: palette.muted, range: m.range(at: 1))
        }

        quoteRegex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let m = match, !self.isInside(m.range, fences) else { return }
            self.addTrait(.italicFontMask, to: storage, range: m.range)
            storage.addAttribute(.foregroundColor, value: palette.muted, range: m.range)
        }

        listRegex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let m = match, !self.isInside(m.range, fences) else { return }
            storage.addAttribute(.foregroundColor, value: palette.accent, range: m.range(at: 1))
        }

        ruleRegex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let m = match, !self.isInside(m.range, fences) else { return }
            storage.addAttribute(.foregroundColor, value: palette.muted, range: m.range)
        }

        // Inline rules.
        boldRegex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let m = match, !self.isInside(m.range, fences) else { return }
            self.addTrait(.boldFontMask, to: storage, range: m.range)
            self.muteMarkers(m, inner: m.range(at: 2), storage: storage, palette: palette)
        }

        italicRegex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let m = match, !self.isInside(m.range, fences) else { return }
            self.addTrait(.italicFontMask, to: storage, range: m.range)
            self.muteMarkers(m, inner: m.range(at: 2), storage: storage, palette: palette)
        }

        strikeRegex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let m = match, !self.isInside(m.range, fences) else { return }
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            self.muteMarkers(m, inner: m.range(at: 1), storage: storage, palette: palette)
        }

        linkRegex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let m = match, !self.isInside(m.range, fences) else { return }
            storage.addAttribute(.foregroundColor, value: palette.muted, range: m.range)
            storage.addAttribute(.foregroundColor, value: palette.accent, range: m.range(at: 1))
        }

        codeRegex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let m = match, !self.isInside(m.range, fences) else { return }
            storage.addAttributes([
                .font: mono,
                .foregroundColor: palette.text,
                .backgroundColor: palette.codeBackground,
            ], range: m.range)
            self.muteMarkers(m, inner: m.range(at: 2), storage: storage, palette: palette)
        }

        for block in fences {
            let overlap = NSIntersectionRange(block, range)
            guard overlap.length > 0 else { continue }
            storage.addAttributes([
                .font: mono,
                .foregroundColor: palette.text,
                .backgroundColor: palette.codeBackground,
            ], range: overlap)
        }
    }

    /// Ranges of ``` / ~~~ fenced code blocks, including the fence lines. Always scans the
    /// whole document because a fence opened far above can affect the edited paragraph.
    func fencedBlocks(in string: String) -> [NSRange] {
        let ns = string as NSString
        var blocks: [NSRange] = []
        var openStart: Int?
        fenceRegex.enumerateMatches(in: string, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match else { return }
            if let start = openStart {
                let end = NSMaxRange(ns.lineRange(for: m.range))
                blocks.append(NSRange(location: start, length: end - start))
                openStart = nil
            } else {
                openStart = m.range.location
            }
        }
        if let start = openStart {
            blocks.append(NSRange(location: start, length: ns.length - start))
        }
        return blocks
    }

    private func isInside(_ range: NSRange, _ blocks: [NSRange]) -> Bool {
        blocks.contains { NSIntersectionRange($0, range).length > 0 }
    }

    private func muteMarkers(_ m: NSTextCheckingResult, inner: NSRange, storage: NSTextStorage, palette: Palette) {
        let leading = NSRange(location: m.range.location, length: inner.location - m.range.location)
        let trailing = NSRange(location: NSMaxRange(inner), length: NSMaxRange(m.range) - NSMaxRange(inner))
        storage.addAttribute(.foregroundColor, value: palette.muted, range: leading)
        storage.addAttribute(.foregroundColor, value: palette.muted, range: trailing)
    }

    private func addTrait(_ trait: NSFontTraitMask, to storage: NSTextStorage, range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            guard let font = value as? NSFont else { return }
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: sub)
        }
    }

    private func color(for role: GrammarRole, palette: Palette) -> NSColor {
        switch role {
        case .subject: return palette.subject
        case .predicate: return palette.predicate
        case .object: return palette.object
        case .modifier: return palette.modifier
        }
    }
}
