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
/// the flow's end is a position of its own, and the reading turns the page once that last
/// sentence has been shown (`moreComing`).
final class BooksDocument: ReadableDocument {
    let element: AXUIElement
    private let window: AXUIElement
    private var flow: Flow?
    /// The end index of the last sentence `lines(of:)` measured (what is being read), per flow.
    private var measured: (flow: Flow, endIndex: Int)?
    /// The flow's end was reached and the next page not turned yet.
    private var pendingTurn = false
    private var ended = false

    /// The bridge's web area: a Books (or Catalyst) web view, which has none of WebKit's
    /// text-marker parameters (only `AXReplaceRangeWithText`). An app that doesn't answer (a
    /// Chromium page still building its tree) is a web document, as before.
    static func isBridged(_ area: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(area, &names) == .success, let list = names as? [String], !list.isEmpty else { return false }
        return !list.contains("AXTextMarkerRangeForUIElement")
    }

    init?(around hit: AXUIElement) {
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
    }

    // MARK: The chapter

    /// The web area holding the visible pages' leaves (the others are empty), and a flow over it.
    private func currentFlow() -> Flow? {
        if let flow, !AX.children(flow.area).isEmpty { return flow }
        guard let area = AX.find(in: window, maxNodes: 2000, { e, r in r == "AXWebArea" && !AX.children(e).isEmpty }),
              let leaf = AX.children(area).first(where: { AX.role($0) == kAXStaticTextRole }) else { return nil }
        if let flow, CFEqual(flow.area, area) { return flow }
        flow = Flow(area: area, anchor: leaf)
        return flow
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

    // MARK: Positions

    func paragraph(at point: CGPoint) -> (start: AnyObject, bounds: CGRect)? {
        guard let flow = currentFlow(), let viewport = visibleRect() else { return nil }
        for leaf in AX.children(flow.area) where AX.role(leaf) == kAXStaticTextRole {
            guard let f = AX.frame(leaf), f.insetBy(dx: -4, dy: -4).contains(point), let block = flow.block(of: leaf) else { continue }
            let boxes = block.lines.map { flow.box(of: $0) }
            guard let hit = boxes.firstIndex(where: { $0?.insetBy(dx: -2, dy: -3).contains(point) == true }), let hitBox = boxes[hit] else { continue }
            let onPage = zip(block.lines, boxes).compactMap { line, box -> CGRect? in
                guard let box, isVisible(box, in: viewport), (box.midX < viewport.midX) == (hitBox.midX < viewport.midX) else { return nil }
                return box
            }
            guard let start = start(in: flow, block: block, viewport: viewport), let bounds = onPage.dropFirst().reduce(onPage.first, { $0?.union($1) }) else { continue }
            return (start, bounds.intersection(viewport))
        }
        return nil
    }

    /// Where to start reading a block: its start if that is on the visible pages, else the first
    /// sentence that starts there (the tail of a sentence begun on the previous page isn't read),
    /// else the next block's start.
    private func start(in flow: Flow, block: Block, viewport: CGRect) -> Position? {
        guard let firstVisible = block.lines.first(where: { flow.box(of: $0).map { isVisible($0, in: viewport) } == true }) else { return nil }
        let from = firstVisible.firstCharIndex - block.startIndex
        if let s = block.sentences.first(where: { $0.location >= from }) { return flow.position(at: block.startIndex + s.location, in: block) }
        return flow.blockStart(after: block)
    }

    func firstVisible() -> AnyObject? {
        guard let flow = currentFlow(), let viewport = visibleRect() else { return nil }
        var best: (page: Int, y: CGFloat, block: Block)?
        for leaf in AX.children(flow.area) where AX.role(leaf) == kAXStaticTextRole {
            guard let block = flow.block(of: leaf) else { continue }
            for line in block.lines {
                guard let box = flow.box(of: line), isVisible(box, in: viewport) else { continue }
                let page = box.midX < viewport.midX ? 0 : 1
                if best == nil || (page, box.minY) < (best!.page, best!.y) { best = (page, box.minY, block) }
                break
            }
        }
        guard let best else { return nil }
        return start(in: flow, block: best.block, viewport: viewport)
    }

    /// The first visible sentence: what was read is behind, and the pages before it were turned.
    func documentStart() -> AnyObject? { firstVisible() }

    // MARK: Sentences

    func sentence(from position: AnyObject, in scope: ReadingScope?) -> Sentence? {
        guard let p = position as? Position else { return nil }
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
                let next: Position? = i + 1 < block.sentences.count ? flow.position(at: block.startIndex + block.sentences[i + 1].location, in: block) : flow.blockStart(after: block)
                if let text = SpeechText.clean(block.text.substring(with: r)),
                   let start = flow.position(at: block.startIndex + r.location, in: block), let stop = flow.position(at: end, in: block) {
                    return Sentence(text: text, range: SentenceRange(start: start, end: stop, block: block), next: next)
                }
                guard let next else { return nil }
                pos = next
            } else {
                guard let next = flow.blockStart(after: block) else { return nil }
                pos = next
            }
        }
        return nil
    }

    /// The flow ended: turn the page once its last sentence has been shown, and read on in the
    /// web area that holds the next chapter; nothing new there is the end of the book.
    private func nextChapter(after end: Position) -> Sentence? {
        guard !ended else { return nil }
        let shown = measured.map { $0.flow === end.flow && $0.endIndex >= end.index } ?? true
        guard shown else { pendingTurn = true; return nil }
        pendingTurn = false
        guard turn(forward: true, in: end.flow) else { ended = true; return nil }
        // The next chapter's web area fills in up to a second after the turn. The same area still
        // showing means the pages weren't at the chapter's end (a dev walk, or the user turned
        // back), and nothing new means the book's end.
        let deadline = Date().addingTimeInterval(2.5)
        flow = nil
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            if let fresh = currentFlow() {
                guard !CFEqual(fresh.area, end.flow.area) else { break }
                guard let start = firstVisible() else { continue }
                print("[books] next chapter")
                return sentence(from: start, in: nil)
            }
        }
        ended = true
        print("[books] the book ends here")
        return nil
    }

    func moreComing() -> Bool { pendingTurn && !ended }

    // MARK: Geometry

    /// The sentence's lines on the visible pages, clipped to them. If none is visible, all of
    /// them, off screen: the session then asks to scroll, which turns the page.
    func lines(of sentence: Sentence) -> [CGRect] {
        guard let r = sentence.range as? SentenceRange, let viewport = visibleRect() else { return [] }
        let flow = r.start.flow
        measured = (flow, r.end.index)
        var boxes: [CGRect] = []
        for line in r.block.lines where line.endIndex > r.start.index && line.firstCharIndex < r.end.index {
            let a = r.start.index > line.firstCharIndex ? r.start.marker : line.start
            let b = r.end.index < line.endIndex ? r.end.marker : line.end
            if let box = flow.box(from: a, to: b, line: line) { boxes.append(box) }
        }
        boxes = flow.rows(boxes)
        let visible = boxes.filter { isVisible($0, in: viewport) }.map { $0.intersection(viewport) }
        return visible.isEmpty ? boxes : visible
    }

    func linesDiagnosis(of sentence: Sentence) -> String {
        guard let r = sentence.range as? SentenceRange else { return "not a Books position" }
        return "flow \(r.start.flow === flow ? "current" : "replaced"), indices \(r.start.index)–\(r.end.index), \(AX.children(r.start.flow.area).count) leaves"
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
        let rows = r.start.flow.rows(pieces.map { $0.rect })
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

    /// Turn to the page the sentence is on: right if it comes after the visible pages, left if before.
    func scrollIntoView(_ sentence: Sentence) {
        guard let r = sentence.range as? SentenceRange, let viewport = visibleRect(), let flow = currentFlow() else { return }
        let line = r.block.lines.first { $0.endIndex > r.start.index }
        guard let box = line.flatMap({ flow.box(of: $0) }), !isVisible(box, in: viewport) else { return }
        let before = pageState()
        guard turn(forward: box.midX > viewport.midX, in: flow) else { return }
        _ = waitForChange(from: before)
    }

    /// `AXScrollRightByPage` / `AXScrollLeftByPage` on a visible leaf turns the spread: no focus, no
    /// key event, and while Books is hidden. ~50 ms until the tree shows the new pages.
    private func turn(forward: Bool, in flow: Flow) -> Bool {
        let leaf = AX.children(flow.area).first(where: { AX.role($0) == kAXStaticTextRole }) ?? flow.anchor
        let err = AXUIElementPerformAction(leaf, (forward ? "AXScrollRightByPage" : "AXScrollLeftByPage") as CFString)
        print("[books] page turn \(forward ? "forward" : "back"): \(err == .success ? "ok" : "error \(err.rawValue)")")
        return err == .success
    }

    /// The visible pages, as the start of each leaf's text identifies them.
    private func pageState() -> String {
        (flow.map { AX.children($0.area) } ?? []).compactMap { (AX.attr($0, kAXValueAttribute) as? String)?.prefix(20) }.joined(separator: "|")
    }

    private func waitForChange(from before: String, timeout: TimeInterval = 0.8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            if pageState() != before { return true }
        }
        return false
    }
}

