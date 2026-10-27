import AppKit

/// Spell checking for Indonesian paragraphs.
///
/// macOS ships an Indonesian word list for completions, but its Indonesian spelling
/// dictionary accepts any word. So words are checked against the completion list instead,
/// allowing for clitics (-nya, -ku, -mu, -lah, -kah, -pun), reduplication (anak-anak) and
/// compounds inside confixes (per·tanggung·jawab·an). Words in the custom dictionary, learned
/// words and words ignored in the document are always accepted.
final class IndonesianSpellChecker {
    static let shared = IndonesianSpellChecker()

    private let checker = NSSpellChecker.shared
    private var lexiconCache: [String: Bool] = [:]
    private static let clitics = ["nya", "lah", "kah", "pun", "ku", "mu"]
    private static let derivedSuffixes = ["nya", "ku", "mu", "kan", "an", "i", "lah"]
    private static let confixes: [(String, String)] = [
        ("per", "an"), ("ke", "an"), ("pe", "an"), ("pen", "an"), ("pem", "an"), ("peng", "an"),
        ("di", "kan"), ("men", "kan"), ("mem", "kan"), ("meng", "kan"), ("memper", "kan"),
        ("diper", "kan"), ("", "an"), ("", ""),
    ]
    private static let skipRegex = try! NSRegularExpression(
        pattern: "`[^`\\n]*`|\\]\\([^)\\n]*\\)|<[^>\\n]*>|\\b(?:https?://|www\\.)\\S+|\\S+@\\S+\\.\\S+")

    /// Replaces the system's spelling results inside Indonesian paragraphs with this checker's.
    func adjust(_ results: [NSTextCheckingResult], in string: String, range: NSRange,
                documentTag: Int, skipping typing: NSRange?) -> [NSTextCheckingResult] {
        let ns = string as NSString
        let paragraphs = ns.paragraphRange(for: NSIntersectionRange(range, NSRange(location: 0, length: ns.length)))
        var indonesian: [NSRange] = []
        ns.enumerateSubstrings(in: paragraphs, options: [.byParagraphs, .substringNotRequired]) { _, paragraph, _, _ in
            if Indonesian.looksIndonesian(ns.substring(with: paragraph)) { indonesian.append(paragraph) }
        }
        guard !indonesian.isEmpty else { return results }

        let replacedTypes: [NSTextCheckingResult.CheckingType] = [.spelling, .correction, .grammar]
        var adjusted = results.filter { result in
            !(replacedTypes.contains(result.resultType)
              && indonesian.contains { NSIntersectionRange($0, result.range).length > 0 })
        }
        for paragraph in indonesian {
            let checked = NSIntersectionRange(paragraph, range)
            guard checked.length > 0 else { continue }
            for word in misspellings(in: string, range: checked, documentTag: documentTag)
            where typing.map({ NSMaxRange(word) != $0.location }) ?? true {
                adjusted.append(NSTextCheckingResult.spellCheckingResult(range: word))
            }
        }
        return adjusted
    }

    func misspellings(in string: String, range: NSRange, documentTag: Int) -> [NSRange] {
        let ns = string as NSString
        let paragraph = ns.paragraphRange(for: range)
        var skipped: [NSRange] = []
        Self.skipRegex.enumerateMatches(in: string, range: paragraph) { match, _, _ in
            if let r = match?.range { skipped.append(r) }
        }
        let ignored = Set((checker.ignoredWords(inSpellDocumentWithTag: documentTag) ?? []).map { $0.lowercased() })

        var result: [NSRange] = []
        for (word, wordRange) in Indonesian.wordRanges(in: string, range: range) {
            if skipped.contains(where: { NSIntersectionRange($0, wordRange).length > 0 }) { continue }
            if ignored.contains(word.lowercased()) { continue }
            if isName(word, at: wordRange.location, in: ns) { continue }
            if !isKnown(word) { result.append(wordRange) }
        }
        return result
    }

    func isKnown(_ word: String) -> Bool {
        let w = word.lowercased().replacingOccurrences(of: "’", with: "'")
        if w.count <= 1 || CustomDictionary.shared.contains(w)
            || checker.hasLearnedWord(word) || checker.hasLearnedWord(w) { return true }
        let parts = w.split(separator: "-").map(String.init)
        if parts.count > 1 { return parts.allSatisfy { inLexicon($0) } }
        return inLexicon(w)
    }

    /// Indonesian corrections: the system's guesses that are real words, plus words from the
    /// completion list within two edits of the misspelling.
    func guesses(for word: String, in string: String, range: NSRange, documentTag: Int) -> [String] {
        let lower = word.lowercased()
        var candidates: [(String, Int)] = []
        var seen = Set<String>()
        func consider(_ candidate: String) {
            let key = candidate.lowercased()
            guard key != lower, !seen.contains(key) else { return }
            let distance = Self.editDistance(lower, key)
            guard distance <= 2 else { return }
            seen.insert(key)
            candidates.append((candidate, distance))
        }
        for guess in checker.guesses(forWordRange: range, in: string, language: "id",
                                     inSpellDocumentWithTag: documentTag) ?? [] where isKnown(guess) {
            consider(guess)
        }
        var length = lower.count - 1
        while length >= 2 && candidates.count < 8 {
            for completion in completions(String(lower.prefix(length))) { consider(completion) }
            length -= 1
        }
        let ranked = candidates.enumerated()
            .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
            .map { $0.element.0 }
        // Keep the writer's capitalisation.
        let capitalized = word.first.map { String($0).uppercased() == String($0) } ?? false
        return ranked.prefix(6).map { capitalized ? $0.prefix(1).uppercased() + $0.dropFirst() : $0 }
    }

