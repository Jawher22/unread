import AppKit
import ApplicationServices

/// One page of a PDFKit document (#86), as its `AXAttributedStringForRange` gives it: the
/// whole text in reading order with a font per run, and that is all a page answers. The text
/// has the page's furniture in it (running header, footer, page number, footnotes, figure
/// labels), so each "\n"-line is judged by its font against the document's body size:
/// smaller is furniture, bold or larger a heading, the rest is read. A running header set like
/// the body is known by repeating on the pages around (`PDFKitDocument.runningLines`). A "\n" isn't a paragraph
/// end (it comes at a link that ends a line, at a column end, at odd blocks), so lines of one
/// kind join into a block until one ends like a sentence.
final class PDFPage {
    struct Line {
        let range: NSRange // in the page's text, without the "\n"
        let size: CGFloat
        let bold: Bool
        let small: Bool // smaller than the body text: furniture
        /// A running header or footer: it repeats at the top or foot of the pages around. Furniture.
        let running: Bool
        /// Bold or larger than the body text: a heading, unless it says otherwise.
        let headingLike: Bool
        /// Footnote markers inside the line (a superscript digit or symbol): dropped.
        let markers: [NSRange]
        /// Other small runs inside the line (a subscript: "BERT" + "BASE"): kept, said as their own word.
        let subscripts: [NSRange]
        let text: String
        var words: Int { text.split(whereSeparator: \.isWhitespace).count }
        /// A page number.
        var isNumber: Bool { text.allSatisfy { $0.isNumber || $0.isWhitespace } }
        var startsLowercase: Bool { text.first(where: { !$0.isWhitespace })?.isLowercase ?? false }
        /// A list item: it starts a block of its own and no sentence runs into it.
        var isListItem: Bool { text.first(where: { !$0.isWhitespace }).map { "•–◦▪∗-".contains($0) } ?? false }
        /// A table row: several cells, half of them numbers.
        var isTabular: Bool {
            let tokens = text.split(whereSeparator: \.isWhitespace)
            return tokens.count >= 4 && tokens.filter { $0.contains(where: \.isNumber) }.count * 2 >= tokens.count
        }
    }

    enum Kind: Equatable { case heading, paragraph, caption(String), furniture }

    struct BlockID: Hashable, Comparable {
        let page: Int, index: Int
        static func < (a: BlockID, b: BlockID) -> Bool { (a.page, a.index) < (b.page, b.index) }
    }

    /// One or more lines of one kind that read as a unit: a heading, a paragraph (or the part of
    /// one in this column or page), a caption, or furniture. Its lines are in reading order,
    /// which is the text's order unless geometry said otherwise (`reorder`).
    final class Block {
        let id: BlockID
        let kind: Kind
        let lines: [Line]
        /// In the reference list, which is skipped unless the user points into it.
        var inReferences = false
        /// Furniture known to be a figure's labels (`markLabelStacks`, a heatmap's row).
        let labels: Bool
        init(id: BlockID, kind: Kind, lines: [Line], labels: Bool = false) {
            self.id = id; self.kind = kind; self.lines = lines; self.labels = labels
        }
        var ranges: [NSRange] { lines.map(\.range) }
        var small: Bool { lines[0].small }
        var endsLikeSentence: Bool { ReadingSession.endsLikeSentence(lines.last?.text ?? "") }
        var isReferencesHeading: Bool {
            kind == .heading && PDFPage.referencesHeading.firstMatch(in: lines[0].text, range: NSRange(lines[0].text.startIndex..., in: lines[0].text)) != nil
        }
        /// A drawn figure's text or a table's cells: its labels, each a short line of its own, or set
        /// small, or rows half of numbers.
        var isFigureText: Bool { kind == .furniture && !lines[0].isNumber && !lines[0].running && (labels || small || PDFPage.isLabelRun(lines) || lines.filter(\.isTabular).count * 2 > lines.count) }
        func contains(_ offset: Int) -> Bool { lines.contains { NSLocationInRange(offset, $0.range) } }
    }

