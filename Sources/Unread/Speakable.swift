import Foundation
import NaturalLanguage

/// What the narrator says for a sentence's display words (#18): technical writing made sayable.
///
/// The narrator already reads numbers, units, currencies, percentages, versions and "#48" well
/// (`--hear`), so this leaves them alone. It rewrites what comes out wrong: abbreviations ("e.g."
/// as "E G"), ISO dates ("2026-11-05" as "eleven hundred five"), identifiers (`CORS_ORIGIN`,
/// `getUserName()`), file paths, flags, code operators, and a few all-caps words ("README" as "Read M").
///
/// Each display word becomes zero or more spoken words, so word timing maps back to the page
/// exactly: the aligner times the spoken words, and a display word starts where its first one does.
struct Speakable: Equatable {
    /// What the narrator is given.
    let text: String
    /// The spoken words, in order (`text` split at spaces).
    let words: [Substring]
    /// For each spoken word, the display word it came from.
    let owners: [Int]

    init(_ display: [Substring], language: NLLanguage) {
        var said: [String] = [], owners: [Int] = []
        for (i, word) in display.enumerated() {
            let spoken = Self.say(word, last: i == display.count - 1, language: language)
            for w in spoken.split(separator: " ") { said.append(String(w)); owners.append(i) }
        }
        text = said.joined(separator: " ")
        words = text.split(separator: " ")
        self.owners = owners
    }

    init(_ text: String, language: NLLanguage) { self.init(text.split(separator: " "), language: language) }

    /// For each of `displayCount` display words, the first of `starts` (one per spoken word) it owns; nil if it
    /// has no spoken word with a start.
    func displayStarts(_ starts: [Int?], displayCount: Int) -> [Int?] {
        var out = [Int?](repeating: nil, count: displayCount)
        for (k, owner) in owners.enumerated() where k < starts.count && owner < displayCount && out[owner] == nil {
            out[owner] = starts[k]
        }
        return out
    }

    // MARK: Rules

    /// One display word, said. `last`: it ends the sentence, so a sentence-final period is kept.
    static func say(_ word: Substring, last: Bool, language: NLLanguage) -> String {
        let english = language != .french
        // Abbreviations keep their own periods, so match them before splitting off punctuation.
        let opening = word.prefix { leading.contains($0) }, rest = word.dropFirst(opening.count).lowercased()
        for (abbreviation, spoken) in english ? englishAbbreviations : frenchAbbreviations where rest.hasPrefix(abbreviation) {
            let tail = rest.dropFirst(abbreviation.count)
            guard tail.allSatisfy(trailing.contains) else { continue }
            return opening + spoken + (tail.isEmpty && last && abbreviation.hasSuffix(".") ? "." : String(tail))
        }
        let (lead, core, trail) = split(word)
        guard !core.isEmpty else { return String(word) }
        let said = sayCore(core, english: english)
        return said == core ? String(word) : lead + said + trail
    }

    private static let englishAbbreviations: [(String, String)] = [
        ("e.g.", "for example"), ("eg.", "for example"), ("i.e.", "that is"), ("ie.", "that is"), ("etc.", "et cetera"),
        ("vs.", "versus"), ("vs", "versus"), ("cf.", "compare"), ("approx.", "approximately"), ("w/", "with"), ("w/o", "without"),
        ("a.k.a.", "also known as"), ("n.b.", "note"),
    ]
    private static let frenchAbbreviations: [(String, String)] = [
        ("c.-à-d.", "c'est-à-dire"), ("cf.", "voir"), ("env.", "environ"), ("etc.", "et cetera"),
    ]

    /// Said as words: the narrator reads them as letters, or as something else.
    private static let lexicon: [String: String] = ["README": "read me", "TODO": "to do", "FIXME": "fix me", "WIP": "work in progress"]