    // MARK: Lexicon

    private func completions(_ prefix: String) -> [String] {
        checker.completions(forPartialWordRange: NSRange(location: 0, length: (prefix as NSString).length),
                            in: prefix, language: "id", inSpellDocumentWithTag: 0) ?? []
    }

    /// Whether the completion list knows the word, or a form derived from it.
    private func listed(_ w: String) -> Bool {
        guard w.count >= 2 else { return false }
        return completions(w).contains { completion in
            let c = completion.lowercased()
            if c == w { return true }
            guard c.hasPrefix(w) else { return false }
            let rest = String(c.dropFirst(w.count))
            return Self.derivedSuffixes.contains(rest) || rest == "-" + w
        }
    }

    private func inLexicon(_ w: String) -> Bool {
        if let cached = lexiconCache[w] { return cached }
        var known = listed(w)
        if !known {
            for clitic in Self.clitics where w.hasSuffix(clitic) && w.count > clitic.count + 2 {
                if listed(String(w.dropLast(clitic.count))) { known = true; break }
            }
        }
        if !known && w.count >= 9 { known = isCompound(w) }
        lexiconCache[w] = known
        return known
    }

    /// Two known words inside an optional confix: pertanggungjawaban = per + tanggung + jawab + an.
    private func isCompound(_ w: String) -> Bool {
        for (prefix, suffix) in Self.confixes where w.hasPrefix(prefix) && w.hasSuffix(suffix) {
            let core = Array(w.dropFirst(prefix.count).dropLast(suffix.count))
            guard core.count >= 6 else { continue }
            for split in 3...(core.count - 3) where listed(String(core[..<split])) {
                if listed(String(core[split...])) { return true }
            }
        }
        return false
    }

    /// Capitalised words that don't start a sentence are taken to be names; so are acronyms.
    private func isName(_ word: String, at location: Int, in ns: NSString) -> Bool {
        guard let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) else { return false }
        if word.count > 1 && word == word.uppercased() { return true }
        var i = location - 1
        while i >= 0, let scalar = Unicode.Scalar(ns.character(at: i)),
              CharacterSet.whitespaces.contains(scalar) || "\"'“‘(*_#>-".unicodeScalars.contains(scalar) {
            i -= 1
        }
        guard i >= 0 else { return false }
        let previous = ns.character(at: i)
        return !(previous == 0x2E || previous == 0x21 || previous == 0x3F || previous == 0x0A || previous == 0x3A)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)   // swapped letters
                }
            }
        }
        return d[a.count][b.count]
    }
}

/// Words the writer added to the dictionary. They are also taught to macOS's spell checker,
/// so they're accepted in every language and in other apps. With a writing library set up,
/// the list is also kept in the library, so it syncs to other Macs.
final class CustomDictionary {
    static let shared = CustomDictionary()
    private let key = "customWords"

    private(set) var words: [String]
    private var lowercased: Set<String>

    private init() {
        words = (UserDefaults.standard.stringArray(forKey: key) ?? []).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        lowercased = Set(words.map { $0.lowercased() })
    }

    func contains(_ word: String) -> Bool { lowercased.contains(word.lowercased()) }

    func add(_ word: String) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !contains(word) else { return }
        NSSpellChecker.shared.learnWord(word)
        words.append(word)
        save()
    }

    func remove(_ word: String) {
        NSSpellChecker.shared.unlearnWord(word)
        words.removeAll { $0.lowercased() == word.lowercased() }
        save()
    }

    /// Adopts the library's list after a sync: words added on other Macs are learned,
    /// words removed there are forgotten.
    func reloadFromLibrary() {
        guard let url = SyncLibrary.shared.dictionaryURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let synced = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let syncedSet = Set(synced.map { $0.lowercased() })
        guard syncedSet != lowercased else { return }
        for word in words where !syncedSet.contains(word.lowercased()) { NSSpellChecker.shared.unlearnWord(word) }
        for word in synced where !lowercased.contains(word.lowercased()) { NSSpellChecker.shared.learnWord(word) }
        words = synced
        save(toLibrary: false)
    }

    private func save(toLibrary: Bool = true) {
        words.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        lowercased = Set(words.map { $0.lowercased() })
        UserDefaults.standard.set(words, forKey: key)
        if toLibrary, let url = SyncLibrary.shared.dictionaryURL {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (words.joined(separator: "\n") + (words.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
            SyncLibrary.shared.scheduleSync(after: 10)
        }
        NotificationCenter.default.post(name: .customDictionaryChanged, object: nil)
    }
}

extension Notification.Name {
    static let customDictionaryChanged = Notification.Name("LaserFocusCustomDictionaryChanged")
}
