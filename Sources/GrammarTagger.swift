import Foundation

enum GrammarRole {
    case subject, predicate, object, modifier
}

/// Approximates sentence roles from macOS's built-in part-of-speech tagger.
///
/// The system tagger only knows lexical classes (noun, verb, adjective...), so roles are
/// inferred per sentence: nouns/pronouns before the first verb are the subject, verbs are
/// the predicate, nouns/pronouns after it are the object (unless inside a prepositional
/// phrase), and adjectives/adverbs are modifiers. Works for every language the tagger
/// supports (English, French, German, Italian, Spanish, Portuguese, Russian, Turkish...).
final class GrammarTagger {
    private let tagger = NSLinguisticTagger(tagSchemes: [.lexicalClass], options: 0)

    func roles(in string: String, range: NSRange) -> [(NSRange, GrammarRole)] {
        guard range.length > 0 else { return [] }
        tagger.string = string
        let ns = string as NSString
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
