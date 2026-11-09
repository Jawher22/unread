import AppKit
import ApplicationServices

/// Chromium's PDF viewer (Chrome, Aside, Electron; #85). PDFium shows the PDF in the innermost of three nested
/// web areas (the extension page, the viewer's toolbar and thumbnails, the document), one region per page and one
/// group per PDF paragraph. What each block is and how sentences run across them is `PDFLayout`'s, from the
/// blocks' text, boxes and fonts; this side finds the blocks, and turns the layout's readings into text-marker
/// ranges anchored to the blocks' text leaves, measured by a `WebDocument` on the same area.
final class PDFiumDocument: ReadableDocument {
    typealias BlockID = PDFLayout.BlockID

    let element: AXUIElement
    private let web: WebDocument
    private lazy var layout = PDFLayout(pageCount: { [unowned self] in pageCount() }, page: { [unowned self] in pageBlocks($0) },
                                        debug: ProcessInfo.processInfo.environment["UNREAD_DEBUG_WALK"] != nil)

    /// The viewer's extension page (the same id in Chrome, Electron and other Chromium builds).
    private static let viewer = "chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai/"

    private init(area: AXUIElement) {
        element = area
        web = WebDocument(area: area)
    }

    /// What a web area is to the PDF viewer.
    enum Found {
        /// Not the viewer: a web page.
        case page
        /// The viewer with no PDF in it to read: still loading, a password prompt, a PDF that failed.
        case nothing
        case document(PDFiumDocument)
    }

    /// The last documents opened, so a hold that moves the pointer keeps the pages it already read (AXWorker only).
    private static var recent: [PDFiumDocument] = []
    /// Viewers lately found with no document in them: looked into again only after a while, not at each lookup.
    private static var empty: [(viewer: AXUIElement, at: Date)] = []

    /// Chromium's PDF viewer, if `area` is one of its web areas, and the PDF's own area in it, which holds the
    /// text. Pointing lands in that one (`below: false`); a search from the window finds the outermost one, the
    /// page's, with the viewer two groups below it. A page's iframe isn't the viewer. Never waits: the
    /// document's area comes up after the viewer's, and a lookup then finds nothing until it does.
    static func find(near area: AXUIElement, below: Bool) -> Found {
        guard let viewerArea = viewerArea(near: area, below: below) else { return .page }
        let doc: AXUIElement
        if let known = viewerArea.document {
            doc = known
        } else {
            empty.removeAll { Date().timeIntervalSince($0.at) > 2 }
            if empty.contains(where: { CFEqual($0.viewer, viewerArea.viewer) }) { return .nothing }
            guard let inner = AX.find(in: viewerArea.viewer, maxNodes: 600, { e, role in role == "AXWebArea" && !CFEqual(e, viewerArea.viewer) }) else {
                empty.append((viewerArea.viewer, Date()))
                return .nothing
            }
            doc = inner
        }
        if let known = recent.first(where: { CFEqual($0.element, doc) }) { return .document(known) }
        let made = PDFiumDocument(area: doc)
        recent = [made] + recent.prefix(1)
        return .document(made)
    }

    private static func url(_ e: AXUIElement) -> String? {
        let v = AX.attr(e, "AXURL")
        return (v as? URL)?.absoluteString ?? (v as? String)
    }

    /// The viewer's area for `area`, and the document's area when `area` is that one.
    private static func viewerArea(near area: AXUIElement, below: Bool) -> (viewer: AXUIElement, document: AXUIElement?)? {
        let address = url(area)
        if address?.hasPrefix(viewer) == true { return (area, nil) }
        if address == nil || address == "" {
            // The document's own area has no URL; the viewer's area is the next one up.
            var cur = AX.parent(area)
            for _ in 0..<16 {
                guard let c = cur else { break }
                if AX.role(c) == "AXWebArea" { return url(c)?.hasPrefix(viewer) == true ? (c, area) : nil }
                if AX.role(c) == kAXWindowRole { break }
                cur = AX.parent(c)
            }
            return nil
        }
        guard below, let inner = AX.find(in: area, maxNodes: 8, { e, role in role == "AXWebArea" && !CFEqual(e, area) }),
              url(inner)?.hasPrefix(viewer) == true else { return nil }
        return (inner, nil)
    }

