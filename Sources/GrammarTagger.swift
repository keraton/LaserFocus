import Foundation

enum GrammarRole {
    case subject, predicate, object, modifier
}

/// Approximates sentence roles from word classes, paragraph by paragraph.
///
/// Roles are inferred per sentence: nouns/pronouns before the first verb are the subject,
/// verbs are the predicate, nouns/pronouns after it are the object (unless inside a
/// prepositional phrase), and adjectives/adverbs are modifiers. Word classes come from
/// macOS's built-in tagger (English, French, German, Italian, Spanish, Portuguese, Russian,
/// Turkish...) or, for Indonesian, which macOS has no tagger for, from ``IndonesianTagger``.
final class GrammarTagger {
    private let tagger = NSLinguisticTagger(tagSchemes: [.lexicalClass], options: 0)
    private let indonesian = IndonesianTagger()

    func roles(in string: String, range: NSRange) -> [(NSRange, GrammarRole)] {
        guard range.length > 0 else { return [] }
        let ns = string as NSString
        var result: [(NSRange, GrammarRole)] = []
        var systemTaggerReady = false

        ns.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, paragraph, _, _ in
            guard paragraph.length > 0 else { return }
            if Indonesian.looksIndonesian(ns.substring(with: paragraph)) {
                result += self.indonesian.roles(in: string, range: paragraph)
            } else {
                if !systemTaggerReady {
                    self.tagger.string = string
                    systemTaggerReady = true
                }
                result += self.systemRoles(in: ns, range: paragraph)
            }
        }
        return result
    }

    private func systemRoles(in ns: NSString, range: NSRange) -> [(NSRange, GrammarRole)] {
        var result: [(NSRange, GrammarRole)] = []
        let options: NSLinguisticTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]

        ns.enumerateSubstrings(in: range, options: [.bySentences, .substringNotRequired]) { _, sentence, _, _ in
            var seenVerb = false
            var inPrepositionalPhrase = false

            self.tagger.enumerateTags(in: sentence, unit: .word, scheme: .lexicalClass, options: options) { tag, token, _ in
                guard let tag = tag else { return }
                switch tag {
                case .verb:
                    result.append((token, .predicate))
                    seenVerb = true
                    inPrepositionalPhrase = false
                case .noun, .pronoun, .personalName, .placeName, .organizationName:
                    if !inPrepositionalPhrase {
                        result.append((token, seenVerb ? .object : .subject))
                    }
                case .adjective, .adverb:
                    result.append((token, .modifier))
                case .preposition:
                    inPrepositionalPhrase = true
                case .conjunction:
                    inPrepositionalPhrase = false
                default:
                    break
                }
            }
        }
        return result
    }
}

/// Rule-based word classes for Indonesian: function-word lists plus verb affixes
/// (me-, ber-, di-, ter-, memper-). Everything else counts as a noun.
final class IndonesianTagger {
    enum WordClass {
        case noun, pronoun, verb, adjective, adverb, preposition, conjunction, relative, determiner, other
    }

    func wordClass(of word: String, sentenceStart: Bool) -> WordClass {
        let w = word.lowercased()
        if w == "yang" { return .relative }
        if ["itu", "ini", "tersebut"].contains(w) { return .determiner }
        if Indonesian.functionWords.contains(w) { return .other }
        if Indonesian.conjunctions.contains(w) { return .conjunction }
        if Indonesian.prepositions.contains(w) { return .preposition }
        if Indonesian.adverbs.contains(w) { return .adverb }
        if Indonesian.pronouns.contains(w) { return .pronoun }
        if Indonesian.adjectives.contains(w) { return .adjective }
        if !sentenceStart, let first = word.unicodeScalars.first,
           CharacterSet.uppercaseLetters.contains(first) { return .noun }   // a name
        // Reduplicated words (anak-anak, berlari-lari) take the class of their first half.
        let head = w.split(separator: "-").first.map(String.init) ?? w
        if head != w { return wordClass(of: head, sentenceStart: sentenceStart) }
        if Indonesian.rootVerbs.contains(w) || Indonesian.hasVerbPrefix(w) { return .verb }
        return .noun
    }

    func roles(in string: String, range: NSRange) -> [(NSRange, GrammarRole)] {
        let ns = string as NSString
        var result: [(NSRange, GrammarRole)] = []

        ns.enumerateSubstrings(in: range, options: [.bySentences, .substringNotRequired]) { _, sentence, _, _ in
            var seenVerb = false
            var inPrepositionalPhrase = false
            var inRelativeClause = false
            var previousEnd = sentence.location

            for (word, token) in Indonesian.wordRanges(in: string, range: sentence) {
                // A comma, semicolon or colon starts a new clause.
                let gap = ns.substring(with: NSRange(location: previousEnd, length: token.location - previousEnd))
                if gap.rangeOfCharacter(from: CharacterSet(charactersIn: ",;:")) != nil {
                    seenVerb = false
                    inPrepositionalPhrase = false
                    inRelativeClause = false
                }
                let sentenceStart = previousEnd == sentence.location
                previousEnd = NSMaxRange(token)

                switch self.wordClass(of: word, sentenceStart: sentenceStart) {
                case .verb:
                    if inRelativeClause {
                        result.append((token, .modifier))   // buku yang menarik
                    } else {
                        result.append((token, .predicate))
                        seenVerb = true
                        inPrepositionalPhrase = false
                    }
                case .noun, .pronoun:
                    if !inPrepositionalPhrase && !inRelativeClause {
                        result.append((token, seenVerb ? .object : .subject))
                    }
                case .adjective, .adverb:
                    result.append((token, .modifier))
                case .preposition:
                    inPrepositionalPhrase = true
                    inRelativeClause = false
                case .relative:
                    inRelativeClause = true
                case .determiner:
                    inRelativeClause = false   // orang yang tinggi itu | membaca
                case .conjunction:
                    inPrepositionalPhrase = false
                    inRelativeClause = false
                    // "dan/atau/serta" usually join words; other conjunctions start a clause.
                    if !["dan", "atau", "serta"].contains(word.lowercased()) { seenVerb = false }
                case .other:
                    break
                }
            }
        }
        return result
    }
}
