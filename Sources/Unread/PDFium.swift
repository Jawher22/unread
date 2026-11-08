import AppKit
import ApplicationServices
import NaturalLanguage

/// A place in a Chromium PDF: a UTF-16 offset into the run of paragraphs (a flow) that starts at `block`.
/// `walked`: reached by reading on, not by pointing, so what isn't read there is passed over.
/// `cued`: a caption whose figure cue has been given.
final class PDFPosition: NSObject {
    let block: PDFiumDocument.BlockID
    let offset: Int
    let walked: Bool
    let cued: Bool
    init(_ block: PDFiumDocument.BlockID, offset: Int = 0, walked: Bool, cued: Bool = false) {
        self.block = block
        self.offset = offset
        self.walked = walked
        self.cued = cued
    }
    var key: String { "\(block.page).\(block.index)+\(offset)\(walked ? "w" : "")\(cued ? "c" : "")" }
    // By value, like a text marker: a hold's speculation is matched to its release with CFEqual.
    override func isEqual(_ object: Any?) -> Bool { (object as? PDFPosition)?.key == key }
    override var hash: Int { key.hashValue }
}

/// Chromium's PDF viewer (Chrome, Aside, Electron; #85). PDFium shows the PDF in the innermost of three nested
/// web areas (the extension page, the viewer's toolbar and thumbnails, the document), one region per page and one
/// group per PDF paragraph. The text is the PDF's, not a web page's: line ends are "\r\n", a hyphen at a line end
/// is U+0002, a paragraph runs on across a column or a page with the footnotes, running header and page number in
/// between, headings are guessed (a paragraph can be an `AXHeading`, a section title a plain group), and a figure's
/// labels are short runs of text. So sentences are cut from the paragraphs, not from the text-marker stream: each
/// block is classified, a paragraph is joined to its continuation, and the joined text is tokenized. Ranges are
/// still text markers, anchored to the blocks' text leaves, and measured by a `WebDocument` on the same area.
final class PDFiumDocument: ReadableDocument {
    struct BlockID: Hashable { let page: Int; let index: Int }

    let element: AXUIElement
    private let web: WebDocument
    private let debugWalk = ProcessInfo.processInfo.environment["UNREAD_DEBUG_WALK"] != nil

    /// The viewer's extension page (the same id in Chrome, Electron and other Chromium builds).
    private static let viewer = "chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai/"

    private init(area: AXUIElement) {
        element = area
        web = WebDocument(area: area)
    }

    /// The last documents opened, so a hold that moves the pointer keeps the pages it already read (AXWorker only).
    private static var recent: [PDFiumDocument] = []

    /// Chromium's PDF viewer, if `area` is one of its web areas: the PDF's own area, which holds the text.
    /// Pointing lands in that one (`below: false`); a search from the window finds the outermost one, the page's,
    /// with the viewer two groups below it. A page's iframe isn't the viewer.
    static func open(near area: AXUIElement, below: Bool) -> PDFiumDocument? {
        guard let doc = documentArea(near: area, below: below) else { return nil }
        if let known = recent.first(where: { CFEqual($0.element, doc) }) { return known }
        let made = PDFiumDocument(area: doc)
        recent = [made] + recent.prefix(1)
        return made
    }

    private static func url(_ e: AXUIElement) -> String? {
        let v = AX.attr(e, "AXURL")
        return (v as? URL)?.absoluteString ?? (v as? String)
    }

    private static func documentArea(near area: AXUIElement, below: Bool) -> AXUIElement? {
        // The viewer's own area comes up before the document's: wait for that one a little.
        func nested(in viewerArea: AXUIElement) -> AXUIElement? {
            let deadline = Date().addingTimeInterval(2)
            repeat {
                if let doc = AX.find(in: viewerArea, maxNodes: 600, { e, role in role == "AXWebArea" && !CFEqual(e, viewerArea) }) { return doc }
                Thread.sleep(forTimeInterval: 0.05)
            } while Date() < deadline
            return nil
        }
        let url = url(area)
        if url?.hasPrefix(viewer) == true { return nested(in: area) }
        if url == nil || url == "" {
            // The document's own area has no URL; the viewer's area is the next one up.
            var cur = AX.parent(area)
            for _ in 0..<16 {
                guard let c = cur else { break }
                if AX.role(c) == "AXWebArea" { return Self.url(c)?.hasPrefix(viewer) == true ? area : nil }
                if AX.role(c) == kAXWindowRole { break }
                cur = AX.parent(c)
            }
            return nil
        }
        guard below, let inner = AX.find(in: area, maxNodes: 8, { e, role in role == "AXWebArea" && !CFEqual(e, area) }),
              Self.url(inner)?.hasPrefix(viewer) == true else { return nil }
        return nested(in: inner)
    }