    // MARK: Pages and blocks

    private struct Leaf { let element: AXUIElement; let start: Int; let length: Int }
    /// A block as Accessibility has it: its group and text leaves.
    private struct AXBlock { let element: AXUIElement; let leaves: [Leaf]; let raw: NSString }

    private var regionList: [AXUIElement] = []
    private var regionParent: AXUIElement?
    private var pageTotal: Int?
    private var axPages: [Int: [AXBlock]] = [:]
    /// When the last page arrived; how many there were when a wait for the next one last gave up, and how many
    /// waits have.
    private var grewAt = Date()
    private var stalledAt: Int?
    private var stalls = 0
    /// In `paragraph(at:)` or `firstVisible()`: pages aren't waited for.
    private var pointing = false

    /// The pages' regions, as far as PDFium has built them: it adds one every ~150–300 ms after the PDF opens.
    private func regions() -> [AXUIElement] {
        if regionParent == nil {
            var queue = [element], seen = 0
            while !queue.isEmpty, seen < 400 {
                let e = queue.removeFirst()
                seen += 1
                if AX.subrole(e) == "AXLandmarkRegion" { regionParent = AX.parent(e); break }
                queue.append(contentsOf: AX.children(e))
            }
        }
        guard let parent = regionParent else { return [] }
        if pageTotal == nil || regionList.count < pageTotal! {
            let now = AX.children(parent).filter { AX.subrole($0) == "AXLandmarkRegion" }
            if now.count > regionList.count { grewAt = Date() }
            regionList = now
        }
        return regionList
    }

    /// How many pages the PDF has, from the document's own description ("PDF document containing 15 pages"),
    /// there from the start. Until it's found, the pages built so far.
    private func pageCount() -> Int {
        if let known = pageTotal { return known }
        let built = regions().count
        if let parent = regionParent, let d = AX.attr(parent, kAXDescriptionAttribute) as? String,
           let n = d.split(whereSeparator: { !$0.isNumber }).compactMap({ Int($0) }).first, n > 0 {
            pageTotal = n
            return n
        }
        return built
    }

    private func region(_ page: Int) -> AXUIElement? {
        var all = regions()
        // A page the PDF has that PDFium hasn't built yet, met reading on: wait while pages keep coming (one every
        // ~150–300 ms), at most 3 s past the last one; not again until another arrives, and never after two waits
        // gave up. Not while pointing (the hold asks 30 times a second): the layout keeps nothing it worked out
        // without the page, and asks again.
        while page >= all.count, page < pageCount(), !pointing, stalledAt != all.count, stalls < 2 {
            if Date().timeIntervalSince(grewAt) > 3 { stalledAt = all.count; stalls += 1; break }
            Thread.sleep(forTimeInterval: 0.05)
            all = regions()
        }
        return page >= 0 && page < all.count ? all[page] : nil
    }

    /// A page's blocks for the layout: text, box and font, from Accessibility.
    private func pageBlocks(_ page: Int) -> [PDFBlock]? {
        guard let region = region(page) else { return nil }
        var made: [AXBlock] = [], out: [PDFBlock] = []
        for e in AX.children(region) {
            var leaves: [Leaf] = []
            var text = ""
            func visit(_ x: AXUIElement, depth: Int) {
                guard depth < 8 else { return }
                if AX.role(x) == kAXStaticTextRole {
                    let v = (AX.attr(x, kAXValueAttribute) as? String) ?? ""
                    leaves.append(Leaf(element: x, start: (text as NSString).length, length: (v as NSString).length))
                    text += v
                    return
                }
                for c in AX.children(x) { visit(c, depth: depth + 1) }
            }
            visit(e, depth: 0)
            var b = PDFBlock(raw: text, headingRole: AX.role(e) == kAXHeadingRole)
            if let first = leaves.first, let last = leaves.last {
                b.bounds = [first, last].compactMap(textBounds).reduce(nil) { acc, r in acc.map { $0.union(r) } ?? r }
                b.fontSize = fontSize(from: first, to: last)
            }
            made.append(AXBlock(element: e, leaves: leaves, raw: text as NSString))
            out.append(b)
        }
        axPages[page] = made
        return out
    }

