import AppKit
import ApplicationServices
import NaturalLanguage

/// One unit of speech: what to say, and an opaque handle the document can
/// use later to locate it on screen (it may have scrolled since).
struct Sentence {
    let text: String
    let range: AnyObject
    /// Where the following sentence starts, or nil at the end of the document.
    let next: AnyObject?
}

/// Something on screen we can read aloud, regardless of which app owns it.
/// Positions are opaque: a text marker for web content, a UTF-16 index for
/// native text views.
protocol ReadableDocument: AnyObject {
    var element: AXUIElement { get }
    /// The paragraph under `point`, for the hold-to-point preview.
    func paragraph(at point: CGPoint) -> (start: AnyObject, bounds: CGRect)?
    /// Where to start when the user didn't point anywhere.
    func firstVisible() -> AnyObject?
    /// The very beginning of the document (dev tools and fixtures).
    func documentStart() -> AnyObject?
    func sentence(from position: AnyObject) -> Sentence?
    /// The sentence's on-screen boxes, one per line, so a highlight never
    /// covers the end of the previous sentence or the start of the next.
    func lines(of sentence: Sentence) -> [CGRect]
    func visibleRect() -> CGRect?
    func scrollIntoView(_ sentence: Sentence)
}

extension ReadableDocument {
    /// The union of the sentence's line boxes.
    func bounds(of sentence: Sentence) -> CGRect? {
        let l = lines(of: sentence)
        return l.dropFirst().reduce(l.first) { $0?.union($1) }
    }
}

