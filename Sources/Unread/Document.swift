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
    /// The next sentence to read from `position`. With a scope, sentences
    /// outside it end the reading and page chrome inside it is skipped.
    func sentence(from position: AnyObject, in scope: ReadingScope?) -> Sentence?
    /// Where a reading that starts at `position` may go.
    func scope(from position: AnyObject) -> ReadingScope?
    /// The same sentence, found again after the page rebuilt its elements
    /// (chat apps re-render messages all the time). Nil if it's still alive
    /// or can't be found.
    func relocate(_ sentence: Sentence) -> Sentence?
    /// The sentence's on-screen boxes, one per line, so a highlight never
    /// covers the end of the previous sentence or the start of the next.
    func lines(of sentence: Sentence) -> [CGRect]
    /// Why the last `lines(of:)` came back the way it did (for the log).
    func linesDiagnosis(of sentence: Sentence) -> String
    func visibleRect() -> CGRect?
    func scrollIntoView(_ sentence: Sentence)
}

extension ReadableDocument {
    func linesDiagnosis(of sentence: Sentence) -> String { "" }
    func scope(from position: AnyObject) -> ReadingScope? { nil }
    func relocate(_ sentence: Sentence) -> Sentence? { nil }
    func sentence(from position: AnyObject) -> Sentence? { sentence(from: position, in: nil) }

    /// The sentence after `last`. If there's none because the page rebuilt
    /// its elements under us (stale markers read as nothing), find `last`
    /// again and carry on from there, with a scope recomputed in the new tree.
    func sentence(after last: Sentence, scope: inout ReadingScope?) -> Sentence? {
        if let next = last.next, let s = sentence(from: next, in: scope) { return s }
        guard let fresh = relocate(last), let next = fresh.next else { return nil } // alive: that's the real end
        print("[unread] page re-rendered; found \(last.text.prefix(30).debugDescription) again")
        if scope != nil { scope = self.scope(from: startOf(fresh)) } // the old container may be gone too
        return sentence(from: next, in: scope)
    }

    /// Opaque start position of a sentence's range (web only; native ranges
    /// are indices and never go stale).
    func startOf(_ s: Sentence) -> AnyObject {
        CFGetTypeID(s.range) == AXTextMarkerRangeGetTypeID() ? AXTextMarkerRangeCopyStartMarker(s.range as! AXTextMarkerRange) : s.range
    }

    /// The union of the sentence's line boxes.
    func bounds(of sentence: Sentence) -> CGRect? {
        let l = lines(of: sentence)
        return l.dropFirst().reduce(l.first) { $0?.union($1) }
    }
}

/// Where a reading may go (#10): the article, or else the main area, it
/// started in. Reading ends when it leaves that container. Page chrome inside
/// it (navigation, buttons, code blocks, captions, hidden labels, timestamps,
/// link rows) is skipped, except a chrome container the user started inside:
/// pointing at something means "read this".
final class ReadingScope {
    let container: AXUIElement?
    let pointedInto: AXUIElement?
    init(container: AXUIElement?, pointedInto: AXUIElement?) {
        self.container = container
        self.pointedInto = pointedInto
    }
}

enum SpeechText {
    private static let timestamp = try! NSRegularExpression(
        pattern: #"^(\d{1,2}:\d{2}(:\d{2})?\s?([AaPp]\.?[Mm]\.?)?|\d+\s?(s|m|h|d|w|mo|y|sec|min|hr|hrs)|\d+\s(seconds?|minutes?|hours?|days?|weeks?|months?|years?)\sago|yesterday|today|just now|\d{1,2}\s[A-Za-z]{3,9}\.?,?\s\d{4}|[A-Za-z]{3,9}\.?\s\d{1,2},?\s\d{4}|\d{4}-\d{2}-\d{2})$"#,
        options: .caseInsensitive)