extension BooksDocument {
    /// One chapter of the book: a web area whose leaves answer marker calls, and the blocks
    /// read so far. Markers are asked of `anchor`, a leaf of the flow; they stay valid after
    /// page turns.
    final class Flow {
        let area: AXUIElement
        let anchor: AXUIElement
        private var blocks: [Int: Block] = [:]

        init(area: AXUIElement, anchor: AXUIElement) {
            self.area = area
            self.anchor = anchor
        }

        private func marker(_ v: AnyObject?) -> AXTextMarker? {
            guard let v, CFGetTypeID(v) == AXTextMarkerGetTypeID() else { return nil }
            return (v as! AXTextMarker)
        }
        private func range(_ a: AXTextMarker, _ b: AXTextMarker) -> AXTextMarkerRange { AXTextMarkerRangeCreate(kCFAllocatorDefault, a, b) }
        func next(_ m: AXTextMarker) -> AXTextMarker? { marker(AX.param(anchor, "AXNextTextMarkerForTextMarker", m)) }
        private func lineEnd(_ m: AXTextMarker) -> AXTextMarker? { marker(AX.param(anchor, "AXNextLineEndTextMarkerForTextMarker", m)) }
        func index(_ m: AXTextMarker) -> Int? { (AX.param(anchor, "AXIndexForTextMarker", m) as? NSNumber)?.intValue }
        private func string(_ a: AXTextMarker, _ b: AXTextMarker) -> String? {
            (AX.param(anchor, "AXAttributedStringForTextMarkerRange", range(a, b)) as? NSAttributedString)?.string
        }
        private func bounds(_ a: AXTextMarker, _ b: AXTextMarker) -> CGRect? { AX.rect(AX.param(anchor, "AXBoundsForTextMarkerRange", range(a, b))) }

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
        func block(startingAt start: AXTextMarker, index startIndex: Int) -> Block? {
            if let known = blocks[startIndex] { return known }
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
            let block = Block(start: start, end: last.end, startIndex: startIndex, text: text as NSString, lines: lines)
            if text.utf16.count != block.endIndex - startIndex {
                print("[books] block at \(startIndex): text \(text.utf16.count) chars for \(block.endIndex - startIndex) indices")
            }
            blocks[startIndex] = block
            return block
        }

