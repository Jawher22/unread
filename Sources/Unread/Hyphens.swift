import Foundation

/// What a word broken at a line end ("para-" / "graph") was before the typesetter broke it (#86).
/// The document's own spelling decides first: a compound it writes with a hyphen elsewhere
/// ("multi-head", "pre-trained") keeps it, a word it writes whole ("Radford") is joined. Then a
/// few prefixes keep their hyphen ("multi-" + "head"). Then the system word list
/// (`/usr/share/dict/words`, base forms, with the common inflections): "para" + "graph" is one
/// word, "task" + "specific" two.
enum Hyphens {
    enum Join {
        /// One word: the hyphen was the typesetter's ("para-graph", "unidi-rectionality").
        case word
        /// The hyphen is the word's ("task-specific", "multi-head").
        case compound
        /// Two words: the hyphen hangs from the first ("pre- and post-training").
        case apart
    }

    /// The words a document writes, as it writes them: whole, or hyphenated inside a line.
    struct Vocabulary {
        private var plain: Set<String> = []
        private var hyphenated: Set<String> = []

        /// Hyphens at a line end ("para- graph": hyphen, space) are the ones in question, so only
        /// tokens with a hyphen inside count as the document's compounds, and neither half of a
        /// broken word counts as a word ("plicative" in "multi- plicative" would keep its hyphen).
        mutating func add(_ text: String) {
            var broken = false
            for token in text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "-" }) {
                defer { broken = token.hasSuffix("-") }
                if broken || token.hasPrefix("-") || token.hasSuffix("-") { continue }
                if token.contains("-") { hyphenated.insert(String(token)) } else { plain.insert(String(token)) }
            }
        }

        /// Whether the document writes the word on its own, singular or plural.
        func uses(_ word: String) -> Bool {
            plain.contains(word) || plain.contains(word + "s") || (word.hasSuffix("s") && plain.contains(String(word.dropLast())))
        }

        func join(_ left: String, _ right: String) -> Join? {
            if hyphenated.contains(left + "-" + right) { return .compound }
            if plain.contains(left + right) { return .word }
            return nil
        }
    }

    private static let words: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()

    /// The list takes ~50 ms to read; done at launch, the first PDF sentence doesn't wait for it on the AX worker.
    static func preload() {
        Task.detached(priority: .utility) { _ = words.count }
    }

    /// A half the hyphen can't follow: "pre- and post-training" is two words.
    private static let connectors: Set<String> = ["and", "or", "to", "nor", "but", "et", "ou"]
    /// Prefixes that keep their hyphen before a word the document uses on its own ("multi-head"
    /// where it writes "heads", but "multi-plicative" is one word), even where the word list has
    /// the whole: it's Webster's of 1934, with "multihead". Only prefixes that seldom begin a
    /// closed word whose rest is a word too: not "pre" ("pre-sent"), "sub" ("sub-set"), "inter"
    /// ("inter-national") or "trans" ("trans-form"); those are left to the document's own
    /// spelling and the list.
    private static let prefixes: Set<String> = ["multi", "self", "semi", "quasi", "pseudo", "non", "cross", "post", "meta", "intra", "ultra", "hyper"]
    private static let inflections: [(suffix: String, stems: [String])] = [("ies", ["y"]), ("ied", ["y"]), ("ing", ["", "e"]), ("ed", ["", "e"]), ("es", [""]), ("s", [""]), ("ly", [""]), ("er", ["", "e"]), ("est", ["", "e"]), ("ness", [""]), ("ment", [""]), ("tion", ["te", "t"]), ("ity", ["", "e"]), ("al", [""]), ("ally", [""]), ("ive", ["", "e"]), ("ous", [""]), ("able", ["", "e"]), ("ible", [""]), ("ful", [""]), ("less", [""]), ("ism", [""]), ("ist", [""])]

    /// What "left-" at a line end and "right" on the next line make. `wordList: false` (French, which
    /// has none): only the document's spelling joins; otherwise the hyphen stays.
    static func join(_ left: String, _ right: String, in vocabulary: Vocabulary, wordList: Bool = true) -> Join {
        let l = left.lowercased(), r = right.lowercased()
        if connectors.contains(r) { return .apart }
        if let known = vocabulary.join(l, r) { return known }
        guard wordList else { return .compound }
        guard !words.isEmpty else { return .word } // the list is missing: a line-end hyphen is usually a break
        if prefixes.contains(l), vocabulary.uses(r) { return .compound }
        if isWord(l + r) { return .word }
        if !isWord(l) || !isWord(r) { return .word }
        return .compound
    }

    static func isWord(_ w: String) -> Bool {
        let s = w.lowercased()
        guard s.count >= 2 else { return false }
        if words.contains(s) { return true }
        for (suffix, stems) in inflections {
            guard s.hasSuffix(suffix), s.count > suffix.count + 2 else { continue }
            let base = String(s.dropLast(suffix.count))
            for stem in stems where words.contains(base + stem) { return true }
            // A doubled final consonant ("stopping"): the base is one shorter.
            if base.count >= 2, base.last == base[base.index(base.endIndex, offsetBy: -2)], words.contains(String(base.dropLast())) { return true }
        }
        return false
    }
}