    /// "6:03 PM", "4h", "2 days ago", "29 October 2026": metadata, not something to read aloud.
    static func isTimestamp(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return timestamp.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

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
           let leaf = Self.textLeaf(in: hit, at: point), let m = leafStart(leaf) {
            return m
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

    /// Consecutive sentences share most of their ancestors; remember what each
    /// element turned out to be, so judging a sentence costs a few AX calls
    /// instead of dozens.
    private var parentMemo: [AXKey: AXUIElement?] = [:]
    private var chromeMemo: [AXKey: String?] = [:]
    private var linkRowMemo: [AXKey: Bool] = [:]

    func paragraph(at point: CGPoint) -> (start: AnyObject, bounds: CGRect)? {
        if let last = lastParagraph, last.bounds.contains(point) { return last }
        lastParagraph = findParagraph(at: point)
        return lastParagraph
    }

    private func findParagraph(at point: CGPoint) -> (start: AnyObject, bounds: CGRect)? {
        guard let m = marker(at: point),
              let para = p("AXParagraphTextMarkerRangeForTextMarker", m),
              SpeechText.clean(string(para)) != nil,
              let bounds = { () -> CGRect? in
                  probeTextGeometry(near: para)
                  if noTextGeometry {
                      let frames = elementFrames(of: para)
                      return frames.dropFirst().reduce(frames.first) { acc, f in acc?.union(f) }
                  }
                  return AX.rect(p("AXBoundsForTextMarkerRange", para))
              }()
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
        // Start in the content, not in the site header or a sidebar.
        let isChrome = { (m: AnyObject) in self.scope(from: m)?.pointedInto != nil }
        if let m = p("AXStartTextMarkerForBounds", AX.rectValue(visible.insetBy(dx: 0, dy: 8))),
           let para = p("AXParagraphTextMarkerRangeForTextMarker", m), !isChrome(start(of: para)) {
            return start(of: para)
        }
        // Scan down the viewport for the first readable paragraph.
        // Start a little below the top to skip toolbars and sticky headers.
        var fallback: AnyObject?
        for y in stride(from: visible.minY + visible.height * 0.12, to: visible.maxY, by: 24) {
            for x in [visible.minX + visible.width * 0.5, visible.minX + visible.width * 0.3] {
                guard let para = paragraph(at: CGPoint(x: x, y: y)) else { continue }
                if !isChrome(para.start) { return para.start }
                fallback = fallback ?? para.start
            }
        }
        return fallback
    }

    /// Whitespace plus U+FFFC (embedded objects): nothing to say, nothing to cover.
    static let blank = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FFFC}"))

    func sentence(from position: AnyObject, in scope: ReadingScope?) -> Sentence? {
        var cursor = position
        for _ in 0..<400 { // skip empty fragments (images, separators, icons) and page chrome
            guard let (chunkEnd, blockBreaks) = chunk(from: cursor), let chunkRange = range(cursor, chunkEnd) else { return nil }
            let chunk = string(chunkRange)
            let chunkNS = chunk as NSString
            guard chunkNS.length > 0, !chunk.trimmingCharacters(in: Self.blank).isEmpty else {
                guard let next = step(past: chunkEnd), !CFEqual(next, cursor) else { return nil }
                cursor = next
                continue
            }
            // A new paragraph's chunk starts with its separator ("\nRun swift…").
            // Tokenized as is, that lone "\n" comes back as the first "sentence",
            // and walking to cover it swallows the next word. So tokenize from
            // the first visible character; the sentence's range simply keeps
            // the leading whitespace (it's cleaned out of the spoken text).
            // Also skip U+FFFC: WebKit's stand-in for embedded objects (icon
            // buttons, images). Alone, "￼" would come back as a sentence too.
            let lead = chunkNS.rangeOfCharacter(from: Self.blank.inverted).location
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
                  Self.blank.contains(c) { visibleEnd -= 1 }
            // End on the last visible character, even when the sentence runs to
            // the chunk's end: trailing "￼" (an icon button) would otherwise
            // make the sentence count as part of that button.
            let sentenceEnd = visibleEnd >= chunkNS.length ? chunkEnd : walk(from: cursor, utf16Length: visibleEnd, limit: chunkEnd)
            if debugWalk {
                let got = range(cursor, sentenceEnd).map(string) ?? "?"
                print("    chunk=\(chunk.prefix(120).debugDescription) breaks=\(blockBreaks) first=\(first) len=\(length) range→\(got.debugDescription)")
            }
            if let r = range(cursor, sentenceEnd), let text = SpeechText.clean(chunkNS.substring(to: length)) {
                guard let scope else { return Sentence(text: text, range: r, next: sentenceEnd) }
                switch verdict(text: text, endingAt: sentenceEnd, in: scope) {
                case .read: return Sentence(text: text, range: r, next: sentenceEnd)
                case .end:
                    if debugWalk { print("    end of scope at \(text.prefix(40).debugDescription)") }
                    return nil
                case .skip(let why):
                    if debugWalk { print("    skip (\(why)) \(text.prefix(40).debugDescription)") }
                }
            }
            if CFEqual(sentenceEnd, cursor) { return nil }
            cursor = sentenceEnd
        }
        return nil
    }

    // MARK: Surviving re-renders

    /// Stale markers point at deleted nodes and read as nothing.
    private func isStale(_ s: Sentence) -> Bool {
        let now = SpeechText.clean(string(s.range)) ?? ""
        if debugWalk { print("    stale? \(s.text.prefix(24).debugDescription) range now reads \(now.prefix(24).debugDescription)") }
        return now.isEmpty || !now.hasPrefix(String(s.text.prefix(12)))
    }

    func relocate(_ s: Sentence) -> Sentence? {
        guard isStale(s) else { return nil }
        // Search for the start of its text in the current tree. A list item's
        // bullet is a separate marker element, so match what follows it.
        var needle = s.text
        if needle.hasPrefix("• ") { needle.removeFirst(2) }
        let key = String(needle.prefix(24))
        guard key.count >= 3 else { return nil }
        var hits: [(leaf: AXUIElement, offset: Int)] = []
        _ = AX.firstInOrder(in: element, maxNodes: 8000) { e in
            guard AX.role(e) == kAXStaticTextRole, let v = AX.attr(e, kAXValueAttribute) as? String,
                  let r = v.range(of: key) ?? (key.count > 12 ? v.range(of: String(key.prefix(12))) : nil) else { return false }
            hits.append((e, NSRange(r, in: v).location))
            return hits.count >= 4 // stop early; Chromium's per-line boxes repeat the parent's text
        }
        // Same text twice on a page: prefer the copy nearest where it was.
        let lastBox = layouts.last?.lines.first
        let best = hits.min { a, b in
            guard let box = lastBox, let fa = AX.frame(a.leaf), let fb = AX.frame(b.leaf) else { return false }
            return hypot(fa.midX - box.midX, fa.midY - box.midY) < hypot(fb.midX - box.midX, fb.midY - box.midY)
        } ?? hits.first
        if debugWalk { print("    relocate \(s.text.prefix(30).debugDescription): key \(key.debugDescription), \(hits.count) hit(s) \(hits.map { "\(((AX.attr($0.leaf, kAXValueAttribute) as? String) ?? "").prefix(30).debugDescription)@\($0.offset)" })") }
        guard let best, let leafRange = p("AXTextMarkerRangeForUIElement", best.leaf) else { return nil }
        let leafStartMarker = start(of: leafRange)
        let startMarker = best.offset == 0 ? leafStartMarker : advance(leafStartMarker, by: best.offset)
        let fresh = sentence(from: startMarker, in: nil)
        if debugWalk { print("    relocate → \(fresh.map { $0.text.prefix(40).debugDescription } ?? "nil")") }
        guard let fresh, fresh.text.hasPrefix(String(needle.prefix(8))) || s.text.hasPrefix(String(fresh.text.prefix(8))) else {
            return nil
        }
        return Sentence(text: s.text, range: fresh.range, next: fresh.next)
    }

    /// The marker `target` UTF-16 units after `from`, or as close as it gets
    /// without passing it (unlike `walk`, never jumps to a limit).
    private func advance(_ from: AnyObject, by target: Int) -> AnyObject {
        func covered(_ m: AnyObject) -> Int { range(from, m).map { (string($0) as NSString).length } ?? 0 }
        var m = from
        for _ in 0..<400 {
            guard let next = p("AXNextWordEndTextMarkerForTextMarker", m), !CFEqual(next, m) else { break }
            let n = covered(next)
            if n > target { break }
            m = next
            if n == target { return m }
        }
        for _ in 0..<64 {
            guard let next = p("AXNextTextMarkerForTextMarker", m), !CFEqual(next, m) else { break }
            let n = covered(next)
            if n > target { break }
            m = next
            if n == target { return m }
        }
        return m
    }

    // MARK: Reading scope (#10)

    func scope(from position: AnyObject) -> ReadingScope? {
        // The position may sit on the boundary with the previous element, so
        // judge by where the first sentence actually ends.
        guard let first = sentence(from: position, in: nil), let leaf = leaf(endingAt: first.next ?? end(of: first.range)) else { return nil }
        let chain = ancestry(of: leaf)
        let container = chain.first { AX.subrole($0) == "AXDocumentArticle" } ?? chain.first { AX.subrole($0) == "AXLandmarkMain" }
        let pointedInto = chain.first { chromeKind($0) != nil }
        if debugWalk {
            print("    scope: \(container.map { AX.subrole($0) ?? "?" } ?? "whole document"), pointed into: \(pointedInto.map { Self.chromeKind($0) ?? "?" } ?? "nothing")")
        }
        return ReadingScope(container: container, pointedInto: pointedInto)
    }

    private enum Verdict { case read, skip(String), end }

    /// The text leaf a sentence ending at `marker` belongs to. The end marker
    /// itself sits on the boundary with whatever follows, and which side it
    /// reports is up to the engine, so ask one character before it.
    ///
    /// Chromium may answer with an internal per-line text box (no value, and
    /// zero height on a paragraph's last line), so climb to the static text.
    private func leaf(endingAt marker: AnyObject) -> AXUIElement? {
        let inside = p("AXPreviousTextMarkerForTextMarker", marker) ?? marker
        guard let hit = AX.element(p("AXUIElementForTextMarker", inside)) ?? AX.element(p("AXUIElementForTextMarker", marker)) else { return nil }
        var cur: AXUIElement? = hit
        for _ in 0..<3 {
            guard let c = cur else { break }
            if AX.role(c) == kAXStaticTextRole { return c }
            cur = AX.parent(c)
        }
        return hit
    }

    private func verdict(text: String, endingAt marker: AnyObject, in scope: ReadingScope) -> Verdict {
        guard let leaf = leaf(endingAt: marker) else { return .read }
        let chain = ancestry(of: leaf)
        if let c = scope.container, !chain.contains(where: { CFEqual($0, c) }) { return .end }
        if let pointed = scope.pointedInto, chain.contains(where: { CFEqual($0, pointed) }) { return .read }
        // Visually hidden ("sr-only") text is ~1 px *wide*: Chromium gives the
        // text a 0–1 px frame, WebKit gives its container 1 px. Don't judge by
        // height: Chromium clips frames to the nearest scrolling container
        // (T3 Code's chat, not just the viewport), so text scrolled out of
        // view comes back full width but 0–1 px tall. That's off screen, not hidden.
        if chain.prefix(3).contains(where: { AX.frame($0).map { $0.width < 4 } ?? false }) { return .skip("hidden") }
        // …or, when the 1 px container isn't exposed, text wrapped one word
        // per line into a column no real paragraph is that narrow. (Chromium's
        // per-line text boxes are AXStaticText too, so look a level up.)
        if text.count > 8, chain.prefix(2).contains(where: { AX.frame($0).map { $0.height >= 40 && $0.width < 120 } ?? false }) {
            return .skip("hidden")
        }
        for e in chain {
            if let c = scope.container, CFEqual(e, c) { break }
            if let kind = chromeKind(e) { return .skip(kind) }
        }
        if SpeechText.isTimestamp(text) { return .skip("timestamp") }
        if let block = Self.block(containing: leaf), isLinkRow(block) { return .skip("links") }
        return .read
    }

    /// `e`, its parent, … up to and including the web area (bounded, memoized).
    private func ancestry(of e: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var cur: AXUIElement? = e
        while let c = cur, out.count < 48 {
            out.append(c)
            if CFEqual(c, element) { break }
            let key = AXKey(element: c)
            if let known = parentMemo[key] { cur = known } else { cur = AX.parent(c); parentMemo[key] = cur }
        }
        return out
    }

    private func chromeKind(_ e: AXUIElement) -> String? {
        let key = AXKey(element: e)
        if let known = chromeMemo[key] { return known }
        let kind = Self.chromeKind(e)
        chromeMemo[key] = kind
        return kind
    }

    private func isLinkRow(_ block: AXUIElement) -> Bool {
        let key = AXKey(element: block)
        if let known = linkRowMemo[key] { return known }
        let row = Self.isLinkRow(block)
        linkRowMemo[key] = row
        return row
    }

    private static let controlRoles: Set<String> = [
        "AXButton", "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXComboBox", "AXTextField",
        "AXToolbar", "AXMenu", "AXMenuBar", "AXMenuItem", "AXTabGroup", "AXSlider", "AXOutline",
    ]
    private static let chromeLandmarks: Set<String> = [
        "AXLandmarkNavigation", "AXLandmarkBanner", "AXLandmarkContentInfo", "AXLandmarkComplementary", "AXLandmarkSearch",
    ]

    /// Is `e` page chrome that a listener doesn't want read? Both engines
    /// expose the same roles/subroles for these (see docs/design.md §6).
    static func chromeKind(_ e: AXUIElement) -> String? {
        guard let role = AX.role(e) else { return nil }
        if controlRoles.contains(role) { return "control" }
        let sub = AX.subrole(e)
        if let sub, chromeLandmarks.contains(sub) { return "landmark" }
        guard role == kAXGroupRole else { return nil }
        // <pre>: WebKit says so; Chromium shows a group whose only child is the code.
        if sub == "AXPreformattedStyleGroup" { return "code" }
        let kids = AX.children(e)
        if sub == nil, kids.count == 1, AX.subrole(kids[0]) == "AXCodeStyleGroup" { return "code" }
        // <figcaption>: a text group beside an image in a small figure group.
        if let parent = AX.parent(e), AX.role(parent) == kAXGroupRole {
            let siblings = AX.children(parent)
            if siblings.count <= 3, siblings.contains(where: { AX.role($0) == kAXImageRole }),
               !kids.contains(where: { AX.role($0) == kAXImageRole }) { return "caption" }
        }
        return nil
    }

    /// A short block that is mostly links: share rows, tag lists, "related" lines.
    static func isLinkRow(_ block: AXUIElement) -> Bool {
        var total = 0, linked = 0
        func visit(_ e: AXUIElement, inLink: Bool, depth: Int) {
            guard depth < 6, total < 400 else { return }
            let role = AX.role(e)
            if role == kAXStaticTextRole {
                let n = ((AX.attr(e, kAXValueAttribute) as? String) ?? "").trimmingCharacters(in: .whitespaces).count
                total += n
                if inLink { linked += n }
            }
            for c in AX.children(e) { visit(c, inLink: inLink || role == "AXLink", depth: depth + 1) }
        }
        visit(block, inLink: false, depth: 0)
        return total > 0 && total < 200 && Double(linked) >= Double(total) * 0.6
    }

    /// The next position after `m`. WebKit's character step returns nothing at
    /// the end of an embedded object (an icon button's "￼"), which stalled the
    /// walk in front of it; fall back to the next word end, then the next
    /// paragraph end (both in the common subset).
    ///
    /// When a step crosses an embedded object ("￼"), it may stall at the next
    /// one (WebKit moves past one icon button at a time and then stops), so
    /// jump to the next text leaf in document order instead.
    private func step(past m: AnyObject) -> AnyObject? {
        var stepped: AnyObject?
        for name in ["AXNextTextMarkerForTextMarker", "AXNextWordEndTextMarkerForTextMarker", "AXNextParagraphEndTextMarkerForTextMarker"] {
            if let n = p(name, m), !CFEqual(n, m), let r = range(m, n), (string(r) as NSString).length > 0 { stepped = n; break }
        }
        // Only an embedded object stalls the step; plain whitespace and line
        // breaks are ordinary separators (and block-break detection relies on them).
        if let n = stepped, let r = range(m, n), !string(r).contains("\u{FFFC}") { return n }
        return leafStart(after: m) ?? stepped
    }

    /// The start of the first text leaf after the element holding `m`, in
    /// document order: later siblings first, then up a level. Unlike
    /// `textLeaf`, off-screen leaves count (Chromium clips their frames).
    private func leafStart(after m: AnyObject) -> AnyObject? {
        guard var node = AX.element(p("AXUIElementForTextMarker", m)) else { return nil }
        func firstText(in e: AXUIElement) -> AXUIElement? {
            AX.firstInOrder(in: e, maxNodes: 300) { x in
                AX.role(x) == kAXStaticTextRole && !(((AX.attr(x, kAXValueAttribute) as? String) ?? "").trimmingCharacters(in: Self.blank).isEmpty)
            }
        }
        for _ in 0..<16 {
            guard !CFEqual(node, element), let parent = AX.parent(node) else { return nil }
            let siblings = AX.children(parent)
            if let i = siblings.firstIndex(where: { CFEqual($0, node) }) {
                for sibling in siblings[(i + 1)...] {
                    if let leaf = firstText(in: sibling), let start = leafStart(leaf) { return start }
                }
            }
            node = parent
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
            if CFEqual(paraEnd, probe), let n = step(past: paraEnd),
               let nextPara = p("AXParagraphTextMarkerRangeForTextMarker", n) {
                paraEnd = end(of: nextPara) // probe sat on a boundary; take the following paragraph
            }
            chunkEnd = paraEnd
            let length = range(cursor, paraEnd).map { (string($0) as NSString).length } ?? 0
            if length >= 600 { break }
            guard let n = step(past: paraEnd), !CFEqual(n, probe) else { break }
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
        guard role == kAXGroupRole, let sub = AX.attr(e, kAXSubroleAttribute) as? String else { return false }
        return sub.hasSuffix("StyleGroup") && sub != "AXPreformattedStyleGroup" // <pre> is a block
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
        var overshoot: AnyObject?
        for _ in 0..<8 {
            guard let next = p("AXNextTextMarkerForTextMarker", m), !CFEqual(next, m) else { break }
            let n = covered(next)
            if n > target { overshoot = next; break }
            m = next
            if n == target { return m }
        }
        // Couldn't land exactly (an embedded object counts as one character
        // but steps as more): take the smallest overshoot. Jumping to `limit`
        // (the end of the 600-character window) silently skipped paragraphs.
        if CFEqual(m, start) { return overshoot ?? limit }
        return m
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
        probeTextGeometry(near: sentence.range)
        if noTextGeometry { return elementFrames(of: sentence.range) }
        let words = wordBoxes(in: sentence.range)
        guard let lineHeight = words.map(\.rect.height).sorted().dropFirst(words.count / 2).first else {
            if let whole = rect(sentence.range) { return plausible([whole]) }
            // No text positions at all, yet the text has a frame: a Chromium
            // browser without inline text boxes (Aside, Chrome without
            // VoiceOver). Highlight the text's element instead, and stop
            // asking for word boxes on this page.
            return elementFrames(of: sentence.range)
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
            // A word that starts across a line break or an embedded object
            // ("\n￼\nAlmost") gets a box at the separator (an icon on the line
            // above); always measure it from its first visible character.
            let crosses = string(w.range).trimmingCharacters(in: .whitespaces).contains { $0 == "\n" || $0 == "\u{FFFC}" }
            if !crosses, fits(w.rect, chars: w.chars) { return (w.range, w.rect) }
            return repairedBox(w.range, lineHeight: lineHeight).map { (w.range, $0) }
        }
        guard let first = good.first else { return plausible(rect(sentence.range).map { [$0] } ?? []) }
        // A caret-thin box (< 3 px) is a position on a line boundary, not a
        // glyph: WebKit can place a word's start at the end of the line above.
        let lines = Self.groupIntoLines(good.map(\.rect).filter { $0.width >= 3 })
        layouts.append(Layout(range: sentence.range, anchor: first.range, anchorRect: first.rect, lines: lines))
        if layouts.count > 6 { layouts.removeFirst() }
        if debugWalk { print("    lines: \(good.count)/\(words.count) words kept, line \(Int(lineHeight)) → \(lines)") }
        return plausible(lines)
    }

    /// When a sentence gets no box: are its markers still alive (the page
    /// may have re-rendered since it was extracted), and what did the words say?
    func linesDiagnosis(of sentence: Sentence) -> String {
        let now = SpeechText.clean(string(sentence.range)) ?? ""
        let words = wordBoxes(in: sentence.range)
        let whole = rect(sentence.range).map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil"
        let alive = now == sentence.text ? "markers alive" : "markers STALE (range now reads \(now.prefix(30).debugDescription))"
        return "\(alive), \(words.count) word boxes, whole-range box \(whole)"
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

    /// Set once the app answers text-position queries with zero-size boxes
    /// while its elements have real frames: a Chromium browser without inline
    /// text boxes (Aside; Chrome when VoiceOver hasn't switched on its full
    /// mode). Then highlights fall back to whole text blocks.
    private var noTextGeometry = false
    private var geometryProbed = false

    /// Ask once, on a text element that's on screen: does measuring its own
    /// text give a real box? (Off-screen text can't tell: Chromium clips frames.)
    private func probeTextGeometry(near range: AnyObject) {
        guard !geometryProbed, let leaf = leaf(endingAt: end(of: range)), let frame = AX.frame(leaf),
              frame.width >= 4, frame.height >= 4, let own = p("AXTextMarkerRangeForUIElement", leaf) else { return }
        geometryProbed = true
        if AX.rect(p("AXBoundsForTextMarkerRange", own)) == nil {
            noTextGeometry = true
            print("[unread] this page gives no text positions (no inline text boxes); highlighting whole text blocks")
        }
    }

    /// Frames of the text blocks (paragraph, heading, list item) a range starts
    /// and ends in: the coarse fallback when the app gives no text positions.
    /// The start is judged from inside the first word (the start marker sits
    /// on the boundary with the previous block).
    private func elementFrames(of range: AnyObject) -> [CGRect] {
        let begin = start(of: range)
        let firstWord = p("AXNextWordEndTextMarkerForTextMarker", begin) ?? begin
        var frames: [CGRect] = []
        for m in [firstWord, end(of: range)] {
            guard let leaf = leaf(endingAt: m) else { continue }
            let box = Self.block(containing: leaf).flatMap(AX.frame) ?? AX.frame(leaf)
            guard let f = box, f.width >= 4, f.height >= 4, !frames.contains(f) else { continue }
            frames.append(f)
        }
        return frames
    }

    /// Measure a word from up to three characters in (past a leaf boundary
    /// or the space before a wrap), then extend left by what was skipped.
    private func repairedBox(_ word: AnyObject, lineHeight: CGFloat) -> CGRect? {
        let isBlank = { (c: Character) in c.isWhitespace || c == "\u{FFFC}" }
        let visible = { (r: AnyObject) in self.string(r).filter { !isBlank($0) }.count }
        let total = visible(word)
        // Step past any leading separators (newlines, "￼"), then a little more.
        let leading = string(word).prefix { isBlank($0) }.utf16.count
        var inner = start(of: word)
        for _ in 0..<(leading + 3) {
            guard let next = p("AXNextTextMarkerForTextMarker", inner), !CFEqual(next, inner) else { return nil }
            inner = next
            guard let rest = range(inner, end(of: word)) else { return nil }
            let restText = string(rest)
            let shown = visible(rest)
            guard shown > 0 else { return nil }
            if let first = restText.first, isBlank(first) { continue } // still on a separator
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

    func sentence(from position: AnyObject, in scope: ReadingScope?) -> Sentence? {
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

    /// For the log: why pointing at `point` gave nothing to read.
    static func whyNothing(at point: CGPoint, found doc: ReadableDocument?) -> String {
        let hit = AX.element(at: point)
        let app = hit.map { NSRunningApplication(processIdentifier: AX.pid($0))?.localizedName ?? "pid \(AX.pid($0))" } ?? "?"
        let what = hit.map { "\(AX.role($0) ?? "?")\(AX.subrole($0).map { "/\($0)" } ?? "")" } ?? "nothing (hit test failed or timed out)"
        if doc == nil { return "no web area or text view under the pointer in \(app) (hit: \(what))" }
        return "\(type(of: doc!)) in \(app) has no readable paragraph at the pointer (hit: \(what))"
    }

    static func frontAppName() -> String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }

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
