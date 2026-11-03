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
    func sentence(from position: AnyObject) -> Sentence?
    func bounds(of sentence: Sentence) -> CGRect?
    func visibleRect() -> CGRect?
    func scrollIntoView(_ sentence: Sentence)
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

    init(area: AXUIElement) { element = area }

    private func p(_ name: String, _ arg: AnyObject) -> AnyObject? { AX.param(element, name, arg) }
    private func string(_ range: AnyObject) -> String { p("AXStringForTextMarkerRange", range) as? String ?? "" }
    private func start(of range: AnyObject) -> AnyObject { AXTextMarkerRangeCopyStartMarker(range as! AXTextMarkerRange) }
    private func end(of range: AnyObject) -> AnyObject { AXTextMarkerRangeCopyEndMarker(range as! AXTextMarkerRange) }
    private func range(_ a: AnyObject, _ b: AnyObject) -> AnyObject? { p("AXTextMarkerRangeForUnorderedTextMarkers", [a, b] as CFArray) }

    /// A marker at a screen point: WebKit answers directly; for Chromium,
    /// hit-test the element and take the start of its text.
    private func marker(at point: CGPoint) -> AnyObject? {
        if let m = p("AXTextMarkerForPosition", AX.pointValue(point)) { return m }
        guard let hit = AX.element(at: point), let r = p("AXTextMarkerRangeForUIElement", hit) else { return nil }
        return start(of: r)
    }

    func paragraph(at point: CGPoint) -> (start: AnyObject, bounds: CGRect)? {
        guard let m = marker(at: point),
              let para = p("AXParagraphTextMarkerRangeForTextMarker", m),
              SpeechText.clean(string(para)) != nil,
              let bounds = AX.rect(p("AXBoundsForTextMarkerRange", para))
        else { return nil }
        return (start(of: para), bounds)
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
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = chunk
            let first = tokenizer.tokens(for: chunk.startIndex..<chunk.endIndex).first.map { NSRange($0, in: chunk) }
                ?? NSRange(location: 0, length: chunkNS.length)
            // Chromium joins separate blocks with no separator ("TitleBody…"),
            // so a block boundary always ends the sentence.
            let length = min(NSMaxRange(first), blockBreaks.first { $0 > first.location } ?? .max)
            let sentenceEnd = length >= chunkNS.length ? chunkEnd : walk(from: cursor, utf16Length: length, limit: chunkEnd)
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

    /// Same block element? Wrapped lines share a text node; inline spans
    /// (bold, links, `code`) share the paragraph one or two levels up.
    private func sameBlock(_ a: AnyObject, _ b: AnyObject) -> Bool {
        guard let ea = AX.element(p("AXUIElementForTextMarker", a)),
              let eb = AX.element(p("AXUIElementForTextMarker", b)) else { return false }
        if CFEqual(ea, eb) { return true }
        let ancestorsA = ancestors(ea, 3), ancestorsB = ancestors(eb, 3)
        // Nearest common ancestor within two hops of both = same paragraph.
        for (i, x) in ancestorsA.enumerated() {
            if let j = ancestorsB.firstIndex(where: { CFEqual($0, x) }) {
                return i <= 2 && j <= 2 && AX.role(x) != "AXWebArea" && AX.role(x) != kAXListRole
            }
        }
        return false
    }

    private func ancestors(_ e: AXUIElement, _ n: Int) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var cur: AXUIElement? = AX.parent(e)
        while let c = cur, out.count < n { out.append(c); cur = AX.parent(c) }
        return out
    }

    /// Step word by word until the text from `start` covers `utf16Length`.
    private func walk(from start: AnyObject, utf16Length: Int, limit: AnyObject) -> AnyObject {
        var m = start
        for _ in 0..<400 {
            guard let next = p("AXNextWordEndTextMarkerForTextMarker", m), !CFEqual(next, m) else { return limit }
            m = next
            if let r = range(start, m), (string(r) as NSString).length >= utf16Length - 1 { return m }
        }
        return limit
    }

    func bounds(of sentence: Sentence) -> CGRect? {
        guard let r = AX.rect(p("AXBoundsForTextMarkerRange", sentence.range)) else { return nil }
        // Chromium sometimes answers with the whole viewport; that's not a sentence.
        if let v = visibleRect(), r.width >= v.width * 0.95, r.height >= v.height * 0.9 { return nil }
        return r
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

    func bounds(of sentence: Sentence) -> CGRect? { bounds((sentence.range as! NSValue).rangeValue) }

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
        AX.enableTree(for: app.processIdentifier)
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = AX.element(AX.attr(axApp, kAXFocusedWindowAttribute))
                ?? AX.element(AX.attr(axApp, kAXMainWindowAttribute)) else { return nil }
        let found = AX.find(in: window) { e, role in
            role == "AXWebArea" || (textRoles.contains(role) && ((AX.attr(e, kAXValueAttribute) as? String)?.count ?? 0) > 200)
        }
        guard let e = found else { return nil }
        return AX.role(e) == "AXWebArea" ? WebDocument(area: e) : NativeDocument(element: e)
    }
}