    // MARK: Pages and blocks

    /// What a block is to a listener.
    enum Kind: Equatable {
        case paragraph, heading, other
        /// Starts with "Figure 3:" or "Table 2.": read after a cue for what it captions.
        case caption(String)
        /// Text inside a figure or table ("E[CLS] E1", a table's rows): the cue stands for it.
        case label(String)
        case footnote, furniture
        /// "References": reading on ends here.
        case references
        var skippedInFlow: Bool {
            switch self { case .furniture, .footnote, .label, .caption: true; default: false }
        }
    }

    private struct Leaf { let element: AXUIElement; let start: Int; let length: Int }

    private final class Block {
        let id: BlockID
        let element: AXUIElement
        let headingRole: Bool
        let leaves: [Leaf]
        let raw: NSString
        /// One line, trimmed, U+0002 shown as "-".
        let flat: String
        let lines: Int, words: Int
        /// Holds a sentence of three words or more.
        let reads: Bool
        /// Its text's box, from text markers: unlike element frames, not clipped to the viewer's scroller.
        var bounds: CGRect?
        var kind: Kind = .other
        init(id: BlockID, element: AXUIElement, headingRole: Bool, leaves: [Leaf], raw: NSString) {
            self.id = id
            self.element = element
            self.headingRole = headingRole
            self.leaves = leaves
            self.raw = raw
            let text = (raw as String).replacingOccurrences(of: "\u{02}", with: "-")
            flat = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            words = flat.split(separator: " ").filter { $0.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) }.count
            let unmarked = PDFiumDocument.withoutMarkers(text) // "…a wide margin.12" ends a sentence
            reads = words >= 3 && PDFiumDocument.sentenceEnd.firstMatch(in: unmarked, range: NSRange(location: 0, length: (unmarked as NSString).length)) != nil
        }
    }

    private var regionList: [AXUIElement] = []
    private var regionParent: AXUIElement?
    private var pageTotal: Int?
    private var pages: [Int: [Block]] = [:]
    private var classified: Set<Int> = []
    /// Page 1's blocks before its first paragraph: the title, authors, affiliations, "Abstract".
    private var titleEnd = 0
    /// Words the loaded pages spell whole, for line-end hyphens.
    private var vocabulary: Set<String> = []

    /// The pages' regions, as far as PDFium has built them: it adds one every ~150 ms after the PDF opens.
    private func regions() -> [AXUIElement] {
        if let parent = regionParent {
            if regionList.count < pageCount() || pageCount() == 0 { regionList = AX.children(parent).filter { AX.subrole($0) == "AXLandmarkRegion" } }
            return regionList
        }
        var queue = [element], seen = 0
        while !queue.isEmpty, seen < 400 {
            let e = queue.removeFirst()
            seen += 1
            if AX.subrole(e) == "AXLandmarkRegion" { regionParent = AX.parent(e); break }
            queue.append(contentsOf: AX.children(e))
        }
        if let parent = regionParent { regionList = AX.children(parent).filter { AX.subrole($0) == "AXLandmarkRegion" } }
        return regionList
    }

    /// How many pages the PDF has: the viewer's thumbnails are all there from the start.
    private func pageCount() -> Int {
        if let known = pageTotal { return known }
        var viewerArea = AX.parent(element)
        while let v = viewerArea, AX.role(v) != "AXWebArea" { viewerArea = AX.parent(v) }
        let tabs = viewerArea.flatMap { AX.find(in: $0, maxNodes: 300) { _, role in role == kAXTabGroupRole } }.map(AX.children) ?? []
        pageTotal = tabs.count
        return tabs.count
    }

    private func region(_ page: Int) -> AXUIElement? {
        var all = regions()
        // A page the viewer has but hasn't built yet: wait for it a little.
        let deadline = Date().addingTimeInterval(3)
        while page >= all.count, page < pageCount(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            all = regions()
        }
        return page >= 0 && page < all.count ? all[page] : nil
    }

    private func blocks(_ page: Int) -> [Block] {
        if let known = pages[page] { return known }
        guard let region = region(page) else { return [] }
        var out: [Block] = []
        for (i, e) in AX.children(region).enumerated() {
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
            let b = Block(id: BlockID(page: page, index: i), element: e, headingRole: AX.role(e) == kAXHeadingRole, leaves: leaves, raw: text as NSString)
            if let first = leaves.first, let last = leaves.last {
                b.bounds = [first, last].compactMap(textBounds).reduce(nil) { acc, r in acc.map { $0.union(r) } ?? r }
            }
            out.append(b)
            for w in (text as String).split(whereSeparator: \.isWhitespace) where !w.contains("\u{02}") {
                vocabulary.insert(String(w).lowercased().trimmingCharacters(in: .punctuationCharacters))
            }
        }
        pages[page] = out
        return out
    }

    private func textBounds(_ leaf: Leaf) -> CGRect? {
        guard let r = AX.param(element, "AXTextMarkerRangeForUIElement", leaf.element),
              let v = AX.param(element, "AXBoundsForTextMarkerRange", r), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
        return rect
    }

    private func block(_ id: BlockID) -> Block? {
        let page = classifiedBlocks(id.page)
        return id.index >= 0 && id.index < page.count ? page[id.index] : nil
    }

    private func after(_ id: BlockID) -> BlockID? {
        if id.index + 1 < blocks(id.page).count { return BlockID(page: id.page, index: id.index + 1) }
        var page = id.page + 1
        while page < max(pageCount(), regions().count) {
            if !blocks(page).isEmpty { return BlockID(page: page, index: 0) }
            page += 1
        }
        return nil
    }

    private func before(_ id: BlockID) -> BlockID? {
        if id.index > 0 { return BlockID(page: id.page, index: id.index - 1) }
        var page = id.page - 1
        while page >= 0 {
            let n = blocks(page).count
            if n > 0 { return BlockID(page: page, index: n - 1) }
            page -= 1
        }
        return nil
    }

    // MARK: What each block is

    static let sentenceEnd = try! NSRegularExpression(pattern: #"[\p{L}\p{N})\]"'”’][.!?…]+["'”’)\]]*(\s|$)"#)
    private static let pageNumber = try! NSRegularExpression(pattern: #"^(\d{1,4}|[ivxlc]{1,7})$"#, options: .caseInsensitive)
    /// A footnote starts with its marker: a number raised onto a line of its own or against its first word ("5The"), or a symbol.
    private static let footnote = try! NSRegularExpression(pattern: #"^(\d{1,2}[ \t]*[\r\n]|\d{1,2}\p{Lu}\p{L}|[*∗†‡§¶])"#)
    private static let caption = try! NSRegularExpression(pattern: #"^(Figure|Fig\.|Table)\s*\d+[.:]"#)
    private static let references = try! NSRegularExpression(
        pattern: #"^(\d+\.?\s+)?(References|Bibliography|Works Cited|Références|Bibliographie)$"#, options: .caseInsensitive)
    private static let numberedSection = try! NSRegularExpression(pattern: #"^(\d+(\.\d+)*\.?|[A-Z](\.\d+)+)\s+\p{Lu}"#)

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    private func classifiedBlocks(_ page: Int) -> [Block] {
        let all = blocks(page)
        guard !all.isEmpty, !classified.contains(page) else { return all }
        classified.insert(page)
        // A running header repeats on the next or previous page (a page number before or after it aside); the first
        // page has none.
        func plain(_ s: String) -> String {
            var words = s.split(separator: " ")
            while let w = words.first, w.allSatisfy(\.isNumber) { words.removeFirst() }
            while let w = words.last, w.allSatisfy(\.isNumber) { words.removeLast() }
            return words.joined(separator: " ")
        }
        let neighbours = page == 0 ? [] : Set((blocks(page - 1) + blocks(page + 1)).filter { $0.lines <= 2 }.map { plain($0.flat) })
        for b in all {
            let lead = (b.raw as String).trimmingCharacters(in: .whitespacesAndNewlines)
            let rotated = b.bounds.map { $0.height > 3 * $0.width && $0.height > 60 } ?? false // arXiv's stamp in the margin
            b.kind = b.flat.isEmpty || Self.matches(Self.pageNumber, b.flat) || rotated ? .furniture
                : Self.matches(Self.footnote, lead) ? .footnote
                : b.lines <= 2 && plain(b.flat).count >= 8 && neighbours.contains(plain(b.flat)) ? .furniture
                : Self.matches(Self.caption, b.flat) ? .caption(b.flat.hasPrefix("Table") ? "table" : "figure")
                : Self.matches(Self.references, b.flat) ? .references
                : b.reads ? .paragraph
                : b.lines == 1 && b.words <= 14 ? .heading
                : .other
        }
        // A footnote can run on into the next block, as a paragraph does.
        var previous: Block?
        for b in all where b.kind != .furniture {
            if let p = previous, p.kind == .footnote, unfinished(p), b.flat.first?.isLowercase == true { b.kind = .footnote }
            previous = b
        }
        // A footer (proceedings, copyright, the page number) sits below the page's text.
        let body = all.filter { $0.kind == .paragraph && $0.lines >= 3 }.compactMap(\.bounds)
        let boxes = all.compactMap(\.bounds)
        // Not one right after a heading: that's the first lines of its section.
        if let bodyBottom = body.map(\.maxY).max(), let top = boxes.map(\.minY).min(), let bottom = boxes.map(\.maxY).max() {
            var previous: Block?
            for b in all {
                if [.paragraph, .heading, .other].contains(b.kind), b.lines <= 2, previous?.kind != .heading,
                   let r = b.bounds, r.minY >= bodyBottom, r.minY >= top + 0.85 * (bottom - top) { b.kind = .furniture }
                if b.kind != .furniture { previous = b }
            }
        }
        // A figure's labels come right before its caption; a table's rows (mostly numbers) before or after its caption.
        func labelish(_ b: Block) -> Bool {
            let tokens = b.flat.split(separator: " ")
            let numbers = tokens.filter { t in t.contains(where: \.isNumber) || t.allSatisfy { "-–—".contains($0) } }.count
            let tabular = tokens.count >= 6 && numbers * 5 >= tokens.count * 2
            return ([.heading, .other, .furniture].contains(b.kind) || tabular) && !Self.matches(Self.numberedSection, b.flat)
        }
        for (i, b) in all.enumerated() {
            guard case .caption(let what) = b.kind else { continue }
            var j = i - 1
            while j >= 0, labelish(all[j]) { if all[j].kind != .furniture { all[j].kind = .label(what) }; j -= 1 }
            if what == "table" {
                j = i + 1
                while j < all.count, labelish(all[j]) { if all[j].kind != .furniture { all[j].kind = .label(what) }; j += 1 }
            }
        }
        if page == 0 {
            // Before the first paragraph, only the title, headings ("Abstract") and sentences are read: authors,
            // affiliations and addresses are lines of names ("Aidan N. Gomez … aidan@cs.toronto.edu" reads as a sentence).
            let address = { (b: Block) in b.flat.contains("@") }
            titleEnd = all.firstIndex { $0.kind == .paragraph && $0.words >= 6 && !address($0) } ?? 0
            for b in all[..<titleEnd] where b.kind == .other || address(b) { b.kind = .furniture }
        }
        if debugWalk { for b in all { print("    pdf block \(page).\(b.id.index) \(b.kind) \(b.bounds.map { "y=\(Int($0.minY))-\(Int($0.maxY)) lines=\(b.lines)" } ?? "-") \(b.flat.prefix(60).debugDescription)") } }
        return all
    }

    // MARK: Paragraphs across columns and pages

    private static let terminal = CharacterSet(charactersIn: ".!?…:;")
    private static let closing = CharacterSet(charactersIn: "\"'”’)]")

    /// A block whose text stops mid-sentence: no closing punctuation, or a line-end hyphen.
    private func unfinished(_ b: Block) -> Bool {
        let text = Self.withoutMarkers(b.raw as String).trimmingCharacters(in: .whitespacesAndNewlines)
        guard var last = text.unicodeScalars.last else { return false }
        if last == "\u{02}" { return true }
        var scalars = Array(text.unicodeScalars)
        while let l = scalars.last, Self.closing.contains(l) { scalars.removeLast(); last = scalars.last ?? l }
        return !Self.terminal.contains(last)
    }

    private var continuationMemo: [BlockID: BlockID?] = [:]
    private var headMemo: [BlockID: BlockID] = [:]

    /// The block that carries on `a`'s last sentence: the next one, past footnotes, figures, captions, page numbers,
    /// footers and headers, if it starts in lower case. In the title, two heading lines in a row are one title.
    private func continuation(of a: Block) -> Block? {
        if let known = continuationMemo[a.id] { return known.flatMap(block) }
        var found: Block?
        let inTitle = a.id.page == 0 && a.id.index < titleEnd
        if unfinished(a), a.kind == .paragraph || a.kind == .other || (a.kind == .heading && inTitle) {
            var id = after(a.id), skipped = 0
            while let i = id, let b = block(i), skipped < 80 {
                if b.kind.skippedInFlow { id = after(i); skipped += 1; continue }
                guard [.paragraph, .other, .heading].contains(b.kind), let first = b.flat.unicodeScalars.first else { break }
                let title = inTitle && skipped == 0 && a.headingRole && b.headingRole && b.id.index < titleEnd
                if CharacterSet.lowercaseLetters.contains(first) || title { found = b }
                break
            }
        }
        continuationMemo[a.id] = .some(found?.id)
        return found
    }

    /// The block whose flow `b` is part of: itself, or the paragraph it carries on.
    private func head(of b: Block) -> Block {
        if let known = headMemo[b.id], let h = block(known) { return h }
        var head = b
        var id = before(b.id), skipped = 0
        while let i = id, let a = block(i), skipped < 80 {
            if a.kind.skippedInFlow { id = before(i); skipped += 1; continue }
            if continuation(of: a) === b { head = self.head(of: a) }
            break
        }
        headMemo[b.id] = head.id
        return head
    }

    /// A paragraph and the blocks it runs on into, as one text.
    private struct Flow {
        let blocks: [Block]
        /// Where each block's text starts in `raw` (a space may sit between two).
        let starts: [Int]
        let raw: NSString
        /// `raw` as it's said: the same length, with hyphens at block ends marked.
        let said: NSString
        /// Each sentence's visible span in `raw`.
        let spans: [NSRange]
        let language: String
    }

    private var flowMemo: [BlockID: Flow] = [:]

    private func flow(from head: Block) -> Flow {
        if let known = flowMemo[head.id] { return known }
        var parts = [head]
        while parts.count < 8, let next = continuation(of: parts.last!) { parts.append(next) }
        var raw = "", starts: [Int] = []
        for b in parts {
            if let last = raw.unicodeScalars.last, !CharacterSet.whitespacesAndNewlines.contains(last), last != "\u{02}" { raw += " " }
            starts.append((raw as NSString).length)
            raw += b.raw as String
        }
        let ns = raw as NSString
        // What's said: a block that ends in a hyphen carries it on as a line-end hyphen (PDFium marks only those
        // inside a block with U+0002), with nothing between it and the next block (U+0001, dropped when said).
        let said = NSMutableString(string: raw)
        for i in 0..<(parts.count - 1) {
            let last = said.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, options: .backwards,
                                             range: NSRange(location: starts[i], length: parts[i].raw.length))
            guard last.location != NSNotFound, last.location > starts[i], [0x2D, 0x02].contains(said.character(at: last.location)),
                  CharacterSet.letters.contains(UnicodeScalar(said.character(at: last.location - 1)) ?? " ") else { continue }
            said.replaceCharacters(in: last, with: "\u{02}")
            let gap = NSRange(location: NSMaxRange(last), length: starts[i + 1] - NSMaxRange(last))
            said.replaceCharacters(in: gap, with: String(repeating: "\u{01}", count: gap.length))
        }
        // Tokenized with line ends as spaces, line-end hyphens as hyphens and footnote markers blanked: same length.
        let tokenized = NSMutableString(string: raw)
        for i in 0..<tokenized.length {
            switch tokenized.character(at: i) {
            case 0x0D, 0x0A, 0x09: tokenized.replaceCharacters(in: NSRange(location: i, length: 1), with: " ")
            case 0x02: tokenized.replaceCharacters(in: NSRange(location: i, length: 1), with: "-")
            default: break
            }
        }
        for m in Self.markerRanges(raw) { tokenized.replaceCharacters(in: m, with: String(repeating: " ", count: m.length)) }
        let text = tokenized as String
        var spans: [NSRange] = []
        func visible(_ r: NSRange) -> NSRange? {
            var lo = r.location, hi = NSMaxRange(r)
            while lo < hi, let c = UnicodeScalar(tokenized.character(at: lo)), WebDocument.blank.contains(c) { lo += 1 }
            while hi > lo, let c = UnicodeScalar(tokenized.character(at: hi - 1)), WebDocument.blank.contains(c) { hi -= 1 }
            return hi > lo ? NSRange(location: lo, length: hi - lo) : nil
        }
        if head.kind == .heading {
            if let v = visible(NSRange(location: 0, length: ns.length)) { spans = [v] }
        } else {
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = text
            for t in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
                if let v = visible(NSRange(t, in: text)), SpeechText.clean(tokenized.substring(with: v)) != nil { spans.append(v) }
            }
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(400)))
        let f = Flow(blocks: parts, starts: starts, raw: ns, said: said, spans: spans, language: recognizer.dominantLanguage == .french ? "fr" : "en")
        flowMemo[head.id] = f
        return f
    }

    // MARK: Text

    /// Footnote markers in running text: a number right after a word's punctuation ("drawn.1"), or a number on a
    /// line of its own (raised: "heads as A.\r\n3\r\n").
    private static let marker = try! NSRegularExpression(
        pattern: #"(?<=[\p{L})\]][.,;:!?])\d{1,2}(?=[\r\n]|\s*$|\s+\p{Lu})|(?<=\n)\d{1,2}(?=\r?\n)"#)

    private static func markerRanges(_ s: String) -> [NSRange] {
        marker.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).map(\.range)
    }

    private static func withoutMarkers(_ s: String) -> String {
        marker.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
    }

    /// What a span of PDF text says: footnote markers out, line-end hyphens resolved, line ends as spaces.
    private func spoken(_ raw: String, language: String) -> String? {
        SpeechText.clean(resolvingHyphens(Self.withoutMarkers(raw), language: language))
    }

    /// A line-end hyphen (U+0002) joins a word the typesetter broke ("para-graph") and stays in a word that has
    /// one ("task-specific", "state-of-the-art"). The document's own spelling decides first, then the spell checker.
    private func resolvingHyphens(_ s: String, language: String) -> String {
        guard s.contains("\u{02}") else { return s }
        let chars = Array(s)
        var out = ""
        for (i, c) in chars.enumerated() {
            guard c == "\u{02}" else { out.append(c); continue }
            var l = i
            while l > 0, chars[l - 1].isLetter || chars[l - 1] == "-" { l -= 1 }
            var r = i + 1
            while r < chars.count, chars[r].isLetter { r += 1 }
            let left = String(chars[l..<i]), right = String(chars[(i + 1)..<r])
            out += joins(left, right, language: language) ? "" : "-"
        }
        return out
    }

    private func joins(_ left: String, _ right: String, language: String) -> Bool {
        guard !left.isEmpty, !right.isEmpty else { return true }
        let joined = (left + right).lowercased()
        if vocabulary.contains(joined) { return true }
        if vocabulary.contains((left + "-" + right).lowercased()) { return false }
        if left.contains("-") || right.first?.isUppercase == true { return false }
        return Spelling.isWord(left + right, language: language)
    }

    // MARK: Sentences

    private var sentenceMemo: [String: Sentence] = [:]
    /// A sentence's part in each block it runs across (so the highlight leaves out what lies between), and those blocks.
    private struct Shape { let parts: [Sentence]; let blocks: [AXUIElement] }
    private var shapes: [ObjectIdentifier: Shape] = [:]

    func documentStart() -> AnyObject? { blocks(0).isEmpty ? nil : PDFPosition(BlockID(page: 0, index: 0), walked: true) }

    func sentence(from position: AnyObject, in scope: ReadingScope?) -> Sentence? {
        guard var pos = position as? PDFPosition else { return nil }
        for _ in 0..<2000 {
            if let known = sentenceMemo[pos.key] { return known }
            guard let b = block(pos.block) else { return nil }
            var flowHead = b, offset = pos.offset
            if pos.offset == 0, !pos.cued {
                let h = head(of: b)
                switch b.kind {
                case .furniture:
                    if !pos.walked { return nil }
                    pos = next(after: b); continue
                case .footnote where pos.walked:
                    pos = next(after: b); continue
                case .references where pos.walked:
                    if debugWalk { print("    pdf: references, end of reading") }
                    return nil
                case .label(let what):
                    return remember(cue(at: b, kind: what), for: pos)
                case .caption(let what) where pos.walked:
                    // Labels or rows after a table's caption get their cue after it; otherwise the cue is the caption's.
                    if let n = after(b.id), let nb = block(n), case .label = nb.kind { break }
                    guard let r = visibleRange(of: [b]) else { break }
                    let s = Sentence(text: "", range: r, next: PDFPosition(b.id, walked: true, cued: true), cue: what)
                    return remember(s, for: pos)
                case .other where pos.walked && continuation(of: b) == nil && h === b:
                    pos = next(after: b); continue
                default: break
                }
                if h !== b {
                    // Carries on an earlier paragraph: read on, it's been said; pointed at, read its sentence.
                    if pos.walked { pos = next(after: b); continue }
                    let f = flow(from: h)
                    guard let i = f.blocks.firstIndex(where: { $0 === b }) else { return nil }
                    flowHead = h
                    offset = f.starts[i]
                }
            }
            let f = flow(from: flowHead)
            guard let t = f.spans.lastIndex(where: { $0.location <= offset }) ?? (f.spans.isEmpty ? nil : 0) else {
                pos = next(after: flowHead); continue
            }
            return remember(sentence(in: f, at: t), for: pos)
        }
        return nil
    }

    private func remember(_ s: Sentence?, for pos: PDFPosition) -> Sentence? {
        if let s { sentenceMemo[pos.key] = s }
        return s
    }

    /// Reading on after `b`'s flow. At the end, the next page's start, in case PDFium builds it later.
    private func next(after b: Block) -> PDFPosition {
        PDFPosition(after(b.id) ?? BlockID(page: b.id.page + 1, index: 0), walked: true)
    }

    private func sentence(in f: Flow, at t: Int) -> Sentence? {
        let span = f.spans[t]
        var pieces: [(range: AnyObject, raw: String, block: AXUIElement)] = []
        for (i, b) in f.blocks.enumerated() {
            let lo = max(span.location, f.starts[i]), hi = min(NSMaxRange(span), f.starts[i] + b.raw.length)
            guard hi > lo, let r = range(in: b, from: lo - f.starts[i], to: hi - f.starts[i]) else { continue }
            pieces.append((r, f.raw.substring(with: NSRange(location: lo, length: hi - lo)), b.element))
        }
        guard let first = pieces.first, let last = pieces.last,
              let whole = range(start(of: first.range), end(of: last.range)),
              let text = spoken(f.said.substring(with: span).replacingOccurrences(of: "\u{01}", with: ""), language: f.language) else { return nil }
        let next: AnyObject = t + 1 < f.spans.count ? PDFPosition(f.blocks[0].id, offset: f.spans[t + 1].location, walked: true)
            : self.next(after: f.blocks[0])
        let s = Sentence(text: text, range: whole, next: next)
        let split = pieces.count == 1 ? [s] : pieces.map { p in
            Sentence(text: SpeechText.clean((p.raw as NSString).replacingOccurrences(of: "\u{02}", with: "")) ?? "", range: p.range, next: nil)
        }
        shapes[ObjectIdentifier(whole)] = Shape(parts: split, blocks: pieces.map(\.block))
        return s
    }

    /// One cue for a figure's labels (or a table's rows), then its caption.
    private func cue(at b: Block, kind: String) -> Sentence? {
        var run: [Block] = [], id: BlockID? = b.id
        while let i = id, let x = block(i) {
            if case .label = x.kind { run.append(x) } else if x.kind != .furniture { break }
            id = after(i)
        }
        guard let r = visibleRange(of: run) else { return nil }
        let following = id.flatMap(block)
        var next: AnyObject = following.map { PDFPosition($0.id, walked: true) } ?? self.next(after: run.last!)
        if let c = following, case .caption = c.kind { next = PDFPosition(c.id, walked: true, cued: true) }
        return Sentence(text: "", range: r, next: next, cue: kind)
    }

    /// From the first visible character of the first block to the last of the last.
    private func visibleRange(of run: [Block]) -> AnyObject? {
        func bounds(_ b: Block) -> (Int, Int)? {
            let lo = b.raw.rangeOfCharacter(from: WebDocument.blank.inverted).location
            guard lo != NSNotFound else { return nil }
            let hi = NSMaxRange(b.raw.rangeOfCharacter(from: WebDocument.blank.inverted, options: .backwards))
            return (lo, hi)
        }
        guard let first = run.first(where: { bounds($0) != nil }), let last = run.last(where: { bounds($0) != nil }),
              let a = range(in: first, from: bounds(first)!.0, to: bounds(first)!.1),
              let z = range(in: last, from: bounds(last)!.0, to: bounds(last)!.1) else { return nil }
        return range(start(of: a), end(of: z))
    }

    // MARK: Markers

    private func p(_ name: String, _ arg: AnyObject) -> AnyObject? { AX.param(element, name, arg) }
    private func string(_ range: AnyObject) -> String { p("AXStringForTextMarkerRange", range) as? String ?? "" }
    private func start(of range: AnyObject) -> AnyObject { AXTextMarkerRangeCopyStartMarker(range as! AXTextMarkerRange) }
    private func end(of range: AnyObject) -> AnyObject { AXTextMarkerRangeCopyEndMarker(range as! AXTextMarkerRange) }
    private func range(_ a: AnyObject, _ b: AnyObject) -> AnyObject? { p("AXTextMarkerRangeForUnorderedTextMarkers", [a, b] as CFArray) }

    /// The markers around a block's characters `lo..<hi`, each anchored to the text leaf it falls in.
    private func range(in b: Block, from lo: Int, to hi: Int) -> AnyObject? {
        guard let a = marker(in: b, at: lo, end: false), let z = marker(in: b, at: hi, end: true) else { return nil }
        return range(a, z)
    }

    /// Markers already found in each leaf, so a paragraph is stepped through once, not once per sentence.
    private var known: [AXKey: [(offset: Int, marker: AnyObject)]] = [:]

    private func marker(in b: Block, at offset: Int, end: Bool) -> AnyObject? {
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
    /// miss it are moved back to its left edge.
    private func inside(_ block: AXUIElement, _ boxes: [CGRect]) -> [CGRect] { inside(block, boxes.map(Optional.some)).compactMap { $0 } }

    private func inside(_ block: AXUIElement, _ boxes: [CGRect?]) -> [CGRect?] {
        guard let frame = AX.frame(block), frame.width > 0 else { return boxes }
        let misses = { (r: CGRect) in r.maxX <= frame.minX || r.minX >= frame.maxX }
        guard let left = boxes.compactMap({ $0 }).filter(misses).map(\.minX).min() else { return boxes }
        return boxes.map { b in b.map { misses($0) ? $0.offsetBy(dx: frame.minX - left, dy: 0) : $0 } }
    }

    func linesDiagnosis(of sentence: Sentence) -> String {
        web.linesDiagnosis(of: shapes[ObjectIdentifier(sentence.range)]?.parts.first ?? sentence)
    }

    func visibleRect() -> CGRect? { web.visibleRect() }

    func scrollIntoView(_ sentence: Sentence) { web.scrollIntoView(shapes[ObjectIdentifier(sentence.range)]?.parts.first ?? sentence) }

    /// Blocks on screen, in reading order (element frames are right for these).
    private func visibleBlocks() -> [(block: Block, frame: CGRect)] {
        guard let visible = visibleRect() else { return [] }
        var out: [(Block, CGRect)] = []
        for (page, region) in regions().enumerated() {
            guard let f = AX.frame(region), f.height >= 4, f.intersects(visible) else { continue }
            for b in classifiedBlocks(page) {
                if let bf = AX.frame(b.element), bf.height >= 4, bf.intersects(visible) { out.append((b, bf)) }
            }
        }
        return out
    }

    /// The hold asks 30 times a second; while the pointer stays in the last block, that's the answer (its frame is
    /// asked again: the document outlives a hold, and the page may have scrolled since).
    private var lastParagraph: (block: Block, start: AnyObject)?

    func paragraph(at point: CGPoint) -> (start: AnyObject, bounds: CGRect)? {
        if let last = lastParagraph, let frame = AX.frame(last.block.element), frame.contains(point) { return (last.start, frame) }
        guard let hit = visibleBlocks().first(where: { $0.frame.contains(point) && $0.block.kind != .furniture }) else {
            lastParagraph = nil
            return nil
        }
        let start = PDFPosition(hit.block.id, walked: false)
        lastParagraph = (hit.block, start)
        return (start, hit.frame)
    }

    func firstVisible() -> AnyObject? {
        visibleBlocks().first { ![.furniture, .footnote].contains($0.block.kind) }.map { PDFPosition($0.block.id, walked: false) }
    }
}

/// Is a word spelled right? The system spell checker, asked once per word.
enum Spelling {
    private static let lock = NSLock()
    private static var memo: [String: Bool] = [:]

    static func isWord(_ word: String, language: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let key = language + ":" + word
        if let known = memo[key] { return known }
        let miss = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        let ok = miss.location == NSNotFound
        memo[key] = ok
        return ok
    }
}