    private func axBlock(_ id: BlockID) -> AXBlock? {
        guard let page = axPages[id.page], id.index >= 0, id.index < page.count else { return nil }
        return page[id.index]
    }

    private func textBounds(_ leaf: Leaf) -> CGRect? {
        guard let r = AX.param(element, "AXTextMarkerRangeForUIElement", leaf.element),
              let v = AX.param(element, "AXBoundsForTextMarkerRange", r), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
        return rect
    }

    /// The size most of a block's visible characters are set in (`AXFont`'s `AXFontSize`).
    private func fontSize(from first: Leaf, to last: Leaf) -> CGFloat? {
        guard let a = p("AXTextMarkerRangeForUIElement", first.element), let z = p("AXTextMarkerRangeForUIElement", last.element),
              let r = range(start(of: a), end(of: z)), let text = p("AXAttributedStringForTextMarkerRange", r) as? NSAttributedString else { return nil }
        var weight: [CGFloat: Int] = [:]
        let s = text.string as NSString
        text.enumerateAttribute(NSAttributedString.Key("AXFont"), in: NSRange(location: 0, length: text.length)) { v, run, _ in
            guard let size = ((v as? [String: Any])?["AXFontSize"] as? NSNumber).map({ CGFloat($0.doubleValue) }) else { return }
            weight[size, default: 0] += s.substring(with: run).filter { !$0.isWhitespace }.count
        }
        return weight.max { $0.value < $1.value }?.key
    }

    // MARK: Sentences

    private var sentenceMemo: [String: Sentence] = [:]
    /// A sentence's part in each block it runs across (so the highlight leaves out what lies between), and those blocks.
    private struct Shape { let parts: [Sentence]; let blocks: [AXUIElement] }
    private var shapes: [ObjectIdentifier: Shape] = [:]

    func documentStart() -> AnyObject? { layout.start() }

    func sentence(from position: AnyObject, in scope: ReadingScope?) -> Sentence? {
        guard var pos = position as? PDFPosition else { return nil }
        for _ in 0..<200 {
            if let known = sentenceMemo[pos.key] { return known }
            let (reading, complete) = layout.read(from: pos)
            func remember(_ s: Sentence) -> Sentence {
                if complete { sentenceMemo[pos.key] = s }
                return s
            }
            switch reading {
            case nil: return nil
            case .sentence(let text, let parts, let next):
                if let s = sentence(text: text, parts: parts, next: next) { return remember(s) }
                pos = next
            case .cue(let what, let blocks, let next):
                // A cue that can't be placed is left out; a caption is then read without one.
                if let r = visibleRange(of: blocks) { return remember(Sentence(text: "", range: r, next: next, cue: what)) }
                pos = next
            }
        }
        return nil
    }

    private func sentence(text: String, parts: [(block: BlockID, range: NSRange)], next: PDFPosition) -> Sentence? {
        var pieces: [(range: AnyObject, raw: String, block: AXUIElement)] = []
        for part in parts {
            guard let b = axBlock(part.block), let r = range(in: b, from: part.range.location, to: NSMaxRange(part.range)) else { continue }
            pieces.append((r, NSMaxRange(part.range) <= b.raw.length ? b.raw.substring(with: part.range) : "", b.element))
        }
        guard let first = pieces.first, let last = pieces.last, let whole = range(start(of: first.range), end(of: last.range)) else { return nil }
        let s = Sentence(text: text, range: whole, next: next)
        let split = pieces.count == 1 ? [s] : pieces.map { p in
            Sentence(text: SpeechText.clean((p.raw as NSString).replacingOccurrences(of: "\u{02}", with: "")) ?? "", range: p.range, next: nil)
        }
        shapes[ObjectIdentifier(whole)] = Shape(parts: split, blocks: pieces.map(\.block))
        return s
    }

