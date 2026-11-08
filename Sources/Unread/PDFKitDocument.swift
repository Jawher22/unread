import AppKit
import ApplicationServices
import NaturalLanguage

/// A place in a PDFKit document (#86): ranges in pages' strings, in reading
/// order. A position is one empty range; a sentence that crosses a page break
/// has a part on each page.
final class PDFRange: NSObject {
    struct Part { let page: Int; let range: NSRange }
    let parts: [Part]
    /// The start the user pointed at: its block is read whatever it is.
    let pointed: Bool
    /// A caption's start reached from its cue: don't cue it again.
    let afterCue: Bool
    init(_ parts: [Part], pointed: Bool = false, afterCue: Bool = false) {
        self.parts = parts
        self.pointed = pointed
        self.afterCue = afterCue
    }
    convenience init(page: Int, offset: Int, pointed: Bool = false, afterCue: Bool = false) {
        self.init([Part(page: page, range: NSRange(location: offset, length: 0))], pointed: pointed, afterCue: afterCue)
    }
    var start: Part { parts[0] }
    var end: Part { parts[parts.count - 1] }
}

/// PDFKit's pages (Preview, Safari, WKWebView; #86). Every page is an `AXPage`
/// from the start. Its text comes whole and in reading order from
/// `AXAttributedStringForRange`, with a font per run, and that is all the page
/// answers. The text has the page's furniture in it (running header, footer,
/// page number, footnotes, figure labels), so each line is judged by its
/// font: smaller than the body is furniture, bold is a heading, the rest is
/// read. Line ends are spaces, except at a link, a column end or an odd
/// block, where they are "\n", so lines are joined into a block until one
/// ends like a sentence; a block that doesn't ends carries on into the next,
/// across a column or a page. A line-end hyphen stays when the two halves
/// aren't one word ("task-specific"). Boxes come from the `AXStaticText`
/// leaves under the page, which measure sub-ranges per line but hold the
/// page's text with "\n" at every line end, so each leaf is matched to the
/// page string ignoring whitespace.
final class PDFKitDocument: ReadableDocument {
    /// The pages' container (`AXSharedDocumentContainer` in Preview, the plugin group in WebKit).
    let element: AXUIElement
    private let pageElements: [AXUIElement]
    private var pages: [Int: Page] = [:]
    private var leaves: [Int: [Leaf]] = [:]
    private var lineRangesMemo: [AXKey: [NSRange]] = [:]
    private var units: [BlockID: Unit] = [:]
    /// The user pointed into the reference list: read it.
    private var referencesReadable = false
    private let debugWalk = ProcessInfo.processInfo.environment["UNREAD_DEBUG_WALK"] != nil

    convenience init?(page: AXUIElement) {
        guard let container = AX.parent(page) else { return nil }
        self.init(container: container)
    }

    init?(container: AXUIElement) {
        let pages = AX.children(container).filter { AX.role($0) == "AXPage" }
        guard !pages.isEmpty else { return nil }
        element = container
        pageElements = pages
    }

    // MARK: Pages

    private struct Run {
        let range: NSRange
        let size: CGFloat
        let bold: Bool
    }

    private struct Line {
        let range: NSRange // in the page's text, without the "\n"
        let size: CGFloat
        let bold: Bool
        let small: Bool // smaller than the body text: furniture
        /// Bold or larger than the body text: a heading, unless it says otherwise.
        let headingLike: Bool
        /// Superscripts inside the line (footnote markers): dropped.
        let dropped: [NSRange]
        let text: String
        /// A page number.
        var isNumber: Bool { text.allSatisfy { $0.isNumber || $0.isWhitespace } }
    }

    enum Kind: Equatable { case heading, paragraph, caption(String), furniture }

    struct BlockID: Hashable { let page: Int; let index: Int }

    /// One or more lines of one kind that read as a unit: a heading, a paragraph (or the
    /// part of one in this column or page), a caption, or furniture.
    private final class Block {
        let id: BlockID
        let range: NSRange
        let kind: Kind
        let small: Bool
        let lines: [Line]
        var inReferences = false
        init(id: BlockID, range: NSRange, kind: Kind, small: Bool, lines: [Line]) {
            self.id = id; self.range = range; self.kind = kind; self.small = small; self.lines = lines
        }
        var endsLikeSentence: Bool { ReadingSession.endsLikeSentence(lines.last?.text ?? "") }
        var isReferencesHeading: Bool {
            kind == .heading && PDFKitDocument.referencesHeading.firstMatch(in: lines[0].text, range: NSRange(lines[0].text.startIndex..., in: lines[0].text)) != nil
        }
    }

