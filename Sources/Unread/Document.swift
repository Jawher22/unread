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
    /// A cue (#24, #26): in place of a run of code, a table, or before a figure's caption, a soft sound is
    /// played and nothing is said; `range` covers what it stands for, for the highlight. "code", "table", "figure".
    var cue: String? = nil
    /// The figure, video or picture a "figure" cue stands for: the highlight covers it while the cue plays.
    var shows: AXUIElement? = nil
}

/// Something on screen we can read aloud, regardless of which app owns it.
/// Positions are opaque: a text marker for web content, a `NativeRange` for
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
    /// A box for each of the sentence's display words (`Sentence.words`), nil
    /// where a word couldn't be measured. Empty if the app gives no word
    /// positions. Measured right after `lines(of:)`, in the same layout.
    func words(of sentence: Sentence) -> [CGRect?]
    func visibleRect() -> CGRect?
    func scrollIntoView(_ sentence: Sentence)
}

/// The window an Accessibility element is in, as the window server knows it (private, but long stable).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ window: UnsafeMutablePointer<CGWindowID>) -> AXError

extension ReadableDocument {
    /// The window server's id for the window the document is in. AXWorker only.
    func windowID() -> CGWindowID? {
        guard let window = AX.element(AX.attr(element, kAXWindowAttribute)) else { return nil }
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(window, &id) == .success && id != 0 ? id : nil
    }
}

extension ReadableDocument {
    func linesDiagnosis(of sentence: Sentence) -> String { "" }
    func words(of sentence: Sentence) -> [CGRect?] { [] }
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

    /// Opaque start position of a sentence's range (web only; a native range
    /// doubles as its own start).
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
///
/// Inside it, the article's main text (#11) decides the rest: reading ends at
/// the first block after the last paragraph that doesn't read as one, and
/// metadata between the start and the first paragraph is skipped.
final class ReadingScope {
    let container: AXUIElement?
    let pointedInto: AXUIElement?
    /// The text leaf the reading started in: its block is always read.
    let startLeaf: AXUIElement?
    /// Its unit, and the first paragraph of main text at or after it, looked up on first use (AXWorker only).
    var startUnit: TextUnit.Key?
    var mainText: MainText?
    var mainTextResolved = false
    init(container: AXUIElement?, pointedInto: AXUIElement?, startLeaf: AXUIElement? = nil) {
        self.container = container
        self.pointedInto = pointedInto
        self.startLeaf = startLeaf
    }
}

/// What a page lays out as one block of text (#11): a paragraph, heading,
/// list item or cell. Where an engine lists a container's inline children
/// beside its blocks (WebKit drops plain `<div>`s, so a byline's links can sit
/// next to the paragraphs), the run of inline siblings between two blocks.
struct TextUnit {
    let block: AXUIElement
    /// `[block]`, or the run of `block`'s children starting at index `first`.
    let members: [AXUIElement]
    let first: Int
    var key: Key { Key(block: AXKey(element: block), first: first) }
    struct Key: Hashable { let block: AXKey; let first: Int }
}

/// The first paragraph of an article's main text: where metadata ends, and
/// the column later paragraphs must share.
struct MainText {
    let start: AnyObject
    let column: ClosedRange<CGFloat>?
}

/// A unit's text, measured the way Readability scores a paragraph (#11).
struct UnitText {
    enum Kind { case text, heading, listItem, cell }
    let kind: Kind
    let chars: Int, linkChars: Int, links: Int, words: Int
    /// How many sentences end in it (".", "?", "!", ":", ";" before a space or the end).
    let sentences: Int
    /// The unit itself ends like a sentence.
    let terminal: Bool
    let frame: CGRect?
    /// Inside the article's `<header>` (byline, read time, translations), a
    /// `<figure>`, or a form (beside a text field: "We never share your address.").
    let inHeader: Bool, inFigure: Bool, inForm: Bool
    /// "6:03 PM", "Oct 2, 2026": a timestamp, skipped where it's read.
    let isTimestamp: Bool

