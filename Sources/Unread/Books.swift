import AppKit
import ApplicationServices
import NaturalLanguage

/// A book open in Apple Books (#87). Books is an iOS-style app: its book view is WebKit behind
/// the iOS accessibility bridge, so `WebDocument`'s calls fail on it (the web area answers no
/// text call), but each text leaf answers the bridge's own marker calls: a marker steps by
/// character and by line through the whole chapter, any marker range has bounds and a string,
/// and `AXIndexForTextMarker` gives a marker's offset in the chapter's text, the same text that
/// `AXAttributedStringForTextMarkerRange` returns. The chapter is one flow laid out as columns
/// (two pages a spread): lines left of the window were read, lines right of it come next.
///
/// Positions are markers with their index. A block is the text between two "\n", with its
/// lines (the bridge ends a line at a wrap and at a "\n"). Markers survive page turns, which
/// `AXScrollRightByPage` / `AXScrollLeftByPage` on a leaf perform without focus or key events,
/// hidden or not. A chapter is one flow: past its end the next page is another web area, so
/// the flow's end is a position of its own. A lookup from it never turns the page: it reports
/// the end (`pageEnd`), the session turns (`turnPage`) once the chapter's last sentence has
/// played, and later lookups find the next chapter once its area has filled in.
final class BooksDocument: ReadableDocument {
    let element: AXUIElement
    private let window: AXUIElement
    private var flow: Flow?
    /// The last lookup stopped at the flow's end, and the book may go on past it.
    private var stoppedAtEnd = false
    /// The way the last chapter turned ran, for a chapter with no text to judge by.
    private var rightward: Bool?
    /// The flow's end, once a lookup has reached it: `turnPage` turns past it.
    private var endReached: Position?
    /// The page turn the session asked for, while the next chapter's area fills in.
    private var turn: Turn?
    private struct Turn {
        let from: Flow
        /// The pages before the turn, as `pageState` gives them.
        let before: String
        let at: Date
        /// Another web area, the pages it showed and since when: adopted once they have held
        /// for `settled` (it fills in over ~0.3 s; a lookup and its retry come microseconds apart).
        var seen: (area: AXUIElement, pages: String, since: Date)?
        /// The wait is over: lookups no longer say more is coming, but still take the next
        /// chapter if it shows. The turn stays, so it isn't made twice.
        var waitedOut = false
    }
    /// A turn that moves nothing for this long is the book's end; once the old pages have gone,
    /// the next ones are waited for this long (they show ~0.3 s after the turn). Either way the
    /// wait ends the reading, not the book: nothing is marked ended on a timeout.
    private static let noChange: TimeInterval = 2
    private static let fillLimit: TimeInterval = 10
    private static let settled: TimeInterval = 0.1

    /// The bridge's web area: a Books web view, which has none of WebKit's text-marker
    /// parameters (only `AXReplaceRangeWithText`). Any other app's (Safari, Chromium) is a web
    /// document without a call; so is a Books area that doesn't answer.
    static func isBridged(_ area: AXUIElement) -> Bool {
        guard isBooks(AX.pid(area)) else { return false }
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(area, &names) == .success, let list = names as? [String], !list.isEmpty else { return false }
        return !list.contains("AXTextMarkerRangeForUIElement")
    }

