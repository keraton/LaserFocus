import AppKit

/// NSTextView with inline "ghost" word completion powered by the system spell checker,
/// which knows every language installed on the Mac.
///
/// While typing a word, the most likely completion is drawn faintly after the caret.
/// Tab accepts it, Esc dismisses it. Option-Esc still opens the standard completion list.
final class FocusTextView: NSTextView {
    var autocompleteEnabled = true
    var ghostColor = NSColor.gray

    private var suggestion: String?
    private var suggestionLocation = NSNotFound
    private let languageTagger = NSLinguisticTagger(tagSchemes: [.language], options: 0)

    // MARK: Suggestion lifecycle

    override func didChangeText() {
        super.didChangeText()
        updateSuggestion()
    }

    override func deleteBackward(_ sender: Any?) {
        super.deleteBackward(sender)
        clearSuggestion()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if suggestion != nil && selectedRange() != NSRange(location: suggestionLocation, length: 0) {
            clearSuggestion()
        }
    }

    override func insertTab(_ sender: Any?) {
        if let suffix = suggestion {
            clearSuggestion()
            insertText(suffix, replacementRange: selectedRange())
            clearSuggestion()
        } else {
            super.insertTab(sender)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if suggestion != nil {
            clearSuggestion()
        } else {
            super.cancelOperation(sender)
        }
    }

    func clearSuggestion() {
        guard suggestion != nil else { return }
        suggestion = nil
        suggestionLocation = NSNotFound
        needsDisplay = true
    }

    private func updateSuggestion() {
        suggestion = nil
        suggestionLocation = NSNotFound
        defer { needsDisplay = true }

        guard autocompleteEnabled, !hasMarkedText() else { return }
        let caret = selectedRange()
        guard caret.length == 0 else { return }
        let ns = string as NSString

        // Only suggest when the caret sits at the end of a word.
        if caret.location < ns.length, isWordCharacter(ns.character(at: caret.location)) { return }
        var start = caret.location
        while start > 0, isWordCharacter(ns.character(at: start - 1)) { start -= 1 }
        let wordRange = NSRange(location: start, length: caret.location - start)
        guard wordRange.length >= 2 else { return }

        let checker = NSSpellChecker.shared
        let completions = checker.completions(forPartialWordRange: wordRange,
                                              in: string,
                                              language: language(around: caret.location),
                                              inSpellDocumentWithTag: spellCheckerDocumentTag) ?? []
        let prefix = ns.substring(with: wordRange)
        guard let best = completions.first(where: {
            ($0 as NSString).length > wordRange.length && $0.lowercased().hasPrefix(prefix.lowercased())
        }) else { return }

        var suffix = (best as NSString).substring(from: wordRange.length)
        if prefix == prefix.uppercased() && prefix.count > 1 {
            suffix = suffix.uppercased()
        }
        suggestion = suffix
        suggestionLocation = caret.location
    }

    private func isWordCharacter(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.letters.contains(scalar) || c == 0x27 /* apostrophe */
    }

    /// The language of the paragraph being typed, if the spell checker has a dictionary for it.
    private func language(around location: Int) -> String? {
        let ns = string as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: min(location, ns.length), length: 0))
        guard paragraph.length > 8 else { return nil }
        languageTagger.string = ns.substring(with: paragraph)
        guard let detected = languageTagger.dominantLanguage, detected != "und" else { return nil }
        let available = NSSpellChecker.shared.availableLanguages
        if available.contains(detected) { return detected }
        return available.first { $0.hasPrefix(detected + "_") || $0.hasPrefix(detected + "-") }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let annotate = NSMenuItem(title: "Add Annotation",
                                  action: #selector(DocumentViewController.addAnnotation(_:)), keyEquivalent: "")
        menu.insertItem(annotate, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let suffix = suggestion,
              let layoutManager = layoutManager,
              let container = textContainer,
              suggestionLocation > 0,
              suggestionLocation <= (string as NSString).length else { return }

        let glyph = layoutManager.glyphIndexForCharacter(at: suggestionLocation - 1)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let baseline = lineRect.minY + layoutManager.location(forGlyphAt: glyph).y
        let font = (textStorage?.attribute(.font, at: suggestionLocation - 1, effectiveRange: nil) as? NSFont)
            ?? self.font ?? NSFont.systemFont(ofSize: 16)

        let origin = textContainerOrigin
        // Without .usesLineFragmentOrigin the rect's origin is the baseline, so the ghost lines up exactly.
        let rect = NSRect(x: glyphRect.maxX + origin.x, y: baseline + origin.y, width: 2000, height: font.pointSize * 2)
        (suffix as NSString).draw(with: rect, options: [], attributes: [.font: font, .foregroundColor: ghostColor])
    }
}