    private static let leading: Set<Character> = ["\"", "'", "“", "‘", "(", "[", "«", "`"]
    private static let trailing: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»", "`", ",", ";", ":", "!", "?", "."]

    /// Leading quotes and brackets, the word, and trailing punctuation.
    private static func split(_ word: Substring) -> (String, String, String) {
        var core = word[...]
        var lead = "", trail = ""
        while let c = core.first, leading.contains(c) { lead.append(c); core = core.dropFirst() }
        while let c = core.last, trailing.contains(c) {
            // A call's parentheses are part of the identifier: "fetch()", "setName(name)".
            if c == ")", core.contains("(") { break }
            trail.insert(c, at: trail.startIndex)
            core = core.dropLast()
        }
        return (lead, String(core), trail)
    }

    private static func sayCore(_ core: String, english: Bool) -> String {
        if let word = lexicon[core] { return word }
        if let date = isoDate(core, english: english) { return date }
        if let amount = magnitude(core, english: english) { return amount }
        if core == "*" { return english ? "star" : "étoile" }
        var s = core
        for (op, spoken) in english ? englishOperators : frenchOperators where s.contains(op) {
            s = s.replacingOccurrences(of: op, with: " \(spoken) ")
        }
        if s != core { return collapse(s) }
        guard looksLikeCode(core) else { return core }
        return identifier(core, english: english)
    }

    private static let englishOperators = [("->", "arrow"), ("=>", "arrow"), ("!=", "not equal to"), ("==", "equals"),
                                           (">=", "at least"), ("<=", "at most"), ("&&", "and"), ("||", "or")]
    private static let frenchOperators = [("->", "flèche"), ("=>", "flèche"), ("!=", "différent de"), ("==", "égal"),
                                          (">=", "au moins"), ("<=", "au plus"), ("&&", "et"), ("||", "ou")]

    private static let isoDatePattern = try! NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2})$"#)

    /// "2026-11-05" → "November 5, 2026". The narrator read it as numbers.
    private static func isoDate(_ s: String, english: Bool) -> String? {
        guard let m = isoDatePattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        let part = { (i: Int) in Int((s as NSString).substring(with: m.range(at: i)))! }
        var c = DateComponents()
        (c.year, c.month, c.day) = (part(1), part(2), part(3))
        guard let date = Calendar(identifier: .gregorian).date(from: c), (1...12).contains(part(2)), (1...31).contains(part(3)) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: english ? "en_US" : "fr_FR")
        f.dateFormat = english ? "MMMM d, yyyy" : "d MMMM yyyy"
        return f.string(from: date)
    }

    private static let magnitudePattern = try! NSRegularExpression(pattern: #"^(\d+(?:[.,]\d+)?)([MB])$"#)

    /// "82M" → "82 million", "7B" → "7 billion". Not "k": a "56k modem" is said "fifty-six K", and "4K" is a screen.
    private static func magnitude(_ s: String, english: Bool) -> String? {
        guard let m = magnitudePattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        let number = (s as NSString).substring(with: m.range(at: 1)), unit = (s as NSString).substring(with: m.range(at: 2))
        let words = english ? ["M": "million", "B": "billion"] : ["M": "millions", "B": "milliards"]
        return "\(number) \(words[unit]!)"
    }

    /// An identifier, a path, a file name or a flag, rather than a word: it has an underscore, a
    /// call's "()", a leading "-" before letters ("--dry-run"), a path to a file or from a root
    /// ("docs/design.md", "~/Library", "/usr/bin"; not "and/or", "NGINX/OpenResty" or "11/05/2026"),
    /// a "." between two words of two letters or more ("App.swift", "github.com"; not "U.S." or "3.5"),
    /// or starts lower-case with three humped words or more ("getUserName"). Brand names are left
    /// whole: "GitHub", "OpenAI", "macOS", "useState" are said well as they are.
    private static func looksLikeCode(_ s: String) -> Bool {
        if s.contains("_") || s.hasSuffix("()") { return true }
        // A call with arguments, no spaces: "goLive(_:_:)", "setUserName(name)".
        if s.hasSuffix(")"), let open = s.firstIndex(of: "("), s.distance(from: s.startIndex, to: open) >= 2,
           s[..<open].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." }) { // not "f(x)"
            return true
        }
        if s.hasPrefix("-"), s.drop(while: { $0 == "-" }).first?.isLetter == true { return true }
        if s.contains("/"), s.contains(where: \.isLetter),
           s.hasPrefix("~/") || s.hasPrefix("./") || s.hasPrefix("/") || isFileName(s.split(separator: "/").last ?? "") {
            return true
        }
        if isFileName(Substring(s)) { return true }
        return s.first?.isLowercase == true && camelWords(Substring(s)).count >= 3
    }

    private static func isFileName(_ s: Substring) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count > 1 && parts.allSatisfy { $0.count >= 2 && $0.first?.isLetter == true }
    }

    private static func identifier(_ core: String, english: Bool) -> String {
        var s = Substring(core)
        // A call or a selector: its arguments aren't said ("goLive(_:_:)", "setName(name)").
        if s.hasSuffix(")"), let open = s.firstIndex(of: "("), open > s.startIndex { s = s[..<open] }
        // "Session.swift:566": the line, said as one.
        var line = ""
        if let m = lineSuffix.firstMatch(in: String(s), range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s),
           let number = Range(m.range(at: 1), in: s) {
            line = (english ? ", line " : ", ligne ") + s[number] // "main.swift:12:5": the line, not the column
            s = s[..<r.lowerBound]
        }
        // "KEY=value": a setting.
        if let equals = s.firstIndex(of: "="), equals > s.startIndex, s.index(after: equals) < s.endIndex {
            return collapse(identifier(String(s[..<equals]), english: english) + (english ? " equals " : " égal ")
                            + s[s.index(after: equals)...] + line)
        }
        // A one-letter flag is said with its dash ("-c"); a long one without ("--dry-run").
        if s.count == 2, s.first == "-" { return (english ? "dash " : "tiret ") + s.dropFirst() }
        while s.hasPrefix("-") { s = s.dropFirst() }
        if s.hasPrefix("~/") || s.hasPrefix("./") { s = s.dropFirst(2) } // the home folder, the current one: said as where it leads
        let slash = "slash", dot = english ? "dot" : "point"
        let segments = s.split(separator: "/", omittingEmptySubsequences: true).map { segment -> String in
            let pieces = segment.split(separator: ".", omittingEmptySubsequences: true)
            return pieces.enumerated().map { i, piece in
                // A short extension without vowels is spelled: "md", "js", "py".
                if i > 0, i == pieces.count - 1, piece.count <= 4, !piece.contains(where: { "aeiouAEIOU".contains($0) }) {
                    return piece.uppercased()
                }
                return words(of: piece)
            }.joined(separator: " \(dot) ")
        }
        return collapse(segments.joined(separator: " \(slash) ") + line)
    }

    /// An identifier's words: split at "_" and "-" and at humps; all-caps words longer than four
    /// letters are lowered, or the narrator spells them ("ORIGIN").
    private static func words(of s: Substring) -> String {
        s.split(whereSeparator: { $0 == "_" || $0 == "-" }).flatMap(camelWords).map { w in
            if let word = lexicon[String(w)] { return word }
            return w.count > 4 && w.allSatisfy({ !$0.isLetter || $0.isUppercase }) ? w.lowercased() : String(w)
        }.joined(separator: " ")
    }

    /// "getUserName" → get, User, Name; "HTTPServer" → HTTP, Server. A hump only counts after three
    /// letters ("iPhone", "McDonald" stay whole) and before two lower-case ones ("IDs", "URLs" stay whole).
    private static func camelWords(_ s: Substring) -> [Substring] {
        let chars = Array(s)
        var out: [Substring] = [], start = 0
        for i in chars.indices.dropFirst() {
            let lowerToUpper = chars[i - 1].isLowercase && chars[i].isUppercase
            let acronymEnd = i + 2 < chars.count && chars[i - 1].isUppercase && chars[i].isUppercase
                && chars[i + 1].isLowercase && chars[i + 2].isLowercase
            guard lowerToUpper || acronymEnd, i - start >= 3 || acronymEnd && i - start >= 2 else { continue }
            out.append(s[s.index(s.startIndex, offsetBy: start)..<s.index(s.startIndex, offsetBy: i)])
            start = i
        }
        out.append(s[s.index(s.startIndex, offsetBy: start)...])
        return out
    }

    private static let lineSuffix = try! NSRegularExpression(pattern: #"(?<=[A-Za-z]):(\d+)(?::\d+)?$"#)

    private static func collapse(_ s: String) -> String { s.split(separator: " ").joined(separator: " ") }
}

extension Speakable {
    /// Written → said, checked by `--speakable-check` (scripts/test.sh). English unless marked French.
    static let checks: [(written: String, said: String, french: Bool)] = [
        ("It takes ~250 ms, e.g. on an M1, i.e. most Macs.", "It takes ~250 ms, for example on an M1, that is most Macs.", false),
        ("Lists, tables, etc.", "Lists, tables, et cetera.", false),
        ("Some (e.g. this) and more, etc.) here.", "Some (for example this) and more, et cetera) here.", false),
        ("It's 3× faster vs. the old one.", "It's 3× faster versus the old one.", false),
        ("On 2026-11-05 we shipped it.", "On November 5, 2026 we shipped it.", false),
        ("Le 2026-11-05, c.-à-d. jeudi.", "Le 5 novembre 2026, c'est-à-dire jeudi.", true),
        ("The model has 82M parameters, the big one 7B.", "The model has 82 million parameters, the big one 7 billion.", false),
        ("A 4K screen, a 56k modem, 50kB and 500M users.", "A 4K screen, a 56k modem, 50kB and 500 million users.", false),
        ("Rename user_id to account_id.", "Rename user id to account id.", false),
        ("Set CORS_ORIGIN to * now.", "Set CORS origin to star now.", false),
        ("Call getUserName() first.", "Call get User Name first.", false),
        ("Then setUserName(name) and getHTTPStatusCode.", "Then set User Name and get HTTP Status Code.", false),
        ("It's in Session.swift:566, in goLive(_:_:), at main.swift:12:5.", "It's in Session dot swift, line 566, in goLive, at main dot swift, line 12.", false),
        ("Set UNREAD_DEBUG_OVERLAY=1 first.", "Set unread debug overlay equals 1 first.", false),
        ("Where f(x) grows.", "Where f(x) grows.", false),
        ("Run swift build -c release with --dry-run.", "Run swift build dash c release with dry run.", false),
        ("Edit Sources/Unread/App.swift today.", "Edit Sources slash Unread slash App dot swift today.", false),
        ("Read docs/design.md and the README.", "Read docs slash design dot MD and the read me.", false),
        ("Open ~/Library/Logs and ./build.", "Open Library slash Logs and build.", false),
        ("Ask github.com, Node.js or a c4.xlarge.", "Ask github dot com, Node dot JS or a c4 dot xlarge.", false),
        ("Use a->b, x => y and a != b.", "Use a arrow b, x arrow y and a not equal to b.", false),
        ("TODO: fix README.md.", "to do: fix read me dot MD.", false),
        // Left alone: the narrator says these well, or they're words.
        ("Version v3.5 replaced v3.4.1 in the U.S. and/or 11/05/2026.", "Version v3.5 replaced v3.4.1 in the U.S. and/or 11/05/2026.", false),
        ("My iPhone, McDonald's, IDs and URLs -- fine.", "My iPhone, McDonald's, IDs and URLs -- fine.", false),
        ("It costs $45.99, or 10% less; see #48.", "It costs $45.99, or 10% less; see #48.", false),
        ("A well-known, low-latency JavaScript API.", "A well-known, low-latency JavaScript API.", false),
        ("GitHub, OpenAI, ChatGPT, macOS, CaMeL, useState and HTTPServer.", "GitHub, OpenAI, ChatGPT, macOS, CaMeL, useState and HTTPServer.", false),
        ("NGINX/OpenResty and heatmap/gradient/styling.", "NGINX/OpenResty and heatmap/gradient/styling.", false),
    ]

    /// Every check passes. Prints the ones that don't.
    static func check() -> Bool {
        var ok = true
        for c in checks {
            let said = Speakable(c.written, language: c.french ? .french : .english).text
            if said != c.said { ok = false; print("speakable: \(c.written.debugDescription)\n   said     \(said.debugDescription)\n   expected \(c.said.debugDescription)") }
        }
        print(ok ? "speakable: \(checks.count) checks pass" : "speakable: FAILED")
        return ok
    }
}