    /// Books only (other Catalyst web views aren't known to answer the marker calls), with a
    /// chapter whose leaves answer them: a book still opening has none yet.
    static func isBooks(_ pid: pid_t) -> Bool { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.iBooksX" }

    init?(around hit: AXUIElement) {
        guard Self.isBooks(AX.pid(hit)) else { return nil }
        var e: AXUIElement? = hit
        var window: AXUIElement?
        for _ in 0..<40 {
            guard let cur = e else { break }
            if AX.role(cur) == kAXWindowRole { window = cur; break }
            e = AX.parent(cur)
        }
        guard let window else { return nil }
        self.window = window
        element = AX.children(window).first { AX.subrole($0) == "iOSContentGroup" } ?? window
        guard let flow = currentFlow(), flow.block(of: flow.anchor) != nil else { return nil }
    }

    // MARK: The chapter

    /// The web area holding the visible pages' leaves (the others are empty), and a flow over it.
    private func currentFlow() -> Flow? {
        if let flow, !Self.leaves(of: flow.area).isEmpty { return flow }
        guard let area = flow.flatMap({ Self.liveArea(after: $0, in: window) }) ?? Self.liveArea(in: window), let leaf = Self.leaves(of: area).first else { return nil }
        if let flow, CFEqual(flow.area, area) { return flow }
        flow = Flow(area: area, anchor: leaf, window: window)
        return flow
    }

    private static func liveArea(in window: AXUIElement) -> AXUIElement? {
        AX.find(in: window, maxNodes: 2000) { e, r in r == "AXWebArea" && !leaves(of: e).isEmpty }
    }

    /// The area showing pages now in place of a flow's, among the book view's, so a web area
    /// elsewhere in the window (a popover) isn't taken for the next chapter; the window's if the
    /// view has gone too.
    private static func liveArea(after flow: Flow, in window: AXUIElement) -> AXUIElement? {
        let view = flow.view.flatMap { AX.role($0) != nil ? $0 : nil } ?? window
        return AX.find(in: view, maxNodes: 2000) { e, r in r == "AXWebArea" && !CFEqual(e, flow.area) && !leaves(of: e).isEmpty }
    }

    /// The book view: the ancestor that holds every chapter's area (each in three groups of its
    /// own) and the page numbers. It outlives the areas: the cover's is gone once turned past.
    fileprivate static func view(of area: AXUIElement, in window: AXUIElement) -> AXUIElement? {
        var e = AX.parent(area)
        for _ in 0..<6 {
            guard let v = e, !CFEqual(v, window) else { return nil }
            if AX.children(v).count > 1 { return v }
            e = AX.parent(v)
        }
        return nil
    }

    /// The visible pages' text: one leaf per paragraph piece, a heading's leaf being an `AXHeading`,
    /// and their pictures (a cover or a plate is an area holding one `AXImage`).
    private static func leaves(of area: AXUIElement) -> [AXUIElement] {
        AX.children(area).filter { [kAXStaticTextRole, "AXHeading", kAXImageRole].contains(AX.role($0)) }
    }

    /// The pages: the ancestor of the web area that sits inside the window (the area itself is
    /// as wide as the chapter and mostly off screen).
    func visibleRect() -> CGRect? {
        guard let flow = currentFlow(), let wf = AX.frame(window) else { return nil }
        var e: AXUIElement? = AX.parent(flow.area)
        for _ in 0..<6 {
            guard let cur = e else { break }
            if let f = AX.frame(cur), f.minX >= wf.minX - 1, f.width <= wf.width { return f }
            e = AX.parent(cur)
        }
        return wf
    }

    private func isVisible(_ box: CGRect, in viewport: CGRect) -> Bool {
        box.midX >= viewport.minX && box.midX <= viewport.maxX && box.maxY > viewport.minY && box.minY < viewport.maxY
    }

    /// Where the text goes on in the next column (a page, two a spread, in either direction): a
    /// line above the one before it.
    static func columnBreak(after previous: CGRect, at box: CGRect) -> Bool { box.maxY <= previous.minY + 1 }

    // MARK: Positions

    func paragraph(at point: CGPoint) -> (start: AnyObject, bounds: CGRect)? {
        guard let flow = currentFlow(), let viewport = visibleRect() else { return nil }
        for leaf in Self.leaves(of: flow.area) {
            guard let f = AX.frame(leaf), f.insetBy(dx: -4, dy: -4).contains(point), let block = flow.block(of: leaf) else { continue }
            let boxes = block.lines.map { flow.box(of: $0) }
            guard let hit = boxes.firstIndex(where: { $0?.insetBy(dx: -2, dy: -3).contains(point) == true }) else { continue }
            // The bounds are the block's lines on the page pointed at: its column.
            var column = 0, previous: CGRect?
            let columns = boxes.map { box -> Int in
                if let box, let p = previous, Self.columnBreak(after: p, at: box) { column += 1 }
                if let box { previous = box }
                return column
            }
            let onPage = zip(boxes, columns).compactMap { box, c -> CGRect? in
                guard let box, c == columns[hit], isVisible(box, in: viewport) else { return nil }
                return box
            }
            guard let start = start(in: flow, block: block, viewport: viewport), let bounds = onPage.dropFirst().reduce(onPage.first, { $0?.union($1) }) else { continue }
            return (start, bounds.intersection(viewport))
        }
        return nil
    }

    /// Where to start reading a block: its start if that is on the visible pages, else the first
    /// sentence that starts there (the tail of a sentence begun on the previous page isn't read),
    /// else the next sentence after the block. At the chapter's end, the visible tail itself: a
    /// lookup never turns the page, so pointing at the last page's text reads what's on it.
    private func start(in flow: Flow, block: Block, viewport: CGRect) -> Position? {
        guard let firstVisible = block.lines.first(where: { flow.box(of: $0).map { isVisible($0, in: viewport) } == true }) else { return nil }
        if block.cue != nil { return Position(flow: flow, marker: block.start, index: block.startIndex) } // pointing at a picture cues it
        let from = firstVisible.firstCharIndex - block.startIndex
        if let s = block.sentences.first(where: { $0.location >= from }) { return flow.position(at: block.startIndex + s.location, in: block) }
        guard let next = flow.sentenceStart(after: block) else { return nil }
        guard next.atEnd else { return next }
        guard block.sentences.contains(where: { NSMaxRange($0) > from }) else { return nil }
        return flow.position(at: firstVisible.firstCharIndex, in: block)
    }

    /// The first sentence starting on the visible pages, past pictures (a page of nothing else, a
    /// plate, is its picture's cue): the leaves in the chapter's order (two calls each), their
    /// blocks built only until one has a start, not all of them first.
    func firstVisible() -> AnyObject? { currentFlow().flatMap { firstVisible(in: $0) } }

    private func firstVisible(in flow: Flow) -> AnyObject? {
        guard let viewport = visibleRect() else { return nil }
        var tried = Set<Int>(), picture: Position?
        for leaf in flow.inOrder(Self.leaves(of: flow.area)) {
            guard let block = flow.block(of: leaf), tried.insert(block.startIndex).inserted else { continue }
            guard let start = start(in: flow, block: block, viewport: viewport) else { continue }
            if block.cue != "figure" { return start }
            if picture == nil { picture = start }
        }
        return picture
    }

    /// The first visible sentence: what was read is behind, and the pages before it were turned.
    func documentStart() -> AnyObject? { firstVisible() }

    // MARK: Sentences

    func sentence(from position: AnyObject, in scope: ReadingScope?) -> Sentence? {
        guard let p = position as? Position else { return nil }
        stoppedAtEnd = false
        var pos = p
        for _ in 0..<50 {
            let flow = pos.flow
            switch pos.kind {
            case .end: return nextChapter(after: pos)
            case .after(let block):
                // Books didn't answer at this block's end when the sentence before was found: ask again.
                guard let p = flow.sentenceStart(after: block), !p.isUnresolved else {
                    print("[books] Books didn't answer at the end of the block at \(block.startIndex): the reading ends here")
                    return nil
                }
                pos = p
                continue
            case .text: break
            }
            guard let block = flow.block(containing: pos.index) ?? flow.block(startingAt: pos.marker, index: pos.index) else { return nil }
            let from = pos.index - block.startIndex
            if let kind = block.cue {
                // A picture with nothing to read, or text that can't be read at the right offsets: a cue (#24, #26), on it.
                guard let start = flow.position(at: block.startIndex, in: block), let stop = flow.position(at: block.endIndex, in: block) else { return nil }
                return Sentence(text: "", range: SentenceRange(start: start, end: stop, block: block), next: flow.sentenceStart(after: block), cue: kind)
            }
            if let i = block.sentences.firstIndex(where: { NSMaxRange($0) > from }) {
                var r = block.sentences[i]
                if r.location < from { r = NSRange(location: from, length: NSMaxRange(r) - from) }
                let end = block.startIndex + NSMaxRange(r)
                let next: Position? = i + 1 < block.sentences.count ? flow.position(at: block.startIndex + block.sentences[i + 1].location, in: block) : flow.sentenceStart(after: block)
                if let text = SpeechText.clean(block.text.substring(with: r)),
                   let start = flow.position(at: block.startIndex + r.location, in: block), let stop = flow.position(at: end, in: block) {
                    return Sentence(text: text, range: SentenceRange(start: start, end: stop, block: block), next: next)
                }
                guard let next else { return nil }
                pos = next
            } else {
                guard let next = flow.sentenceStart(after: block) else { return nil }
                pos = next
            }
        }
        return nil
    }

    /// At the flow's end, which a lookup only notes (`pageEnd`): the session turns the page
    /// (`turnPage`) once the chapter's last sentence has been said. While the turn is under way,
    /// each lookup looks at the window once, without waiting: the old area clears within ~0.15 s
    /// and the next chapter's fills in over ~0.3 s, so another area is taken once its pages have
    /// held for 0.1 s from one lookup to a later one. Then the next chapter is read from its start,
    /// by this lookup and every later one from this end; a chapter with nothing to read (a plate)
    /// is a cue, and its own end another page end. A turn that moved nothing for 2 s is the book's
    /// end, and one whose next pages haven't settled in 10 s is waited out: the reading ends.
    private func nextChapter(after end: Position) -> Sentence? {
        let from = end.flow
        if let next = from.next { return sentence(from: next, in: nil) }
        guard !from.ended else { return nil }
        endReached = end
        stoppedAtEnd = true
        guard var t = turn, t.from === from else { return nil }
        let now = Date(), waited = now.timeIntervalSince(t.at)
        if let area = Self.liveArea(after: from, in: window) {
            let pages = pageState(of: area)
            if let seen = t.seen, CFEqual(seen.area, area), seen.pages == pages {
                if now.timeIntervalSince(seen.since) >= Self.settled, let start = adopt(area, after: t) { return sentence(from: start, in: nil) }
            } else {
                t.seen = (area, pages, now)
            }
            turn = t
            if waited <= Self.fillLimit, !t.waitedOut { return nil }
        }
        let unchanged = pageState(of: from.area) == t.before
        if t.waitedOut || (unchanged ? waited > Self.noChange : waited > Self.fillLimit) {
            if !t.waitedOut { print(unchanged ? "[books] the page didn't turn: the book ends here" : "[books] the next chapter didn't settle in \(Int(Self.fillLimit)) s") }
            t.waitedOut = true
            turn = t
            stoppedAtEnd = false
        }
        return nil
    }

    /// The next chapter's area, settled: its start, now the reading's place past the old end.
    private func adopt(_ area: AXUIElement, after t: Turn) -> Position? {
        guard let anchor = Self.leaves(of: area).first else { return nil }
        let chapter = Flow(area: area, anchor: anchor, window: window)
        flow = chapter
        guard let start = chapter.start() ?? (firstVisible(in: chapter) as? Position) else { return nil }
        turn = nil
        endReached = nil
        t.from.next = start
        print("[books] next chapter, \(Int(Date().timeIntervalSince(t.at) * 1000)) ms after the turn")
        return start
    }

    /// The page end the last lookup stopped at, while the book may go on past it: one per chapter.
    func pageEnd() -> Int? { stoppedAtEnd ? endReached.map { ObjectIdentifier($0.flow).hashValue } : nil }

    var mayGrow: Bool { false }

    /// Turn past the flow's end a lookup reached, in the direction the chapter runs, unless a turn
    /// is under way or done, or the pages shown are another chapter's. Doesn't wait for the tree.
    /// The end is checked again first: a chapter is never left with text after it unread. A turn
    /// that can't be made (the book closed, the action failed, Books not answering at the end)
    /// ends the reading there.
    func turnPage() {
        guard let end = endReached, turn?.from !== end.flow, end.flow.next == nil, !end.flow.ended, case .end(let last) = end.kind else { return }
        let flow = currentFlow(), before = flow.map { pageState(of: $0.area) }
        guard let flow, let before, flow === end.flow, let viewport = visibleRect() else {
            print("[books] no page to turn: the reading ends here")
            end.flow.ended = true
            return
        }
        switch flow.step(pastEnd: last) {
        case .end: break
        case .text(let p):
            print("[books] the text goes on past \(last.endIndex): no turn")
            flow.next = p
            endReached = nil
            stoppedAtEnd = false
            return
        case .unanswered:
            print("[books] Books didn't answer at the chapter's end: the reading ends here")
            end.flow.ended = true
            return
        }
        guard turn(forward: readsRightward(flow, viewport: viewport, text: last.text as String), in: flow) else {
            print("[books] no page to turn: the reading ends here")
            end.flow.ended = true
            return
        }
        turn = Turn(from: flow, before: before, at: Date())
    }

    /// Which way the chapter runs: its area is the view's size, moved past the view by the
    /// columns before the ones shown, to the left in a left-to-right book and to the right in a
    /// right-to-left one. On a chapter's first pages it overlaps the view (a cover sits on the
    /// spread's right half): the text's language says, and for a picture, the chapter before.
    private func readsRightward(_ flow: Flow, viewport: CGRect, text: String) -> Bool {
        if let f = AX.frame(flow.area) {
            if f.maxX <= viewport.minX + 1 { rightward = true; return true }
            if f.minX >= viewport.maxX - 1 { rightward = false; return false }
        }
        if let language = NLLanguageRecognizer.dominantLanguage(for: text) {
            rightward = Locale.Language(identifier: language.rawValue).characterDirection != .rightToLeft
        }
        return rightward ?? true
    }

    // MARK: Geometry

    /// The sentence's lines on the visible pages, clipped to them. If none is visible, all of
    /// them, off screen: the session then asks to scroll, which turns the page.
    func lines(of sentence: Sentence) -> [CGRect] {
        guard let r = sentence.range as? SentenceRange, let viewport = visibleRect() else { return [] }
        let flow = r.start.flow
        var boxes: [CGRect] = []
        if r.block.isPicture { return r.block.lines.compactMap { flow.box(of: $0) }.map { isVisible($0, in: viewport) ? $0.intersection(viewport) : $0 } }
        for line in r.block.lines where line.endIndex > r.start.index && line.firstCharIndex < r.end.index {
            let a = r.start.index > line.firstCharIndex ? r.start.marker : line.start
            let b = r.end.index < line.endIndex ? r.end.marker : line.end
            if let box = flow.box(from: a, to: b, line: line) { boxes.append(box) }
        }
        boxes = flow.rows(boxes, lines: true)
        let visible = boxes.filter { isVisible($0, in: viewport) }.map { $0.intersection(viewport) }
        return visible.isEmpty ? boxes : visible
    }

    func linesDiagnosis(of sentence: Sentence) -> String {
        guard let r = sentence.range as? SentenceRange else { return "not a Books position" }
        return "flow \(r.start.flow === flow ? "current" : "replaced"), indices \(r.start.index)–\(r.end.index), \(Self.leaves(of: r.start.flow.area).count) leaves"
    }

    /// One box per whitespace-separated word, by stepping the sentence's characters. A word
    /// hyphenated across two lines gets the box of its longer part.
    func words(of sentence: Sentence) -> [CGRect?] {
        guard let r = sentence.range as? SentenceRange else { return [] }
        let flow = r.start.flow, block = r.block, text = block.text
        guard var cursor = Cursor(block: block, index: r.start.index, marker: r.start.marker) else { return [] }
        var pieces: [(text: String, rect: CGRect)] = []
        func char(_ i: Int) -> unichar { text.character(at: i - block.startIndex) }
        while cursor.index < r.end.index, pieces.count < 300 {
            while cursor.index < r.end.index, Self.isSpace(char(cursor.index)) { guard cursor.advance(flow) else { return finish(pieces, for: sentence) } }
            let wordStart = cursor.index
            var parts: [CGRect] = []
            var partStart = cursor
            while cursor.index < r.end.index, !Self.isSpace(char(cursor.index)) {
                guard cursor.advance(flow) else { return finish(pieces, for: sentence) }
                if cursor.line != partStart.line || cursor.index >= r.end.index || Self.isSpace(char(cursor.index)) {
                    let end = cursor.line != partStart.line ? partStart.lineEnd : cursor.marker
                    if let box = flow.box(from: partStart.marker, to: end, line: block.lines[partStart.line]) { parts.append(box) }
                    partStart = cursor
                }
            }
            guard cursor.index > wordStart, let box = parts.max(by: { $0.width < $1.width }) else { continue }
            pieces.append((text.substring(with: NSRange(location: wordStart - block.startIndex, length: cursor.index - wordStart)), box))
        }
        return finish(pieces, for: sentence)
    }

    private func finish(_ pieces: [(text: String, rect: CGRect)], for sentence: Sentence) -> [CGRect?] {
        guard let r = sentence.range as? SentenceRange else { return [] }
        let rows = r.start.flow.rows(pieces.map { $0.rect }, lines: false)
        return WordBoxes.assign(display: sentence.words, pieces: zip(pieces, rows).map { ($0.text, $1) })
    }

    /// A place in a block's text with its marker, moving one character at a time; across a
    /// wrap it jumps to the next line's first character (the wrap space has no marker).
    private struct Cursor {
        let block: Block
        var line: Int
        var index: Int
        var marker: AXTextMarker
        var lineEnd: AXTextMarker { block.lines[line].end }

        init?(block: Block, index: Int, marker: AXTextMarker) {
            guard let line = block.lines.firstIndex(where: { index < $0.endIndex }) else { return nil }
            self.block = block
            self.line = line
            self.index = max(index, block.lines[line].firstCharIndex)
            self.marker = marker
        }

        /// Lands on a wrap space (the index before a line's first character) with the marker
        /// already before that character, and leaves it without moving the marker.
        mutating func advance(_ flow: Flow) -> Bool {
            let current = block.lines[line]
            if index < current.firstCharIndex { index += 1; return true }
            if index + 1 < current.endIndex {
                guard let n = flow.next(marker) else { return false }
                marker = n
                index += 1
                return true
            }
            guard line + 1 < block.lines.count else { marker = block.end; index = block.endIndex; return true }
            line += 1
            index = current.endIndex
            marker = block.lines[line].start
            return true
        }
    }

    private static func isSpace(_ c: unichar) -> Bool {
        Unicode.Scalar(c).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }

    // MARK: Page turns

    /// Turn to the page the sentence is on: right if it lies past the view's right edge, left if
    /// past its left edge. Geometry, not reading order: the same in a right-to-left book.
    func scrollIntoView(_ sentence: Sentence) {
        guard let r = sentence.range as? SentenceRange, let viewport = visibleRect() else { return }
        let flow = r.start.flow
        guard let line = r.block.lines.first(where: { $0.endIndex > r.start.index }), let box = flow.box(of: line), !isVisible(box, in: viewport) else { return }
        let forward: Bool
        if box.minX >= viewport.maxX { forward = true } else if box.maxX <= viewport.minX { forward = false } else { return }
        let before = pageState(of: flow.area)
        guard turn(forward: forward, in: flow) else { return }
        _ = waitForChange(from: before, in: flow.area)
    }

    /// `AXScrollRightByPage` / `AXScrollLeftByPage` on a visible leaf turns the spread: no focus, no
    /// key event, and while Books is hidden. ~50 ms until the tree shows the new pages.
    private func turn(forward: Bool, in flow: Flow) -> Bool {
        let leaf = Self.leaves(of: flow.area).first ?? flow.anchor
        let err = AXUIElementPerformAction(leaf, (forward ? "AXScrollRightByPage" : "AXScrollLeftByPage") as CFString)
        print("[books] page turn \(forward ? "right" : "left"): \(err == .success ? "ok" : "error \(err.rawValue)")")
        return err == .success
    }

    /// The pages an area shows, as its leaves identify them: the start of each one's text, a
    /// picture's description ("Image"). An area gone or emptied shows none.
    private func pageState(of area: AXUIElement) -> String {
        let leaves = Self.leaves(of: area)
        let shown = leaves.map { ((AX.attr($0, kAXValueAttribute) as? String) ?? (AX.attr($0, kAXDescriptionAttribute) as? String) ?? "").prefix(20) }
        return "\(leaves.count):" + shown.joined(separator: "|")
    }

    /// A turn within a chapter shows in the tree within ~50 ms: the worker waits for it, briefly.
    private func waitForChange(from before: String, in area: AXUIElement, timeout: TimeInterval = 0.3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
            if pageState(of: area) != before { return true }
        }
        return false
    }
}