    var linkDensity: Double { chars == 0 ? 0 : Double(linkChars) / Double(chars) }
    /// Running text: a sentence of words, mostly not links.
    var reads: Bool { sentences > 0 && words >= 2 && linkDensity < 0.5 }
    /// Running prose, as a list of footnotes or steps can be: sentences of
    /// seven words or more on average, few links. A reference list is
    /// fragments ("Coast Press.", "Retrieved March 3, 2024.") and linked titles.
    var isProse: Bool { reads && linkDensity < 0.25 && words >= 7 * sentences }
    /// A paragraph of the article's body (a list item or heading never is).
    var isParagraph: Bool { kind == .text && reads && !inHeader && !inFigure && !inForm }
    /// Navigation: short, mostly links, no sentence (#52). A list item that is
    /// one link ("• The Claude Agent SDK;", "• AT-SPI") is content, not a row.
    var isLinkRow: Bool {
        chars > 0 && chars < 200 && Double(linkChars) >= Double(chars) * 0.6 && !terminal && !(kind == .listItem && links == 1)
    }
    func within(_ column: ClosedRange<CGFloat>?) -> Bool {
        guard let column, let f = frame, f.width > 0 else { return true }
        let overlap = min(f.maxX, column.upperBound) - max(f.minX, column.lowerBound)
        return overlap >= 0.6 * (column.upperBound - column.lowerBound)
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

    /// "[12]", "[edit]", and inline cleanup tags: "[who?]", "[citation needed]", "[clarification needed]".
    private static let citation = try! NSRegularExpression(pattern: #"\[(\d+|edit|[a-z][a-z ]{0,30}(\?| needed))\]"#, options: .caseInsensitive)
    private static let url = try! NSRegularExpression(pattern: #"https?://\S+"#)
    /// Screen-reader-only link hints. Clipped to 1 px, but their text frame is
    /// full size in both engines, so geometry can't tell; the idiom can.
    private static let linkHint = try! NSRegularExpression(pattern: #"\((opens )?in (a )?new (window|tab)\)|\(external link\)"#, options: .caseInsensitive)

    /// Citation markers blanked out, same length: the sentence tokenizer split
    /// "…disability.[3] Screen…" inside the marker, leaving "[" in one sentence
    /// and "3]" in the next. Offsets don't move, so a walk still lines up.
    static func blankingCitations(_ s: String) -> String {
        let ns = NSMutableString(string: s)
        for m in citation.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            ns.replaceCharacters(in: m.range, with: String(repeating: " ", count: m.range.length))
        }
        return ns as String
    }

    /// Make a raw on-screen string speakable, or nil if there's nothing to say.
    static func clean(_ raw: String) -> String? {
        var s = raw.replacingOccurrences(of: "\u{00AD}", with: "") // soft hyphens
            .replacingOccurrences(of: "\u{FFFC}", with: " ") // embedded objects (images, icons)
        for re in [citation, url, linkHint] {
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
    private var flowsMemo: [AXKey: Bool] = [:]
    private var roleMemo: [AXKey: (role: String?, subrole: String?)] = [:]
    private var figureMemo: [AXKey: Bool] = [:]
    private var oneLinerMemo: [AXKey: Bool] = [:]
    /// Figures (or captions without one) whose cue has been given: the next walk reads what follows.
    private var cuedFigures: Set<AXKey> = []
    private var mediaMemo: [TextUnit.Key: AXUIElement?] = [:]
    private var piecesMemo: [TextUnit.Key: [Piece]] = [:]
    private var unitTextMemo: [TextUnit.Key: UnitText] = [:]
    private var nextParagraphMemo: [Lookahead: TextUnit] = [:]
    private struct Lookahead: Hashable { let unit: TextUnit.Key; let container: AXKey?; let column: ClosedRange<CGFloat>? }
    private var inlineGroupMemo: [AXKey: Bool] = [:]
    private var childrenMemo: [AXKey: [AXUIElement]] = [:]

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
        // A run of code or table text walked past: one cue stands for it, given before what follows.
        var cue: (start: AnyObject, end: AnyObject, kind: String, shows: AXUIElement?)?
        func cueSentence(next: AnyObject?) -> Sentence? {
            cue.flatMap { c in range(c.start, c.end).map { Sentence(text: "", range: $0, next: next, cue: c.kind, shows: c.shows) } }
        }
        for _ in 0..<400 { // skip empty fragments (images, separators, icons) and page chrome
            guard let (chunkEnd, blockBreaks, lostSpaces) = chunk(from: cursor), let chunkRange = range(cursor, chunkEnd) else { return cueSentence(next: nil) }
            let chunk = string(chunkRange)
            let chunkNS = chunk as NSString
            guard chunkNS.length > 0, !chunk.trimmingCharacters(in: Self.blank).isEmpty else {
                guard let next = step(past: chunkEnd), !CFEqual(next, cursor) else { return cueSentence(next: nil) }
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
            let tokenized = SpeechText.blankingCitations(chunk)
            tokenizer.string = tokenized
            let from = String.Index(utf16Offset: lead, in: tokenized)
            let tokens = tokenizer.tokens(for: from..<tokenized.endIndex).map { NSRange($0, in: tokenized) }
            // Chromium joins separate blocks with no separator ("TitleBody…"),
            // so a block boundary always ends the sentence.
            let blockEnd = blockBreaks.first { $0 > (tokens.first?.location ?? lead) } ?? .max
            // Where a sentence made of tokens 0…last ends: its length, its last
            // visible character, and the marker there.
            func ending(through last: Int) -> (length: Int, visibleEnd: Int, marker: AnyObject) {
                let length = min(tokens.isEmpty ? chunkNS.length : NSMaxRange(tokens[last]), blockEnd)
                // The on-screen range must end on the sentence's last visible
                // character: not short of its final "." and never into the next word.
                var visibleEnd = length
                while visibleEnd > lead, let c = UnicodeScalar(chunkNS.character(at: visibleEnd - 1)),
                      Self.blank.contains(c) { visibleEnd -= 1 }
                // End on the last visible character, even when the sentence runs to
                // the chunk's end: trailing "￼" (an icon button) would otherwise
                // make the sentence count as part of that button.
                let marker = visibleEnd >= chunkNS.length ? chunkEnd : walk(from: cursor, utf16Length: visibleEnd, limit: chunkEnd)
                return (length, visibleEnd, marker)
            }
            var (length, visibleEnd, sentenceEnd) = ending(through: 0)
            // WebKit puts a numbered item's marker in the text ("1. Carry…") and
            // the tokenizer returns "1." as a sentence. One character step covers
            // the marker and the next letter, so the walk overshot its end and the
            // item lost its first letter. A fragment with nothing to say whose end
            // can't be reached joins the next sentence of its block, unspoken.
            var spoken = 0
            while spoken + 1 < tokens.count, tokens[spoken + 1].location < blockEnd,
                  SpeechText.clean(chunkNS.substring(with: NSRange(location: tokens[spoken].location, length: length - tokens[spoken].location))) == nil,
                  (range(cursor, sentenceEnd).map { (string($0) as NSString).length } ?? 0) > visibleEnd {
                spoken += 1
                (length, visibleEnd, sentenceEnd) = ending(through: spoken)
            }
            if debugWalk {
                let got = range(cursor, sentenceEnd).map(string) ?? "?"
                print("    chunk=\(chunk.prefix(120).debugDescription) breaks=\(blockBreaks) lostSpaces=\(lostSpaces) first=\(tokens.first.map { "\($0)" } ?? "-") joined=\(spoken) len=\(length) range→\(got.debugDescription)")
            }
            // What to say: from the first token with something to say, with the
            // spaces Chromium lost put back.
            var said = ""
            var at = spoken > 0 ? tokens[spoken].location : 0
            for gap in lostSpaces where gap > at && gap < length {
                said += chunkNS.substring(with: NSRange(location: at, length: gap - at)) + " "
                at = gap
            }
            said += chunkNS.substring(with: NSRange(location: at, length: length - at))
            if var r = range(cursor, sentenceEnd), var text = SpeechText.clean(said) {
                guard let scope else { return Sentence(text: text, range: r, next: sentenceEnd) }
                // A heading's permalink or "edit" link, a title's site name:
                // say, highlight and judge only what's left (WebKit's "Historyedit"
                // ends in the link). The walk still goes on after the furniture.
                var judgeAt = sentenceEnd, endLeaf = leaf(endingAt: sentenceEnd)
                let own = endLeaf.flatMap { furnitureFree(text, leaf: $0) }
                if let own, !own.isEmpty {
                    let at = (chunkNS.substring(to: length) as NSString).range(of: own)
                    if at.location != NSNotFound {
                        let e = walk(from: cursor, utf16Length: NSMaxRange(at), limit: chunkEnd)
                        if let narrowed = range(at.location == 0 ? cursor : advance(cursor, by: at.location), e) {
                            r = narrowed; judgeAt = e; endLeaf = leaf(endingAt: e)
                        }
                    }
                    text = own
                }
                switch own == "" ? .skip("furniture") : verdict(text: text, endingAt: judgeAt, leaf: endLeaf, in: scope) {
                case let v where v.reads:
                    // A caption, or the first text after a drawing, video or picture: its cue, on this text, then the text.
                    var figure: (key: AXKey, kind: String, shows: AXUIElement?)?
                    if case .cueThenRead(let kind) = v, let endLeaf {
                        let around = ancestry(of: endLeaf).first(where: isFigure)
                        figure = (AXKey(element: around ?? endLeaf), kind, around)
                    } else if let endLeaf, let media = media(before: endLeaf, in: scope) {
                        figure = (AXKey(element: media), "figure", media)
                    }
                    if cue == nil, let figure, !cuedFigures.contains(figure.key) {
                        cuedFigures.insert(figure.key)
                        cue = (start(of: r), end(of: r), figure.kind, figure.shows)
                    }
                    if cue != nil { return cueSentence(next: cursor) } // the cue first; this sentence on the next walk
                    return Sentence(text: text, range: r, next: sentenceEnd)
                case .end:
                    if debugWalk { print("    end of scope at \(text.prefix(40).debugDescription)") }
                    return cueSentence(next: nil)
                case .cue(let kind):
                    if debugWalk { print("    cue (\(kind)) \(text.prefix(40).debugDescription)") }
                    cue = (cue?.start ?? start(of: r), sentenceEnd, cue?.kind ?? kind, nil)
                case .skip(let why):
                    if debugWalk { print("    skip (\(why)) \(text.prefix(40).debugDescription)") }
                default: break
                }
            }
            if CFEqual(sentenceEnd, cursor) { return cueSentence(next: nil) }
            cursor = sentenceEnd
        }
        return cueSentence(next: nil)
    }

    // MARK: Surviving re-renders

    /// Stale markers point at deleted nodes and read as nothing.
    private func isStale(_ s: Sentence) -> Bool {
        if s.cue != nil { return false } // nothing said, nothing to find again
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

    // MARK: Reading scope (#10, #11)

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
        return ReadingScope(container: container, pointedInto: pointedInto, startLeaf: leaf)
    }

    /// `cue`: walked past, with a sound in its place (code, tables). `cueThenRead`: a sound, then read (a caption).
    private enum Verdict {
        case read, skip(String), end, cue(String), cueThenRead(String)
        var reads: Bool { switch self { case .read, .cueThenRead: true; default: false } }
    }

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

    /// `leaf`: the text leaf the sentence ends in (`leaf(endingAt: marker)`).
    private func verdict(text: String, endingAt marker: AnyObject, leaf: AXUIElement?, in scope: ReadingScope) -> Verdict {
        guard let leaf else { return .read }
        let chain = ancestry(of: leaf)
        if let c = scope.container, !chain.contains(where: { CFEqual($0, c) }) { return .end }
        // Code and tables are a sound, not read (#24, #26), even pointed at; a one-line command is read.
        if let cue = cueVerdict(chain, leaf: leaf, in: scope) { return cue }
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
            if let kind = chromeKind(e) { return kind == "caption" ? .cueThenRead("figure") : .skip(kind) }
        }
        if SpeechText.isTimestamp(text) { return .skip("timestamp") }
        guard let unit = unit(of: leaf) else { return .read }
        let t = self.text(of: unit)
        if t.isLinkRow { return .skip("links") }
        // The text layer (#11), around the article's main text. Pointing means
        // "read this", and a page without a paragraph keeps the rules above.
        if scope.startUnit == nil, let start = scope.startLeaf { scope.startUnit = self.unit(of: start)?.key }
        if scope.startUnit == unit.key { return .read }
        guard let main = mainText(of: scope) else { return .read }
        if t.isParagraph, t.within(main.column) { return .read }
        // Between the start (the title) and the first paragraph: bylines, read
        // times, label rows, topic links, notices. Headings, sentences and
        // list items that aren't links stay (pointing at a heading above a
        // list). From one character inside: Chromium joins blocks with no
        // separator, so the end of a line can be the paragraph's start.
        if t.kind != .heading, isAfter(main.start, p("AXPreviousTextMarkerForTextMarker", marker) ?? marker) {
            let stays = !t.inHeader && (t.reads || (t.kind == .listItem && t.linkDensity < 0.6))
            return stays ? .read : .skip("metadata")
        }
        // Past the last paragraph, the first block that isn't one ends the
        // reading: tag rows, "Keep reading", sign-up boxes, a sidebar column,
        // "See also" and the references. Unless nothing follows: then it's the
        // article's last line (a chat's "All tests pass"), and reading ends after it.
        if !t.reads || !t.within(main.column) {
            let next = paragraph(after: section(of: unit, kind: t.kind), in: scope, column: main.column)
            if next.paragraph == nil { return next.moreText ? .end : .read }
            if t.inFigure, !t.reads { return .cueThenRead("figure") }
        }
        return .read
    }

    /// Code (a `<pre>`) and table cells: a cue instead of their text. A code block of one short line (a
    /// command, 60 characters or less) is read: "Run this:" followed by it is common in an agent's answer.
    private func cueVerdict(_ chain: [AXUIElement], leaf: AXUIElement, in scope: ReadingScope) -> Verdict? {
        for e in chain {
            if let c = scope.container, CFEqual(e, c) { break }
            if chromeKind(e) == "code" { return isOneLiner(e) ? .read : .cue("code") }
        }
        if let unit = unit(of: leaf), text(of: unit).kind == .cell { return .cue("table") }
        return nil
    }

    private func isOneLiner(_ code: AXUIElement) -> Bool {
        let key = AXKey(element: code)
        if let known = oneLinerMemo[key] { return known }
        let text = p("AXTextMarkerRangeForUIElement", code).map(string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let one = !text.isEmpty && text.count <= 60 && !text.contains("\n")
        oneLinerMemo[key] = one
        return one
    }

    /// Where the article's ending is judged from: a list item's list, a
    /// heading's list right after it ("Key takeaways" and its bullets), or the
    /// unit itself. Judged from the item, the list's own remaining bullets
    /// looked like text after the article and ended the reading at its last
    /// section.
    private func section(of unit: TextUnit, kind: UnitText.Kind) -> TextUnit {
        let chain = ancestry(of: unit.block)
        switch kind {
        case .listItem:
            if let list = chain.dropFirst().first, roles(list).role == kAXListRole { return TextUnit(block: list, members: [list], first: -1) }
        case .heading:
            if unit.first < 0, let parent = chain.dropFirst().first, case let kids = children(of: parent),
               let i = kids.firstIndex(where: { CFEqual($0, unit.block) }), i + 1 < kids.count, roles(kids[i + 1]).role == kAXListRole {
                return TextUnit(block: kids[i + 1], members: [kids[i + 1]], first: -1)
            }
        default: break
        }
        return unit
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
        // <figcaption>: a group of text (one block, not a header's columns of metadata) beside an image in a small figure group.
        if holdsOnlyInline(e), let parent = AX.parent(e), AX.role(parent) == kAXGroupRole {
            let siblings = AX.children(parent)
            if siblings.count <= 3, siblings.contains(where: { AX.role($0) == kAXImageRole }),
               !kids.contains(where: { AX.role($0) == kAXImageRole }) { return "caption" }
        }
        return nil
    }

    // MARK: Text units (#11)

    /// The unit `leaf`'s text belongs to: its block, or the run of inline
    /// siblings around it where the block also holds blocks.
    private func unit(of leaf: AXUIElement) -> TextUnit? {
        guard let b = block(containing: leaf) else { return nil }
        let kids = children(of: b)
        if !isMixed(b) { return TextUnit(block: b, members: [b], first: -1) }
        let chain = ancestry(of: leaf)
        guard let i = chain.firstIndex(where: { CFEqual($0, b) }), i > 0,
              let at = kids.firstIndex(where: { CFEqual($0, chain[i - 1]) }) else { return TextUnit(block: b, members: [b], first: -1) }
        var lo = at, hi = at
        while lo > 0, flows(kids[lo - 1]) { lo -= 1 }
        while hi + 1 < kids.count, flows(kids[hi + 1]) { hi += 1 }
        return TextUnit(block: b, members: Array(kids[lo...hi]), first: lo)
    }

    /// Role and subrole, asked once per element.
    private func roles(_ e: AXUIElement) -> (role: String?, subrole: String?) {
        let key = AXKey(element: e)
        if let known = roleMemo[key] { return known }
        let r = (AX.role(e), AX.subrole(e))
        roleMemo[key] = r
        return r
    }

    /// Inline content: text, links, style groups, inline plain groups.
    private func flows(_ e: AXUIElement) -> Bool {
        let key = AXKey(element: e)
        if let known = flowsMemo[key] { return known }
        let f = Self.isInline(e) || isInlineGroup(e)
        flowsMemo[key] = f
        return f
    }

    /// A block that holds blocks as well as inline content (WebKit's flattened `<div>`s).
    private func isMixed(_ b: AXUIElement) -> Bool { !children(of: b).allSatisfy(flows) }

    /// A unit's text, in order, each piece with the link it sits in.
    private struct Piece { let text: String; let link: AXUIElement? }

    private func pieces(of unit: TextUnit) -> [Piece] {
        if let known = piecesMemo[unit.key] { return known }
        var out: [Piece] = []
        var budget = 600
        func visit(_ e: AXUIElement, link: AXUIElement?, depth: Int) {
            budget -= 1
            guard depth < 10, budget > 0 else { return }
            let role = AX.role(e)
            // Chromium's static text has per-line text boxes as children; its value is the whole text.
            if role == kAXStaticTextRole { out.append(Piece(text: (AX.attr(e, kAXValueAttribute) as? String) ?? "", link: link)); return }
            if let role, Self.controlRoles.contains(role) { return }
            for c in children(of: e) { visit(c, link: role == "AXLink" ? e : link, depth: depth + 1) }
        }
        for m in unit.members { visit(m, link: nil, depth: 0) }
        piecesMemo[unit.key] = out
        return out
    }

    private static func isCitation(_ linkText: String) -> Bool {
        let t = linkText.trimmingCharacters(in: blank)
        guard !t.isEmpty, t.lowercased() != "edit" else { return false }
        let bracketed = t.hasPrefix("[") ? t : "[" + t + "]"
        return SpeechText.blankingCitations(bracketed).trimmingCharacters(in: blank).isEmpty
    }

    private static let sentenceEnd = try! NSRegularExpression(pattern: #"[\p{L}\p{N})\]"'”’][.!?…:;]+["'”’)\]]*(\s|$)"#)

    private func text(of unit: TextUnit) -> UnitText {
        if let known = unitTextMemo[unit.key] { return known }
        let all = pieces(of: unit)
        // A citation marker ("[19]", or "who?" between brackets outside the
        // link) is a link, but not one a reader follows: leave it out.
        var linkText: [AXKey: String] = [:]
        for p in all { if let l = p.link { linkText[AXKey(element: l), default: ""] += p.text } }
        let citations = Set(linkText.filter { Self.isCitation($0.value) }.keys)
        let ps = all.filter { $0.link.map { !citations.contains(AXKey(element: $0)) } ?? true }
        var chars = 0, linkChars = 0
        for p in ps {
            let n = p.text.trimmingCharacters(in: .whitespaces).count
            chars += n
            if p.link != nil { linkChars += n }
        }
        let links = Set(ps.compactMap { $0.link.map { AXKey(element: $0) } })
        let joined = SpeechText.blankingCitations(ps.map(\.text).joined())
        let words = joined.split(whereSeparator: \.isWhitespace).filter { $0.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) }.count
        let ns = joined as NSString
        let ends = Self.sentenceEnd.matches(in: joined, range: NSRange(location: 0, length: ns.length))
        let trimmed = joined.trimmingCharacters(in: Self.blank)
        let terminal = ends.contains { NSMaxRange($0.range) >= ns.length || ns.substring(from: NSMaxRange($0.range)).trimmingCharacters(in: Self.blank).isEmpty }
            && !trimmed.isEmpty
        let b = unit.block
        let parentRole = ancestry(of: b).dropFirst().first.flatMap { roles($0).role }
        let kind: UnitText.Kind = roles(b).role == kAXHeadingRole ? .heading
            : parentRole == kAXListRole ? .listItem
            : ancestry(of: b).prefix(4).contains(where: { ["AXCell", "AXRow", "AXTable"].contains(roles($0).role ?? "") }) ? .cell
            : .text
        let frame = self.frame(of: unit)
        // The article's <header>, a <figure>.
        var inHeader = false, inFigure = false
        for e in ancestry(of: b).prefix(8) {
            if roles(e).subrole == "AXSectionHeader" { inHeader = true }
            if isFigure(e) { inFigure = true }
        }
        // A form is a plain group in Chromium; what gives it away is a text field (or a label holding one) beside the text.
        var inForm = false
        if let parent = ancestry(of: b).dropFirst().first, case let siblings = children(of: parent), siblings.count <= 8 {
            let fields: Set<String> = ["AXTextField", "AXComboBox", "AXTextArea"]
            inForm = siblings.contains { k in
                fields.contains(roles(k).role ?? "") || (roles(k) == (kAXGroupRole, nil) && children(of: k).count <= 4 && children(of: k).contains { fields.contains(roles($0).role ?? "") })
            }
        }
        let t = UnitText(kind: kind, chars: chars, linkChars: linkChars, links: links.count, words: words,
                         sentences: ends.count, terminal: terminal, frame: frame, inHeader: inHeader, inFigure: inFigure, inForm: inForm,
                         isTimestamp: SpeechText.isTimestamp(trimmed))
        unitTextMemo[unit.key] = t
        return t
    }

    /// A unit's box: its block's, or the union of its run's (a `<sub>` loose in the
    /// article is a run, and its block is the whole article).
    private func frame(of unit: TextUnit) -> CGRect? {
        var frame: CGRect?
        for m in unit.members { if let f = AX.frame(m), f.width > 0 { frame = frame.map { $0.union(f) } ?? f } }
        return frame
    }

    /// The drawing, video or picture right before `leaf`'s unit, when nothing
    /// in it is read: a `<figure>` without a `<figcaption>` (raphaelsalaja.com
    /// puts the caption in a `<sub>` after it), a video, an image. Pointing at
    /// the text after one reads that text, with no cue.
    private func media(before leaf: AXUIElement, in scope: ReadingScope) -> AXUIElement? {
        if scope.startUnit == nil, let start = scope.startLeaf { scope.startUnit = self.unit(of: start)?.key }
        guard let unit = unit(of: leaf), scope.startUnit != unit.key else { return nil }
        if let known = mediaMemo[unit.key] { return known }
        var before: AXUIElement?
        if unit.first > 0 {
            before = children(of: unit.block)[unit.first - 1]
        } else if unit.first < 0, let parent = ancestry(of: unit.block).dropFirst().first {
            let kids = children(of: parent)
            if let i = kids.firstIndex(where: { CFEqual($0, unit.block) }), i > 0 { before = kids[i - 1] }
        }
        let media = before.flatMap { isMedia($0) ? $0 : nil }
        mediaMemo[unit.key] = media
        return media
    }

    /// Something shown with nothing to read in it. WebKit says "figure", "video
    /// playback" or gives an empty group; Chromium's `<video>` is an empty group
    /// (beside its play button), and it drops an `alt=""` image.
    private func isMedia(_ e: AXUIElement) -> Bool {
        var budget = 40
        var shown = false
        func visit(_ x: AXUIElement, depth: Int) -> Bool { // false: there's text to read
            budget -= 1
            guard budget > 0, depth < 4 else { return false }
            let (role, subrole) = roles(x)
            if role == kAXStaticTextRole { return ((AX.attr(x, kAXValueAttribute) as? String) ?? "").trimmingCharacters(in: Self.blank).isEmpty }
            if let role, Self.controlRoles.contains(role) { return true }
            let kids = children(of: x)
            let wide = (AX.frame(x)?.width ?? 0) >= 100
            if role == kAXImageRole || isFigure(x) || subrole == "AXEmptyGroup" || (role == kAXGroupRole && kids.isEmpty) { shown = shown || wide }
            if role == kAXImageRole { return true }
            return kids.allSatisfy { visit($0, depth: depth + 1) }
        }
        return visit(e, depth: 0) && shown
    }

    /// A `<figure>`. Both engines expose it as a plain group whose role
    /// description says "figure" (localized by the browser: English and
    /// French say "figure"). Its image may not be there: Chromium drops a
    /// decorative one (alt=""), leaving only the caption.
    private func isFigure(_ e: AXUIElement) -> Bool {
        let key = AXKey(element: e)
        if let known = figureMemo[key] { return known }
        let f = roles(e).role == kAXGroupRole && (AX.attr(e, kAXRoleDescriptionAttribute) as? String)?.lowercased() == "figure"
        figureMemo[key] = f
        return f
    }

    /// The article's first paragraph at or after where the reading started.
    private func mainText(of scope: ReadingScope) -> MainText? {
        if scope.mainTextResolved { return scope.mainText }
        scope.mainTextResolved = true
        guard let leaf = scope.startLeaf, let start = unit(of: leaf),
              let first = text(of: start).isParagraph ? start : paragraph(after: start, in: scope, column: nil).paragraph,
              let firstLeaf = AX.firstInOrder(in: first.members[0], maxNodes: 200, { x in
                  AX.role(x) == kAXStaticTextRole && !(((AX.attr(x, kAXValueAttribute) as? String) ?? "").trimmingCharacters(in: Self.blank).isEmpty)
              }),
              let marker = leafStart(firstLeaf) else { return nil }
        let f = text(of: first).frame
        scope.mainText = MainText(start: marker, column: f.map { $0.minX...$0.maxX })
        if debugWalk { print("    main text starts at \(pieces(of: first).map(\.text).joined().prefix(40).debugDescription), column \(f.map { "\($0.minX)…\($0.maxX)" } ?? "?")") }
        return scope.mainText
    }

    /// The next paragraph of main text after `unit` in document order, inside
    /// the scope, in the column. Chrome, tables and headings are passed over
    /// whole, and lists unless they read as prose (footnotes, steps): only
    /// paragraphs count as the article going on. `moreText`: anything else to
    /// read comes after it.
    private func paragraph(after unit: TextUnit, in scope: ReadingScope, column: ClosedRange<CGFloat>?) -> (paragraph: TextUnit?, moreText: Bool) {
        let memoKey = Lookahead(unit: unit.key, container: scope.container.map { AXKey(element: $0) }, column: column)
        if let known = nextParagraphMemo[memoKey] { return (known, true) }
        var budget = 3000
        var moreText = false
        func isMain(_ u: TextUnit) -> Bool {
            let t = text(of: u)
            if t.words > 0, !t.isLinkRow, !t.isTimestamp { moreText = true }
            return t.isParagraph && t.within(column)
        }
        func scan(_ kids: [AXUIElement], from: Int, in parent: AXUIElement) -> TextUnit? {
            var i = from
            while i < kids.count {
                budget -= 1
                guard budget > 0 else { return nil }
                if flows(kids[i]) {
                    var j = i
                    while j + 1 < kids.count, flows(kids[j + 1]) { j += 1 }
                    let run = TextUnit(block: parent, members: Array(kids[i...j]), first: i)
                    if isMain(run) { return run }
                    i = j + 1
                } else {
                    if let u = search(kids[i]) { return u }
                    i += 1
                }
            }
            return nil
        }
        func search(_ e: AXUIElement) -> TextUnit? {
            guard chromeKind(e) == nil else { return nil }
            let role = roles(e).role
            // A text area is an input (a chat's composer), not more of the page,
            // though WebKit gives an empty one its placeholder as text. It stays
            // readable elsewhere: rich editors are text areas.
            if role == kAXImageRole || role == kAXTextAreaRole { return nil }
            if let role, [kAXHeadingRole, "AXTable"].contains(role) { moreText = true; return nil }
            if role == kAXListRole {
                let list = TextUnit(block: e, members: [e], first: -1), t = text(of: list)
                moreText = moreText || t.words > 0
                return t.isProse && t.within(column) ? list : nil
            }
            let kids = children(of: e)
            if kids.isEmpty { return nil }
            if !isMixed(e) { let u = TextUnit(block: e, members: [e], first: -1); return isMain(u) ? u : nil }
            return scan(kids, from: 0, in: e)
        }
        var found: TextUnit?
        var node = unit.block
        if unit.first >= 0 { found = scan(children(of: unit.block), from: unit.first + unit.members.count, in: unit.block) }
        while found == nil, budget > 0 {
            if let c = scope.container, CFEqual(node, c) { break }
            guard !CFEqual(node, element), let parent = ancestry(of: node).dropFirst().first else { break }
            let kids = children(of: parent)
            if let i = kids.firstIndex(where: { CFEqual($0, node) }) { found = scan(kids, from: i + 1, in: parent) }
            node = parent
        }
        // Only a hit is remembered: a chat keeps growing below the last message.
        if let found { nextParagraphMemo[memoKey] = found }
        return (found, moreText || found != nil)
    }

    // MARK: Furniture (#11)

    /// What a heading or a title line says without its furniture: a permalink
    /// ("#", "¶"), an "edit" link beside the heading, a hidden "Copy link"
    /// tooltip that only WebKit puts in the text, a site name after a
    /// separator ("How web bloat impacts users | Patreon"). Nil if there's
    /// nothing to take out, "" if the sentence is all furniture.
    private func furnitureFree(_ text: String, leaf: AXUIElement) -> String? {
        guard let unit = unit(of: leaf) else { return nil }
        if let heading = heading(of: unit) {
            let own = SpeechText.clean(pieces(of: TextUnit(block: heading, members: [heading], first: -1))
                .filter { $0.link == nil || $0.text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) }
                .map(\.text).joined()) ?? ""
            if own == text { return nil }
            if !own.isEmpty, text.contains(own) { return own }
            return ancestry(of: leaf).contains(where: { CFEqual($0, heading) }) ? nil : ""
        }
        let t = self.text(of: unit)
        guard !t.terminal, t.words <= 24 else { return nil }
        // Links at the end, after text that ends with a separator (WebKit may
        // fold the separator into the title's text, Chromium keeps it apart).
        let ps = pieces(of: unit)
        guard let last = ps.lastIndex(where: { $0.link == nil && !$0.text.trimmingCharacters(in: Self.blank).isEmpty }),
              ps[(last + 1)...].contains(where: { $0.link != nil }) else { return nil }
        let head = ps[...last].map(\.text).joined().trimmingCharacters(in: Self.blank)
        guard let sep = head.last, "|·•–—/".contains(sep),
              let own = SpeechText.clean(String(head.dropLast())), own != text, text.contains(own) else { return nil }
        return own
    }

    /// The heading a unit belongs to: the unit itself, or the one heading in
    /// a small row beside its links ("History" and "edit" on Wikipedia). The
    /// row's `<div>` may not be in the tree: then the links follow the heading.
    private func heading(of unit: TextUnit) -> AXUIElement? {
        if roles(unit.block).role == kAXHeadingRole { return unit.block }
        if unit.first > 0, case let before = children(of: unit.block)[unit.first - 1], roles(before).role == kAXHeadingRole,
           unit.members.allSatisfy({ ["AXLink", kAXStaticTextRole].contains(roles($0).role ?? "") }), text(of: unit).words <= 2 {
            return before
        }
        guard roles(unit.block) == (kAXGroupRole, nil) else { return nil }
        let kids = children(of: unit.block)
        guard kids.count <= 6 else { return nil }
        let headings = kids.filter { roles($0).role == kAXHeadingRole }
        guard headings.count == 1,
              kids.allSatisfy({ k in [kAXHeadingRole, "AXLink", kAXStaticTextRole, "AXButton"].contains(roles(k).role ?? "")
                  || (roles(k) == (kAXGroupRole, nil) && children(of: k).allSatisfy { ["AXLink", kAXStaticTextRole].contains(roles($0).role ?? "") }) })
        else { return nil }
        return headings[0]
    }

    /// The next position after `m`. WebKit's character step returns nothing at
    /// the end of an embedded object (an icon button's "￼"), which stalled the
    /// walk in front of it; fall back to the next word end, then the next
    /// paragraph end (both in the common subset).
    ///
    /// When a step crosses an embedded object ("￼"), it may stall at the next
    /// one (WebKit moves past one icon button at a time and then stops), so
    /// jump to the next text leaf in document order instead.
    ///
    /// A "next" marker can lie behind `m`: from the empty line between two
    /// `<br>`s, WebKit's character step returns the start of the paragraph
    /// before them, and the walk went round that paragraph until it gave up.
    private func step(past m: AnyObject) -> AnyObject? {
        var stepped: AnyObject?
        for name in ["AXNextTextMarkerForTextMarker", "AXNextWordEndTextMarkerForTextMarker", "AXNextParagraphEndTextMarkerForTextMarker"] {
            if let n = p(name, m), isAfter(n, m) { stepped = n; break }
        }
        // Only an embedded object stalls the step; plain whitespace and line
        // breaks are ordinary separators (and block-break detection relies on them).
        if let n = stepped, let r = range(m, n), !string(r).contains("\u{FFFC}") { return n }
        // Chromium lists a table's cells again under its AXColumns, so the
        // next leaf in tree order after the last cell is the first cell.
        if let leaf = leafStart(after: m), isAfter(leaf, m) { return leaf }
        return stepped
    }

    /// Is `b` past `a`, with text between them? Ranges are built from
    /// unordered markers, so a marker that went backwards reads like one that
    /// went forwards; the ordered range's start tells them apart.
    private func isAfter(_ b: AnyObject, _ a: AnyObject) -> Bool {
        guard !CFEqual(a, b), let r = range(a, b), (string(r) as NSString).length > 0 else { return false }
        return !CFEqual(start(of: r), b)
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
    /// the window, not per paragraph. Returns the window's end, the UTF-16
    /// offsets where one block element ends and a different one begins, and
    /// those where the window's text lost a space (`lostSpace`).
    ///
    /// Twelve paragraphs are usually plenty, but Chromium's "paragraphs" can
    /// be single text runs ("ChatGPT itself", " (", "April 2023", "), "…), and
    /// in link-dense prose twelve of them ended the window, and the sentence,
    /// mid-sentence. Past twelve, keep going only while the first sentence is
    /// unfinished: going on regardless made a Wikipedia walk four times slower.
    private func chunk(from cursor: AnyObject) -> (end: AnyObject, breaks: [Int], lostSpaces: [Int])? {
        var probe = cursor
        var chunkEnd: AnyObject?
        var breaks: [Int] = [], lostSpaces: [Int] = []
        var text = ""
        for i in 0..<64 {
            if i >= 12, Self.holdsFirstSentence(text, breaks: breaks) { break }
            guard let para = p("AXParagraphTextMarkerRangeForTextMarker", probe) else { break }
            var paraEnd = end(of: para)
            if CFEqual(paraEnd, probe), let n = step(past: paraEnd),
               let nextPara = p("AXParagraphTextMarkerRangeForTextMarker", n) {
                paraEnd = end(of: nextPara) // probe sat on a boundary; take the following paragraph
            }
            chunkEnd = paraEnd
            text = range(cursor, paraEnd).map(string) ?? ""
            let length = (text as NSString).length
            if length >= 600 { break }
            guard let n = step(past: paraEnd), !CFEqual(n, probe) else { break }
            if !sameBlock(paraEnd, n) { breaks.append(length) }
            else if let last = text.unicodeScalars.last, !Self.blank.contains(last), lostSpace(between: paraEnd, and: n) { lostSpaces.append(length) }
            probe = n
        }
        return chunkEnd.map { ($0, breaks, lostSpaces) }
    }

    /// Does the window already hold its first sentence's end: a block break
    /// after its first visible character, or the start of a second sentence
    /// (with a letter in it: "…disability.[3" isn't one yet)?
    private static func holdsFirstSentence(_ text: String, breaks: [Int]) -> Bool {
        let ns = text as NSString
        let lead = ns.rangeOfCharacter(from: blank.inverted).location
        guard lead != NSNotFound else { return false }
        if breaks.contains(where: { $0 > lead }) { return true }
        let tokenizer = NLTokenizer(unit: .sentence)
        let tokenized = SpeechText.blankingCitations(text)
        tokenizer.string = tokenized
        let tokens = tokenizer.tokens(for: String.Index(utf16Offset: lead, in: tokenized)..<tokenized.endIndex)
        return tokens.count >= 2 && tokenized[tokens[1]].unicodeScalars.contains(where: CharacterSet.letters.contains)
    }

    /// Chromium drops the space at a line wrap that falls where one element
    /// ends and the next begins: "half past seven" + " every weekday…" reads
    /// "sevenevery". Its text leaves still hold the space, so ask them.
    /// `b` is one step past the line's end `a`, so the text between them is
    /// the next line's first character.
    private func lostSpace(between a: AnyObject, and b: AnyObject) -> Bool {
        guard let first = range(a, b).map(string)?.unicodeScalars.first, !Self.blank.contains(first),
              let before = leaf(endingAt: a).flatMap(valued), let after = leaf(endingAt: b).flatMap(valued),
              !CFEqual(before.element, after.element) else { return false }
        return before.value.last?.isWhitespace == true || after.value.first?.isWhitespace == true
    }

    /// The text element and its value, past Chromium's per-line text boxes
    /// (also AXStaticText, but with no value).
    private func valued(_ leaf: AXUIElement) -> (element: AXUIElement, value: String)? {
        var cur: AXUIElement? = leaf
        for _ in 0..<3 {
            guard let c = cur, AX.role(c) == kAXStaticTextRole else { return nil }
            if let v = AX.attr(c, kAXValueAttribute) as? String, !v.isEmpty { return (c, v) }
            cur = AX.parent(c)
        }
        return nil
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
        guard let blockA = block(containing: ea), let blockB = block(containing: eb) else { return false }
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

    /// Chromium exposes a `<b>`, `<abbr>` or `<span>` that has an id
    /// (Wikipedia's do) as a plain group in the text flow, where WebKit folds
    /// it into the text. Judged a block, it cut "A" / "screen reader" / "is a
    /// form of…". A plain group of inline content is inline when it sits in
    /// the flow: inside a link or style group (a citation's "[1]"), or with
    /// inline neighbours, at least one of them text. A `<p>` holds only text
    /// too, but its neighbours are blocks (bare text beside one, like a
    /// visually hidden span, is on one side at most). An empty group is
    /// Chromium's `<br>`, a line break.
    private func isInlineGroup(_ e: AXUIElement) -> Bool {
        guard Self.isPlainGroup(e) else { return false }
        let key = AXKey(element: e)
        if let known = inlineGroupMemo[key] { return known }
        func isText(_ x: AXUIElement) -> Bool {
            AX.role(x) == kAXStaticTextRole && !(((AX.attr(x, kAXValueAttribute) as? String) ?? "").trimmingCharacters(in: Self.blank).isEmpty)
        }
        var inline = false
        if Self.holdsOnlyInline(e), let parent = AX.parent(e) {
            if Self.isInline(parent) {
                inline = true
            } else {
                let siblings = children(of: parent)
                if let i = siblings.firstIndex(where: { CFEqual($0, e) }) {
                    let neighbours = [i > 0 ? siblings[i - 1] : nil, i + 1 < siblings.count ? siblings[i + 1] : nil].compactMap { $0 }
                    inline = neighbours.contains(where: isText) && neighbours.allSatisfy(Self.isInline)
                }
            }
        }
        inlineGroupMemo[key] = inline
        return inline
    }

    private static func isPlainGroup(_ e: AXUIElement) -> Bool { AX.role(e) == kAXGroupRole && AX.subrole(e) == nil }

    /// Text, links and style groups only, or plain groups of those (a few levels).
    private static func holdsOnlyInline(_ e: AXUIElement, depth: Int = 0) -> Bool {
        let kids = AX.children(e)
        return !kids.isEmpty && depth < 3 && kids.allSatisfy { isInline($0) || (isPlainGroup($0) && holdsOnlyInline($0, depth: depth + 1)) }
    }

    /// A container's children, listed once per document (an article can have hundreds).
    private func children(of e: AXUIElement) -> [AXUIElement] {
        let key = AXKey(element: e)
        if let known = childrenMemo[key] { return known }
        let kids = AX.children(e)
        childrenMemo[key] = kids
        return kids
    }

    func block(containing e: AXUIElement) -> AXUIElement? {
        var cur: AXUIElement? = e
        for _ in 0..<8 {
            guard let c = cur else { return nil }
            if !flows(c) { return c }
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
    private struct Layout { let range: AnyObject; let anchor: AnyObject; let anchorRect: CGRect; let lines: [CGRect]; let words: [CGRect?] }
    private var layouts: [Layout] = []
    /// How far the cached layout of the sentence measured last has moved (#20).
    private var lastShift: (range: AnyObject, dx: CGFloat, dy: CGFloat)?

    /// The words' boxes from the layout `lines(of:)` measured, moved as far
    /// as its lines have moved since.
    func words(of sentence: Sentence) -> [CGRect?] {
        if layouts.first(where: { $0.range === sentence.range }) == nil { _ = lines(of: sentence) }
        guard let layout = layouts.first(where: { $0.range === sentence.range }) else { return [] }
        let shift = lastShift.flatMap { $0.range === sentence.range ? ($0.dx, $0.dy) : nil } ?? (0, 0)
        return layout.words.map { $0?.offsetBy(dx: shift.0, dy: shift.1) }
    }

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
        if let shown = sentence.shows { return AX.frame(shown).flatMap(onScreen).map { [$0] } ?? [] }
        if let cached = layouts.first(where: { $0.range === sentence.range }) {
            if let now = rect(cached.anchor), abs(now.width - cached.anchorRect.width) < 1, abs(now.height - cached.anchorRect.height) < 1 {
                let dx = now.minX - cached.anchorRect.minX, dy = now.minY - cached.anchorRect.minY
                lastShift = (sentence.range, dx, dy)
                return plausible(cached.lines.map { $0.offsetBy(dx: dx, dy: dy) })
            }
            layouts.removeAll { $0.range === sentence.range } // reflowed: measure again
        }
        probeTextGeometry(near: sentence.range)
        if noTextGeometry { return elementFrames(of: sentence.range) }
        let words = wordBoxes(in: sentence.range)
        // Words that start on a leaf boundary all get the same enclosing
        // block's box from Chromium; in link-dense text that's most of them,
        // and the median "line" became the block. No two real words share a box.
        let shared = Dictionary(grouping: words, by: { "\($0.rect)" }).filter { $0.value.count > 1 }
        let own = words.filter { shared["\($0.rect)"] == nil }
        let measured = own.isEmpty ? words : own
        guard let lineHeight = measured.map(\.rect.height).sorted().dropFirst(measured.count / 2).first else {
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
        let wordRects = WordBoxes.assign(display: sentence.words, pieces: good.filter { $0.rect.width >= 3 }.map { (string($0.range), $0.rect) })
        layouts.append(Layout(range: sentence.range, anchor: first.range, anchorRect: first.rect, lines: lines, words: wordRects))
        lastShift = (sentence.range, 0, 0)
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
    ///
    /// Chromium clips element frames to the scroll container, so a block scrolled
    /// out of view comes back as a 0–1 px sliver on the edge it left by. It's
    /// reported as a line just past that edge: off screen, which is what the
    /// reading needs to know to hide the highlight, stop following, or scroll.
    /// A block cut by an edge is clipped to look whole, so one touching an edge
    /// is reported as reaching past it, and gets scrolled into view.
    private func elementFrames(of range: AnyObject) -> [CGRect] {
        let begin = start(of: range)
        let firstWord = p("AXNextWordEndTextMarkerForTextMarker", begin) ?? begin
        var frames: [CGRect] = []
        for m in [firstWord, end(of: range)] {
            guard let leaf = leaf(endingAt: m) else { continue }
            guard let f = (unit(of: leaf).flatMap(frame(of:)) ?? AX.frame(leaf)).flatMap(onScreen) else { continue }
            if !frames.contains(f) { frames.append(f) }
        }
        return frames
    }

    /// An element frame as the highlight takes it. Chromium clips frames to the
    /// scroll container: one scrolled away is a sliver on the edge it left by,
    /// reported just past that edge; one touching an edge, as reaching past it.
    private func onScreen(_ frame: CGRect) -> CGRect? {
        var f = frame
        guard f.width >= 4, let visible = visibleRect() else { return nil }
        if f.height < 4 {
            let above = abs(f.minY - visible.minY) <= abs(f.maxY - visible.maxY)
            f = CGRect(x: f.minX, y: above ? visible.minY - 21 : visible.maxY + 1, width: f.width, height: 20)
        } else {
            if abs(f.minY - visible.minY) < 1 { f = CGRect(x: f.minX, y: f.minY - 2, width: f.width, height: f.height + 2) }
            if abs(f.maxY - visible.maxY) < 1 { f.size.height += 2 }
        }
        return f
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

/// A character range in a native text view, as of one reading of its text
/// (`version`). Positions are empty ranges. If the text is edited while we
/// read, `NativeDocument` carries older ranges forward to the current text.
final class NativeRange: NSObject {
    let range: NSRange
    let version: Int
    init(_ range: NSRange, version: Int) {
        self.range = range
        self.version = version
    }
}

final class NativeDocument: ReadableDocument {
    let element: AXUIElement
    private var text: NSString
    private var sentences: [NSRange]
    /// One edit per re-read of the text: `edits[v]` turns version v into v + 1.
    private var edits: [(start: Int, oldEnd: Int, delta: Int)] = []
    private var version: Int { edits.count }

    init?(element: AXUIElement) {
        guard let value = AX.attr(element, kAXValueAttribute) as? String, value.count > 1 else { return nil }
        self.element = element
        self.text = value as NSString
        sentences = Self.sentences(in: value)
    }

    private static func sentences(in value: String) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = value
        return tokenizer.tokens(for: value.startIndex..<value.endIndex).map { NSRange($0, in: value) }
    }

    /// Indices are taken from a snapshot of the text, so re-read it if its
    /// length changed (the user typed, or the app synced). One cheap call.
    private func refreshIfEdited() {
        guard let count = (AX.attr(element, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue, count != text.length,
              let value = AX.attr(element, kAXValueAttribute) as? String else { return }
        let new = value as NSString
        var prefix = 0
        let shorter = min(text.length, new.length)
        while prefix < shorter, text.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, text.character(at: text.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        edits.append((prefix, text.length - suffix, new.length - text.length))
        text = new
        sentences = Self.sentences(in: value)
    }

    /// `r` in the current text: shifted past edits before it, shrunk to what's left of it if it was edited.
    private func current(_ r: NativeRange) -> NSRange {
        var start = r.range.location, end = NSMaxRange(r.range)
        for e in edits[r.version...] {
            // Text typed exactly at a range's start goes before it; at its end, after it.
            start = start >= e.oldEnd ? start + e.delta : min(start, e.start)
            end = end <= e.start ? end : max(end, e.oldEnd) + e.delta
        }
        start = min(start, text.length)
        return NSRange(location: start, length: max(0, min(end, text.length) - start))
    }

    private func range(_ position: AnyObject) -> NSRange { current(position as! NativeRange) }
    private func handle(_ r: NSRange) -> NativeRange { NativeRange(r, version: version) }
    private func position(_ i: Int) -> NativeRange { handle(NSRange(location: i, length: 0)) }

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
        refreshIfEdited()
        guard let i = index(at: point), i < text.length else { return nil }
        let para = text.paragraphRange(for: NSRange(location: i, length: 0))
        guard SpeechText.clean(text.substring(with: para)) != nil, let b = bounds(para) else { return nil }
        return (position(para.location), b)
    }

    func documentStart() -> AnyObject? { position(0) }

    func firstVisible() -> AnyObject? {
        refreshIfEdited()
        guard let v = AX.attr(element, kAXVisibleCharacterRangeAttribute) else { return position(0) }
        var r = CFRange()
        AXValueGetValue(v as! AXValue, .cfRange, &r)
        let s = sentences.first { NSMaxRange($0) > r.location }
        return position(s?.location ?? r.location)
    }

    func sentence(from position: AnyObject, in scope: ReadingScope?) -> Sentence? {
        refreshIfEdited()
        let start = range(position).location
        guard var i = sentences.firstIndex(where: { NSMaxRange($0) > start }) else { return nil }
        while i < sentences.count {
            var r = sentences[i]
            if r.location < start { r = NSRange(location: start, length: NSMaxRange(r) - start) }
            let next: AnyObject? = i + 1 < sentences.count ? self.position(sentences[i + 1].location) : nil
            if let t = SpeechText.clean(text.substring(with: r)) {
                return Sentence(text: t, range: handle(r), next: next)
            }
            i += 1
        }
        return nil
    }

    /// One box per line, from the text view's own line ranges.
    func lines(of sentence: Sentence) -> [CGRect] {
        refreshIfEdited()
        let r = range(sentence.range)
        guard r.length > 0, let firstLine = line(at: r.location), let lastLine = line(at: NSMaxRange(r) - 1), lastLine >= firstLine,
              lastLine - firstLine < 200 else { return bounds(r).map { [$0] } ?? [] }
        return (firstLine...lastLine).compactMap { l in
            guard let lr = range(ofLine: l) else { return nil }
            let part = NSIntersectionRange(lr, r)
            return part.length > 0 ? bounds(part) : nil
        }
    }

    /// One box per whitespace-separated word of the sentence's on-screen text.
    func words(of sentence: Sentence) -> [CGRect?] {
        let r = range(sentence.range)
        guard r.length > 0 else { return [] }
        let raw = text.substring(with: r) as NSString
        var pieces: [(text: String, rect: CGRect)] = []
        let separators = CharacterSet.whitespacesAndNewlines
        var i = 0
        while i < raw.length, pieces.count < 300 {
            while i < raw.length, let u = Unicode.Scalar(raw.character(at: i)), separators.contains(u) { i += 1 }
            let start = i
            while i < raw.length, !(Unicode.Scalar(raw.character(at: i)).map(separators.contains) ?? false) { i += 1 }
            guard i > start else { continue }
            let word = NSRange(location: r.location + start, length: i - start)
            if let b = bounds(word) { pieces.append((text.substring(with: word), b)) }
        }
        return WordBoxes.assign(display: sentence.words, pieces: pieces)
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

    /// Setting the visible range is NSTextView's "scroll this range to
    /// visible": it leaves the selection, the caret and focus alone, unlike
    /// moving the caret (#13). Scrolling down, AppKit puts the range near the
    /// middle, so what was just read stays on screen above it. A range taller
    /// than the view lands with its start below the view, so for a sentence
    /// that tall only its first line is asked for.
    func scrollIntoView(_ sentence: Sentence) {
        var r = range(sentence.range)
        guard r.length > 0 else { return }
        if let view = visibleRect(), let box = bounds(r), box.height > view.height * 0.8,
           let first = line(at: r.location), let lr = range(ofLine: first) {
            r = NSIntersectionRange(lr, r)
        }
        AXUIElementSetAttributeValue(element, kAXVisibleCharacterRangeAttribute as CFString, AX.rangeValue(r))
    }
}

// MARK: - Finding the document

enum DocumentFinder {
    private static let textRoles: Set<String> = [kAXTextAreaRole, kAXTextFieldRole]

    /// The document under a screen point, if any.
    static func document(at point: CGPoint) -> ReadableDocument? {
        guard let hit = AX.element(at: point) else { return nil }
        AX.enableTree(for: AX.pid(hit))
        if let doc = document(climbingFrom: hit) { return doc }
        // A Chromium browser may have no page tree right now: wake it, then hit-test again.
        guard let window = AX.element(AX.attr(hit, kAXWindowAttribute)), AX.wakeWebArea(in: window) != nil,
              let again = AX.element(at: point) else { return nil }
        return document(climbingFrom: again)
    }

    private static func document(climbingFrom hit: AXUIElement) -> ReadableDocument? {
        var e: AXUIElement? = hit
        for _ in 0..<40 {
            guard let cur = e, let role = AX.role(cur) else { break }
            if role == "AXWebArea" { return webDocument(cur, below: false) }
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
        guard let e = found ?? AX.wakeWebArea(in: window) else { return nil }
        // The search finds the outermost web area; Chromium's PDF viewer nests the document two areas in.
        return AX.role(e) == "AXWebArea" ? webDocument(e, below: true) : NativeDocument(element: e)
    }

    /// A web area's document: a page, or the PDF in Chromium's viewer. The viewer's own controls (its toolbar,
    /// a password prompt) are never read.
    private static func webDocument(_ area: AXUIElement, below: Bool) -> ReadableDocument? {
        switch PDFiumDocument.find(near: area, below: below) {
        case .page: WebDocument(area: area)
        case .nothing: nil
        case .document(let pdf): pdf
        }
    }
}
