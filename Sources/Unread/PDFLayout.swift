import AppKit
import NaturalLanguage

/// A place in a Chromium PDF: a UTF-16 offset into the run of paragraphs (a flow) that starts at `block`.
/// `walked`: reached by reading on, not by pointing, so what isn't read there is passed over.
/// `cued`: a caption whose figure cue has been given.
final class PDFPosition: NSObject {
    let block: PDFLayout.BlockID
    let offset: Int
    let walked: Bool
    let cued: Bool
    init(_ block: PDFLayout.BlockID, offset: Int = 0, walked: Bool, cued: Bool = false) {
        self.block = block
        self.offset = offset
        self.walked = walked
        self.cued = cued
    }
    var key: String { "\(block.page).\(block.index)+\(offset)\(walked ? "w" : "")\(cued ? "c" : "")" }
    // By value, like a text marker: a hold's speculation is matched to its release with CFEqual.
    override func isEqual(_ object: Any?) -> Bool { (object as? PDFPosition)?.key == key }
    override var hash: Int { key.hashValue }
}

/// One of PDFium's paragraph blocks, as text and geometry: all the reading needs (#85).
struct PDFBlock {
    /// PDFium's text: line ends are "\r\n", a hyphen at a line end is U+0002.
    let raw: String
    /// Its text's box, from text markers: unlike element frames, not clipped to the viewer's scroller.
    var bounds: CGRect? = nil
    /// PDFium made it an `AXHeading` (a guess from its font size, often wrong).
    var headingRole = false
    /// The font size most of its characters are set in. Exact in TeX's PDFs, a step or two off in others.
    var fontSize: CGFloat? = nil
}

/// How Chromium's PDF viewer is read, from its blocks' text and boxes alone: what each block is, which blocks
/// one paragraph runs across (columns, pages), and the sentences and cues a reading gives, in order. No
/// Accessibility here: `PDFiumDocument` gives it the pages and turns its readings into text-marker ranges,
/// and `--pdf-check` gives it a table.
final class PDFLayout {
    struct BlockID: Hashable { let page: Int; let index: Int }

    /// What a block is to a listener.
    enum Kind: Equatable {
        case paragraph, heading, other
        /// Starts with "Figure 3:" or "Table 2.": read after a cue for what it captions.
        case caption(String)
        /// Text inside a figure or table ("E[CLS] E1", a table's rows): the cue stands for it.
        case label(String)
        case footnote, furniture
        /// "References": reading on ends here.
        case references
        var skippedInFlow: Bool {
            switch self { case .furniture, .footnote, .label, .caption: true; default: false }
        }
    }

    /// What reading from a position gives next.
    enum Reading {
        /// A sentence, said as `text`, and its part in each block it runs across (a range of that block's text).
        case sentence(text: String, parts: [(block: BlockID, range: NSRange)], next: PDFPosition)
        /// A cue for a figure's labels, a table's rows, or before a caption, over these blocks.
        case cue(String, blocks: [BlockID], next: PDFPosition)
    }

    /// The most blocks one flow joins; a longer chain of continuations starts a new flow every this many.
    static let maxParts = 8

    private let pageCount: () -> Int
    private let source: (Int) -> [PDFBlock]?
    private let debug: Bool

    /// `page` gives a page's blocks, or nil if it isn't there (yet: PDFium builds pages one at a time).
    init(pageCount: @escaping () -> Int, page: @escaping (Int) -> [PDFBlock]?, debug: Bool = false) {
        self.pageCount = pageCount
        source = page
        self.debug = debug
    }

