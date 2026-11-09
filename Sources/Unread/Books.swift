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
/// the flow's end is a position of its own. A lookup from it never turns the page: the session
/// does (`turnPage`) once the chapter's last sentence has played, and later lookups find the
/// next chapter once its area has filled in.
final class BooksDocument: ReadableDocument {
    let element: AXUIElement
    private let window: AXUIElement
    private var flow: Flow?
    /// The last lookup stopped at the flow's end, and the book may go on past it.
    private var stoppedAtEnd = false
    /// The flow's end, once a lookup has reached it: `turnPage` turns past it.
    private var endReached: Position?
    /// The page turn the session asked for, while the next chapter's area fills in.
    private var turn: Turn?
    private struct Turn {
        let from: Flow
        /// The pages before the turn, as `pageState` gives them.
        let before: String
        let at: Date
        /// The leaves another web area showed at the last lookup: adopted once two lookups agree.
        var seen: (area: AXUIElement, leaves: Int)?
        /// The wait is over: lookups no longer say more is coming, but still take the next
        /// chapter if it shows. The turn stays, so it isn't made twice.
        var waitedOut = false
    }
    /// A turn that moves nothing for this long is the book's end; once the old pages have gone,
    /// the next ones are waited for this long (they show ~0.3 s after the turn). Either way the
    /// wait ends the reading, not the book: nothing is marked ended on a timeout.
    private static let noChange: TimeInterval = 2
    private static let fillLimit: TimeInterval = 10

    /// The bridge's web area: a Books (or Catalyst) web view, which has none of WebKit's
    /// text-marker parameters (only `AXReplaceRangeWithText`). An app that doesn't answer (a
    /// Chromium page still building its tree) is a web document, as before.
    static func isBridged(_ area: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(area, &names) == .success, let list = names as? [String], !list.isEmpty else { return false }
        return !list.contains("AXTextMarkerRangeForUIElement")
    }

    /// Books only (other Catalyst web views aren't known to answer the marker calls), with a
    /// chapter whose leaves answer them: a book still opening has none yet.
    init?(around hit: AXUIElement) {
        guard NSRunningApplication(processIdentifier: AX.pid(hit))?.bundleIdentifier == "com.apple.iBooksX" else { return nil }
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
        guard let area = Self.liveArea(in: window), let leaf = Self.leaves(of: area).first else { return nil }
        if let flow, CFEqual(flow.area, area) { return flow }
        flow = Flow(area: area, anchor: leaf)
        return flow
    }

    private static func liveArea(in window: AXUIElement) -> AXUIElement? {
        AX.find(in: window, maxNodes: 2000) { e, r in r == "AXWebArea" && !leaves(of: e).isEmpty }
    }

    /// The visible pages' text: one leaf per paragraph piece, a heading's leaf being an `AXHeading`.
    private static func leaves(of area: AXUIElement) -> [AXUIElement] {
        AX.children(area).filter { [kAXStaticTextRole, "AXHeading"].contains(AX.role($0)) }
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
        let from = firstVisible.firstCharIndex - block.startIndex
        if let s = block.sentences.first(where: { $0.location >= from }) { return flow.position(at: block.startIndex + s.location, in: block) }
        guard let next = flow.sentenceStart(after: block) else { return nil }
        guard next.atEnd else { return next }
        guard block.sentences.contains(where: { NSMaxRange($0) > from }) else { return nil }
        return flow.position(at: firstVisible.firstCharIndex, in: block)
    }

    /// The first sentence starting on the visible pages: the leaves in the chapter's order.
    func firstVisible() -> AnyObject? {
        guard let flow = currentFlow(), let viewport = visibleRect() else { return nil }
        let blocks = Self.leaves(of: flow.area).compactMap { flow.block(of: $0) }.sorted { $0.startIndex < $1.startIndex }
        for block in blocks {
            if let start = start(in: flow, block: block, viewport: viewport) { return start }
        }
        return nil
    }

    /// The first visible sentence: what was read is behind, and the pages before it were turned.
    func documentStart() -> AnyObject? { firstVisible() }

    // MARK: Sentences