extension BooksDocument {
    /// One chapter of the book: a web area whose leaves answer marker calls, and the blocks
    /// read so far. Markers are asked of `anchor`, a leaf of the flow; they stay valid after
    /// page turns (a leaf answered after six), and if the bridge ever drops the leaf, a leaf
    /// still on screen takes over.
    final class Flow {
        let area: AXUIElement
        private(set) var anchor: AXUIElement
        private var blocks: [Int: Block] = [:]
        /// Where reading goes on past its end: the next chapter's start, once the page has been
        /// turned to it (or the text after an end that turned out not to be one).
        var next: Position?
        /// Nothing past its end will be read: the turn past it couldn't be made (the book closed,
        /// the action failed). Never set by a timeout.
        var ended = false

        /// The book view the area is in (`BooksDocument.view(of:in:)`), where the next chapter's area shows.
        let view: AXUIElement?

        init(area: AXUIElement, anchor: AXUIElement, window: AXUIElement) {
            self.area = area
            self.anchor = anchor
            view = BooksDocument.view(of: area, in: window)
        }

        private func param(_ name: String, _ p: AnyObject) -> AnyObject? { call(name, p).value }

        /// A marker call, with its error. Books answers −25204 while it's busy: asked again, briefly.
        private func call(_ name: String, _ p: AnyObject) -> (value: AnyObject?, error: AXError) {
            var v: AnyObject?
            var err = AXUIElementCopyParameterizedAttributeValue(anchor, name as CFString, p, &v)
            for _ in 0..<3 where err == .cannotComplete {
                Thread.sleep(forTimeInterval: 0.03)
                err = AXUIElementCopyParameterizedAttributeValue(anchor, name as CFString, p, &v)
            }
            if err == .success { return (v, err) }
            guard err == .invalidUIElement, let fresh = BooksDocument.leaves(of: area).first, !CFEqual(fresh, anchor) else { return (nil, err) }
            print("[books] the anchor leaf is gone; asking another")
            anchor = fresh
            err = AXUIElementCopyParameterizedAttributeValue(anchor, name as CFString, p, &v)
            return (err == .success ? v : nil, err)
        }