    /// From the first visible character of the first block to the last of the last.
    private func visibleRange(of run: [BlockID]) -> AnyObject? {
        func bounds(_ b: AXBlock) -> (Int, Int)? {
            let raw = b.raw
            let lo = raw.rangeOfCharacter(from: WebDocument.blank.inverted).location
            guard lo != NSNotFound else { return nil }
            return (lo, NSMaxRange(raw.rangeOfCharacter(from: WebDocument.blank.inverted, options: .backwards)))
        }
        let blocks = run.compactMap(axBlock).compactMap { b in bounds(b).map { (b, $0) } }
        guard let first = blocks.first, let last = blocks.last,
              let a = range(in: first.0, from: first.1.0, to: first.1.1),
              let z = range(in: last.0, from: last.1.0, to: last.1.1) else { return nil }
        return range(start(of: a), end(of: z))
    }

    // MARK: Markers

    private func p(_ name: String, _ arg: AnyObject) -> AnyObject? { AX.param(element, name, arg) }
    private func string(_ range: AnyObject) -> String { p("AXStringForTextMarkerRange", range) as? String ?? "" }
    private func start(of range: AnyObject) -> AnyObject { AXTextMarkerRangeCopyStartMarker(range as! AXTextMarkerRange) }
    private func end(of range: AnyObject) -> AnyObject { AXTextMarkerRangeCopyEndMarker(range as! AXTextMarkerRange) }
    private func range(_ a: AnyObject, _ b: AnyObject) -> AnyObject? { p("AXTextMarkerRangeForUnorderedTextMarkers", [a, b] as CFArray) }

    /// The markers around a block's characters `lo..<hi`, each anchored to the text leaf it falls in.
    private func range(in b: AXBlock, from lo: Int, to hi: Int) -> AnyObject? {
        guard let a = marker(in: b, at: lo, end: false), let z = marker(in: b, at: hi, end: true) else { return nil }
        return range(a, z)
    }

    /// Markers already found in each leaf, so a paragraph is stepped through once, not once per sentence.
    private var known: [AXKey: [(offset: Int, marker: AnyObject)]] = [:]

    private func marker(in b: AXBlock, at offset: Int, end: Bool) -> AnyObject? {
        guard let leaf = b.leaves.first(where: { end ? $0.start < offset && offset <= $0.start + $0.length : $0.start <= offset && offset < $0.start + $0.length })
                ?? b.leaves.last, let whole = p("AXTextMarkerRangeForUIElement", leaf.element) else { return nil }
        let target = min(max(offset - leaf.start, 0), leaf.length)
        if target == 0 { return start(of: whole) }
        if target == leaf.length { return self.end(of: whole) }
        let key = AXKey(element: leaf.element)
        var points = known[key] ?? [(0, start(of: whole))]
        let from = points.last(where: { $0.offset <= target }) ?? points[0]
        func covered(_ m: AnyObject) -> Int { from.offset + (range(from.marker, m).map { (string($0) as NSString).length } ?? 0) }
        var m = from.marker, at = from.offset
        for name in ["AXNextWordEndTextMarkerForTextMarker", "AXNextTextMarkerForTextMarker"] {
            for _ in 0..<400 where at < target {
                guard let n = p(name, m), !CFEqual(n, m) else { break }
                let c = covered(n)
                if c > target || c <= at { break }
                m = n; at = c
            }
        }
        points.append((at, m))
        points.sort { $0.offset < $1.offset }
        known[key] = points
        return m
    }

    // MARK: Geometry

    func lines(of sentence: Sentence) -> [CGRect] {
        guard let shape = shapes[ObjectIdentifier(sentence.range)] else { return web.lines(of: sentence) }
        return zip(shape.parts, shape.blocks).flatMap { part, block in inside(block, web.lines(of: part)) }
    }