    let index: Int
    let text: NSString
    private(set) var blocks: [Block]
    private let body: CGFloat
    private let headingSizes: Set<CGFloat>
    /// Whether the reference list is open at the page's end, as its last heading (or a caption, which
    /// closes it) says; nil without either (then it's whatever it was at the page's start).
    var referencesAfterLastHeading: Bool? {
        var open: Bool?
        for b in blocks {
            if b.kind == .heading { open = b.isReferencesHeading }
            if case .caption = b.kind { open = false }
        }
        return open
    }
    /// Whether the reference list is open at the page's end, once `resolveReferences` has placed it.
    private(set) var referencesAtEnd = false

    /// "Table 1: GLUE Test results…", not "Table 1." alone: a sentence ("Results are presented in") can wrap there.
    static let captionStart = try! NSRegularExpression(pattern: #"^\s*(Figure|Fig\.|Table|Tab\.)\s*\d+[.:]\s*\S"#)
    private static let captionInside = try! NSRegularExpression(pattern: #"\s(Figure|Fig\.|Table|Tab\.)\s*\d+[.:]"#)
    /// A sentence end and the space after it, before a lower-case word.
    private static let captionEnd = try! NSRegularExpression(pattern: #"(?<=\S)[.!?]\s+(?=\p{Ll})"#)
    private static let footnoteStart = try! NSRegularExpression(pattern: #"^\s*([∗*†‡§¶]|\d{1,2}(?=\p{Lu}))"#)
    private static let footnoteMarker = try! NSRegularExpression(pattern: #"^\s*[∗*†‡§¶\d]{1,3}\s*$"#)
    private static let referencesHeading = try! NSRegularExpression(pattern: #"^\s*(\d+(\.\d+)*\.?\s+)?(references|bibliography|works cited)\s*$"#, options: .caseInsensitive)
    private static let sentenceEnd = try! NSRegularExpression(pattern: #"[\p{L}\p{N})\]"'”’][.!?…][\s"'”’)\]]"#)

    /// Non-space characters per font size (rounded to the half point) in a page's string.
    static func sizeHistogram(of attributed: NSAttributedString) -> [CGFloat: Int] {
        var weight: [CGFloat: Int] = [:]
        let text = attributed.string as NSString
        for run in runs(of: attributed) where run.size > 0 {
            weight[(run.size * 2).rounded() / 2, default: 0] += text.substring(with: run.range).unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        }
        return weight
    }

    /// The sizes of the lines a page would take for headings, at the half point.
    static func headingSizes(of attributed: NSAttributedString, body: CGFloat, running: [NSRange]) -> Set<CGFloat> {
        let page = PDFPage(index: 0, attributed: attributed, body: body, headingSizes: [], running: running)
        return Set(page.blocks.filter { $0.kind == .heading }.map { $0.lines[0].size })
    }

    /// The size most characters are set in (the larger on a tie).
    static func dominant(_ histogram: [CGFloat: Int]) -> CGFloat? {
        histogram.max { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }?.key
    }

    private struct Run {
        let range: NSRange
        let size: CGFloat
        let bold: Bool
    }

    private static func runs(of attributed: NSAttributedString) -> [Run] {
        var runs: [Run] = []
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, range, _ in
            let font = attrs[NSAttributedString.Key("AXFont")] as? [String: Any]
            let size = (font?["AXFontSize"] as? NSNumber)?.doubleValue ?? (font?["AXFontSize"] as? String).flatMap(Double.init) ?? 0
            let name = ((font?["AXFontName"] as? String) ?? "") + " " + ((font?["AXVisibleName"] as? String) ?? "")
            runs.append(Run(range: range, size: CGFloat(size), bold: name.localizedCaseInsensitiveContains("bold") || name.localizedCaseInsensitiveContains("black") || name.localizedCaseInsensitiveContains("heavy")))
        }
        return runs
    }

    /// `body`: the document's body size (`PDFKitDocument.bodySize`), not this page's: a page
    /// that is one figure has more label text than anything else.
    /// `headingSizes`: the sizes headings come in on the document's first pages (`PDFKitDocument.headingSizes`).
    /// `running`: the "\n"-lines that are a running header or footer (`edgeLines`, matched across pages).
    init(index: Int, attributed: NSAttributedString, body: CGFloat, headingSizes: Set<CGFloat>, running: [NSRange]) {
        self.index = index
        self.body = body
        self.headingSizes = headingSizes
        text = attributed.string as NSString
        let runs = Self.runs(of: attributed)
        var lines: [Line] = []
        /// A sentence of the page is still open: a caption now interrupts it.
        var waiting = false
        for nl in Self.newlineLines(of: text) {
            let isRunning = running.contains(nl)
            for piece in Self.split(nl, runs: runs, text: text) {
                for part in waiting ? Self.endCaption(piece, text: text) : [piece] {
                    guard let line = Self.line(part, runs: runs, text: text, body: body, running: isRunning) else { continue }
                    lines.append(line)
                    if !line.small, !line.running, !line.isTabular, !Self.startsLikeCaption(line.text), line.words > 2 { waiting = !ReadingSession.endsLikeSentence(line.text) }
                }
            }
        }
        blocks = []
        blocks = Self.group(Self.captionsInOrder(lines), page: index, body: body, headingSizes: headingSizes)
    }

    /// The page's text cut at each "\n", without it.
    private static func newlineLines(of text: NSString) -> [NSRange] {
        var out: [NSRange] = [], at = 0
        while at < text.length {
            let nl = text.range(of: "\n", range: NSRange(location: at, length: text.length - at))
            let end = nl.location == NSNotFound ? text.length : nl.location
            out.append(NSRange(location: at, length: end - at))
            at = end + 1
        }
        return out
    }

    /// The first two and last two "\n"-lines of a page's text that have words (a page number alone
    /// has none), each keyed by its size and its words alone: lower-cased, without digits or
    /// punctuation, so "4 · The Long Way Home" and "The Long Way Home · 6" are one key. A running
    /// header or footer is among them, set alike on every page; a paper's title, which its running
    /// header repeats, is set larger. A caption isn't taken for one: "Figure 2: Accuracy per epoch"
    /// can follow "Figure 1: …".
    static func edgeLines(of attributed: NSAttributedString) -> [(range: NSRange, key: String)] {
        let text = attributed.string as NSString
        var keyed = newlineLines(of: text).compactMap { r -> (range: NSRange, key: String)? in
            let s = text.substring(with: r)
            let words = s.lowercased().split(whereSeparator: { !$0.isLetter }).joined(separator: " ")
            return words.count >= 4 && !startsLikeCaption(s) ? (r, words) : nil
        }
        if keyed.count > 4 { keyed = Array(keyed.prefix(2) + keyed.suffix(2)) }
        let runs = runs(of: attributed)
        return keyed.map { line in
            var weight: [CGFloat: Int] = [:]
            for run in runs where run.size > 0 { weight[(run.size * 2).rounded() / 2, default: 0] += NSIntersectionRange(run.range, line.range).length }
            return (line.range, "\(dominant(weight.filter { $0.value > 0 }) ?? 0) \(line.key)")
        }
    }

    /// PDFKit puts things on one line that aren't: a caption glued to the table rows above it
    /// ("… 95.5 - Table 7: CoNLL-2003 …") or to a figure's labels, and to the text after it
    /// ("… per viewer. reading finishes …"), a heading glued to a figure's title set much larger
    /// ("Attention Visualizations" + "Input-Input Layer5"), a bold run-in heading glued to its
    /// paragraph ("1 Hyphens Some checks…"), a footnote glued to the line above it. Cut at each.
    private static func split(_ range: NSRange, runs: [Run], text: NSString) -> [NSRange] {
        var cuts: [Int] = []
        let s = text.substring(with: range) as NSString
        // A caption start inside the line, unless the sentence names a figure ("as shown in Table 2." is prose).
        for m in captionInside.matches(in: s as String, range: NSRange(location: 0, length: s.length)) {
            let before = s.substring(to: m.range.location)
            if s.substring(with: m.range).hasSuffix(":") ? !refers(before) : !looksLikeProse(before) { cuts.append(range.location + m.range.location + 1) }
        }
        let inLine = runs.compactMap { r -> (run: Run, range: NSRange, chars: Int)? in
            let x = NSIntersectionRange(r.range, range)
            guard x.length > 0 else { return nil }
            return (r, x, text.substring(with: x).unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count)
        }
        var lastLong: CGFloat? // the size of the last run of eight characters or more
        var bold: NSRange? // the bold run this one continues
        for (k, (r, x, chars)) in inLine.enumerated() {
            if k > 0, abs(inLine[k - 1].run.size - r.size) > 2.5, chars >= 8, inLine[k - 1].chars >= 8 { cuts.append(x.location) }
            // A footnote: smaller text that starts like one ("… in Appendix B.1." + "8See (10) in …"), its number a short run before it.
            if chars >= 8, let l = lastLong, l - r.size > 1.5 {
                let at = k > 0 && inLine[k - 1].chars <= 3 ? inLine[k - 1].range.location : x.location
                let rest = text.substring(with: NSRange(location: at, length: NSMaxRange(range) - at))
                if footnoteStart.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) != nil { cuts.append(at) }
            }
            if chars >= 8 { lastLong = r.size }
            // A run-in heading: bold text that starts the line or a sentence, then plain text.
            if r.bold {
                bold = bold.map { NSUnionRange($0, x) } ?? x
            } else if let b = bold {
                bold = nil
                let before = text.substring(with: NSRange(location: range.location, length: b.location - range.location))
                let starts = before.trimmingCharacters(in: .whitespaces).isEmpty || ReadingSession.endsLikeSentence(before)
                if starts, chars >= 8, text.substring(with: b).split(whereSeparator: \.isWhitespace).count <= 12 { cuts += [b.location, NSMaxRange(b)] }
            }
        }
        var out: [NSRange] = []
        var start = range.location
        for cut in cuts.sorted() where cut > start && cut < NSMaxRange(range) {
            out.append(NSRange(location: start, length: cut - start)); start = cut
        }
        out.append(NSRange(location: start, length: NSMaxRange(range) - start))
        return out
    }

    private static let abbreviations: Set<String> = ["e.g", "i.e", "al", "vs", "etc", "cf", "fig", "eq", "resp", "approx", "no"]

    /// A caption that interrupts a sentence ends at the sentence end after which the text goes on
    /// in lower case: that's the sentence going on ("… per viewer. reading finishes the sentence …").
    private static func endCaption(_ range: NSRange, text: NSString) -> [NSRange] {
        let s = text.substring(with: range)
        guard startsLikeCaption(s) else { return [range] }
        let ns = s as NSString
        for m in captionEnd.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(to: m.range.location).split(whereSeparator: \.isWhitespace).last.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "([")) } ?? ""
            guard !abbreviations.contains(word) else { continue }
            let cut = NSMaxRange(m.range)
            return [NSRange(location: range.location, length: cut), NSRange(location: range.location + cut, length: range.length - cut)]
        }
        return [range]
    }

    private static func line(_ range: NSRange, runs: [Run], text: NSString, body: CGFloat, running: Bool) -> Line? {
        let s = text.substring(with: range)
        guard s.unicodeScalars.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
        let inLine = runs.compactMap { r -> (Run, NSRange)? in
            let x = NSIntersectionRange(r.range, range)
            return x.length > 0 ? (r, x) : nil
        }
        var sizeWeight: [CGFloat: Int] = [:], boldChars = 0, chars = 0
        for (r, x) in inLine {
            let n = text.substring(with: x).unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
            sizeWeight[(r.size * 2).rounded() / 2, default: 0] += n
            chars += n
            if r.bold { boldChars += n }
        }
        let size = dominant(sizeWeight) ?? body
        var markers: [NSRange] = [], subscripts: [NSRange] = []
        for (r, x) in inLine where r.size < size - 1.5 {
            let t = text.substring(with: x).trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count <= 8 else { continue }
            if footnoteMarker.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { markers.append(x) } else { subscripts.append(x) }
        }
        let bold = chars > 0 && boldChars * 10 >= chars * 6
        return Line(range: range, size: size, bold: bold, small: size < body - 1.5, running: running, headingLike: bold || size > body + 0.75, markers: markers, subscripts: subscripts, text: s)
    }

    static func startsLikeCaption(_ s: String) -> Bool {
        captionStart.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// A drawn figure's labels, each a line of its own: axis ticks, box names, the words of a heatmap.
    static func isLabelRun(_ lines: [Line]) -> Bool {
        lines.count >= 3 && lines.filter { $0.words <= 2 }.count * 3 >= lines.count * 2
    }

    private static let functionWords: Set<String> = ["the", "a", "an", "of", "and", "to", "in", "is", "are", "was", "were", "that", "this", "for", "with", "as", "on", "by", "we", "it", "its", "our", "or", "be", "from", "which", "at", "not", "le", "la", "les", "de", "des", "et", "un", "une", "est", "que", "qui", "pour", "dans", "sur", "pas"]

    /// Running text, whether or not a sentence ends in it: mostly alphabetic words, several of
    /// them lower-case, with a function word among them. A table row ("Weighted Sum Last Four
    /// Hidden 95.9 -", "train steps PPL BLEU params"), an author line, an equation fragment or a
    /// figure label isn't.
    static func looksLikeProse(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard tokens.count >= 5 else { return false }
        let alphabetic = tokens.filter { t in let letters = t.filter(\.isLetter); return letters.count >= 2 && letters.count * 10 >= t.count * 8 }
        let lowercase = alphabetic.filter { $0.first(where: \.isLetter)?.isLowercase ?? false }
        return alphabetic.count * 10 >= tokens.count * 6 && lowercase.count >= 3
            && tokens.contains { functionWords.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
    }

    /// Lines of one kind join into a block until one ends like a sentence; a caption or a page
    /// number starts its own; heading lines stand alone unless one wraps onto the next.
    private static func group(_ lines: [Line], page: Int, body: CGFloat, headingSizes: Set<CGFloat>) -> [Block] {
        var groups: [[Line]] = []
        var group: [Line] = []
        func flush() {
            if !group.isEmpty { groups.append(group) }
            group = []
        }
        for line in lines {
            if let prev = group.last {
                // A caption is read whole: it takes lines of its own size only (a figure's labels are set a half
                // point smaller), and a line ending in a colon runs on ("… anaphora resolution. Top:" / "Full
                // attentions for head 5."). In the body, what a colon introduces is a block of its own (an
                // equation, a list).
                let caption = startsLikeCaption(group[0].text)
                let same = prev.small == line.small && prev.running == line.running && prev.bold == line.bold && abs(prev.size - line.size) <= (caption ? 0.25 : 0.6) && prev.isTabular == line.isTabular
                let ends = ReadingSession.endsLikeSentence(prev.text) && !(caption && prev.text.trimmingCharacters(in: .whitespaces).hasSuffix(":"))
                var joins = same && !ends && (!startsLikeCaption(line.text) || refers(prev.text)) && !prev.isNumber && !line.isNumber && !line.isListItem
                if joins, line.headingLike, !wraps(prev.text, onto: line.text) { joins = false }
                if !joins { flush() }
            }
            group.append(line)
        }
        flush()
        var blocks: [Block] = []
        for (i, g) in groups.enumerated() {
            let last = groups[(i + 1)...].allSatisfy { $0[0].isNumber }
            blocks.append(Block(id: BlockID(page: page, index: i), kind: classify(g, body: body, last: last), lines: g))
        }
        // A drawn figure's title looks like a heading, set large. It isn't one when the same text heads
        // another block of the page (two heatmaps, one title each), or when the page has figure text and
        // no heading of the document's first pages is set at its size.
        if blocks.contains(where: \.isFigureText) || blocks.filter({ $0.kind == .heading }).count > 1 {
            let texts = blocks.filter { $0.kind == .heading }.map { $0.lines.map(\.text).joined(separator: " ") }
            for i in blocks.indices where blocks[i].kind == .heading {
                let text = blocks[i].lines.map(\.text).joined(separator: " ")
                let repeats = texts.filter { $0 == text }.count > 1
                let oddSize = blocks.contains(where: \.isFigureText) && !headingSizes.isEmpty && !headingSizes.contains(blocks[i].lines[0].size)
                if repeats || oddSize { blocks[i] = Block(id: blocks[i].id, kind: .furniture, lines: blocks[i].lines) }
            }
        }
        // A heatmap's labels laid out in a row ("The Law will never be , but its be just") read like
        // prose, but every word is one of the figure's labels.
        let labels = Set(blocks.filter(\.isFigureText).flatMap { $0.lines.flatMap { Self.letterWords($0.text) } })
        if !labels.isEmpty {
            for i in blocks.indices where blocks[i].kind == .paragraph && !blocks[i].endsLikeSentence {
                let words = blocks[i].lines.flatMap { Self.letterWords($0.text) }
                if !words.isEmpty, words.allSatisfy(labels.contains) { blocks[i] = Block(id: blocks[i].id, kind: .furniture, lines: blocks[i].lines, labels: true) }
            }
        }
        return blocks
    }

    private static func letterWords(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// `last`: the block is the page's last, or only page numbers follow it (a footer).
    private static func classify(_ lines: [Line], body: CGFloat, last: Bool) -> Kind {
        let text = lines.map(\.text).joined(separator: " ")
        let words = text.split(whereSeparator: \.isWhitespace).count
        if lines[0].running || isLabelRun(lines) || lines.filter(\.isTabular).count * 2 > lines.count { return .furniture }
        if startsLikeCaption(text) { return lines[0].size >= body - 2.5 ? .caption(text.hasPrefix("Tab") ? "table" : "figure") : .furniture }
        if lines[0].small || lines[0].isNumber { return .furniture }
        // An author grid (names, affiliations, emails), arXiv's stamp down the margin.
        if text.contains("@") && !ReadingSession.endsLikeSentence(text) || text.hasPrefix("arXiv:") { return .furniture }
        // A footnote ("3In all cases…", "∗Equal contribution.") or a footer, set a little smaller than the body.
        if lines[0].size < body - 0.5, footnoteStart.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil || (last && lines.count == 1) { return .furniture }
        let headingLike = lines[0].headingLike
        if headingLike, words <= 15, !ReadingSession.endsLikeSentence(text) { return .heading }
        let ends = sentenceEnd.firstMatch(in: text + " ", range: NSRange(location: 0, length: (text as NSString).length + 1)) != nil
        if words >= 2, ends || ReadingSession.endsLikeSentence(text) { return .paragraph }
        // No sentence ends in it, but it reads like one: a paragraph's first sentence cut by a column or page end.
        if looksLikeProse(text) { return .paragraph }
        // A list item set like the body ("• Batch size: 16, 32").
        if lines[0].isListItem, words >= 3 { return .paragraph }
        if headingLike, words <= 15 { return .heading }
        return .furniture
    }

    /// On a page that is one figure, PDFKit can list its caption's lines bottom first: the last
    /// line, ending the caption, then the ones above it, then the caption's start. A run of lines
    /// that start in lower case, the first ending a sentence, before a caption start that doesn't,
    /// with nothing but page furniture above it, is that, and is put back after the start.
    private static func captionsInOrder(_ lines: [Line]) -> [Line] {
        var lines = lines
        for k in lines.indices where startsLikeCaption(lines[k].text) && !ReadingSession.endsLikeSentence(lines[k].text) {
            var j = k
            while j > 0, lines[j - 1].startsLowercase, abs(lines[j - 1].size - lines[k].size) <= 0.25 { j -= 1 }
            guard j < k, ReadingSession.endsLikeSentence(lines[j].text), lines[..<j].allSatisfy({ $0.isNumber || $0.small }) else { continue }
            lines[j...k] = [lines[k]] + lines[j..<k].reversed()
        }
        return lines
    }

    /// A line that ends where a figure or table is named: the "Table 1." on the next line is the
    /// sentence going on ("Results are presented in" / "Table 1. Both…", the link ending the line), not a caption.
    private static func refers(_ prev: String) -> Bool {
        guard !ReadingSession.endsLikeSentence(prev), let last = prev.lowercased().split(whereSeparator: \.isWhitespace).last else { return false }
        return ["in", "see", "of", "and", "to", "from", "with", "by", "on", "as", "cf.", "per", "the"].contains(String(last))
    }

    /// A heading line that runs on: it ends in a connector, or the next line starts in lower case.
    private static func wraps(_ prev: String, onto next: String) -> Bool {
        if let first = next.first(where: { !$0.isWhitespace }), first.isLowercase { return true }
        let words = prev.lowercased().split(whereSeparator: \.isWhitespace)
        guard let lastWord = words.last else { return false }
        if let c = lastWord.last, ":,-–".contains(c) { return true }
        return ["a", "an", "the", "of", "for", "and", "or", "in", "on", "with", "to", "from", "by", "via", "at", "as", "into", "over", "under", "without", "between", "through", "toward", "towards", "versus", "vs."].contains(String(lastWord))
    }

    // MARK: Order

    /// Whether the text's order may not be the page's: a block that starts in lower case is a
    /// continuation, and PDFKit has given a figure page's caption last line first.
    var mayBeOutOfOrder: Bool {
        blocks.contains { $0.kind != .furniture && $0.lines[0].startsLowercase }
    }

    /// Puts lines back in the page's order where the text's order isn't (#86: on a page that is
    /// one figure, PDFKit lists the caption's lines bottom first). Around each block that starts
    /// in lower case, the lines of the nearby readable blocks that sit in one column are sorted by
    /// their position and grouped again; nothing changes where the text was already in order.
    /// Blocks up to `used` are in use (read, or a reading's position is in them) and stay as they
    /// are. Returns false if some lines had no frame (Preview, on a page out of view): it's worth
    /// doing again once the page has them.
    @discardableResult
    func reorder(after used: Int = -1, frame: (Line) -> CGRect?) -> Bool {
        var complete = true
        var i = used + 1
        while i < blocks.count {
            defer { i += 1 }
            guard blocks[i].kind != .furniture, blocks[i].lines[0].startsLowercase else { continue }
            let window = (max(used + 1, i - 3)...min(blocks.count - 1, i + 3)).filter { blocks[$0].kind != .furniture }
            let placed = window.flatMap { blocks[$0].lines }.compactMap { line in frame(line).map { (line: line, frame: $0) } }
            guard placed.count == window.reduce(0, { $0 + blocks[$1].lines.count }) else { complete = false; continue }
            guard let left = placed.map(\.frame.minX).min(), placed.allSatisfy({ $0.frame.minX - left < 24 }) else { continue }
            let sorted = placed.sorted { $0.frame.minY < $1.frame.minY }
            guard sorted.map(\.line.range.location) != placed.map(\.line.range.location) else { continue }
            let regrouped = Self.group(sorted.map(\.line), page: index, body: body, headingSizes: headingSizes)
            var out: [Block] = []
            for (k, b) in blocks.enumerated() where !window.contains(k) { out.append(b) }
            out.insert(contentsOf: regrouped, at: window[0])
            blocks = out.enumerated().map { k, b in Block(id: BlockID(page: index, index: k), kind: b.kind, lines: b.lines, labels: b.labels) }
            i = window[0] + regrouped.count - 1
        }
        return complete
    }

    var hasFigure: Bool {
        blocks.contains { b in
            if case .caption = b.kind { return true }
            return b.isFigureText
        }
    }

    /// A figure's labels stacked a word or two a line read like a paragraph, since PDFKit joins
    /// them into one line of the page's text ("The reader keeps its place on the"); the leaves'
    /// line ends (`wraps`) show the stack.
    func markLabelStacks(wraps: Set<Int>) {
        for i in blocks.indices where blocks[i].kind == .paragraph && !blocks[i].endsLikeSentence {
            var perLine: [Int] = [], words = 0, inWord = false
            for line in blocks[i].lines {
                for o in line.range.location..<NSMaxRange(line.range) {
                    let space = Unicode.Scalar(text.character(at: o)).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
                    if !space, !inWord { words += 1 }
                    inWord = !space
                    if wraps.contains(o) { perLine.append(words); words = 0; inWord = false }
                }
            }
            if words > 0 { perLine.append(words) }
            if perLine.count >= 3, perLine.filter({ $0 <= 2 }).count * 3 >= perLine.count * 2 {
                blocks[i] = Block(id: blocks[i].id, kind: .furniture, lines: blocks[i].lines, labels: true)
            }
        }
    }

    // MARK: References

    /// Marks the blocks in the reference list, given whether it was open when the page started.
    func resolveReferences(openAtStart: Bool) {
        var open = openAtStart
        defer { referencesAtEnd = open }
        for b in blocks {
            if b.kind == .heading { open = b.isReferencesHeading }
            if case .caption = b.kind { open = false } // a figure after the references (an appendix of plots) isn't one
            b.inReferences = open
        }
    }

    func block(containing offset: Int) -> Block? {
        blocks.first { $0.contains(offset) } ?? blocks.first { b in b.lines.contains { $0.range.location > offset } }
    }
}