        private func marker(_ v: AnyObject?) -> AXTextMarker? {
            guard let v, CFGetTypeID(v) == AXTextMarkerGetTypeID() else { return nil }
            return (v as! AXTextMarker)
        }
        private func range(_ a: AXTextMarker, _ b: AXTextMarker) -> AXTextMarkerRange { AXTextMarkerRangeCreate(kCFAllocatorDefault, a, b) }
        func next(_ m: AXTextMarker) -> AXTextMarker? { marker(param("AXNextTextMarkerForTextMarker", m)) }
        private func lineEnd(_ m: AXTextMarker) -> AXTextMarker? { marker(param("AXNextLineEndTextMarkerForTextMarker", m)) }
        func index(_ m: AXTextMarker) -> Int? { (param("AXIndexForTextMarker", m) as? NSNumber)?.intValue }
        private func string(_ a: AXTextMarker, _ b: AXTextMarker) -> String? {
            (param("AXAttributedStringForTextMarkerRange", range(a, b)) as? NSAttributedString)?.string
        }
        private func bounds(_ a: AXTextMarker, _ b: AXTextMarker) -> CGRect? { AX.rect(param("AXBoundsForTextMarkerRange", range(a, b))) }

        /// The flow's first block start among the visible leaves (on a chapter's first spread, the
        /// chapter's start).
        func start() -> Position? {
            guard let first = inOrder(BooksDocument.leaves(of: area)).first, let block = block(of: first) else { return nil }
            return Position(flow: self, marker: block.start, index: block.startIndex)
        }