    func words(of sentence: Sentence) -> [CGRect?] {
        guard let shape = shapes[ObjectIdentifier(sentence.range)] else { return web.words(of: sentence) }
        if shape.parts.count == 1 { return inside(shape.blocks[0], web.words(of: sentence)) }
        var pieces: [(text: String, rect: CGRect)] = []
        for (part, block) in zip(shape.parts, shape.blocks) {
            for (w, box) in zip(part.words, inside(block, web.words(of: part))) { if let box { pieces.append((String(w), box)) } }
        }
        return WordBoxes.assign(display: sentence.words, pieces: pieces)
    }

    /// Chromium measures the characters of a run that starts with a line end ("\r\nAbstract") hundreds of points
    /// to the left of where they're drawn, outside their block; the block's frame is right sideways. Boxes that
    /// fall left of it are moved back to its left edge. Not when the frame's left edge is the scroller's (a page
    /// zoomed in and scrolled sideways): the frame is clipped there, and text left of it is only out of view.
    private func inside(_ block: AXUIElement, _ boxes: [CGRect]) -> [CGRect] { inside(block, boxes.map(Optional.some)).compactMap { $0 } }

    private func inside(_ block: AXUIElement, _ boxes: [CGRect?]) -> [CGRect?] {
        guard let frame = AX.frame(block), frame.width > 0 else { return boxes }
        if let visible = visibleRect(), frame.minX <= visible.minX + 1 { return boxes }
        let misses = { (r: CGRect) in r.maxX <= frame.minX }
        guard let left = boxes.compactMap({ $0 }).filter(misses).map(\.minX).min() else { return boxes }
        return boxes.map { b in b.map { misses($0) ? $0.offsetBy(dx: frame.minX - left, dy: 0) : $0 } }
    }

    func linesDiagnosis(of sentence: Sentence) -> String {
        web.linesDiagnosis(of: shapes[ObjectIdentifier(sentence.range)]?.parts.first ?? sentence)
    }

    func visibleRect() -> CGRect? { web.visibleRect() }

    func scrollIntoView(_ sentence: Sentence) { web.scrollIntoView(shapes[ObjectIdentifier(sentence.range)]?.parts.first ?? sentence) }

    /// Blocks on screen, in reading order (element frames are right for these).
    private func visibleBlocks() -> [(id: BlockID, kind: PDFLayout.Kind, frame: CGRect)] {
        guard let visible = visibleRect() else { return [] }
        var out: [(BlockID, PDFLayout.Kind, CGRect)] = []
        for (page, region) in regions().enumerated() {
            guard let f = AX.frame(region), f.height >= 4, f.intersects(visible) else { continue }
            let kinds = layout.kinds(onPage: page)
            for (i, b) in (axPages[page] ?? []).enumerated() where i < kinds.count {
                if let bf = AX.frame(b.element), bf.height >= 4, bf.intersects(visible) { out.append((BlockID(page: page, index: i), kinds[i], bf)) }
            }
        }
        return out
    }

    /// The hold asks 30 times a second; while the pointer stays in the last block, that's the answer (its frame is
    /// asked again: the document outlives a hold, and the page may have scrolled since).
    private var lastParagraph: (element: AXUIElement, start: AnyObject)?

    func paragraph(at point: CGPoint) -> (start: AnyObject, bounds: CGRect)? {
        pointing = true
        defer { pointing = false }
        if let last = lastParagraph, let frame = AX.frame(last.element), frame.contains(point) { return (last.start, frame) }
        guard let hit = visibleBlocks().first(where: { $0.frame.contains(point) && $0.kind != .furniture }), let b = axBlock(hit.id) else {
            lastParagraph = nil
            return nil
        }
        let start = PDFPosition(hit.id, walked: false)
        lastParagraph = (b.element, start)
        return (start, hit.frame)
    }

    func firstVisible() -> AnyObject? {
        pointing = true
        defer { pointing = false }
        return visibleBlocks().first { ![.furniture, .footnote].contains($0.kind) }.map { PDFPosition($0.id, walked: false) }
    }
}