    private final class Block {
        let id: BlockID
        let input: PDFBlock
        let raw: NSString
        /// One line, trimmed, U+0002 shown as "-".
        let flat: String
        let lines: Int, words: Int
        /// The most words on one of its lines.
        let lineWords: Int
        /// Holds a sentence of three words or more.
        let reads: Bool
        var kind: Kind = .other
        var bounds: CGRect? { input.bounds }
        /// Where its own text starts in `input.raw`: past a running header PDFium put in the same group.
        let skip: Int
        init(id: BlockID, input: PDFBlock, skip: Int = 0) {
            self.id = id
            self.input = input
            self.skip = skip
            raw = (input.raw as NSString).substring(from: skip) as NSString
            let text = (raw as String).replacingOccurrences(of: "\u{02}", with: "-")
            flat = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            func count(_ s: some StringProtocol) -> Int {
                s.split(whereSeparator: \.isWhitespace).filter { $0.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) }.count
            }
            words = count(flat)
            lineWords = text.components(separatedBy: "\n").map(count).max() ?? 0
            let unmarked = PDFLayout.withoutMarkers(text) // "…a wide margin.12" ends a sentence
            reads = words >= 3 && PDFLayout.matches(PDFLayout.sentenceEnd, unmarked)
        }
    }

    private var pages: [Int: [Block]] = [:]
    private var classified: Set<Int> = []
    /// Page 1's blocks before its first paragraph: the title, authors, affiliations, "Abstract".
    private var titleEnd = 0
    /// Words the loaded pages spell whole, for line-end hyphens.
    private var vocabulary: Set<String> = []

    // MARK: Pages that aren't there yet

    /// Set when a page the PDF has wasn't built yet: what was worked out without it isn't remembered.
    private var missing = false

    private func tracking<T>(_ body: () -> T) -> (value: T, complete: Bool) {
        let outer = missing
        missing = false
        let value = body()
        let complete = !missing
        missing = outer || missing
        return (value, complete)
    }

    private func blocks(_ page: Int) -> [Block]? {
        if let known = pages[page] { return known }
        guard page >= 0, let input = source(page) else {
            if page >= 0, page < pageCount() { missing = true }
            return nil
        }
        let made = input.enumerated().map { Block(id: BlockID(page: page, index: $0), input: $1) }
        for b in made {
            for w in b.input.raw.split(whereSeparator: \.isWhitespace) where !w.contains("\u{02}") {
                vocabulary.insert(String(w).lowercased().trimmingCharacters(in: .punctuationCharacters))
            }
        }
        pages[page] = made
        return made
    }

    private func block(_ id: BlockID) -> Block? {
        let page = classifiedBlocks(id.page)
        return id.index >= 0 && id.index < page.count ? page[id.index] : nil
    }

    private func after(_ id: BlockID) -> BlockID? {
        if id.index + 1 < (blocks(id.page)?.count ?? 0) { return BlockID(page: id.page, index: id.index + 1) }
        var page = id.page + 1
        while page < pageCount() {
            if blocks(page)?.isEmpty == false { return BlockID(page: page, index: 0) }
            page += 1
        }
        return nil
    }

    private func before(_ id: BlockID) -> BlockID? {
        if id.index > 0 { return BlockID(page: id.page, index: id.index - 1) }
        var page = id.page - 1
        while page >= 0 {
            if let n = blocks(page)?.count, n > 0 { return BlockID(page: page, index: n - 1) }
            page -= 1
        }
        return nil
    }

    func kind(_ id: BlockID) -> Kind? { block(id)?.kind }
    func kinds(onPage page: Int) -> [Kind] { classifiedBlocks(page).map(\.kind) }

    // MARK: What each block is

    static let sentenceEnd = try! NSRegularExpression(pattern: #"[\p{L}\p{N})\]"'”’][.!?…]+["'”’)\]]*(\s|$)"#)
    /// A page number: digits, or a roman numeral all in one case ("iv", "XII"; not "Civil", "ill").
    private static let pageNumber = try! NSRegularExpression(
        pattern: #"^(\d{1,4}|(?=[ivxlc])c{0,3}(xc|xl|l?x{0,3})(ix|iv|v?i{0,3})|(?=[IVXLC])C{0,3}(XC|XL|L?X{0,3})(IX|IV|V?I{0,3}))$"#)
    /// A footnote's marker: a number raised onto a line of its own or against its first word ("5The"), or a
    /// symbol. Not enough alone ("§ 3. Every resident…", "4GB of storage…"): `classifiedBlocks` wants it below
    /// its page's paragraphs, or in a smaller font.
    private static let footnote = try! NSRegularExpression(pattern: #"^(\d{1,2}[ \t]*[\r\n]|\d{1,2}\p{Lu}\p{L}|[*∗†‡§¶])"#)
    private static let caption = try! NSRegularExpression(pattern: #"^(Figure|Fig\.|Table)\s*\d+[.:]"#)
    private static let references = try! NSRegularExpression(
        pattern: #"^(\d+\.?\s+)?(References|Bibliography|Works Cited|Références|Bibliographie)$"#, options: .caseInsensitive)
    private static let numberedSection = try! NSRegularExpression(pattern: #"^(\d+(\.\d+)*\.?|[A-Z](\.\d+)+)\s+\p{Lu}"#)

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// A short block's text without the page number before or after it, to find a running header.
    private static func plain(_ s: String) -> String {
        var words = s.split(separator: " ")
        while let w = words.first, w.allSatisfy(\.isNumber) { words.removeFirst() }
        while let w = words.last, w.allSatisfy(\.isNumber) { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// Short blocks on the neighbouring pages: a running header repeats on one of them. The first page has none.
    private func neighbours(of page: Int) -> Set<String> {
        guard page > 0 else { return [] }
        var out: Set<String> = []
        for p in [page - 1, page + 1] {
            guard let all = blocks(p) else { continue }
            out.formUnion(all.filter { $0.lines <= 2 }.map { Self.plain($0.flat) })
            if let first = all.first.flatMap({ Self.firstLine($0.input.raw) }) { out.insert(Self.plain(first.text)) }
        }
        return out
    }

    /// A block's first line, when more follows it: the text and its length with its line end.
    private static func firstLine(_ raw: String) -> (text: String, length: Int)? {
        let ns = raw as NSString
        let end = ns.range(of: "\n")
        guard end.location != NSNotFound, NSMaxRange(end) < ns.length else { return nil }
        let text = ns.substring(to: end.location).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return (text, NSMaxRange(end))
    }

    /// On a one-column page PDFium can put the running header in the same group as the text under it ("A Report
    /// on the Town Archive\r\nthe archive should keep both…"): the length of that first line, if it's one.
    private func headerLength(_ b: Block, neighbours: Set<String>) -> Int? {
        guard b.id.index == 0, b.skip == 0, let first = Self.firstLine(b.input.raw) else { return nil }
        let text = Self.plain(first.text)
        return text.count >= 8 && neighbours.contains(text) ? first.length : nil
    }

    /// A page number, an empty block, arXiv's stamp in the margin, or a running header: text repeated on a
    /// neighbouring page.
    private func pageFurniture(_ b: Block, neighbours: Set<String>) -> Bool {
        let rotated = b.bounds.map { $0.height > 3 * $0.width && $0.height > 60 } ?? false
        if b.flat.isEmpty || Self.matches(Self.pageNumber, b.flat) || rotated { return true }
        // Not text in lower case: the end of a sentence carried over from the last page ("traffic since the
        // spring floods."), which a document that repeats itself can have on the next page too.
        return b.lines <= 2 && Self.plain(b.flat).count >= 8 && b.flat.first?.isLowercase != true && neighbours.contains(Self.plain(b.flat))
    }

    /// The font a page's paragraphs are set in, if every one of three lines or more agrees: TeX's PDFs report
    /// exact sizes, others (Quartz's) sizes a step or two off block by block (the fixtures' 10-point text comes
    /// out 9.3 and 10.7, their 8-point footer 10.7), and then fonts don't decide anything.
    private func bodyFont(_ all: [Block]) -> CGFloat? {
        let sizes = all.filter { $0.kind == .paragraph && $0.lines >= 3 }.compactMap(\.input.fontSize).sorted()
        guard let median = sizes.isEmpty ? nil : sizes[sizes.count / 2], sizes.allSatisfy({ abs($0 - median) <= median * 0.05 }) else { return nil }
        return median
    }

    private func classifiedBlocks(_ page: Int) -> [Block] {
        guard let all = blocks(page), !all.isEmpty else { return [] }
        if classified.contains(page) { return all }
        let (_, complete) = tracking { () -> Void in
            var all = all
            if let n = headerLength(all[0], neighbours: neighbours(of: page)) {
                all[0] = Block(id: all[0].id, input: all[0].input, skip: n)
                pages[page] = all
            }
            classify(all, page: page)
        }
        if complete { classified.insert(page) }
        return pages[page] ?? all
    }

    private func classify(_ all: [Block], page: Int) {
        let neighbours = neighbours(of: page)
        func base(_ b: Block, footnote: Bool) -> Kind {
            if pageFurniture(b, neighbours: neighbours) { return .furniture }
            if footnote, Self.matches(Self.footnote, (b.raw as String).trimmingCharacters(in: .whitespacesAndNewlines)) { return .footnote }
            if Self.matches(Self.caption, b.flat) { return .caption(b.flat.hasPrefix("Table") ? "table" : "figure") }
            if Self.matches(Self.references, b.flat) { return .references }
            return b.reads ? .paragraph : b.lines == 1 && b.words <= 14 ? .heading : .other
        }
        for b in all { b.kind = base(b, footnote: true) }
        // A footnote has its marker and is set smaller than the page's paragraphs when its fonts can be trusted;
        // else it sits below the paragraphs of its column, in the page's lower half. A paragraph that starts with
        // "§ 3." or "4GB" has neither.
        let body = all.filter { $0.kind == .paragraph }
        let font = bodyFont(all)
        let boxes = all.compactMap(\.bounds)
        func belowBody(_ b: Block) -> Bool {
            guard let r = b.bounds, let top = boxes.map(\.minY).min(), let bottom = boxes.map(\.maxY).max() else {
                return !all[(b.id.index + 1)...].contains { $0.kind == .paragraph }
            }
            return r.minY >= (top + bottom) / 2
                && !body.contains { p in p.bounds.map { $0.minY > r.minY && $0.maxX > r.minX && $0.minX < r.maxX } ?? false }
        }
        for b in all where b.kind == .footnote {
            let smaller = font.flatMap { f in b.input.fontSize.map { $0 < f * 0.95 } }
            if !(smaller ?? belowBody(b)) { b.kind = base(b, footnote: false) }
        }
        // A footnote can run on into the next block, as a paragraph does.
        var previous: Block?
        for b in all where b.kind != .furniture {
            if let p = previous, p.kind == .footnote, unfinished(p), b.flat.first?.isLowercase == true { b.kind = .footnote }
            previous = b
        }
        // A footer (proceedings, copyright) sits below the page's text, in its last lines, and isn't set like it:
        // away from where its paragraphs start (centered, or under one column), or in a smaller font when the
        // page's fonts can be trusted. The last lines of a page are often text too: the first lines of a
        // paragraph the next page carries on, a heading and the first lines of its section, a short paragraph.
        let paragraphs = all.filter { $0.kind == .paragraph }
        let bodyBoxes = all.filter { $0.kind == .paragraph && $0.lines >= 3 }.compactMap(\.bounds)
        func setLikeText(_ b: Block) -> Bool {
            if let f = font, let size = b.input.fontSize, size < f * 0.95 { return false }
            guard let x = b.bounds?.minX else { return true }
            let indent = 2.5 * (b.input.fontSize ?? 12)
            return paragraphs.contains { p in p !== b && p.bounds.map { x >= $0.minX - 3 && x <= $0.minX + indent } ?? false }
        }
        if let bodyBottom = bodyBoxes.map(\.maxY).max(), let top = boxes.map(\.minY).min(), let bottom = boxes.map(\.maxY).max() {
            for b in all {
                if [.paragraph, .heading, .other].contains(b.kind), b.lines <= 2, let r = b.bounds, r.minY >= bodyBottom,
                   r.minY >= top + 0.85 * (bottom - top), !setLikeText(b) { b.kind = .furniture }
            }
        }
        // A line that stops mid-sentence isn't a heading when the text after it carries it on in lower case: it's
        // a paragraph's first line, at the foot of a page or a column.
        for (i, b) in all.enumerated() where b.kind == .heading && unfinished(b) && carriedOnInLowerCase(after: i, in: all) { b.kind = .other }
        // A figure's labels come right before its caption; a table's rows (mostly numbers) before or after its
        // caption. A section title isn't one: numbered, or a line set where the page's paragraphs start and no
        // smaller than them ("Results" above a picture with no text in it).
        let lefts = paragraphs.filter { $0.kind == .paragraph }.compactMap { $0.bounds?.minX }
        func title(_ b: Block) -> Bool {
            if Self.matches(Self.numberedSection, b.flat) { return true }
            guard b.kind == .heading, let x = b.bounds?.minX, lefts.contains(where: { abs($0 - x) <= 3 }) else { return false }
            return !(font.flatMap { f in b.input.fontSize.map { $0 < f * 0.95 } } ?? false)
        }
        func labelish(_ b: Block) -> Bool {
            let tokens = b.flat.split(separator: " ")
            let numbers = tokens.filter { t in t.contains(where: \.isNumber) || t.allSatisfy { "-–—".contains($0) } }.count
            let tabular = tokens.count >= 6 && numbers * 5 >= tokens.count * 2
            return ([.heading, .other, .furniture].contains(b.kind) || tabular) && !title(b)
        }
        for (i, b) in all.enumerated() {
            guard case .caption(let what) = b.kind else { continue }
            var j = i - 1
            while j >= 0, labelish(all[j]) { if all[j].kind != .furniture { all[j].kind = .label(what) }; j -= 1 }
            if what == "table" {
                j = i + 1
                while j < all.count, labelish(all[j]) { if all[j].kind != .furniture { all[j].kind = .label(what) }; j += 1 }
            }
        }
        if page == 0 {
            // Before the first paragraph, only the title, headings ("Abstract") and sentences are read: authors,
            // affiliations and addresses are short lines of names ("Aidan N. Gomez … aidan@cs.toronto.edu" reads as
            // a sentence). A title slide's bullets are longer lines.
            let address = { (b: Block) in b.flat.contains("@") }
            titleEnd = all.firstIndex { $0.kind == .paragraph && $0.words >= 6 && !address($0) } ?? 0
            for b in all[..<titleEnd] where (b.kind == .other && b.lineWords <= 6) || address(b) { b.kind = .furniture }
        }
        if debug {
            for b in all {
                let at = b.bounds.map { "y=\(Int($0.minY))-\(Int($0.maxY)) x=\(Int($0.minX))" } ?? "-"
                print("    pdf block \(page).\(b.id.index) \(b.kind) \(at) lines=\(b.lines) font=\(b.input.fontSize.map { "\($0)" } ?? "-")/\(font.map { "\($0)" } ?? "-") \(b.flat.prefix(60).debugDescription)")
            }
        }
    }

    /// The text after block `i`, past footnotes, captions, the page's foot and the next page's header, starts in
    /// lower case.
    private func carriedOnInLowerCase(after i: Int, in all: [Block]) -> Bool {
        var text: String?
        if let b = all[(i + 1)...].first(where: { ![.furniture, .footnote].contains($0.kind) && !Self.matches(Self.caption, $0.flat) }) {
            text = b.flat
        } else if let next = blocks(all[i].id.page + 1) {
            let around = neighbours(of: all[i].id.page + 1)
            if let first = next.first(where: { !pageFurniture($0, neighbours: around) }) {
                text = headerLength(first, neighbours: around).map { (first.input.raw as NSString).substring(from: $0) } ?? first.flat
            }
        }
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.first.map(CharacterSet.lowercaseLetters.contains) ?? false
    }

    // MARK: Paragraphs across columns and pages

    private static let terminal = CharacterSet(charactersIn: ".!?…:;")
    private static let closing = CharacterSet(charactersIn: "\"'”’)]")

    /// A block whose text stops mid-sentence: no closing punctuation, or a line-end hyphen.
    private func unfinished(_ b: Block) -> Bool {
        let text = Self.withoutMarkers(b.raw as String).trimmingCharacters(in: .whitespacesAndNewlines)
        guard var last = text.unicodeScalars.last else { return false }
        if last == "\u{02}" { return true }
        var scalars = Array(text.unicodeScalars)
        while let l = scalars.last, Self.closing.contains(l) { scalars.removeLast(); last = scalars.last ?? l }
        return !Self.terminal.contains(last)
    }

    private var continuationMemo: [BlockID: BlockID?] = [:]
    private var carriedMemo: [BlockID: BlockID?] = [:]
    private var indexMemo: [BlockID: Int] = [:]

    /// The block that carries on `a`'s last sentence: the next one, past footnotes, figures, captions, page numbers,
    /// footers and headers, if it starts in lower case. In the title, two heading lines in a row are one title.
    private func continuation(of a: Block) -> Block? {
        if let known = continuationMemo[a.id] { return known.flatMap(block) }
        let (found, complete) = tracking { () -> Block? in
            let inTitle = a.id.page == 0 && a.id.index < titleEnd
            guard unfinished(a), a.kind == .paragraph || a.kind == .other || (a.kind == .heading && inTitle) else { return nil }
            var id = after(a.id), skipped = 0
            while let i = id, let b = block(i), skipped < 80 {
                if b.kind.skippedInFlow { id = after(i); skipped += 1; continue }
                guard [.paragraph, .other, .heading].contains(b.kind), let first = b.flat.unicodeScalars.first else { return nil }
                let title = inTitle && skipped == 0 && a.input.headingRole && b.input.headingRole && b.id.index < titleEnd
                return CharacterSet.lowercaseLetters.contains(first) || title ? b : nil
            }
            return nil
        }
        if complete { continuationMemo[a.id] = .some(found?.id) }
        return found
    }

    /// The block whose last sentence `b` carries on, if any.
    private func carried(_ b: Block) -> Block? {
        if let known = carriedMemo[b.id] { return known.flatMap(block) }
        let (found, complete) = tracking { () -> Block? in
            var id = before(b.id), skipped = 0
            while let i = id, let a = block(i), skipped < 80 {
                if a.kind.skippedInFlow { id = before(i); skipped += 1; continue }
                return continuation(of: a) === b ? a : nil
            }
            return nil
        }
        if complete { carriedMemo[b.id] = .some(found?.id) }
        return found
    }

    /// How far into its chain of continuations `b` is: 0 for a block that carries nothing on.
    private func chainIndex(_ b: Block) -> Int {
        var chain: [Block] = [], base = 0
        let (_, complete) = tracking {
            var cur: Block? = b
            while let c = cur {
                if let known = indexMemo[c.id] { base = known + 1; break }
                chain.append(c)
                cur = carried(c)
            }
        }
        let last = base + chain.count - 1
        if complete { for (k, c) in chain.enumerated() { indexMemo[c.id] = last - k } }
        return last
    }

    /// The block whose flow `b` is part of: itself, or the one it carries on. A chain of more than `maxParts`
    /// blocks is cut into flows of that many, so walking on and pointing agree on where each starts.
    private func head(of b: Block) -> Block {
        var head = b, i = chainIndex(b)
        while i % Self.maxParts != 0, let a = carried(head) { head = a; i -= 1 }
        return head
    }

    /// A paragraph and the blocks it runs on into, as one text.
    private struct Flow {
        let blocks: [Block]
        /// Where each block's text starts in `raw` (a space may sit between two).
        let starts: [Int]
        let raw: NSString
        /// `raw` as it's said: the same length, with hyphens at block ends marked.
        let said: NSString
        /// Each sentence's visible span in `raw`.
        let spans: [NSRange]
        let language: String
    }

    private var flowMemo: [BlockID: Flow] = [:]
    /// A list item's mark at a line's start: each one starts a sentence.
    private static let bullets = CharacterSet(charactersIn: "•◦▪▫‣●○■□➢►")

    private func flow(from head: Block) -> Flow {
        if let known = flowMemo[head.id] { return known }
        let (f, complete) = tracking { makeFlow(from: head) }
        if complete { flowMemo[head.id] = f }
        return f
    }

    private func makeFlow(from head: Block) -> Flow {
        var parts = [head]
        while parts.count < Self.maxParts, let next = continuation(of: parts.last!) { parts.append(next) }
        var raw = "", starts: [Int] = []
        for b in parts {
            if let last = raw.unicodeScalars.last, !CharacterSet.whitespacesAndNewlines.contains(last), last != "\u{02}" { raw += " " }
            starts.append((raw as NSString).length)
            raw += b.raw as String
        }
        let ns = raw as NSString
        // What's said: a block that ends in a hyphen carries it on as a line-end hyphen (PDFium marks only those
        // inside a block with U+0002), with nothing between it and the next block (U+0001, dropped when said).
        let said = NSMutableString(string: raw)
        for i in 0..<(parts.count - 1) {
            let last = said.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, options: .backwards,
                                             range: NSRange(location: starts[i], length: parts[i].raw.length))
            guard last.location != NSNotFound, last.location > starts[i], [0x2D, 0x02].contains(said.character(at: last.location)),
                  CharacterSet.letters.contains(UnicodeScalar(said.character(at: last.location - 1)) ?? " ") else { continue }
            said.replaceCharacters(in: last, with: "\u{02}")
            let gap = NSRange(location: NSMaxRange(last), length: starts[i + 1] - NSMaxRange(last))
            said.replaceCharacters(in: gap, with: String(repeating: "\u{01}", count: gap.length))
        }
        // Tokenized with line ends as spaces, line-end hyphens as hyphens, footnote markers and bullets blanked:
        // the same length. Each bullet starts a piece of its own.
        let tokenized = NSMutableString(string: raw)
        var pieces = [0]
        var lineStart = true
        for i in 0..<tokenized.length {
            let c = tokenized.character(at: i)
            switch c {
            case 0x0D, 0x0A, 0x09: tokenized.replaceCharacters(in: NSRange(location: i, length: 1), with: " ")
            case 0x02: tokenized.replaceCharacters(in: NSRange(location: i, length: 1), with: "-")
            default:
                if lineStart, let u = UnicodeScalar(c), Self.bullets.contains(u) {
                    tokenized.replaceCharacters(in: NSRange(location: i, length: 1), with: " ")
                    if i > 0 { pieces.append(i) }
                }
            }
            if c == 0x0A { lineStart = true } else if !(c == 0x20 || c == 0x0D || c == 0x09) { lineStart = false }
        }
        pieces.append(tokenized.length)
        for m in Self.markerRanges(raw) { tokenized.replaceCharacters(in: m, with: String(repeating: " ", count: m.length)) }
        let text = tokenized as String
        var spans: [NSRange] = []
        func visible(_ r: NSRange) -> NSRange? {
            var lo = r.location, hi = NSMaxRange(r)
            while lo < hi, let c = UnicodeScalar(tokenized.character(at: lo)), WebDocument.blank.contains(c) { lo += 1 }
            while hi > lo, let c = UnicodeScalar(tokenized.character(at: hi - 1)), WebDocument.blank.contains(c) { hi -= 1 }
            return hi > lo ? NSRange(location: lo, length: hi - lo) : nil
        }
        if head.kind == .heading {
            if let v = visible(NSRange(location: 0, length: ns.length)) { spans = [v] }
        } else {
            for (lo, hi) in zip(pieces, pieces.dropFirst()) where hi > lo {
                let piece = tokenized.substring(with: NSRange(location: lo, length: hi - lo))
                let tokenizer = NLTokenizer(unit: .sentence)
                tokenizer.string = piece
                // A sentence with no words numbers the next one at the start ("§ 3.", "2."), and ends the one
                // before anywhere else ("…Parikh et al. (2016)."), unless it's a stray footnote marker ("6").
                var label: Int?, first = spans.count
                for t in tokenizer.tokens(for: piece.startIndex..<piece.endIndex) {
                    let r = NSRange(t, in: piece)
                    guard var v = visible(NSRange(location: lo + r.location, length: r.length)) else { continue }
                    if let l = label { v = NSRange(location: l, length: NSMaxRange(v) - l) }
                    if SpeechText.clean(tokenized.substring(with: v)) != nil { spans.append(v); label = nil }
                    else if Self.matches(Self.strayMarker, tokenized.substring(with: v)) { label = nil }
                    else if spans.count > first, let last = spans.last { spans[spans.count - 1] = NSRange(location: last.location, length: NSMaxRange(v) - last.location) }
                    else { label = v.location }
                }
            }
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(400)))
        return Flow(blocks: parts, starts: starts, raw: ns, said: said, spans: spans, language: recognizer.dominantLanguage?.rawValue ?? "en")
    }

    // MARK: Text

    /// Footnote markers in running text: a number right after a word's punctuation ("drawn.1", "Transformer.”2";
    /// not "Appendix A.1"), or a number on a line of its own (raised: "heads as A.\r\n3\r\n").
    private static let marker = try! NSRegularExpression(
        pattern: #"(?<=\p{L}{2}[.,;:!?]|[)\]][.,;:!?]|[.,;:!?][”’"])\d{1,2}(?=[\r\n]|\s*$|\s+\p{Lu})|(?<=\n)\d{1,2}(?=\r?\n)"#)

    private static let strayMarker = try! NSRegularExpression(pattern: #"^\d{1,2}$"#)

    private static func markerRanges(_ s: String) -> [NSRange] {
        marker.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).map(\.range)
    }

    private static func withoutMarkers(_ s: String) -> String {
        marker.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
    }

    /// What a span of PDF text says: footnote markers out, line-end hyphens resolved, line ends as spaces.
    private func spoken(_ raw: String, language: String) -> String? {
        SpeechText.clean(resolvingHyphens(Self.withoutMarkers(raw), language: language))
    }

    /// A line-end hyphen (U+0002) joins a word the typesetter broke ("para-graph") and stays in a word that has
    /// one ("task-specific", "state-of-the-art"). The document's own spelling decides first, then the spell checker.
    private func resolvingHyphens(_ s: String, language: String) -> String {
        guard s.contains("\u{02}") else { return s }
        let chars = Array(s)
        var out = ""
        for (i, c) in chars.enumerated() {
            guard c == "\u{02}" else { out.append(c); continue }
            var l = i
            while l > 0, chars[l - 1].isLetter || chars[l - 1] == "-" { l -= 1 }
            var r = i + 1
            while r < chars.count, chars[r].isLetter { r += 1 }
            let left = String(chars[l..<i]), right = String(chars[(i + 1)..<r])
            out += joins(left, right, language: language) ? "" : "-"
        }
        return out
    }

    /// Joined unless the hyphen is the word's own: spelled so in the document, inside a compound that has
    /// another, before a capital, or between two words that aren't one word joined ("task-specific").
    /// A language the spell checker doesn't have joins.
    private func joins(_ left: String, _ right: String, language: String) -> Bool {
        guard !left.isEmpty, !right.isEmpty else { return true }
        if vocabulary.contains((left + right).lowercased()) { return true }
        if vocabulary.contains((left + "-" + right).lowercased()) { return false }
        if left.contains("-") || right.first?.isUppercase == true { return false }
        guard Spelling.isWord(left + right, language: language) == false else { return true }
        return !(Spelling.isWord(left, language: language) == true && Spelling.isWord(right, language: language) == true)
    }

    // MARK: Reading

    func start() -> PDFPosition? { blocks(0)?.isEmpty == false ? PDFPosition(BlockID(page: 0, index: 0), walked: true) : nil }

    /// What reading from `position` gives first, or nil at the end (or "References"). `complete`: every page it
    /// looked at was there. One that wasn't built yet can make it longer, so an incomplete reading isn't kept.
    func read(from position: PDFPosition) -> (reading: Reading?, complete: Bool) {
        let r = tracking { firstReading(from: position) }
        return (r.value, r.complete)
    }

    private func firstReading(from position: PDFPosition) -> Reading? {
        var pos = position
        for _ in 0..<2000 {
            guard let b = block(pos.block) else { return nil }
            var flowHead = b, offset = pos.offset
            if pos.offset == 0, !pos.cued {
                let h = head(of: b)
                switch b.kind {
                case .furniture:
                    if !pos.walked { return nil }
                    pos = next(after: b); continue
                case .footnote where pos.walked:
                    pos = next(after: b); continue
                case .references where pos.walked:
                    if debug { print("    pdf: references, end of reading") }
                    return nil
                case .label(let what):
                    return cue(at: b, kind: what)
                case .caption(let what) where pos.walked:
                    // Labels or rows after a table's caption get their cue after it; otherwise the cue is the caption's.
                    if let n = after(b.id), case .label(_)? = block(n)?.kind { break }
                    return .cue(what, blocks: [b.id], next: PDFPosition(b.id, walked: true, cued: true))
                case .other where pos.walked && h === b && continuation(of: b) == nil && b.words < 6:
                    // A stray fragment (an equation's line, a label away from its figure). A longer block that
                    // ends in no sentence is still read: a slide's bullets, a list without periods.
                    pos = next(after: b); continue
                default: break
                }
                if h !== b {
                    // Carries on an earlier paragraph: read on, it's been said; pointed at, read its sentence.
                    if pos.walked { pos = next(after: b); continue }
                    let f = flow(from: h)
                    guard let i = f.blocks.firstIndex(where: { $0 === b }) else { return nil }
                    flowHead = h
                    offset = f.starts[i]
                }
            }
            let f = flow(from: flowHead)
            if var t = f.spans.lastIndex(where: { $0.location <= offset }) ?? (f.spans.isEmpty ? nil : 0) {
                while t < f.spans.count {
                    if let reading = sentence(in: f, at: t) { return reading }
                    t += 1
                }
            }
            pos = next(after: flowHead)
        }
        return nil
    }

    /// Reading on after `b`'s flow. At the end, the next page's start, in case PDFium builds it later.
    private func next(after b: Block) -> PDFPosition {
        PDFPosition(after(b.id) ?? BlockID(page: b.id.page + 1, index: 0), walked: true)
    }

    private func sentence(in f: Flow, at t: Int) -> Reading? {
        let span = f.spans[t]
        var parts: [(block: BlockID, range: NSRange)] = []
        for (i, b) in f.blocks.enumerated() {
            let lo = max(span.location, f.starts[i]), hi = min(NSMaxRange(span), f.starts[i] + b.raw.length)
            if hi > lo { parts.append((b.id, NSRange(location: lo - f.starts[i] + b.skip, length: hi - lo))) }
        }
        guard !parts.isEmpty, let text = spoken(f.said.substring(with: span).replacingOccurrences(of: "\u{01}", with: ""), language: f.language) else { return nil }
        let next = t + 1 < f.spans.count ? PDFPosition(f.blocks[0].id, offset: f.spans[t + 1].location, walked: true) : self.next(after: f.blocks[0])
        return .sentence(text: text, parts: parts, next: next)
    }

    /// One cue for a figure's labels (or a table's rows), then its caption.
    private func cue(at b: Block, kind: String) -> Reading {
        var run: [BlockID] = [], id: BlockID? = b.id
        while let i = id, let x = block(i) {
            if case .label = x.kind { run.append(i) } else if x.kind != .furniture { break }
            id = after(i)
        }
        let following = id.flatMap(block)
        var next = following.map { PDFPosition($0.id, walked: true) } ?? self.next(after: block(run.last!)!)
        if let c = following, case .caption = c.kind { next = PDFPosition(c.id, walked: true, cued: true) }
        return .cue(kind, blocks: run, next: next)
    }
}

/// Is a word spelled right? The system spell checker, asked once per word; nil for a language it doesn't have.
/// Called on `AXWorker`: `NSSpellChecker` is used off the main thread here, behind this lock, and only to check.
enum Spelling {
    private static let lock = NSLock()
    private static var memo: [String: Bool] = [:]
    private static var languages: Set<String>?

    static func isWord(_ word: String, language: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        let known = languages ?? Set(NSSpellChecker.shared.availableLanguages.map { String($0.prefix(2)) })
        languages = known
        guard known.contains(String(language.prefix(2))) else { return nil }
        let key = language + ":" + word
        if let known = memo[key] { return known }
        let miss = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        let ok = miss.location == NSNotFound
        memo[key] = ok
        return ok
    }
}