        /// Leaves in the chapter's order, by where their paragraphs start (two calls each).
        func inOrder(_ leaves: [AXUIElement]) -> [AXUIElement] {
            leaves.compactMap { leaf in paragraphStart(of: leaf).map { (leaf, $0.index) } }.sorted { $0.1 < $1.1 }.map(\.0)
        }

        // MARK: Blocks

        func block(containing index: Int) -> Block? {
            blocks.values.first { $0.startIndex <= index && index < $0.endIndex }
        }

        /// The block a visible leaf shows part of: its marker range is the whole block.
        func block(of leaf: AXUIElement) -> Block? {
            if AX.role(leaf) == kAXImageRole { return picture(leaf) }
            guard let s = paragraphStart(of: leaf) else { return nil }
            return block(startingAt: s.marker, index: s.index)
        }

        /// A picture's block: its range is "￼" with the picture's box, and no width in indices,
        /// so it is one line from its start to its end, kept under its index unless text starts there.
        private func picture(_ leaf: AXUIElement) -> Block? {
            guard let v = AX.param(leaf, "AXTextMarkerRangeForUIElement", leaf), CFGetTypeID(v) == AXTextMarkerRangeGetTypeID() else { return nil }
            let a = AXTextMarkerRangeCopyStartMarker(v as! AXTextMarkerRange), b = AXTextMarkerRangeCopyEndMarker(v as! AXTextMarkerRange)
            guard let i = index(a), let j = index(b) else { return nil }
            if let known = blocks[i], known.isPicture { return known }
            let block = Block(start: a, end: b, startIndex: i, endIndex: j, text: "\u{FFFC}", lines: [Line(start: a, end: b, endIndex: j, firstCharIndex: i)], readable: true)
            if blocks[i] == nil { blocks[i] = block }
            return block
        }