enum SpeechText {
    private static let citation = try! NSRegularExpression(pattern: #"\[(\d+|citation needed|edit)\]"#, options: .caseInsensitive)
    private static let url = try! NSRegularExpression(pattern: #"https?://\S+"#)

    /// Make a raw on-screen string speakable, or nil if there's nothing to say.
    static func clean(_ raw: String) -> String? {
        var s = raw.replacingOccurrences(of: "\u{00AD}", with: "") // soft hyphens
            .replacingOccurrences(of: "\u{FFFC}", with: " ") // embedded objects (images, icons)
        for re in [citation, url] {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        s = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard s.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return nil }
        return s
    }
}

// MARK: - Web content (Safari, Chromium, Electron, WebKit views)

/// Works on both engines by sticking to the subset of the text-marker API
/// they share. WebKit supports position lookups and sentence navigation;
/// Chromium does not, but both support hit-testing elements, paragraph
/// ranges, word stepping and bounds. So: find the paragraph from the element
/// under the point, split it into sentences ourselves, and step word by word
/// to find each sentence's on-screen range.
final class WebDocument: ReadableDocument {
    let element: AXUIElement
    private let debugWalk = ProcessInfo.processInfo.environment["UNREAD_DEBUG_WALK"] != nil

    init(area: AXUIElement) { element = area }

    private func p(_ name: String, _ arg: AnyObject) -> AnyObject? { AX.param(element, name, arg) }
    private func string(_ range: AnyObject) -> String { p("AXStringForTextMarkerRange", range) as? String ?? "" }
    private func start(of range: AnyObject) -> AnyObject { AXTextMarkerRangeCopyStartMarker(range as! AXTextMarkerRange) }
    private func end(of range: AnyObject) -> AnyObject { AXTextMarkerRangeCopyEndMarker(range as! AXTextMarkerRange) }
    private func range(_ a: AnyObject, _ b: AnyObject) -> AnyObject? { p("AXTextMarkerRangeForUnorderedTextMarkers", [a, b] as CFArray) }

    /// A marker at a screen point: WebKit answers directly; for Chromium,
    /// hit-test the element and take the start of its text leaf.
    private func marker(at point: CGPoint) -> AnyObject? {
        if let m = p("AXTextMarkerForPosition", AX.pointValue(point)) { return m }
        // Chromium's hit test is unreliable in some apps (T3 Code returns a
        // 1 px button that doesn't even contain the point). Trust it only if
        // it lands on text under the point; otherwise find the text by
        // descending from the web area. Never anchor to a container.
        if let hit = AX.element(at: point), AX.frame(hit)?.contains(point) ?? false,
           let leaf = Self.textLeaf(in: hit, at: point) {
            return leafStart(leaf)
        }
        return Self.textLeaf(in: element, at: point).flatMap(leafStart)
    }

    /// Markers must be anchored to a text leaf. A marker taken from a
    /// container's range (a hit-tested message block, the web area itself)
    /// stays anchored to that container through every navigation call, and
    /// Chromium then answers every bounds query with the container's box.
    private func leafStart(_ e: AXUIElement) -> AnyObject? {
        p("AXTextMarkerRangeForUIElement", e).map(start(of:))
    }

    /// The static text under `point` inside `e`: descend through children
    /// whose frame contains it; if the point falls between lines, take the
    /// first text at or below it in the deepest container that holds it.
    /// Without a point, the first static text.
    static func textLeaf(in e: AXUIElement, at point: CGPoint? = nil) -> AXUIElement? {
        func visibleText(_ x: AXUIElement) -> Bool {
            AX.role(x) == kAXStaticTextRole && (AX.frame(x).map { $0.height >= 4 } ?? false) // skip collapsed text
        }
        if visibleText(e) { return e }
        guard let point else { return AX.firstInOrder(in: e, maxNodes: 400) { x in visibleText(x) } }
        var cur = e
        for _ in 0..<32 {
            guard let child = AX.children(cur).first(where: { AX.frame($0).map { $0.contains(point) && $0.height >= 4 } ?? false }) else { break }
            if visibleText(child) { return child }
            cur = child
        }
        // Between lines or in padding: the first text at or below the point,
        // in document order, inside the deepest container that holds it.
        return AX.firstInOrder(in: cur, maxNodes: 600) { x in
            visibleText(x) && (AX.frame(x).map { $0.maxY >= point.y } ?? false)
        }
    }

    /// The hold loop asks 30 times a second; while the pointer stays inside
    /// the last paragraph's box, that's still the answer.
    private var lastParagraph: (start: AnyObject, bounds: CGRect)?

    func paragraph(at point: CGPoint) -> (start: AnyObject, bounds: CGRect)? {
        if let last = lastParagraph, last.bounds.contains(point) { return last }
        lastParagraph = findParagraph(at: point)
        return lastParagraph
    }

    private func findParagraph(at point: CGPoint) -> (start: AnyObject, bounds: CGRect)? {
        guard let m = marker(at: point),
              let para = p("AXParagraphTextMarkerRangeForTextMarker", m),
              SpeechText.clean(string(para)) != nil,
              let bounds = AX.rect(p("AXBoundsForTextMarkerRange", para))
        else { return nil }
        return (start(of: para), bounds)
    }

    func documentStart() -> AnyObject? {
        // A marker taken straight from the web area's range is anchored to the
        // web area itself; Chromium keeps that anchor through navigation and
        // then reports every range's bounds as the whole viewport.
        // So start from the first text leaf (see `leafStart`).
        leafStart(Self.textLeaf(in: element) ?? element)
    }

    func firstVisible() -> AnyObject? {
        guard let visible = visibleRect() else { return nil }
        if let m = p("AXStartTextMarkerForBounds", AX.rectValue(visible.insetBy(dx: 0, dy: 8))),
           let para = p("AXParagraphTextMarkerRangeForTextMarker", m) {
            return start(of: para)
        }
        // Scan down the viewport for the first readable paragraph.
        // Start a little below the top to skip toolbars and sticky headers.
        for y in stride(from: visible.minY + visible.height * 0.12, to: visible.maxY, by: 24) {
            for x in [visible.minX + visible.width * 0.5, visible.minX + visible.width * 0.3] {
                if let para = paragraph(at: CGPoint(x: x, y: y)) { return para.start }
            }
        }
        return nil
    }

    func sentence(from position: AnyObject) -> Sentence? {
        var cursor = position
        for _ in 0..<64 { // skip empty fragments: images, separators, icons
            guard let (chunkEnd, blockBreaks) = chunk(from: cursor), let chunkRange = range(cursor, chunkEnd) else { return nil }
            let chunk = string(chunkRange)
            let chunkNS = chunk as NSString
            guard chunkNS.length > 0, !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                guard let next = p("AXNextTextMarkerForTextMarker", chunkEnd), !CFEqual(next, cursor) else { return nil }
                cursor = next
                continue
            }
            // A new paragraph's chunk starts with its separator ("\nRun swift…").
            // Tokenized as is, that lone "\n" comes back as the first "sentence",
            // and walking to cover it swallows the next word. So tokenize from
            // the first visible character; the sentence's range simply keeps
            // the leading whitespace (it's cleaned out of the spoken text).
            let lead = chunkNS.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted).location
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = chunk
            let from = String.Index(utf16Offset: lead, in: chunk)
            let first = tokenizer.tokens(for: from..<chunk.endIndex).first.map { NSRange($0, in: chunk) }
                ?? NSRange(location: lead, length: chunkNS.length - lead)
            // Chromium joins separate blocks with no separator ("TitleBody…"),
            // so a block boundary always ends the sentence.
            let length = min(NSMaxRange(first), blockBreaks.first { $0 > first.location } ?? .max)
            // The on-screen range must end on the sentence's last visible
            // character: not short of its final "." and never into the next word.
            var visibleEnd = length
            while visibleEnd > lead, let c = UnicodeScalar(chunkNS.character(at: visibleEnd - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(c) { visibleEnd -= 1 }
            let sentenceEnd = length >= chunkNS.length ? chunkEnd : walk(from: cursor, utf16Length: visibleEnd, limit: chunkEnd)
            if debugWalk {
                let got = range(cursor, sentenceEnd).map(string) ?? "?"
                print("    chunk=\(chunk.prefix(120).debugDescription) breaks=\(blockBreaks) first=\(first) len=\(length) range→\(got.debugDescription)")
            }
            if let r = range(cursor, sentenceEnd), let text = SpeechText.clean(chunkNS.substring(to: length)) {
                return Sentence(text: text, range: r, next: sentenceEnd)
            }
            if CFEqual(sentenceEnd, cursor) { return nil }
            cursor = sentenceEnd
        }
        return nil
    }

    /// A ~600 character window of text starting exactly at `cursor` (so no
    /// character is ever lost), extended paragraph by paragraph. Chromium
    /// reports every wrapped line as a "paragraph", so sentences are cut from
    /// the window, not per paragraph. Returns the window's end and the UTF-16
    /// offsets where one block element ends and a different one begins.
    private func chunk(from cursor: AnyObject) -> (AnyObject, [Int])? {
        var probe = cursor
        var chunkEnd: AnyObject?
        var breaks: [Int] = []
        for _ in 0..<12 {
            guard let para = p("AXParagraphTextMarkerRangeForTextMarker", probe) else { break }
            var paraEnd = end(of: para)
            if CFEqual(paraEnd, probe), let n = p("AXNextTextMarkerForTextMarker", paraEnd),
               let nextPara = p("AXParagraphTextMarkerRangeForTextMarker", n) {
                paraEnd = end(of: nextPara) // probe sat on a boundary; take the following paragraph
            }
            chunkEnd = paraEnd
            let length = range(cursor, paraEnd).map { (string($0) as NSString).length } ?? 0
            if length >= 600 { break }
            guard let n = p("AXNextTextMarkerForTextMarker", paraEnd), !CFEqual(n, probe) else { break }
            if !sameBlock(paraEnd, n) { breaks.append(length) }
            probe = n
        }
        return chunkEnd.map { ($0, breaks) }
    }

    /// Same block element? Both engines expose inline markup the same way:
    /// static text, links and style groups (code, strong, emphasis…) sit
    /// inside the paragraph, heading or list item they flow in. So climb past
    /// inline elements to the enclosing block and compare. (Counting hops
    /// doesn't work: sibling paragraphs share their article within two hops.)
    private func sameBlock(_ a: AnyObject, _ b: AnyObject) -> Bool {
        guard let ea = AX.element(p("AXUIElementForTextMarker", a)),
              let eb = AX.element(p("AXUIElementForTextMarker", b)) else { return false }
        if CFEqual(ea, eb) { return true }
        guard let blockA = Self.block(containing: ea), let blockB = Self.block(containing: eb) else { return false }
        return CFEqual(blockA, blockB)
    }

    private static let inlineRoles: Set<String> = [kAXStaticTextRole, "AXLink", "AXListMarker", kAXImageRole]

    private static func isInline(_ e: AXUIElement) -> Bool {
        guard let role = AX.role(e) else { return false }
        if inlineRoles.contains(role) { return true }
        // AXCodeStyleGroup, AXStrongStyleGroup, AXEmphasisStyleGroup, AXSubscriptStyleGroup…
        return role == kAXGroupRole && ((AX.attr(e, kAXSubroleAttribute) as? String)?.hasSuffix("StyleGroup") ?? false)
    }

    static func block(containing e: AXUIElement) -> AXUIElement? {
        var cur: AXUIElement? = e
        for _ in 0..<8 {
            guard let c = cur else { return nil }
            if !isInline(c) { return c }
            cur = AX.parent(c)
        }
        return nil
    }

    /// The end marker of the text from `start` covering exactly `utf16Length`.
    /// Word steps first, never past the target (overshooting would put the
    /// next sentence's first word in this one); then single characters for
    /// trailing punctuation after the last word end.
    private func walk(from start: AnyObject, utf16Length target: Int, limit: AnyObject) -> AnyObject {
        func covered(_ m: AnyObject) -> Int { range(start, m).map { (string($0) as NSString).length } ?? 0 }
        var m = start
        for _ in 0..<400 {
            guard let next = p("AXNextWordEndTextMarkerForTextMarker", m), !CFEqual(next, m) else { break }
            let n = covered(next)
            if n > target { break }
            m = next
            if n == target { return m }
        }
        for _ in 0..<8 {
            guard let next = p("AXNextTextMarkerForTextMarker", m), !CFEqual(next, m) else { break }
            let n = covered(next)
            if n > target { break }
            m = next
            if n == target { return m }
        }
        return CFEqual(m, start) ? limit : m
    }

    /// Per-sentence word layout, so the 10 Hz highlight refresh costs one AX
    /// call instead of one per word: re-measure the anchor word, shift the lines.
    private struct Layout { let range: AnyObject; let anchor: AnyObject; let anchorRect: CGRect; let lines: [CGRect] }
    private var layouts: [Layout] = []

    /// The sentence's line boxes, built from its words' boxes.
    ///
    /// Asking Chromium for the bounds of the whole range only works when both
    /// ends sit inside a text leaf. A range that starts or ends on a leaf
    /// boundary (a new paragraph, just after a final ".") gets the bounds of
    /// an enclosing block, which is the "block-level highlight". Word ranges
    /// are almost always inside a leaf; the few that aren't come back much
    /// taller than a line and are re-measured or dropped. WebKit is precise
    /// either way.
    func lines(of sentence: Sentence) -> [CGRect] {
        if let cached = layouts.first(where: { $0.range === sentence.range }) {
            if let now = rect(cached.anchor), abs(now.width - cached.anchorRect.width) < 1, abs(now.height - cached.anchorRect.height) < 1 {
                let dx = now.minX - cached.anchorRect.minX, dy = now.minY - cached.anchorRect.minY
                return plausible(cached.lines.map { $0.offsetBy(dx: dx, dy: dy) })
            }
            layouts.removeAll { $0.range === sentence.range } // reflowed: measure again
        }
        let words = wordBoxes(in: sentence.range)
        guard let lineHeight = words.map(\.rect.height).sorted().dropFirst(words.count / 2).first else {
            return plausible(rect(sentence.range).map { [$0] } ?? [])
        }
        // Too tall (spans lines/blocks) or too wide for its characters (a
        // single-line block's box): not that word's box.
        func fits(_ r: CGRect, chars: Int) -> Bool { r.height <= lineHeight * 1.5 && r.width <= CGFloat(chars + 1) * lineHeight }
        if debugWalk {
            for w in words { print("      word \(string(w.range).debugDescription) \(w.rect) fits=\(fits(w.rect, chars: w.chars)) repaired=\(fits(w.rect, chars: w.chars) ? "-" : repairedBox(w.range, lineHeight: lineHeight).map { "\($0)" } ?? "nil")") }
        }
        // A rejected word usually starts on a leaf boundary (a new paragraph)
        // or on the space before a line wrap. Measure it from a character or
        // two in, which lands inside the leaf / on the new line, and extend
        // left by the characters that were skipped.
        let good = words.compactMap { w -> (range: AnyObject, rect: CGRect)? in
            if fits(w.rect, chars: w.chars) { return (w.range, w.rect) }
            return repairedBox(w.range, lineHeight: lineHeight).map { (w.range, $0) }
        }
        guard let first = good.first else { return plausible(rect(sentence.range).map { [$0] } ?? []) }
        let lines = Self.groupIntoLines(good.map(\.rect))
        layouts.append(Layout(range: sentence.range, anchor: first.range, anchorRect: first.rect, lines: lines))
        if layouts.count > 6 { layouts.removeFirst() }
        if debugWalk { print("    lines: \(good.count)/\(words.count) words kept, line \(Int(lineHeight)) → \(lines)") }
        return plausible(lines)
    }

    /// Words in reading order → one box per visual line.
    static func groupIntoLines(_ boxes: [CGRect]) -> [CGRect] {
        var lines: [CGRect] = []
        for b in boxes {
            if let i = lines.firstIndex(where: { abs($0.midY - b.midY) < min($0.height, b.height) / 2 }) {
                lines[i] = lines[i].union(b)
            } else {
                lines.append(b)
            }
        }
        return lines.sorted { $0.minY < $1.minY }
    }

    /// Chromium sometimes answers with the whole viewport; that's not a sentence.
    private func plausible(_ lines: [CGRect]) -> [CGRect] {
        guard let first = lines.first else { return [] }
        let union = lines.dropFirst().reduce(first) { $0.union($1) }
        if let v = visibleRect(), union.width >= v.width * 0.95, union.height >= v.height * 0.9 { return [] }
        return lines
    }

    private func rect(_ range: AnyObject) -> CGRect? { AX.rect(p("AXBoundsForTextMarkerRange", range)) }

    /// Measure a word from up to three characters in (past a leaf boundary
    /// or the space before a wrap), then extend left by what was skipped.
    private func repairedBox(_ word: AnyObject, lineHeight: CGFloat) -> CGRect? {
        let visible = { (r: AnyObject) in self.string(r).filter { !$0.isWhitespace }.count }
        let total = visible(word)
        var inner = start(of: word)
        for _ in 0..<3 {
            guard let next = p("AXNextTextMarkerForTextMarker", inner), !CFEqual(next, inner) else { return nil }
            inner = next
            guard let rest = range(inner, end(of: word)) else { return nil }
            let shown = visible(rest)
            guard shown > 0 else { return nil }
            if let r = rect(rest), r.height <= lineHeight * 1.5, r.width <= CGFloat(shown + 1) * lineHeight {
                let charWidth = r.width / CGFloat(shown), missing = CGFloat(max(0, total - shown))
                return CGRect(x: r.minX - missing * charWidth, y: r.minY, width: r.width + missing * charWidth, height: r.height)
            }
        }
        return nil
    }

    /// Each word's range (previous word end → this word end) and its box,
    /// stepping until the words cover the sentence's text.
    private func wordBoxes(in sentenceRange: AnyObject) -> [(range: AnyObject, rect: CGRect, chars: Int)] {
        let begin = start(of: sentenceRange)
        let total = (string(sentenceRange) as NSString).length
        var out: [(AnyObject, CGRect, Int)] = []
        var m = begin
        var before = 0
        for _ in 0..<200 {
            guard let next = p("AXNextWordEndTextMarkerForTextMarker", m), !CFEqual(next, m),
                  let covered = range(begin, next).map({ (string($0) as NSString).length }), covered <= total else { break }
            if let w = range(m, next), let r = rect(w) { out.append((w, r, covered - before)) }
            m = next
            before = covered
            if covered == total { break }
        }
        return out
    }

    func visibleRect() -> CGRect? {
        guard var r = AX.frame(element) else { return nil }
        var e: AXUIElement? = AX.parent(element)
        while let cur = e {
            let role = AX.role(cur)
            if role == kAXScrollAreaRole || role == kAXWindowRole, let f = AX.frame(cur) { r = r.intersection(f) }
            if role == kAXWindowRole { break }
            e = AX.parent(cur)
        }
        return r.isNull || r.isEmpty ? nil : r
    }

    func scrollIntoView(_ sentence: Sentence) {
        guard let target = AX.element(p("AXUIElementForTextMarker", start(of: sentence.range))) else { return }
        AXUIElementPerformAction(target, "AXScrollToVisible" as CFString)
    }
}

// MARK: - Native text views (TextEdit, Notes, Mail, most Cocoa apps)

final class NativeDocument: ReadableDocument {
    let element: AXUIElement
    private let text: NSString
    private let sentences: [NSRange]

    init?(element: AXUIElement) {
        guard let value = AX.attr(element, kAXValueAttribute) as? String, value.count > 1 else { return nil }
        self.element = element
        self.text = value as NSString
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = value
        sentences = tokenizer.tokens(for: value.startIndex..<value.endIndex).map { NSRange($0, in: value) }
    }

    private func index(at point: CGPoint) -> Int? {
        guard let v = AX.param(element, kAXRangeForPositionParameterizedAttribute, AX.pointValue(point)) else { return nil }
        var r = CFRange()
        AXValueGetValue(v as! AXValue, .cfRange, &r)
        return r.location
    }

    private func bounds(_ range: NSRange) -> CGRect? {
        AX.rect(AX.param(element, kAXBoundsForRangeParameterizedAttribute, AX.rangeValue(range)))
    }

    func paragraph(at point: CGPoint) -> (start: AnyObject, bounds: CGRect)? {
        guard let i = index(at: point), i < text.length else { return nil }
        let para = text.paragraphRange(for: NSRange(location: i, length: 0))
        guard SpeechText.clean(text.substring(with: para)) != nil, let b = bounds(para) else { return nil }
        return (para.location as NSNumber, b)
    }

    func documentStart() -> AnyObject? { 0 as NSNumber }

    func firstVisible() -> AnyObject? {
        guard let v = AX.attr(element, kAXVisibleCharacterRangeAttribute) else { return 0 as NSNumber }
        var r = CFRange()
        AXValueGetValue(v as! AXValue, .cfRange, &r)
        let s = sentences.first { NSMaxRange($0) > r.location }
        return (s?.location ?? r.location) as NSNumber
    }

    func sentence(from position: AnyObject) -> Sentence? {
        let start = (position as! NSNumber).intValue
        guard var i = sentences.firstIndex(where: { NSMaxRange($0) > start }) else { return nil }
        while i < sentences.count {
            var r = sentences[i]
            if r.location < start { r = NSRange(location: start, length: NSMaxRange(r) - start) }
            let next: AnyObject? = i + 1 < sentences.count ? sentences[i + 1].location as NSNumber : nil
            if let t = SpeechText.clean(text.substring(with: r)) {
                return Sentence(text: t, range: NSValue(range: r), next: next)
            }
            i += 1
        }
        return nil
    }

    /// One box per line, from the text view's own line ranges.
    func lines(of sentence: Sentence) -> [CGRect] {
        let r = (sentence.range as! NSValue).rangeValue
        guard r.length > 0, let firstLine = line(at: r.location), let lastLine = line(at: NSMaxRange(r) - 1), lastLine >= firstLine,
              lastLine - firstLine < 200 else { return bounds(r).map { [$0] } ?? [] }
        return (firstLine...lastLine).compactMap { l in
            guard let lr = range(ofLine: l) else { return nil }
            let part = NSIntersectionRange(lr, r)
            return part.length > 0 ? bounds(part) : nil
        }
    }

    private func line(at index: Int) -> Int? {
        (AX.param(element, kAXLineForIndexParameterizedAttribute, index as NSNumber) as? NSNumber)?.intValue
    }

    private func range(ofLine line: Int) -> NSRange? {
        guard let v = AX.param(element, kAXRangeForLineParameterizedAttribute, line as NSNumber) else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        return NSRange(location: r.location, length: r.length)
    }

    func visibleRect() -> CGRect? {
        var r = AX.frame(element)
        if let scroll = AX.parent(element), AX.role(scroll) == kAXScrollAreaRole, let f = AX.frame(scroll) {
            r = r?.intersection(f)
        }
        return r
    }

    func scrollIntoView(_ sentence: Sentence) {
        // Native text views only scroll by moving the caret, which would
        // hijack the user's selection. Leave it for now.
    }
}

// MARK: - Finding the document

enum DocumentFinder {
    private static let textRoles: Set<String> = [kAXTextAreaRole, kAXTextFieldRole]

    /// The document under a screen point, if any.
    static func document(at point: CGPoint) -> ReadableDocument? {
        guard let hit = AX.element(at: point) else { return nil }
        AX.enableTree(for: AX.pid(hit))
        var e: AXUIElement? = hit
        for _ in 0..<40 {
            guard let cur = e, let role = AX.role(cur) else { break }
            if role == "AXWebArea" { return WebDocument(area: cur) }
            if textRoles.contains(role), let doc = NativeDocument(element: cur) { return doc }
            if role == kAXWindowRole || role == kAXApplicationRole { break }
            e = AX.parent(cur)
        }
        return nil
    }

    /// The main readable document in the frontmost window.
    static func frontDocument() -> ReadableDocument? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return document(inApp: app.processIdentifier)
    }

    /// The main readable document in an app's focused (or main, or first) window.
    static func document(inApp pid: pid_t) -> ReadableDocument? {
        AX.enableTree(for: pid)
        let axApp = AXUIElementCreateApplication(pid)
        guard let window = AX.element(AX.attr(axApp, kAXFocusedWindowAttribute))
                ?? AX.element(AX.attr(axApp, kAXMainWindowAttribute))
                ?? (AX.attr(axApp, kAXWindowsAttribute) as? [AXUIElement])?.first else { return nil }
        let found = AX.find(in: window) { e, role in
            role == "AXWebArea" || (textRoles.contains(role) && ((AX.attr(e, kAXValueAttribute) as? String)?.count ?? 0) > 200)
        }
        guard let e = found else { return nil }
        return AX.role(e) == "AXWebArea" ? WebDocument(area: e) : NativeDocument(element: e)
    }
}