        /// The start of the block after `block`, past its "\n"; at the flow's end, the end position.
        func blockStart(after block: Block) -> Position? {
            guard let n = next(block.end), let i = index(n), i > block.endIndex else {
                return Position(flow: self, marker: block.end, index: block.endIndex, atEnd: true)
            }
            return Position(flow: self, marker: n, index: i)
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
        /// text at its bottom: boxes much taller than the lowest box of the set are cut down to
        /// that height from the bottom. The height is remembered for sets of one.
        private var lineHeight: CGFloat?
        func rows(_ boxes: [CGRect]) -> [CGRect] {
            if let h = boxes.map(\.height).filter({ $0 >= 8 }).min(), boxes.count > 1 || lineHeight == nil { lineHeight = min(h, lineHeight ?? h) }
            guard let h = lineHeight else { return boxes }
            return boxes.map { $0.height > h * 1.4 ? CGRect(x: $0.minX, y: $0.maxY - h, width: $0.width, height: h) : $0 }
        }
    }

    /// A paragraph, heading or other block of the chapter: the text between two "\n".
    final class Block {
        let start: AXTextMarker, end: AXTextMarker
        let startIndex: Int
        let text: NSString
        let lines: [Line]
        let sentences: [NSRange]
        var endIndex: Int { startIndex + text.length }

        init(start: AXTextMarker, end: AXTextMarker, startIndex: Int, text: NSString, lines: [Line]) {
            self.start = start
            self.end = end
            self.startIndex = startIndex
            self.text = text
            self.lines = lines
            let tokenizer = NLTokenizer(unit: .sentence)
            let s = text as String
            tokenizer.string = s
            sentences = tokenizer.tokens(for: s.startIndex..<s.endIndex).map { NSRange($0, in: s) }
        }
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