        /// Where the paragraph a leaf shows part of starts: two calls, no block built.
        func paragraphStart(of leaf: AXUIElement) -> (marker: AXTextMarker, index: Int)? {
            guard let v = AX.param(leaf, "AXTextMarkerRangeForUIElement", leaf), CFGetTypeID(v) == AXTextMarkerRangeGetTypeID() else { return nil }
            let start = AXTextMarkerRangeCopyStartMarker(v as! AXTextMarkerRange)
            return index(start).map { (start, $0) }
        }

        /// The block starting at `start`: its lines up to the next "\n" (a line starting with
        /// one belongs to the next block), and its text in one string, whose offsets are indices.
        func block(startingAt marker: AXTextMarker, index asked: Int) -> Block? {
            if let known = blocks[asked] { return known }
            // A marker before a "\n" (a chapter whose text starts with one, a blank line between two
            // blocks) starts the block after it: its first line would begin with the "\n", or, on
            // a blank line, end where it starts.
            var start = marker, startIndex = asked
            for _ in 0..<6 {
                guard let e = lineEnd(start), let str = string(start, e), str.isEmpty || str.hasPrefix("\n"), let n = next(start), let i = index(n) else { break }
                start = n
                startIndex = i
            }
            if let known = blocks[startIndex] { blocks[asked] = known; return known }
            var lines: [Line] = []
            var s = start, sIdx = startIndex
            for _ in 0..<600 {
                guard let e = lineEnd(s), let eIdx = index(e), eIdx > sIdx, let str = string(s, e) else { break }
                if str.hasPrefix("\n") { break }
                // The line's string drops the wrap space before it, whose index its start marker reports.
                lines.append(Line(start: s, end: e, endIndex: eIdx, firstCharIndex: sIdx + (eIdx - sIdx - str.utf16.count)))
                s = e
                sIdx = eIdx
            }
            guard let last = lines.last, let text = string(start, last.end) else { return nil }
            // Offsets in the text must be marker indices, or positions and boxes would land on the
            // wrong characters: a block whose text and indices disagree isn't read, and gets a cue.
            let readable = text.utf16.count == last.endIndex - startIndex
            if !readable { print("[books] block at \(startIndex) not read: \(text.utf16.count) characters of text for \(last.endIndex - startIndex) indices") }
            let block = Block(start: start, end: last.end, startIndex: startIndex, endIndex: last.endIndex, text: text as NSString, lines: lines, readable: readable)
            blocks[startIndex] = block
            blocks[asked] = block
            return block
        }

