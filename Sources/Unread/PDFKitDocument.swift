import AppKit
import ApplicationServices
import NaturalLanguage

/// A reading position in a PDFKit document (#86): a block, and how far into its unit's spoken
/// text the reading has come. Two positions made for the same place are equal, so a steady
/// aim is one aim (`App.steadyAim`) and the speculation fires.
final class PDFKitPosition: NSObject {
    let block: PDFPage.BlockID
    /// Sentences of the block's unit that end after this offset in its spoken text are still to read.
    let spoken: Int
    /// The start the user pointed at: its block is read whatever it is.
    let pointed: Bool
    /// A caption's start reached from its cue: don't cue it again.
    let afterCue: Bool
    /// A detour: a sentence that crossed a page break skipped the blocks between its parts (a
    /// table and its caption at the top of the next page). They're read from `block` up to
    /// `until`, then the reading goes on at `then`.
    let until: PDFPage.BlockID?
    let then: PDFKitPosition?

    init(block: PDFPage.BlockID, spoken: Int = 0, pointed: Bool = false, afterCue: Bool = false, until: PDFPage.BlockID? = nil, then: PDFKitPosition? = nil) {
        self.block = block; self.spoken = spoken; self.pointed = pointed; self.afterCue = afterCue; self.until = until; self.then = then
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? PDFKitPosition else { return false }
        return block == o.block && spoken == o.spoken && pointed == o.pointed && afterCue == o.afterCue && until == o.until && then == o.then
    }
    override var hash: Int {
        var h = Hasher()
        h.combine(block); h.combine(spoken); h.combine(pointed); h.combine(afterCue)
        return h.finalize()
    }
}

/// A sentence's place in a PDFKit document: ranges in pages' strings, one per run of text (a
/// sentence can cross a page break, or skip a caption that sits inside it).
final class PDFRange: NSObject {
    struct Part { let page: Int; let range: NSRange }
    let parts: [Part]
    init(_ parts: [Part]) { self.parts = parts }
}

/// PDFKit's pages (Preview, Safari, WKWebView; #86). Every page is an `AXPage` from the start;
/// `PDFPage` parses one into blocks. A block that doesn't end like a sentence carries on into
/// the next paragraph, across a column or a page, past a caption in between (read after the
/// sentence that crossed it). Line-end hyphens are resolved by `Hyphens`. Boxes come from the
/// `AXStaticText` leaves under the page, which measure sub-ranges per line but hold the
/// page's text with "\n" at every line end, so each leaf is matched to the page string
/// ignoring whitespace.
final class PDFKitDocument: ReadableDocument {
    typealias BlockID = PDFPage.BlockID
    private typealias Block = PDFPage.Block

    /// The pages' container (`AXSharedDocumentContainer` in Preview, the plugin group in WebKit).
    let element: AXUIElement
    private let pageElements: [AXUIElement]
    private var strings: [Int: NSAttributedString?] = [:]
    /// Pages parsed, their reference list not yet known (`referencesOpen` looks back through these).
    private var parsed: [Int: PDFPage] = [:]
    /// Pages parsed and placed in or out of the reference list.
    private var pages: [Int: PDFPage] = [:]
    private var leafIndex: [Int: LeafIndex] = [:]
    private var lineRangesMemo: [AXKey: [NSRange]] = [:]
    private var units: [BlockID: Unit] = [:]
    /// Per page, the last block a unit or a lookup has used: blocks up to it keep their place (`retryOrder`).
    private var used: [Int: Int] = [:]
    /// Pages `PDFPage.reorder` couldn't judge for lack of frames (Preview, out of view).
    private var unordered: Set<Int> = []
    /// The words the document writes, from its first pages and every page parsed since.
    private var vocabulary = Hyphens.Vocabulary()
    private var inVocabulary: Set<Int> = []
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

