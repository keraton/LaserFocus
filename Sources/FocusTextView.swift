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
    private var dictionaryObserver: NSObjectProtocol?

    deinit {
        if let observer = dictionaryObserver { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard dictionaryObserver == nil else { return }
        dictionaryObserver = NotificationCenter.default.addObserver(
            forName: .customDictionaryChanged, object: nil, queue: .main) { [weak self] _ in self?.recheckSpelling() }
    }

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
        let detected = detectedLanguage(around: caret.location)
        let language = spellingLanguage(for: detected)
        // Without an Indonesian dictionary the system would complete Indonesian in English.
        var completions = detected == "id" && language == nil ? [] :
            checker.completions(forPartialWordRange: wordRange,
                                in: string,
                                language: language,
                                inSpellDocumentWithTag: spellCheckerDocumentTag) ?? []
        let prefix = ns.substring(with: wordRange)
        if detected == "id" && wordRange.length >= 3 {
            // The bundled list is alphabetical, so offer its shortest word after the system's picks.
            // Hyphenated forms (pendidik-ku) are only offered once the writer types a hyphen.
            let bundled = IndonesianLexicon.shared.completions(of: prefix, limit: 500)
                .filter { prefix.contains("-") || !$0.contains("-") }
            completions += bundled.sorted { $0.count < $1.count }
        }
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

    /// The language of the paragraph being typed.
    private func detectedLanguage(around location: Int) -> String? {
        let ns = string as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: min(location, ns.length), length: 0))
        guard paragraph.length > 8 else { return nil }
        return LanguageDetector.language(of: ns.substring(with: paragraph))
    }

    /// The spell checker's name for a language, if it has a dictionary for it.
    private func spellingLanguage(for detected: String?) -> String? {
        guard let detected = detected else { return nil }
        let available = NSSpellChecker.shared.availableLanguages
        if available.contains(detected) { return detected }
        return available.first { $0.hasPrefix(detected + "_") || $0.hasPrefix(detected + "-") }
    }

    // MARK: Spelling

    /// Indonesian paragraphs get their spelling marks from ``IndonesianSpellChecker``.
    override func handleTextCheckingResults(_ results: [NSTextCheckingResult], forRange range: NSRange,
                                            types checkingTypes: NSTextCheckingTypes,
                                            options: [NSSpellChecker.OptionKey: Any] = [:],
                                            orthography: NSOrthography, wordCount: Int) {
        var results = results
        if checkingTypes & NSTextCheckingResult.CheckingType.spelling.rawValue != 0 {
            let caret = selectedRange()
            results = IndonesianSpellChecker.shared.adjust(results, in: string, range: range,
                                                           documentTag: spellCheckerDocumentTag,
                                                           skipping: caret.length == 0 ? caret : nil)
        }
        super.handleTextCheckingResults(results, forRange: range, types: checkingTypes, options: options,
                                        orthography: orthography, wordCount: wordCount)
    }

    /// Re-marks misspellings everywhere, e.g. after a word was added to the dictionary.
    func recheckSpelling() {
        guard isContinuousSpellCheckingEnabled else { return }
        let all = NSRange(location: 0, length: (string as NSString).length)
        layoutManager?.removeTemporaryAttribute(.spellingState, forCharacterRange: all)
        checkText(in: all, types: NSTextCheckingResult.CheckingType.spelling.rawValue, options: [:])
    }

    /// The word at a character index, if it's marked as misspelled.
    private func misspelledWord(at index: Int) -> NSRange? {
        let ns = string as NSString
        guard index < ns.length, let layoutManager = layoutManager else { return nil }
        var marked = NSRange(location: 0, length: 0)
        guard layoutManager.temporaryAttribute(.spellingState, atCharacterIndex: index,
                                               effectiveRange: &marked) != nil else { return nil }
        let paragraph = ns.paragraphRange(for: NSRange(location: index, length: 0))
        return Indonesian.wordRanges(in: string, range: paragraph).first { NSLocationInRange(index, $0.1) }?.1
    }

    @objc private func replaceMisspelling(_ sender: NSMenuItem) {
        guard let range = (sender.representedObject as? NSValue)?.rangeValue,
              shouldChangeText(in: range, replacementString: sender.title) else { return }
        replaceCharacters(in: range, with: sender.title)
        didChangeText()
    }

    @objc private func addToDictionary(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        CustomDictionary.shared.add(word)
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        var position = 0
        func insert(_ item: NSMenuItem) {
            menu.insertItem(item, at: position)
            position += 1
        }

        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if let range = misspelledWord(at: index) {
            let ns = string as NSString
            let word = ns.substring(with: range)
            if Indonesian.looksIndonesian(ns.substring(with: ns.paragraphRange(for: range))) {
                // The system's guesses for these words come from the wrong language.
                removeSystemGuesses(from: menu)
                let guesses = IndonesianSpellChecker.shared.guesses(for: word, in: string, range: range,
                                                                    documentTag: spellCheckerDocumentTag)
                for guess in guesses {
                    let item = NSMenuItem(title: guess, action: #selector(replaceMisspelling(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = NSValue(range: range)
                    insert(item)
                }
                if guesses.isEmpty {
                    let none = NSMenuItem(title: "No Guesses Found", action: nil, keyEquivalent: "")
                    none.isEnabled = false
                    insert(none)
                }
                insert(.separator())
            } else {
                // Keep AppKit's guesses first, as in every Mac app.
                while position < menu.items.count, isSystemGuess(menu.items[position]) { position += 1 }
                if position > 0 {
                    if position < menu.items.count, menu.items[position].isSeparatorItem { position += 1 } else { insert(.separator()) }
                }
            }
            // "Add to Dictionary" replaces Learn Spelling, so the word shows up in Custom Dictionary.
            if let learn = menu.items.firstIndex(where: { $0.action.map(NSStringFromSelector) == "_learnSpellingFromMenu:" }) {
                menu.removeItem(at: learn)
            }
            let add = NSMenuItem(title: "Add “\(word)” to Dictionary", action: #selector(addToDictionary(_:)), keyEquivalent: "")
            add.target = self
            add.representedObject = word
            insert(add)
            insert(.separator())
        }

        let annotate = NSMenuItem(title: "Add Annotation",
                                  action: #selector(DocumentViewController.addAnnotation(_:)), keyEquivalent: "")
        insert(annotate)
        insert(.separator())
        return menu
    }

    /// Drops the guess items AppKit puts at the top of the menu for a misspelled word.
    private func removeSystemGuesses(from menu: NSMenu) {
        guard let first = menu.items.first, isSystemGuess(first) else { return }
        while let first = menu.items.first, isSystemGuess(first) { menu.removeItem(at: 0) }
        if menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
    }

    private func isSystemGuess(_ item: NSMenuItem) -> Bool {
        if item.action.map(NSStringFromSelector) == "_changeSpellingFromMenu:" { return true }
        return item.action == nil && !item.isSeparatorItem && item.submenu == nil && !item.isEnabled   // "No Guesses Found"
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