        /// What follows a block: the next block's start, past its "\n"; the flow's end, where a step
        /// from the block's end answers without moving on; or nothing known, where Books didn't
        /// answer (−25204 while it's busy). Only an answer is taken for the chapter's end: a failed
        /// call taken for it would turn the page with the rest of the spread unread.
        enum Past { case text(Position), end, unanswered }

        func step(pastEnd block: Block) -> Past {
            let first = call("AXNextTextMarkerForTextMarker", block.end)
            guard first.error == .success else { return first.error == .noValue ? .end : .unanswered }
            guard var n = marker(first.value) else { return .end }
            guard let i = index(n) else { return .unanswered }
            guard i > block.endIndex else { return .end }
            // Two markers share the index after a "\n": the string from the first still begins with the
            // "\n" (one character more than its indices), so the block starts at the second.
            if let after = next(n), index(after) == i { n = after }
            return .text(Position(flow: self, marker: n, index: i))
        }

        /// Where reading goes on after `block`: the first sentence past blocks with nothing to say (a
        /// row of asterisks) or the next cue; at the flow's end, the end position, so the sentence
        /// before the end is the one whose `next` is the end, whatever follows it; where Books
        /// didn't answer, a position after the block, to be found when it's read.
        func sentenceStart(after block: Block) -> Position? {
            var b = block
            for _ in 0..<50 {
                switch step(pastEnd: b) {
                case .end: return Position(flow: self, marker: b.end, index: b.endIndex, kind: .end(b))
                case .unanswered: return Position(flow: self, marker: b.end, index: b.endIndex, kind: .after(b))
                case .text(let p):
                    guard let nb = self.block(startingAt: p.marker, index: p.index) else { return nil }
                    if nb.cue != nil { return Position(flow: self, marker: nb.start, index: nb.startIndex) }
                    if let s = nb.sentences.first { return position(at: nb.startIndex + s.location, in: nb) }
                    b = nb
                }
            }
            return nil
        }

        /// The marker at an index of the block, by stepping from its line's start: markers step
        /// one character within a line.
        func position(at index: Int, in block: Block) -> Position? {
            if index >= block.endIndex { return Position(flow: self, marker: block.end, index: block.endIndex) }
            guard let line = block.lines.first(where: { index < $0.endIndex }) else { return nil }
            var m = line.start
            for _ in 0..<max(0, index - line.firstCharIndex) { guard let n = next(m) else { return nil }; m = n }
            return Position(flow: self, marker: m, index: max(index, line.firstCharIndex))
        }