    private func string(of i: Int) -> NSAttributedString? {
        if let s = strings[i] { return s }
        let e = pageElements[i]
        let count = (AX.attr(e, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue ?? 0
        let s = count > 0 ? AX.param(e, "AXAttributedStringForRange", AX.rangeValue(NSRange(location: 0, length: count))) as? NSAttributedString : nil
        strings[i] = s
        return s
    }

    /// The size most of the document's characters are set in, from its first pages: a page
    /// that is one figure has more label text than body text, so its own count would lie.
    private lazy var bodySize: CGFloat = {
        var histogram: [CGFloat: Int] = [:]
        for s in (0..<min(3, pageElements.count)).compactMap({ string(of: $0) }) { for (size, n) in PDFPage.sizeHistogram(of: s) { histogram[size, default: 0] += n } }
        return PDFPage.dominant(histogram) ?? 0
    }()

    /// The sizes headings come in, from the first pages: a figure's title on a later page is set at another.
    private lazy var headingSizes: Set<CGFloat> = {
        var sizes: Set<CGFloat> = []
        for i in 0..<min(3, pageElements.count) {
            guard let s = string(of: i) else { continue }
            sizes.formUnion(PDFPage.headingSizes(of: s, body: bodySize, running: runningLines(of: i)))
        }
        return sizes
    }()

    /// The lines at the top or foot of page `i` that are at the top or foot of a page one or two
    /// away too, in the same size (digits aside): a running header or footer, which a book sets
    /// like its text, alternating its title and the chapter's.
    private func runningLines(of i: Int) -> [NSRange] {
        guard let own = string(of: i) else { return [] }
        var near: Set<String> = []
        for j in [i - 2, i - 1, i + 1, i + 2] where pageElements.indices.contains(j) {
            if let s = string(of: j) { near.formUnion(PDFPage.edgeLines(of: s).map(\.key)) }
        }
        return PDFPage.edgeLines(of: own).filter { near.contains($0.key) }.map(\.range)
    }

    /// Hyphens are judged by the words the document writes: its first pages', then each page's as it's parsed.
    private func learnWords(of i: Int) {
        for j in Array(0..<min(3, pageElements.count)) + [i] where inVocabulary.insert(j).inserted {
            if let s = string(of: j) { vocabulary.add(s.string) }
        }
    }

    private func parse(_ i: Int) -> PDFPage? {
        guard pageElements.indices.contains(i) else { return nil }
        if let p = parsed[i] { return p }
        learnWords(of: i)
        let p = PDFPage(index: i, attributed: string(of: i) ?? NSAttributedString(), body: bodySize, headingSizes: headingSizes, running: runningLines(of: i))
        if p.mayBeOutOfOrder, !p.reorder(frame: { [self] line in frame(of: line, on: i) }) { unordered.insert(i) }
        if p.hasFigure { p.markLabelStacks(wraps: index(of: i).wraps) }
        parsed[i] = p
        return p
    }

    /// A page parsed out of view in Preview had no frames to put its lines in order by: now that it
    /// has them (its leaves measure), order the blocks nothing has used yet.
    private func retryOrder(_ i: Int) {
        guard unordered.remove(i) != nil, let p = parsed[i] else { return }
        let before = p.blocks.map { $0.lines.map(\.range.location) }
        if !p.reorder(after: used[i] ?? -1, frame: { [self] line in frame(of: line, on: i) }) { unordered.insert(i) }
        guard p.blocks.map({ $0.lines.map(\.range.location) }) != before else { return }
        if p.hasFigure { p.markLabelStacks(wraps: index(of: i).wraps) }
        if pages[i] != nil { p.resolveReferences(openAtStart: referencesOpen(before: i)) }
        if debugWalk { print("[pdf] page \(i + 1) put in order once it had frames, from block \((used[i] ?? -1) + 1)") }
    }

    private func page(_ i: Int) -> PDFPage? {
        if let p = pages[i] { return p }
        guard let p = parse(i) else { return nil }
        p.resolveReferences(openAtStart: referencesOpen(before: i))
        pages[i] = p
        if debugWalk {
            for b in p.blocks { print("[pdf] page \(i + 1) block \(b.id.index) \(b.kind)\(b.inReferences ? " refs" : "") \(b.lines.count) lines: \(b.lines.map { "\($0.size)\($0.bold ? "b" : "")\($0.small ? "s" : "") \($0.text.prefix(40).debugDescription)" }.joined(separator: " | "))") }
        }
        return p
    }

    /// Whether the reference list runs into page `i`: the page before says if it's been placed
    /// already (a reading walks in order), else the nearest earlier page with a heading, looking
    /// back eight pages at most and only parsing them, so a hold on page 300 of a book doesn't
    /// parse 299 pages first.
    private func referencesOpen(before i: Int) -> Bool {
        for j in stride(from: i - 1, through: max(0, i - 8), by: -1) {
            if let p = pages[j] { return p.referencesAtEnd }
            if let open = parse(j)?.referencesAfterLastHeading { return open }
        }
        return false
    }

    private func block(_ id: BlockID) -> Block? {
        guard let p = page(id.page), p.blocks.indices.contains(id.index) else { return nil }
        use(id)
        return p.blocks[id.index]
    }

    private func use(_ id: BlockID) { used[id.page] = max(used[id.page] ?? -1, id.index) }

    /// The block after `id` in page order, on this page or the next ones.
    private func nextBlock(after id: BlockID) -> BlockID? {
        var page = id.page, index = id.index + 1
        while let p = self.page(page) {
            if index < p.blocks.count { return BlockID(page: page, index: index) }
            page += 1; index = 0
        }
        return nil
    }

    private func previousBlock(before id: BlockID) -> BlockID? {
        var page = id.page, index = id.index - 1
        while page >= 0, let p = self.page(page) {
            if index >= 0, index < p.blocks.count { return BlockID(page: page, index: index) }
            page -= 1
            if page >= 0, let q = self.page(page) { index = q.blocks.count - 1 }
        }
        return nil
    }

    private func readable(_ b: Block) -> Bool {
        b.kind != .furniture && (!b.inReferences || referencesReadable)
    }

    // MARK: Units: what a block (and the blocks it runs on into) says

    /// One UTF-16 unit of the text to read, and where it is.
    private struct Loc { let block: BlockID; let offset: Int }

    /// A run of blocks read as one text: a paragraph that runs over a column or page end, with
    /// its line ends, footnote markers and line-end hyphens resolved, cut into sentences.
    private struct Unit {
        let blocks: [BlockID]
        /// Readable blocks between members (a caption inside the paragraph), read after the sentence that crosses them.
        let gaps: [BlockID]
        let spoken: String
        let locs: [Loc]
        let sentences: [NSRange]
        func spokenStart(of block: BlockID) -> Int { locs.firstIndex { $0.block == block } ?? 0 }
        func block(at spoken: Int) -> BlockID { locs[min(max(spoken, 0), locs.count - 1)].block }
    }

    /// A paragraph that doesn't end like a sentence carries on into the next paragraph: across a
    /// column end or a page break, and past a caption in between.
    private func unit(containing start: Block) -> Unit {
        if let u = units[start.id] { return u }
        func carriesOn(_ b: Block) -> Bool { b.kind != .heading && !b.endsLikeSentence }
        /// A paragraph the sentence can run into: not a list item, and not already another unit's.
        func continues(_ b: Block) -> Bool { b.kind == .paragraph && !b.lines[0].isListItem && units[b.id] == nil }
        var members = [start], gaps: [BlockID] = []
        if start.kind == .paragraph, !start.lines[0].isListItem {
            var first = start
            for _ in 0..<8 {
                guard let (prev, skipped) = neighbour(of: first.id, forward: false), continues(prev), carriesOn(prev) else { break }
                first = prev; members.insert(prev, at: 0); gaps.insert(contentsOf: skipped, at: 0)
            }
        }
        for _ in 0..<8 {
            guard let last = members.last, carriesOn(last), let (next, skipped) = neighbour(of: last.id, forward: true), continues(next) else { break }
            members.append(next); gaps.append(contentsOf: skipped)
        }
        let u = make(members, gaps: gaps)
        for m in members { units[m.id] = u; use(m.id) }
        gaps.forEach(use)
        return u
    }

    /// The nearest readable block that isn't a caption in one direction, and the captions skipped on the way.
    private func neighbour(of id: BlockID, forward: Bool) -> (Block, [BlockID])? {
        var skipped: [BlockID] = []
        var cur = id
        while let n = forward ? nextBlock(after: cur) : previousBlock(before: cur), let b = block(n) {
            cur = n
            guard readable(b) else { continue }
            if case .caption = b.kind { skipped.append(n); continue }
            return (b, forward ? skipped : skipped.reversed())
        }
        return nil
    }

    private func make(_ blocks: [Block], gaps: [BlockID]) -> Unit {
        var raw: [UInt16] = [], locs: [Loc] = []
        func append(_ u: UInt16, _ loc: Loc) {
            if u == 0x20, raw.last == 0x20 { return }
            raw.append(u); locs.append(loc)
        }
        for b in blocks {
            guard let p = page(b.id.page) else { continue }
            if let last = locs.last, raw.last != 0x20 { append(0x20, last) }
            for line in b.lines {
                let bullet = Self.bullet(of: line, in: p.text)
                for i in line.range.location..<NSMaxRange(line.range) {
                    let loc = Loc(block: b.id, offset: i)
                    if i == bullet || line.markers.contains(where: { NSLocationInRange(i, $0) }) { append(0x20, loc); continue }
                    if line.subscripts.contains(where: { $0.location == i }), let last = raw.last, Self.isLetter(last) || Self.isDigit(last) { append(0x20, loc) } // "BERT" + "BASE": two words
                    let u = p.text.character(at: i)
                    append(Self.isSpace(u) ? 0x20 : u, loc)
                }
                // The line's end, as a space standing on its last character: never past the text.
                append(0x20, Loc(block: b.id, offset: NSMaxRange(line.range) - 1))
            }
        }
        let french = Self.isFrench(raw)
        // Line-end hyphens: "para- graph" is one word, "task- specific" keeps its hyphen, "pre- and" stays apart.
        var out: [UInt16] = [], outLocs: [Loc] = []
        var i = 0
        while i < raw.count {
            let u = raw[i]
            if u == 0x2D, i > 0, Self.isLetter(raw[i - 1]), i + 1 < raw.count, raw[i + 1] == 0x20 {
                var j = i + 1
                while j < raw.count, raw[j] == 0x20 { j += 1 }
                // Only at a line end (the leaf's text has "\n" there; a hyphen inside a line, "pre- and", is left as written).
                if j < raw.count, Self.isLetter(raw[j]), lineEnds(after: locs[i]) != false {
                    var l = i - 1
                    while l > 0, Self.isLetter(raw[l - 1]) { l -= 1 }
                    var r = j
                    while r < raw.count, Self.isLetter(raw[r]) { r += 1 }
                    let left = String(utf16CodeUnits: Array(raw[l..<i]), count: i - l), right = String(utf16CodeUnits: Array(raw[j..<r]), count: r - j)
                    // A half that starts in upper case is a name ("Berkeley-Parser"); a half with a hyphen of its own is
                    // in a chain ("left-to-right"): the hyphen stays. French has no word list: only the document's
                    // own spelling joins a French word.
                    let chained = r < raw.count && raw[r] == 0x2D
                    let join = chained || !Self.isLowercaseLetter(raw[j]) ? Hyphens.Join.compound : Hyphens.join(left, right, in: vocabulary, wordList: !french)
                    switch join {
                    case .word: i = j; continue // drop "- "
                    case .compound: out.append(u); outLocs.append(locs[i]); i = j; continue // keep "-", drop the space
                    case .apart: break
                    }
                }
            }
            out.append(u); outLocs.append(locs[i]); i += 1
        }
        let spoken = String(utf16CodeUnits: out, count: out.count)
        if debugWalk { print("[pdf] unit \(blocks.map { "p\($0.id.page + 1)b\($0.id.index)" }.joined(separator: "+"))\(gaps.isEmpty ? "" : " skipping \(gaps.map { "p\($0.page + 1)b\($0.index)" }.joined(separator: ","))"): \(spoken.debugDescription)") }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = spoken
        // A label alone ("§ 2.", "3.1.", "2.") numbers the sentence after it, as in `PDFLayout`; PDFKit's text
        // doesn't say where a paragraph starts.
        var sentences: [NSRange] = [], label: Int?
        for t in tokenizer.tokens(for: spoken.startIndex..<spoken.endIndex) {
            var r = NSRange(t, in: spoken)
            if let l = label { r = NSRange(location: l, length: NSMaxRange(r) - l); label = nil }
            let text = (spoken as NSString).substring(with: r).trimmingCharacters(in: .whitespaces)
            if Self.numberLabel.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil {
                label = r.location
                continue
            }
            sentences.append(r)
        }
        return Unit(blocks: blocks.map(\.id), gaps: gaps, spoken: spoken, locs: outLocs, sentences: sentences)
    }

    private static let numberLabel = try! NSRegularExpression(pattern: #"^[§¶]?\s*\d{1,3}(\.\d{1,3})*\.$"#)

    /// Bullets that start a list item's line: blanked, as on a web page, where they're markers of their own.
    private static let bullets = CharacterSet(charactersIn: "•◦▪▫‣●○■□➢►")

    /// Where a line's leading bullet is, if it starts with one followed by a space.
    private static func bullet(of line: PDFPage.Line, in text: NSString) -> Int? {
        guard let i = (line.range.location..<NSMaxRange(line.range)).first(where: { !isSpace(text.character(at: $0)) }),
              i + 1 < NSMaxRange(line.range), isSpace(text.character(at: i + 1)),
              let u = Unicode.Scalar(text.character(at: i)), bullets.contains(u) else { return nil }
        return i
    }

    private static func isFrench(_ raw: [UInt16]) -> Bool {
        guard raw.count >= 24 else { return false }
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.english, .french]
        r.processString(String(utf16CodeUnits: raw, count: raw.count))
        return (r.languageHypotheses(withMaximum: 2)[.french] ?? 0) > 0.8
    }

    private static func isSpace(_ u: UInt16) -> Bool { Unicode.Scalar(u).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false }
    private static func isLetter(_ u: UInt16) -> Bool { Unicode.Scalar(u).map { CharacterSet.letters.contains($0) } ?? false }
    private static func isLowercaseLetter(_ u: UInt16) -> Bool { Unicode.Scalar(u).map { CharacterSet.lowercaseLetters.contains($0) } ?? false }
    private static func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }

    /// The parts of a unit's range: one per run of the page's text, so a sentence that crosses a
    /// page, skips a caption or reads lines out of text order gets a box for each run and nothing between.
    private func parts(of u: Unit, _ r: NSRange) -> [PDFRange.Part] {
        var parts: [PDFRange.Part] = []
        for loc in u.locs[r.location..<NSMaxRange(r)] {
            if let last = parts.last, last.page == loc.block.page, loc.offset >= last.range.location, loc.offset <= NSMaxRange(last.range) + 1 {
                parts[parts.count - 1] = PDFRange.Part(page: last.page, range: NSRange(location: last.range.location, length: max(NSMaxRange(last.range), loc.offset + 1) - last.range.location))
            } else {
                parts.append(PDFRange.Part(page: loc.block.page, range: NSRange(location: loc.offset, length: 1)))
            }
        }
        return parts
    }

    // MARK: ReadableDocument

    func documentStart() -> AnyObject? { PDFKitPosition(block: BlockID(page: 0, index: 0)) }

    /// A position at a block's own text: the sentence straddling its start is read whole.
    private func position(at b: Block, pointed: Bool = false) -> PDFKitPosition {
        PDFKitPosition(block: b.id, spoken: unit(containing: b).spokenStart(of: b.id), pointed: pointed)
    }

    func sentence(from position: AnyObject, in scope: ReadingScope?) -> Sentence? {
        guard let pos = position as? PDFKitPosition else { return nil }
        var cursor: BlockID? = pos.block
        var spoken = pos.spoken, pointed = pos.pointed, afterCue = pos.afterCue
        // Members of the unit a detour returns to, and of units read out, aren't read again on the way.
        var skip = Set(pos.then.flatMap { block($0.block) }.map { unit(containing: $0).blocks } ?? [])
        while let id = cursor {
            if id == pos.until, let then = pos.then { return sentence(from: then, in: scope) }
            guard let b = block(id) else { cursor = nextBlock(after: id); continue }
            if pointed {
                if b.inReferences { referencesReadable = true }
                pointed = false
            } else if !readable(b) || skip.contains(id) {
                cursor = nextBlock(after: id); spoken = 0; continue
            }
            if case .caption(let kind) = b.kind, !afterCue, spoken == 0 { return cue(kind, before: b, from: pos) }
            afterCue = false
            let u = unit(containing: b)
            for r in u.sentences where NSMaxRange(r) > spoken {
                guard let text = SpeechText.clean((u.spoken as NSString).substring(with: r), listCitations: true) else { continue }
                let parts = parts(of: u, r)
                if debugWalk { print("[pdf] sentence \(parts.map { "p\($0.page + 1) \($0.range.location)+\($0.range.length)" }.joined(separator: ", ")): \(text.prefix(60).debugDescription)") }
                return Sentence(text: text, range: PDFRange(parts), next: next(after: r, in: u, from: pos))
            }
            skip.formUnion(u.blocks)
            cursor = nextBlock(after: id); spoken = 0
        }
        return nil
    }

    /// Where the reading goes after sentence `r` of unit `u`: on in the unit, or, when the unit
    /// skipped blocks the reading has now passed (a caption inside the sentence, or between it and
    /// the next one), through them first and back to the unit after.
    private func next(after r: NSRange, in u: Unit, from pos: PDFKitPosition) -> PDFKitPosition {
        let first = u.block(at: r.location), last = u.block(at: NSMaxRange(r) - 1)
        let resume = PDFKitPosition(block: last, spoken: NSMaxRange(r), until: pos.until, then: pos.then)
        let upTo = u.sentences.first { $0.location >= NSMaxRange(r) }.map { u.block(at: $0.location) } ?? u.blocks[u.blocks.count - 1]
        guard let gap = u.gaps.first(where: { first < $0 && $0 < upTo }) else { return resume }
        return PDFKitPosition(block: gap, until: upTo, then: resume)
    }

    /// The figure's cue, over the figure's text (short lines, or small ones) before its caption, else
    /// after it, or, without any, the caption itself.
    private func cue(_ kind: String, before caption: Block, from pos: PDFKitPosition) -> Sentence {
        var ranges = caption.ranges
        if let p = page(caption.id.page) {
            var labels: [NSRange] = []
            var i = caption.id.index - 1
            while i >= 0, p.blocks[i].isFigureText { labels.insert(contentsOf: p.blocks[i].ranges, at: 0); i -= 1 }
            if labels.isEmpty {
                i = caption.id.index + 1
                while i < p.blocks.count, p.blocks[i].isFigureText { labels.append(contentsOf: p.blocks[i].ranges); i += 1 }
            }
            if !labels.isEmpty { ranges = labels }
        }
        return Sentence(text: "", range: PDFRange(ranges.map { PDFRange.Part(page: caption.id.page, range: $0) }),
                        next: PDFKitPosition(block: caption.id, afterCue: true, until: pos.until, then: pos.then), cue: kind)
    }

    func paragraph(at point: CGPoint) -> (start: AnyObject, bounds: CGRect)? {
        guard let i = pageElements.firstIndex(where: { AX.frame($0)?.contains(point) ?? false }), let pageFrame = AX.frame(pageElements[i]), let p = page(i) else { return nil }
        let candidates = leaves(of: i).compactMap { l in l.frame(on: pageFrame).map { (leaf: l, frame: $0) } }.filter { $0.frame.contains(point) }
        guard let (leaf, leafFrame) = candidates.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
        // The line under the point, else the leaf's first character.
        var offset = leaf.first
        for lr in lineRanges(of: leaf) {
            guard let box = bounds(leaf.element, lr), box.minY <= point.y, point.y <= box.maxY else { continue }
            if let o = (lr.location..<NSMaxRange(lr)).lazy.compactMap({ leaf.offsets[$0] >= 0 ? leaf.offsets[$0] : nil }).first { offset = o }
            break
        }
        guard let b = p.block(containing: offset) else { return nil }
        // The block's lines in the pointed column: a paragraph that runs into the next column is shown there only.
        let lines = boxes(for: b.ranges.map { PDFRange.Part(page: i, range: $0) }).filter { $0.minX < leafFrame.maxX && $0.maxX > leafFrame.minX }
        guard let box = CGRect.union(of: lines) else { return nil }
        return (position(at: b, pointed: true), box)
    }

    func firstVisible() -> AnyObject? {
        guard let visible = visibleRect() else { return documentStart() }
        for (i, e) in pageElements.enumerated() {
            guard let f = AX.frame(e), f.intersects(visible), let p = page(i) else { continue }
            var measured = 0
            for b in p.blocks where readable(b) && measured < 40 {
                measured += 1
                let lines = boxes(for: b.ranges.map { PDFRange.Part(page: i, range: $0) })
                if lines.contains(where: { $0.intersects(visible) }) { return position(at: b) }
            }
            return PDFKitPosition(block: BlockID(page: i, index: 0))
        }
        return documentStart()
    }

    // MARK: Leaves and boxes

    /// An `AXStaticText` under a page, and where each of its characters is in the page's string (−1: nowhere).
    private struct Leaf {
        let element: AXUIElement
        let text: NSString
        let offsets: [Int]
        let first: Int, last: Int
        /// Its frame relative to the page's origin, so a scroll (which moves both) doesn't stale it.
        /// Nil when it can't be measured: Preview gives no frames on a page out of view, and PDFKit
        /// gives some leaves after a dropped run a box in the PDF's own coordinates, off the page.
        let box: CGRect?
        func frame(on page: CGRect) -> CGRect? { box?.offsetBy(dx: page.minX, dy: page.minY) }
    }

    private struct LeafIndex {
        /// The leaves that can be measured.
        let leaves: [Leaf]
        /// Page offsets of the last character of a line, where a leaf's text has "\n".
        let lineEnds: Set<Int>
        /// Page offsets some leaf holds: elsewhere nothing is known about line ends.
        let covered: [NSRange]
        /// The line ends alone, where a leaf's text has "\n" (`lineEnds` also has each leaf's end).
        let wraps: Set<Int>
        /// A leaf the page had no frame for (Preview, out of view): the index is built again once it has one.
        let unmeasured: AXUIElement?
    }

    private func leaves(of pageIndex: Int) -> [Leaf] { index(of: pageIndex).leaves }

    /// Whether the character at `loc` ends a line; nil where no leaf holds it.
    private func lineEnds(after loc: Loc) -> Bool? {
        let idx = index(of: loc.block.page)
        guard idx.covered.contains(where: { NSLocationInRange(loc.offset, $0) }) else { return nil }
        return idx.lineEnds.contains(loc.offset)
    }

    private func index(of pageIndex: Int) -> LeafIndex {
        if let l = leafIndex[pageIndex], l.unmeasured.map({ AX.frame($0) == nil }) ?? true { return l }
        let text = (string(of: pageIndex)?.string ?? "") as NSString
        var found: [(AXUIElement, NSString)] = []
        var stack = [pageElements[pageIndex]]
        var seen = 0
        while let e = stack.popLast(), seen < 20_000 {
            seen += 1
            if AX.role(e) == kAXStaticTextRole {
                if let v = AX.attr(e, kAXValueAttribute) as? String, !v.isEmpty { found.append((e, v as NSString)) }
                continue
            }
            stack.append(contentsOf: AX.children(e).reversed())
        }
        // Match each leaf to the page string ignoring whitespace: the leaf has "\n" at line ends, the
        // page a space, or a "\n" of its own after a link.
        var compact: [UInt16] = [], compactToPage: [Int] = []
        for i in 0..<text.length { let u = text.character(at: i); if !Self.isSpace(u) { compact.append(u); compactToPage.append(i) } }
        var cursor = 0
        var result: [Leaf] = []
        var lineEnds: Set<Int> = [], wraps: Set<Int> = [], covered: [NSRange] = [], unmeasured: AXUIElement?
        let pageFrame = AX.frame(pageElements[pageIndex])
        for (e, leafText) in found {
            var leafCompact: [UInt16] = [], compactToLeaf: [Int] = []
            for i in 0..<leafText.length { let u = leafText.character(at: i); if !Self.isSpace(u) { leafCompact.append(u); compactToLeaf.append(i) } }
            var offsets = [Int](repeating: -1, count: leafText.length)
            guard !leafCompact.isEmpty else { continue }
            let at = Self.find(leafCompact, in: compact, from: cursor) ?? Self.find(leafCompact, in: compact, from: 0)
            guard let at else {
                if debugWalk { print("[pdf] leaf not in page \(pageIndex + 1)'s text: \((leafText as String).prefix(40).debugDescription)") }
                continue
            }
            for (k, li) in compactToLeaf.enumerated() {
                offsets[li] = compactToPage[at + k]
                if li + 1 < leafText.length, leafText.character(at: li + 1) == 0x0A { wraps.insert(compactToPage[at + k]) }
            }
            let first = compactToPage[at], last = compactToPage[at + leafCompact.count - 1]
            lineEnds.insert(last) // a leaf ends where a link starts or a line does: a hyphen there was the typesetter's
            covered.append(NSRange(location: first, length: last - first + 1))
            cursor = at + leafCompact.count
            let frame = AX.frame(e)
            if frame == nil { unmeasured = unmeasured ?? e }
            let onPage = frame.flatMap { f in pageFrame.flatMap { $0.insetBy(dx: -4, dy: -4).contains(f) ? f.offsetBy(dx: -$0.minX, dy: -$0.minY) : nil } }
            if debugWalk, let frame, onPage == nil { print("[pdf] leaf off page \(pageIndex + 1): \(frame) \((leafText as String).prefix(30).debugDescription)") }
            result.append(Leaf(element: e, text: leafText, offsets: offsets, first: first, last: last, box: onPage))
        }
        let idx = LeafIndex(leaves: result.filter { $0.box != nil }, lineEnds: lineEnds.union(wraps), covered: covered, wraps: wraps, unmeasured: unmeasured)
        leafIndex[pageIndex] = idx
        if debugWalk { print("[pdf] leaves of page \(pageIndex + 1): \(found.count) found, \(idx.leaves.count) measured") }
        if unmeasured == nil { retryOrder(pageIndex) }
        return idx
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
        while line < 400, let v = AX.param(leaf.element, kAXRangeForLineParameterizedAttribute, line as NSNumber), let r = AX.range(v) {
            guard r.length > 0, NSMaxRange(r) <= leaf.text.length else { break }
            if let last = ranges.last, NSMaxRange(last) > r.location { break }
            ranges.append(r)
            if NSMaxRange(r) >= leaf.text.length { break }
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
            var covered = 0, holder: Leaf?
            let measured = out.count
            for leaf in pageLeaves {
                guard let lr = leafRange(leaf, part.range) else { continue }
                covered += lr.length
                holder = holder ?? leaf
                for line in lineRanges(of: leaf) {
                    let x = NSIntersectionRange(line, lr)
                    guard x.length > 0, let b = bounds(leaf.element, x) else { continue }
                    out.append(b)
                }
            }
            if out.count == measured, let holder, let leafFrame = AX.frame(holder.element) {
                out.append(leafFrame) // held by a leaf that won't measure its ranges ("See Figure 2." in Preview)
            } else if covered * 2 < part.range.length,
               let near = pageLeaves.first(where: { $0.first >= part.range.location }) ?? pageLeaves.last(where: { $0.last < part.range.location }),
               let leafFrame = AX.frame(near.element) {
                out.append(paragraphGroup(of: near.element, leafFrame: leafFrame) ?? leafFrame)
            }
        }
        return WebDocument.groupIntoLines(out)
    }

    /// Where a line of the page's text is, for `PDFPage.reorder`.
    private func frame(of line: PDFPage.Line, on page: Int) -> CGRect? {
        CGRect.union(of: boxes(for: [PDFRange.Part(page: page, range: line.range)]))
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
        if sentence.cue != nil, let u = CGRect.union(of: lines) { return [u] }
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
            let end = min(NSMaxRange(part.range), p.text.length)
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
    /// puts the page's top at the view's top), so that's done when the sentence is out of view on a
    /// page whose top is below the view's, or off screen; on a page scrolled partway it would scroll
    /// back up, away from the sentence, so there the reading stays where it is. A sentence that
    /// crosses a page break scrolls to the page of its part in view, else of its first part on a page
    /// not entirely above the view: pointing at a page's first line, whose sentence began at the foot
    /// of the page before, doesn't scroll back to that page's top.
    ///
    /// Preview measures nothing on a page out of view, so a sentence there is found by scrolling its
    /// page's top into view first (`measuresOffScreen`).
    func scrollIntoView(_ sentence: Sentence) -> Bool {
        guard let r = sentence.range as? PDFRange, let first = r.parts.first, let view = visibleRect() else { return false }
        var lines = boxes(for: r.parts)
        if lines.isEmpty, let scroller, let page = AX.frame(pageElements[first.page]), !page.intersects(view) {
            let top = CGRect(x: page.minX, y: page.minY, width: page.width, height: min(page.height, view.height))
            AXUIElementSetAttributeValue(scroller, "AXMakeScreenRectVisible" as CFString, AX.rectValue(top))
            // The page's frames can come a moment after the scroll: wait for them, 0.2 s at most. Once
            // the page is in view this isn't done again (it would help nothing).
            for _ in 0..<10 {
                lines = boxes(for: r.parts)
                if !lines.isEmpty { break }
                usleep(20_000)
            }
        }
        guard var box = CGRect.union(of: lines) else { return false }
        if let scroller {
            if box.height > view.height * 0.8, let top = lines.min(by: { $0.minY < $1.minY }) { box = top }
            AXUIElementSetAttributeValue(scroller, "AXMakeScreenRectVisible" as CFString, AX.rectValue(box))
            return true
        }
        guard !view.contains(box) else { return false }
        var pages: [Int] = []
        for part in r.parts where !pages.contains(part.page) { pages.append(part.page) }
        let shown = pages.first { i in CGRect.union(of: boxes(for: r.parts.filter { $0.page == i })).map(view.intersects) ?? false }
        let target = shown ?? pages.first { AX.frame(pageElements[$0]).map { $0.maxY > view.minY } ?? true } ?? pages[pages.count - 1]
        guard let f = AX.frame(pageElements[target]), f.minY > view.minY + 2 || f.maxY <= view.minY else { return false }
        AXUIElementPerformAction(pageElements[target], "AXScrollToVisible" as CFString)
        return true
    }

    /// WebKit measures every page; Preview only those in view.
    var measuresOffScreen: Bool { scroller == nil }

    /// The frames of the sentence's pages, which Preview gives for every page, in view or not.
    func place(of sentence: Sentence) -> CGRect? {
        guard let r = sentence.range as? PDFRange else { return nil }
        return CGRect.union(of: r.parts.compactMap { AX.frame(pageElements[$0.page]) })
    }
}