    private final class Page {
        let text: NSString
        let blocks: [Block]
        /// Whether the reference list runs on past this page's end.
        let referencesOpenAtEnd: Bool
        init(text: NSString, blocks: [Block], referencesOpenAtEnd: Bool) {
            self.text = text; self.blocks = blocks; self.referencesOpenAtEnd = referencesOpenAtEnd
        }
    }

    private static let captionStart = try! NSRegularExpression(pattern: #"^\s*(Figure|Fig\.|Table|Tab\.)\s*\d+[.:]"#)
    private static let footnoteStart = try! NSRegularExpression(pattern: #"^\s*([∗*†‡§¶]|\d{1,2}(?=\p{Lu}))"#)
    private static let referencesHeading = try! NSRegularExpression(pattern: #"^\s*(\d+(\.\d+)*\.?\s+)?(references|bibliography|works cited)\s*$"#, options: .caseInsensitive)
    private static let sentenceEnd = try! NSRegularExpression(pattern: #"[\p{L}\p{N})\]"'”’][.!?…][\s"'”’)\]]"#)

    /// Earlier pages first: the reference list may start on one and run on.
    private func page(_ i: Int) -> Page? {
        guard pageElements.indices.contains(i) else { return nil }
        if let p = pages[i] { return p }
        var open = false
        if i > 0, let before = page(i - 1) { open = before.referencesOpenAtEnd }
        let p = build(i, referencesOpen: open)
        pages[i] = p
        return p
    }

    private func build(_ index: Int, referencesOpen: Bool) -> Page {
        let e = pageElements[index]
        let count = (AX.attr(e, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue ?? 0
        guard count > 0, let attributed = AX.param(e, "AXAttributedStringForRange", AX.rangeValue(NSRange(location: 0, length: count))) as? NSAttributedString else {
            return Page(text: "", blocks: [], referencesOpenAtEnd: referencesOpen)
        }
        let text = attributed.string as NSString
        var runs: [Run] = []
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, range, _ in
            let font = attrs[NSAttributedString.Key("AXFont")] as? [String: Any]
            let size = (font?["AXFontSize"] as? NSNumber)?.doubleValue ?? (font?["AXFontSize"] as? String).flatMap(Double.init) ?? 0
            let name = ((font?["AXFontName"] as? String) ?? "") + " " + ((font?["AXVisibleName"] as? String) ?? "")
            runs.append(Run(range: range, size: CGFloat(size), bold: name.localizedCaseInsensitiveContains("bold") || name.localizedCaseInsensitiveContains("black") || name.localizedCaseInsensitiveContains("heavy")))
        }
        // The body size: the one most characters are set in.
        var weight: [CGFloat: Int] = [:]
        for r in runs where r.size > 0 {
            let s = text.substring(with: r.range)
            weight[(r.size * 2).rounded() / 2, default: 0] += s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        }
        let body = weight.max { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }?.key ?? 0

        var lines: [Line] = []
        var at = 0
        while at < text.length {
            let nl = text.range(of: "\n", range: NSRange(location: at, length: text.length - at))
            let end = nl.location == NSNotFound ? text.length : nl.location
            let range = NSRange(location: at, length: end - at)
            at = end + 1
            let s = text.substring(with: range)
            guard s.unicodeScalars.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) else { continue }
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
            let size = sizeWeight.max { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }?.key ?? body
            let dropped = inLine.filter { r, x in r.size < size - 1.5 && x.length <= 4 }.map(\.1)
            let bold = chars > 0 && boldChars * 10 >= chars * 6
            lines.append(Line(range: range, size: size, bold: bold, small: size < body - 1.5, headingLike: bold || size > body + 0.75, dropped: dropped, text: s))
        }

        var groups: [[Line]] = []
        var group: [Line] = []
        func flush() {
            if !group.isEmpty { groups.append(group) }
            group = []
        }
        for line in lines {
            if let prev = group.last {
                let same = prev.small == line.small && prev.bold == line.bold && abs(prev.size - line.size) <= 0.6
                var joins = same && !ReadingSession.endsLikeSentence(prev.text) && !Self.startsLikeCaption(line.text) && !prev.isNumber && !line.isNumber
                // Heading lines stand alone, unless one wraps onto the next ("…Transformers for" / "Language Understanding").
                if joins, line.headingLike, !Self.wraps(prev.text, onto: line.text) { joins = false }
                if !joins { flush() }
            }
            group.append(line)
        }
        flush()
        var blocks: [Block] = []
        for (i, g) in groups.enumerated() {
            let last = groups[(i + 1)...].allSatisfy { $0[0].isNumber }
            blocks.append(Block(id: BlockID(page: index, index: i), range: NSRange(location: g[0].range.location, length: NSMaxRange(g[g.count - 1].range) - g[0].range.location),
                                kind: classify(g, body: body, last: last), small: g[0].small, lines: g))
        }
        var open = referencesOpen
        for b in blocks {
            if b.kind == .heading { open = b.isReferencesHeading }
            b.inReferences = open
        }
        if debugWalk {
            for b in blocks { print("[pdf] page \(index + 1) block \(b.id.index) \(b.kind)\(b.inReferences ? " refs" : "") \(b.lines.count) lines: \(b.lines[0].text.prefix(50).debugDescription)") }
        }
        return Page(text: text, blocks: blocks, referencesOpenAtEnd: open)
    }

    private static func startsLikeCaption(_ s: String) -> Bool {
        captionStart.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// `last`: the block is the page's last, or only page numbers follow it (a footer).
    private func classify(_ lines: [Line], body: CGFloat, last: Bool) -> Kind {
        let text = lines.map(\.text).joined(separator: " ")
        let words = text.split(whereSeparator: \.isWhitespace).count
        if Self.startsLikeCaption(text) { return lines[0].size >= body - 2.5 ? .caption(text.hasPrefix("Tab") ? "table" : "figure") : .furniture }
        if lines[0].small || lines[0].isNumber { return .furniture }
        // An author grid (names, affiliations, emails), arXiv's stamp down the margin.
        if text.contains("@") && !ReadingSession.endsLikeSentence(text) || text.hasPrefix("arXiv:") { return .furniture }
        // A footnote ("3In all cases…", "∗Equal contribution.") or a footer, set a little smaller than the body.
        if lines[0].size < body - 0.5, Self.footnoteStart.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil || (last && lines.count == 1) { return .furniture }
        let headingLike = lines[0].headingLike
        if headingLike, words <= 15, !ReadingSession.endsLikeSentence(text) { return .heading }
        let ends = Self.sentenceEnd.firstMatch(in: text + " ", range: NSRange(location: 0, length: (text as NSString).length + 1)) != nil
        if words >= 2, ends || ReadingSession.endsLikeSentence(text) { return .paragraph }
        if headingLike, words <= 15 { return .heading }
        return .furniture
    }

    /// A heading line that runs on: it ends in a connector, or the next line starts in lower case.
    private static func wraps(_ prev: String, onto next: String) -> Bool {
        if let first = next.first(where: { !$0.isWhitespace }), first.isLowercase { return true }
        let words = prev.lowercased().split(whereSeparator: \.isWhitespace)
        guard let lastWord = words.last else { return false }
        if let c = lastWord.last, ":,-–".contains(c) { return true }
        return ["a", "an", "the", "of", "for", "and", "or", "in", "on", "with", "to", "from", "by", "via", "at", "as", "into", "over", "under", "without", "between", "through", "toward", "towards", "versus", "vs."].contains(String(lastWord))
    }

    // MARK: Units: what a block (and the blocks it runs on into) says

    /// One UTF-16 unit of the text to read, and where it is on the page.
    struct Loc { let page: Int; let offset: Int }

    /// A run of blocks read as one text: a paragraph that runs over a column
    /// or page end, with its line ends, superscripts and line-end hyphens
    /// resolved, cut into sentences.
    private struct Unit {
        let blocks: [BlockID]
        let spoken: String
        let locs: [Loc]
        let sentences: [NSRange]
    }

    private func readable(_ b: Block) -> Bool {
        b.kind != .furniture && (!b.inReferences || referencesReadable)
    }

    private func block(_ id: BlockID) -> Block? {
        guard let p = page(id.page), p.blocks.indices.contains(id.index) else { return nil }
        return p.blocks[id.index]
    }

    /// The readable block after `id`, on this page or the next ones.
    private func nextReadable(after id: BlockID) -> Block? {
        var page = id.page, index = id.index + 1
        while let p = self.page(page) {
            while index < p.blocks.count {
                if readable(p.blocks[index]) { return p.blocks[index] }
                index += 1
            }
            page += 1; index = 0
        }
        return nil
    }

    /// The readable block before `id`.
    private func previousReadable(before id: BlockID) -> Block? {
        var page = id.page, index = id.index - 1
        while page >= 0, let p = self.page(page) {
            while index >= 0 {
                if readable(p.blocks[index]) { return p.blocks[index] }
                index -= 1
            }
            page -= 1
            if page >= 0, let q = self.page(page) { index = q.blocks.count - 1 }
        }
        return nil
    }

    /// A paragraph (or a caption PDFKit ran a paragraph into) that doesn't end like a sentence
    /// carries on into the next paragraph: across a column end or a page break.
    private func unit(containing start: Block) -> Unit {
        if let u = units[start.id] { return u }
        func carriesOn(_ b: Block) -> Bool { b.kind != .heading && !b.endsLikeSentence }
        var first = start
        for _ in 0..<8 {
            guard first.kind == .paragraph, let prev = previousReadable(before: first.id), carriesOn(prev) else { break }
            first = prev
        }
        var members = [first]
        for _ in 0..<8 {
            guard let last = members.last, carriesOn(last), let next = nextReadable(after: last.id), next.kind == .paragraph else { break }
            members.append(next)
        }
        let u = make(members)
        for m in members { units[m.id] = u }
        return u
    }

    private func make(_ blocks: [Block]) -> Unit {
        var raw: [UInt16] = [], locs: [Loc] = []
        func append(_ u: UInt16, _ loc: Loc) {
            if u == 0x20, raw.last == 0x20 { return }
            raw.append(u); locs.append(loc)
        }
        for b in blocks {
            guard let p = page(b.id.page) else { continue }
            if !raw.isEmpty, raw.last != 0x20 { append(0x20, locs.last ?? Loc(page: b.id.page, offset: b.range.location)) }
            for line in b.lines {
                for i in line.range.location..<NSMaxRange(line.range) {
                    let loc = Loc(page: b.id.page, offset: i)
                    if line.dropped.contains(where: { NSLocationInRange(i, $0) }) { append(0x20, loc); continue }
                    let u = p.text.character(at: i)
                    append(Self.isSpace(u) ? 0x20 : u, loc)
                }
                append(0x20, Loc(page: b.id.page, offset: NSMaxRange(line.range)))
            }
        }
        // Line-end hyphens: "para- graph" is one word, "task- specific" keeps its hyphen.
        var out: [UInt16] = [], outLocs: [Loc] = []
        var i = 0
        while i < raw.count {
            let u = raw[i]
            if u == 0x2D, i > 0, Self.isLetter(raw[i - 1]), i + 1 < raw.count, raw[i + 1] == 0x20 {
                var j = i + 1
                while j < raw.count, raw[j] == 0x20 { j += 1 }
                if j < raw.count, Self.isLowercaseLetter(raw[j]) {
                    var l = i - 1
                    while l > 0, Self.isLetter(raw[l - 1]) { l -= 1 }
                    var r = j
                    while r < raw.count, Self.isLetter(raw[r]) { r += 1 }
                    let left = String(utf16CodeUnits: Array(raw[l..<i]), count: i - l), right = String(utf16CodeUnits: Array(raw[j..<r]), count: r - j)
                    if Hyphens.join(left, right) { i = j; continue } // drop "- "
                    out.append(u); outLocs.append(locs[i]); i = j; continue // keep "-", drop the space
                }
            }
            out.append(u); outLocs.append(locs[i]); i += 1
        }
        let spoken = String(utf16CodeUnits: out, count: out.count)
        if debugWalk { print("[pdf] unit \(blocks.map { "p\($0.id.page + 1)b\($0.id.index)" }.joined(separator: "+")): \(spoken.debugDescription)") }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = spoken
        let sentences = tokenizer.tokens(for: spoken.startIndex..<spoken.endIndex).map { NSRange($0, in: spoken) }
        return Unit(blocks: blocks.map(\.id), spoken: spoken, locs: outLocs, sentences: sentences)
    }

    private static func isSpace(_ u: UInt16) -> Bool { Unicode.Scalar(u).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false }
    private static func isLetter(_ u: UInt16) -> Bool { Unicode.Scalar(u).map { CharacterSet.letters.contains($0) } ?? false }
    private static func isLowercaseLetter(_ u: UInt16) -> Bool { Unicode.Scalar(u).map { CharacterSet.lowercaseLetters.contains($0) } ?? false }

    /// The parts of a unit's range, one per page.
    private func parts(of u: Unit, _ r: NSRange) -> [PDFRange.Part] {
        var parts: [PDFRange.Part] = []
        for loc in u.locs[r.location..<NSMaxRange(r)] {
            if let last = parts.last, last.page == loc.page {
                let lo = min(last.range.location, loc.offset), hi = max(NSMaxRange(last.range), loc.offset + 1)
                parts[parts.count - 1] = PDFRange.Part(page: loc.page, range: NSRange(location: lo, length: hi - lo))
            } else {
                parts.append(PDFRange.Part(page: loc.page, range: NSRange(location: loc.offset, length: 1)))
            }
        }
        return parts
    }

    // MARK: ReadableDocument

    func documentStart() -> AnyObject? { PDFRange(page: 0, offset: 0) }

    func sentence(from position: AnyObject, in scope: ReadingScope?) -> Sentence? {
        guard let pos = position as? PDFRange else { return nil }
        var pageIndex = pos.start.page, offset = pos.start.range.location
        var pointed = pos.pointed, afterCue = pos.afterCue
        while let p = page(pageIndex) {
            for b in p.blocks where NSMaxRange(b.range) > offset {
                if pointed {
                    if b.inReferences { referencesReadable = true }
                    pointed = false
                } else if !readable(b) { continue }
                if case .caption(let kind) = b.kind, !afterCue, offset <= b.range.location {
                    return cue(kind, before: b, in: p)
                }
                afterCue = false
                let u = unit(containing: b)
                for r in u.sentences {
                    let parts = parts(of: u, r)
                    guard let end = parts.last, end.page > pageIndex || (end.page == pageIndex && NSMaxRange(end.range) > offset) else { continue }
                    guard let text = SpeechText.clean((u.spoken as NSString).substring(with: r)) else { continue }
                    if debugWalk { print("[pdf] sentence p\(end.page + 1) \(parts.map { "\($0.range.location)+\($0.range.length)" }.joined(separator: ",")): \(text.prefix(60).debugDescription)") }
                    return Sentence(text: text, range: PDFRange(parts), next: PDFRange(page: end.page, offset: NSMaxRange(end.range)))
                }
            }
            pageIndex += 1; offset = 0
        }
        return nil
    }

    /// The figure's cue, over the labels before its caption (short furniture
    /// lines right before it) or, without any, the caption itself.
    private func cue(_ kind: String, before caption: Block, in p: Page) -> Sentence {
        var first = caption.id.index
        while first > 0, p.blocks[first - 1].kind == .furniture, p.blocks[first - 1].small { first -= 1 }
        let range = first < caption.id.index
            ? NSRange(location: p.blocks[first].range.location, length: NSMaxRange(p.blocks[caption.id.index - 1].range) - p.blocks[first].range.location)
            : caption.range
        return Sentence(text: "", range: PDFRange([PDFRange.Part(page: caption.id.page, range: range)]),
                        next: PDFRange(page: caption.id.page, offset: caption.range.location, afterCue: true), cue: kind)
    }

    func paragraph(at point: CGPoint) -> (start: AnyObject, bounds: CGRect)? {
        guard let i = pageElements.firstIndex(where: { AX.frame($0)?.contains(point) ?? false }), let p = page(i) else { return nil }
        let candidates = leaves(of: i).filter { $0.frame.contains(point) }
        guard let leaf = candidates.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
        // The line under the point, else the leaf's first character.
        var offset = leaf.first
        for lr in lineRanges(of: leaf) {
            guard let box = bounds(leaf.element, lr), box.minY <= point.y, point.y <= box.maxY else { continue }
            if let o = (lr.location..<NSMaxRange(lr)).lazy.compactMap({ leaf.offsets[$0] >= 0 ? leaf.offsets[$0] : nil }).first { offset = o }
            break
        }
        guard let b = p.blocks.first(where: { NSLocationInRange(offset, $0.range) }) ?? p.blocks.first(where: { $0.range.location > offset }) else { return nil }
        let start = PDFRange(page: i, offset: b.range.location, pointed: true)
        // The block's lines in the pointed column: a paragraph that runs into the next column is shown there only.
        let lines = boxes(for: [PDFRange.Part(page: i, range: b.range)]).filter { $0.minX < leaf.frame.maxX && $0.maxX > leaf.frame.minX }
        guard let box = lines.dropFirst().reduce(lines.first, { $0?.union($1) }) else { return nil }
        return (start, box)
    }

    func firstVisible() -> AnyObject? {
        guard let visible = visibleRect() else { return documentStart() }
        for (i, e) in pageElements.enumerated() {
            guard let f = AX.frame(e), f.intersects(visible), let p = page(i) else { continue }
            var measured = 0
            for b in p.blocks where readable(b) && measured < 40 {
                measured += 1
                let lines = boxes(for: [PDFRange.Part(page: i, range: b.range)])
                if lines.contains(where: { $0.intersects(visible) }) { return PDFRange(page: i, offset: b.range.location) }
            }
            return PDFRange(page: i, offset: 0)
        }
        return documentStart()
    }

    // MARK: Leaves and boxes

    /// An `AXStaticText` under a page, and where each of its characters is in the page's string (−1: nowhere).
    private struct Leaf {
        let element: AXUIElement
        let frame: CGRect
        let text: NSString
        let offsets: [Int]
        let first: Int, last: Int
    }

    private func leaves(of pageIndex: Int) -> [Leaf] {
        if let l = leaves[pageIndex] { return l }
        guard let p = page(pageIndex) else { return [] }
        var found: [(AXUIElement, NSString, CGRect)] = []
        var stack = [pageElements[pageIndex]]
        var seen = 0
        while let e = stack.popLast(), seen < 20_000 {
            seen += 1
            if AX.role(e) == kAXStaticTextRole {
                if let v = AX.attr(e, kAXValueAttribute) as? String, !v.isEmpty, let f = AX.frame(e) { found.append((e, v as NSString, f)) }
                continue
            }
            stack.append(contentsOf: AX.children(e).reversed())
        }
        // Match each leaf to the page string ignoring whitespace: the leaf has "\n" at line ends, the
        // page a space, or a "\n" of its own after a link.
        var compact: [UInt16] = [], compactToPage: [Int] = []
        for i in 0..<p.text.length { let u = p.text.character(at: i); if !Self.isSpace(u) { compact.append(u); compactToPage.append(i) } }
        var cursor = 0
        var result: [Leaf] = []
        let pageFrame = AX.frame(pageElements[pageIndex])?.insetBy(dx: -4, dy: -4)
        for (e, text, frame) in found {
            var leafCompact: [UInt16] = [], compactToLeaf: [Int] = []
            for i in 0..<text.length { let u = text.character(at: i); if !Self.isSpace(u) { leafCompact.append(u); compactToLeaf.append(i) } }
            var offsets = [Int](repeating: -1, count: text.length)
            guard !leafCompact.isEmpty else { continue }
            let at = Self.find(leafCompact, in: compact, from: cursor) ?? Self.find(leafCompact, in: compact, from: 0)
            if let at {
                for (k, li) in compactToLeaf.enumerated() { offsets[li] = compactToPage[at + k] }
                cursor = at + leafCompact.count
                // A leaf whose box isn't on the page (PDFKit gives some leaves after a dropped run a box in the
                // PDF's own coordinates) can't be measured: its text falls back to the paragraph's group.
                guard pageFrame?.contains(frame) ?? true else {
                    if debugWalk { print("[pdf] leaf off page \(pageIndex + 1): \(frame) \((text as String).prefix(30).debugDescription)") }
                    continue
                }
                result.append(Leaf(element: e, frame: frame, text: text, offsets: offsets, first: compactToPage[at], last: compactToPage[at + leafCompact.count - 1]))
            } else if debugWalk {
                print("[pdf] leaf not in page \(pageIndex + 1)'s text: \((text as String).prefix(40).debugDescription)")
            }
        }
        leaves[pageIndex] = result
        return result
    }

    private static func find(_ needle: [UInt16], in hay: [UInt16], from: Int) -> Int? {
        guard needle.count <= hay.count else { return nil }
        var i = from
        while i + needle.count <= hay.count {
            if hay[i] == needle[0], Array(hay[i..<i + needle.count]) == needle { return i }
            i += 1
        }
        return nil
    }

    private func lineRanges(of leaf: Leaf) -> [NSRange] {
        let key = AXKey(element: leaf.element)
        if let r = lineRangesMemo[key] { return r }
        var ranges: [NSRange] = []
        var line = 0
        while line < 400, let v = AX.param(leaf.element, kAXRangeForLineParameterizedAttribute, line as NSNumber) {
            var r = CFRange()
            guard AXValueGetValue(v as! AXValue, .cfRange, &r), r.length > 0, r.location + r.length <= leaf.text.length else { break }
            let range = NSRange(location: r.location, length: r.length)
            if let last = ranges.last, NSMaxRange(last) > range.location { break }
            ranges.append(range)
            if NSMaxRange(range) >= leaf.text.length { break }
            line += 1
        }
        if ranges.isEmpty { ranges = [NSRange(location: 0, length: leaf.text.length)] }
        lineRangesMemo[key] = ranges
        return ranges
    }

    private func bounds(_ e: AXUIElement, _ r: NSRange) -> CGRect? {
        AX.rect(AX.param(e, kAXBoundsForRangeParameterizedAttribute, AX.rangeValue(r)))
    }

    /// The leaf indices of the page range `r` in `leaf`, if any.
    private func leafRange(_ leaf: Leaf, _ r: NSRange) -> NSRange? {
        guard leaf.first < NSMaxRange(r), leaf.last >= r.location else { return nil }
        var lo = Int.max, hi = -1
        for (i, o) in leaf.offsets.enumerated() where o >= 0 && NSLocationInRange(o, r) { lo = min(lo, i); hi = max(hi, i) }
        return hi >= lo ? NSRange(location: lo, length: hi - lo + 1) : nil
    }

    /// Line boxes of the parts, from the leaves' lines. Text mostly in no leaf (PDFKit drops
    /// the text before a paragraph's first link) gets the frame of the paragraph's group.
    private func boxes(for parts: [PDFRange.Part]) -> [CGRect] {
        var out: [CGRect] = []
        for part in parts {
            let pageLeaves = leaves(of: part.page)
            var covered = 0
            for leaf in pageLeaves {
                guard let lr = leafRange(leaf, part.range) else { continue }
                covered += lr.length
                for line in lineRanges(of: leaf) {
                    let x = NSIntersectionRange(line, lr)
                    guard x.length > 0, let b = bounds(leaf.element, x) else { continue }
                    out.append(b)
                }
            }
            if covered * 2 < part.range.length,
               let near = pageLeaves.first(where: { $0.first >= part.range.location }) ?? pageLeaves.last(where: { $0.last < part.range.location }) {
                out.append(paragraphGroup(of: near.element, leafFrame: near.frame) ?? near.frame)
            }
        }
        return WebDocument.groupIntoLines(out)
    }

    /// The first ancestor group taller than the leaf: the paragraph's box.
    private func paragraphGroup(of leaf: AXUIElement, leafFrame: CGRect) -> CGRect? {
        var e = AX.parent(leaf)
        for _ in 0..<8 {
            guard let cur = e, AX.role(cur) != "AXPage" else { return nil }
            if let f = AX.frame(cur), f.height > leafFrame.height + 2 { return f }
            e = AX.parent(cur)
        }
        return nil
    }

    func lines(of sentence: Sentence) -> [CGRect] {
        guard let r = sentence.range as? PDFRange else { return [] }
        let lines = boxes(for: r.parts)
        if sentence.cue != nil, let u = lines.dropFirst().reduce(lines.first, { $0?.union($1) }) { return [u] }
        return lines
    }

    func words(of sentence: Sentence) -> [CGRect?] {
        guard let r = sentence.range as? PDFRange else { return [] }
        var pieces: [(text: String, rect: CGRect)] = []
        /// A word broken at a line end ("para-" / "graph") is one piece, with its first half's box.
        func add(_ text: String, _ box: CGRect) {
            if let last = pieces.last, last.text.hasSuffix("-"), let first = text.first, first.isLowercase {
                pieces[pieces.count - 1] = (last.text + text, last.rect)
            } else {
                pieces.append((text, box))
            }
        }
        for part in r.parts {
            guard let p = page(part.page) else { continue }
            let pageLeaves = leaves(of: part.page)
            var i = part.range.location
            let end = NSMaxRange(part.range)
            while i < end, pieces.count < 300 {
                while i < end, Self.isSpace(p.text.character(at: i)) { i += 1 }
                let start = i
                while i < end, !Self.isSpace(p.text.character(at: i)) { i += 1 }
                guard i > start else { continue }
                let word = NSRange(location: start, length: i - start)
                var box: CGRect?
                for leaf in pageLeaves {
                    guard let lr = leafRange(leaf, word), let b = bounds(leaf.element, lr) else { continue }
                    box = box.map { $0.union(b) } ?? b
                }
                if let box { add(p.text.substring(with: word), box) }
            }
        }
        return WordBoxes.assign(display: sentence.words, pieces: pieces)
    }

    func linesDiagnosis(of sentence: Sentence) -> String {
        guard let r = sentence.range as? PDFRange else { return "not a PDF range" }
        return r.parts.map { part in
            let n = leaves(of: part.page).filter { leafRange($0, part.range) != nil }.count
            return "page \(part.page + 1) \(part.range.location)+\(part.range.length): \(n) leaves"
        }.joined(separator: "; ")
    }

    // MARK: Viewport

    /// The scroll area around the pages (Preview), whose `AXMakeScreenRectVisible` scrolls a box into view.
    private lazy var scroller: AXUIElement? = {
        var e = AX.parent(element)
        for _ in 0..<4 {
            guard let cur = e else { return nil }
            if AX.role(cur) == kAXScrollAreaRole {
                var settable = DarwinBoolean(false)
                return AXUIElementIsAttributeSettable(cur, "AXMakeScreenRectVisible" as CFString, &settable) == .success && settable.boolValue ? cur : nil
            }
            e = AX.parent(cur)
        }
        return nil
    }()

    func visibleRect() -> CGRect? {
        guard var r = AX.frame(element) else { return nil }
        if let parent = AX.parent(element), let f = AX.frame(parent) { r = r.intersection(f) }
        if let window = AX.element(AX.attr(element, kAXWindowAttribute)), let f = AX.frame(window) { r = r.intersection(f) }
        return r.isEmpty ? nil : r
    }

    /// Preview scrolls a box into view. WebKit's plugin scrolls only whole pages (`AXScrollToVisible`
    /// puts the page's top at the view's top), so a sentence on another page brings that page up, and
    /// one in the hidden foot of the page on view stays where it is.
    func scrollIntoView(_ sentence: Sentence) {
        guard let r = sentence.range as? PDFRange else { return }
        let lines = boxes(for: r.parts)
        guard var box = lines.dropFirst().reduce(lines.first, { $0?.union($1) }) else { return }
        if let scroller {
            if let view = visibleRect(), box.height > view.height * 0.8, let first = lines.min(by: { $0.minY < $1.minY }) { box = first }
            AXUIElementSetAttributeValue(scroller, "AXMakeScreenRectVisible" as CFString, AX.rectValue(box))
            return
        }
        let pageElement = pageElements[r.start.page]
        guard let view = visibleRect(), let f = AX.frame(pageElement), abs(f.minY - view.minY) > 2 else { return }
        AXUIElementPerformAction(pageElement, "AXScrollToVisible" as CFString)
    }
}

/// Whether two halves of a word broken at a line end make one word, by the
/// system word list (`/usr/share/dict/words`, base forms) and the common
/// inflections. "para" + "graph" does, "task" + "specific" doesn't.
enum Hyphens {
    private static let words: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()

    /// Whether "left-" at a line end and "right" on the next make one word: they do when
    /// the whole is a word, or when a half isn't one ("unidi-rectionality", "pre-train").
    static func join(_ left: String, _ right: String) -> Bool {
        guard !words.isEmpty else { return true } // no list: a line-end hyphen is usually a break
        return isWord(left + right) || !isWord(left) || !isWord(right)
    }

    static func isWord(_ w: String) -> Bool {
        let s = w.lowercased()
        guard s.count >= 2 else { return false }
        if words.contains(s) { return true }
        for (suffix, stems) in [("ies", ["y"]), ("ied", ["y"]), ("ing", ["", "e"]), ("ed", ["", "e"]), ("es", [""]), ("s", [""]), ("ly", [""]), ("er", ["", "e"]), ("est", ["", "e"]), ("ness", [""]), ("ment", [""]), ("tion", ["te", "t"]), ("ity", ["", "e"]), ("al", [""]), ("ally", [""]), ("ive", ["", "e"]), ("ous", [""]), ("able", ["", "e"]), ("ible", [""]), ("ful", [""]), ("less", [""]), ("ism", [""]), ("ist", [""])] {
            guard s.hasSuffix(suffix), s.count > suffix.count + 2 else { continue }
            let base = String(s.dropLast(suffix.count))
            for stem in stems where words.contains(base + stem) { return true }
            // A doubled final consonant ("stopping"): the base is one shorter.
            if let last = base.last, base.count >= 2, base[base.index(before: base.endIndex)] == last, words.contains(String(base.dropLast())) { return true }
        }
        return false
    }
}