        // MARK: Boxes

        /// A line's box. At a hyphenation wrap the marker before the line's first letter sits at
        /// the end of the line before (a 2 px sliver there), so a range from a line's start can
        /// take in that line: the box is measured from the second character, plus the first
        /// character's own box when it is on the same row.
        func box(of line: Line) -> CGRect? {
            line.endIndex == line.firstCharIndex ? bounds(line.start, line.end) : box(from: line.start, to: line.end, line: line)
        }

        func box(from a: AXTextMarker, to b: AXTextMarker, line: Line) -> CGRect? {
            guard CFEqual(a, line.start) else { return bounds(a, b) }
            guard let n = next(a), !CFEqual(n, b), let rest = bounds(n, b) else { return bounds(a, b) }
            guard let first = bounds(a, n), first.width > 3, abs(first.midY - rest.midY) < rest.height / 2 else { return rest }
            return rest.union(first)
        }

        /// The box of a line at the top of a column takes in the column's top padding, with the
        /// text at its bottom: boxes much taller than the set's typical height (its lower median:
        /// a superscript or an epigraph line doesn't pull it down) are cut to that height from the
        /// bottom. A lone line box is judged by the last set of lines; word boxes judge themselves.
        private var lineHeight: CGFloat?
        func rows(_ boxes: [CGRect], lines: Bool) -> [CGRect] {
            let heights = boxes.map(\.height).filter { $0 >= 8 }.sorted()
            var h = heights.isEmpty ? nil : heights[(heights.count - 1) / 2]
            if lines {
                if heights.count > 1 { lineHeight = h } else { h = lineHeight ?? h }
            }
            guard let h else { return boxes }
            return boxes.map { $0.height > h * 1.4 ? CGRect(x: $0.minX, y: $0.maxY - h, width: $0.width, height: h) : $0 }
        }
    }

    /// A paragraph, heading or other block of the chapter: the text between two "\n".
    final class Block {
        let start: AXTextMarker, end: AXTextMarker
        let startIndex: Int, endIndex: Int
        let text: NSString
        let lines: [Line]
        /// The sentences with something to say, as offsets in `text`; none if its offsets can't
        /// be trusted as indices.
        let sentences: [NSRange]
        /// Played as a cue instead (#24, #26): "figure", a picture with nothing to read (a plate, a
        /// tailpiece: "￼"), or "unread", text whose offsets can't be trusted as indices.
        let cue: String?

        init(start: AXTextMarker, end: AXTextMarker, startIndex: Int, endIndex: Int, text: NSString, lines: [Line], readable: Bool) {
            self.start = start
            self.end = end
            self.startIndex = startIndex
            self.endIndex = endIndex
            self.text = text
            self.lines = lines
            sentences = readable ? BooksDocument.sentences(in: text) : []
            let sayable = SpeechText.clean((text as String).replacingOccurrences(of: "\u{FFFC}", with: " ")) != nil
            if !sayable { cue = text.contains("\u{FFFC}") ? "figure" : nil } else { cue = readable ? nil : "unread" }
        }

        /// A picture's block, which takes no room in the chapter's indices.
        var isPicture: Bool { endIndex == startIndex && cue == "figure" }
    }

    /// The sentences of a block's text that have something to say: `NLTokenizer`'s, less those
    /// `SpeechText.clean` empties (a row of asterisks, a lone image placeholder).
    static func sentences(in text: NSString) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .sentence)
        let s = text as String
        tokenizer.string = s
        return tokenizer.tokens(for: s.startIndex..<s.endIndex).map { NSRange($0, in: s) }.filter { SpeechText.clean(text.substring(with: $0)) != nil }
    }

    /// A laid-out line of a block. Its start marker sits before its first character but reports
    /// the index of the wrap space before it, which the line's string leaves out.
    struct Line {
        let start: AXTextMarker, end: AXTextMarker
        let endIndex: Int
        let firstCharIndex: Int
    }

    /// A marker and its index in the chapter's text. `end`: the flow's end, past its last block,
    /// where the next chapter begins after a page turn. `after`: past a block whose end Books
    /// didn't answer at, found when it's read.
    final class Position {
        enum Kind { case text, end(Block), after(Block) }
        let flow: Flow
        let marker: AXTextMarker
        let index: Int
        let kind: Kind
        init(flow: Flow, marker: AXTextMarker, index: Int, kind: Kind = .text) {
            self.flow = flow
            self.marker = marker
            self.index = index
            self.kind = kind
        }
        var atEnd: Bool { if case .end = kind { true } else { false } }
        var isUnresolved: Bool { if case .after = kind { true } else { false } }
    }

    final class SentenceRange {
        let start: Position, end: Position
        let block: Block
        init(start: Position, end: Position, block: Block) {
            self.start = start
            self.end = end
            self.block = block
        }
    }
}