    func sentence(from position: AnyObject, in scope: ReadingScope?) -> Sentence? {
        guard let p = position as? Position else { return nil }
        stoppedAtEnd = false
        var pos = p
        for _ in 0..<50 {
            if pos.atEnd { return nextChapter(after: pos) }
            let flow = pos.flow
            guard let block = flow.block(containing: pos.index) ?? flow.block(startingAt: pos.marker, index: pos.index) else { return nil }
            let from = pos.index - block.startIndex
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

    /// At the flow's end, which a lookup only notes (`moreComing`): the session turns the page
    /// (`turnPage`) once the chapter's last sentence has been said. While the turn is under way,
    /// each lookup looks at the window once, without waiting: the old area clears within ~0.15 s
    /// and the next chapter's fills in over ~0.3 s, so another area is taken once two lookups have
    /// found it with the same leaves. Then the next chapter is read from its first sentence, by
    /// this lookup and every later one from this end. A turn that moved nothing for 2 s is the
    /// book's end, and one whose next pages haven't shown in 10 s is waited out: the reading ends.
    private func nextChapter(after end: Position) -> Sentence? {
        let from = end.flow
        if let next = from.next { return sentence(from: next, in: nil) }
        guard !from.ended else { return nil }
        endReached = end
        stoppedAtEnd = true
        guard var t = turn, t.from === from else { return nil }
        if let area = Self.liveArea(in: window), !CFEqual(area, from.area) {
            let leaves = Self.leaves(of: area)
            guard let seen = t.seen, CFEqual(seen.area, area), seen.leaves == leaves.count, let anchor = leaves.first else {
                t.seen = (area, leaves.count)
                turn = t
                return nil
            }
            turn = nil
            endReached = nil
            let chapter = Flow(area: area, anchor: anchor)
            flow = chapter
            guard let start = (firstVisible() as? Position) ?? chapter.start() else { stoppedAtEnd = false; return nil }
            from.next = start
            print("[books] next chapter, \(Int(Date().timeIntervalSince(t.at) * 1000)) ms after the turn")
            return sentence(from: start, in: nil)
        }
        let unchanged = pageState(of: from.area) == t.before, waited = Date().timeIntervalSince(t.at)
        if t.waitedOut || (unchanged ? waited > Self.noChange : waited > Self.fillLimit) {
            if !t.waitedOut { print(unchanged ? "[books] the page didn't turn: the book ends here" : "[books] the next chapter didn't show in \(Int(Self.fillLimit)) s") }
            t.waitedOut = true
            turn = t
            stoppedAtEnd = false
        }
        return nil
    }

    func moreComing() -> Bool { stoppedAtEnd }

    /// Turn past the flow's end a lookup reached, in the direction the chapter runs, unless a turn
    /// is under way or done, or the pages shown are another chapter's. Doesn't wait for the tree.
    /// A turn that can't be made (the book closed, the action failed) ends the reading there.
    func turnPage() {
        guard let end = endReached, turn?.from !== end.flow, end.flow.next == nil, !end.flow.ended else { return }
        let flow = currentFlow(), before = flow.map { pageState(of: $0.area) }
        guard let flow, let before, flow === end.flow, let viewport = visibleRect(),
              turn(forward: flow.readsRightward(viewport: viewport), in: flow) else {
            print("[books] no page to turn: the reading ends here")
            end.flow.ended = true
            return
        }
        turn = Turn(from: flow, before: before, at: Date())
    }

    // MARK: Geometry

    /// The sentence's lines on the visible pages, clipped to them. If none is visible, all of
    /// them, off screen: the session then asks to scroll, which turns the page.
    func lines(of sentence: Sentence) -> [CGRect] {
        guard let r = sentence.range as? SentenceRange, let viewport = visibleRect() else { return [] }
        let flow = r.start.flow
        var boxes: [CGRect] = []
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

    /// The pages an area shows, as the start of each leaf's text identifies them.
    private func pageState(of area: AXUIElement) -> String {
        Self.leaves(of: area).compactMap { (AX.attr($0, kAXValueAttribute) as? String)?.prefix(20) }.joined(separator: "|")
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
        /// Where the next chapter's reading starts, once the page has been turned to it.
        var next: Position?
        /// Nothing past its end will be read: the turn past it couldn't be made (the book closed,
        /// the action failed). Never set by a timeout.
        var ended = false

        init(area: AXUIElement, anchor: AXUIElement) {
            self.area = area
            self.anchor = anchor
        }

        private func param(_ name: String, _ p: AnyObject) -> AnyObject? {
            var v: AnyObject?
            let err = AXUIElementCopyParameterizedAttributeValue(anchor, name as CFString, p, &v)
            if err == .success { return v }
            guard err == .invalidUIElement, let fresh = BooksDocument.leaves(of: area).first, !CFEqual(fresh, anchor) else { return nil }
            print("[books] the anchor leaf is gone; asking another")
            anchor = fresh
            return AX.param(anchor, name, p)
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

        /// Which way the chapter runs, from the lines of the blocks on the visible pages in the
        /// chapter's order: where a line is above the one before it, the text went on to the next
        /// column, on its right in a left-to-right book and on its left in a right-to-left one. A
        /// block begun on the previous page has its first lines in that page's column, off screen,
        /// so one page shows it too. Nothing to judge by (one short block): left to right.
        func readsRightward(viewport: CGRect) -> Bool {
            let shown = BooksDocument.leaves(of: area).compactMap { block(of: $0) }
            var seen = Set<Int>(), previous: CGRect?
            for block in shown.sorted(by: { $0.startIndex < $1.startIndex }) where seen.insert(block.startIndex).inserted {
                for line in block.lines {
                    guard let box = box(of: line), box.height >= 8 else { continue }
                    if let p = previous, BooksDocument.columnBreak(after: p, at: box) { return box.midX > p.midX }
                    previous = box
                }
            }
            return true
        }

        /// The flow's first block start among the visible leaves (on a chapter's first spread, the
        /// chapter's start).
        func start() -> Position? {
            let first = BooksDocument.leaves(of: area).compactMap { block(of: $0) }.min { $0.startIndex < $1.startIndex }
            return first.map { Position(flow: self, marker: $0.start, index: $0.startIndex) }
        }

        // MARK: Blocks

        func block(containing index: Int) -> Block? {
            blocks.values.first { $0.startIndex <= index && index < $0.endIndex }
        }

        /// The block a visible leaf shows part of: its marker range is the whole block.
        func block(of leaf: AXUIElement) -> Block? {
            guard let v = AX.param(leaf, "AXTextMarkerRangeForUIElement", leaf), CFGetTypeID(v) == AXTextMarkerRangeGetTypeID() else { return nil }
            let start = AXTextMarkerRangeCopyStartMarker(v as! AXTextMarkerRange)
            guard let i = index(start) else { return nil }
            return blocks[i] ?? block(startingAt: start, index: i)
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
                lines.append(Line(start: s, end: e, startIndex: sIdx, endIndex: eIdx, firstCharIndex: sIdx + (eIdx - sIdx - str.utf16.count)))
                s = e
                sIdx = eIdx
            }
            guard let last = lines.last, let text = string(start, last.end) else { return nil }
            // Offsets in the text must be marker indices, or positions and boxes would land on the
            // wrong characters: a block whose text and indices disagree is skipped, with a note.
            let readable = text.utf16.count == last.endIndex - startIndex
            if !readable { print("[books] block at \(startIndex) skipped: \(text.utf16.count) characters of text for \(last.endIndex - startIndex) indices") }
            let block = Block(start: start, end: last.end, startIndex: startIndex, endIndex: last.endIndex, text: text as NSString, lines: lines, readable: readable)
            blocks[startIndex] = block
            blocks[asked] = block
            return block
        }

        /// The start of the block after `block`, past its "\n"; at the flow's end, the end position.
        /// Two markers share the index after a "\n": the string from the first still begins with the
        /// "\n" (one character more than its indices), so the block starts at the second.
        private func blockStart(after block: Block) -> Position? {
            guard var n = next(block.end), let i = index(n), i > block.endIndex else {
                return Position(flow: self, marker: block.end, index: block.endIndex, atEnd: true)
            }
            if let after = next(n), index(after) == i { n = after }
            return Position(flow: self, marker: n, index: i)
        }

        /// The first sentence after `block`, past blocks with nothing to say (a row of asterisks,
        /// an image's placeholder); at the flow's end, the end position, so the sentence before
        /// the end is the one whose `next` is the end, whatever follows it.
        func sentenceStart(after block: Block) -> Position? {
            var b = block
            for _ in 0..<50 {
                guard let p = blockStart(after: b) else { return nil }
                if p.atEnd { return p }
                guard let nb = self.block(startingAt: p.marker, index: p.index) else { return nil }
                if let s = nb.sentences.first { return position(at: nb.startIndex + s.location, in: nb) }
                b = nb
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
        func box(of line: Line) -> CGRect? { box(from: line.start, to: line.end, line: line) }

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

        init(start: AXTextMarker, end: AXTextMarker, startIndex: Int, endIndex: Int, text: NSString, lines: [Line], readable: Bool) {
            self.start = start
            self.end = end
            self.startIndex = startIndex
            self.endIndex = endIndex
            self.text = text
            self.lines = lines
            sentences = readable ? BooksDocument.sentences(in: text) : []
        }
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
        let startIndex: Int, endIndex: Int
        let firstCharIndex: Int
    }

    /// A marker and its index in the chapter's text. `atEnd`: the flow's end, where the next
    /// chapter begins after a page turn.
    final class Position {
        let flow: Flow
        let marker: AXTextMarker
        let index: Int
        let atEnd: Bool
        init(flow: Flow, marker: AXTextMarker, index: Int, atEnd: Bool = false) {
            self.flow = flow
            self.marker = marker
            self.index = index
            self.atEnd = atEnd
        }
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
