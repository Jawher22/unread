// What a PDF or EPUB reader gives Accessibility (#16, #87). Read-only except `turn`.
//   swift scripts/reader-probe.swift <pid> [pages]   the window's web areas, its PDF pages and their text, and, for the
//                                                    first long text leaves, which range and text-marker calls answer
//   swift scripts/reader-probe.swift <pid> calls     Books: what the web areas and a text leaf answer, how the iOS bridge's
//                                                    text markers step through the chapter, and what a step costs
//   swift scripts/reader-probe.swift <pid> turn      Books: turn one spread forward and back with AXScrollRightByPage /
//                                                    AXScrollLeftByPage on a leaf, timing the tree's change
// Point it at a document opened in the background (`open -g -a Preview file.pdf`, `open -g book.epub`); the app may be
// hidden. Results are in docs/design.md (§6, PDF and EPUB readers). What a book's sentences, lines and words come out
// as is `Unread --extract --pid <pid> --lines --word-boxes`.
import AppKit
import ApplicationServices

setbuf(stdout, nil)
let pid = pid_t(CommandLine.arguments[1])!
let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "survey"
let pageLimit = Int(mode) ?? 2
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func param(_ e: AXUIElement, _ n: String, _ p: AnyObject) -> (AXError, AnyObject?) {
    var v: AnyObject?
    let r = AXUIElementCopyParameterizedAttributeValue(e, n as CFString, p, &v)
    return (r, v)
}
func role(_ e: AXUIElement) -> String { attr(e, kAXRoleAttribute) as? String ?? "?" }
func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func range(_ location: Int, _ length: Int) -> AXValue { var r = CFRange(location: location, length: length); return AXValueCreate(.cfRange, &r)! }
func describe(_ v: AnyObject?) -> String {
    guard let v else { return "nil" }
    if CFGetTypeID(v) == AXValueGetTypeID() {
        let av = v as! AXValue
        switch AXValueGetType(av) {
        case .cgRect: var r = CGRect.zero; AXValueGetValue(av, .cgRect, &r); return "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
        case .cfRange: var r = CFRange(); AXValueGetValue(av, .cfRange, &r); return "range(\(r.location),\(r.length))"
        default: return "axvalue"
        }
    }
    if CFGetTypeID(v) == AXUIElementGetTypeID() { let e = v as! AXUIElement; return "\(role(e)) \(frame(e))" }
    if CFGetTypeID(v) == AXTextMarkerGetTypeID() { return "marker" }
    if CFGetTypeID(v) == AXTextMarkerRangeGetTypeID() { return "marker range" }
    if let s = v as? String { return s.prefix(60).debugDescription }
    if let a = v as? NSAttributedString { return "attributed(\(a.length)) \(a.string.prefix(50).debugDescription)" }
    if let arr = v as? [AnyObject] { return "[\(arr.count)] " + arr.prefix(4).map(describe).joined(separator: ", ") }
    return "\(v)"
}
func frame(_ e: AXUIElement) -> String {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return "-" }
    var pt = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return "[\(Int(pt.x)),\(Int(pt.y)) \(Int(size.width))x\(Int(size.height))]"
}
func all(in root: AXUIElement, where match: (AXUIElement) -> Bool) -> [AXUIElement] {
    var out: [AXUIElement] = [], stack = [root], seen = 0
    while let e = stack.popLast(), seen < 20_000 {
        seen += 1
        if match(e) { out.append(e) }
        stack.append(contentsOf: children(e).reversed())
    }
    return out
}
func names(_ e: AXUIElement) -> [String] { var n: CFArray?; AXUIElementCopyAttributeNames(e, &n); return n as? [String] ?? [] }
func paramNames(_ e: AXUIElement) -> [String] { var n: CFArray?; AXUIElementCopyParameterizedAttributeNames(e, &n); return n as? [String] ?? [] }
func actions(_ e: AXUIElement) -> [String] { var n: CFArray?; AXUIElementCopyActionNames(e, &n); return n as? [String] ?? [] }
func marker(_ v: AnyObject?) -> AXTextMarker? { guard let v, CFGetTypeID(v) == AXTextMarkerGetTypeID() else { return nil }; return (v as! AXTextMarker) }

let app = AXUIElementCreateApplication(pid)
guard let window = (attr(app, kAXFocusedWindowAttribute) ?? attr(app, kAXMainWindowAttribute)) as! AXUIElement?
        ?? (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first else { print("no window"); exit(1) }
print("window \(attr(window, kAXTitleAttribute) as? String ?? "?") \(frame(window)), app hidden: \(NSRunningApplication(processIdentifier: pid)?.isHidden ?? false)")
func leaves(longerThan n: Int) -> [AXUIElement] { all(in: window) { role($0) == "AXStaticText" && (attr($0, kAXValueAttribute) as? String ?? "").count > n } }
func pages() -> String {
    all(in: window) { role($0) == "AXStaticText" && ((attr($0, kAXDescriptionAttribute) as? String) ?? "").hasPrefix("Page") }
        .map { attr($0, kAXDescriptionAttribute) as? String ?? "" }.joined(separator: ", ")
}

switch mode {
case "calls":
    for area in all(in: window, where: { role($0) == "AXWebArea" }) {
        print("\nweb area \(frame(area)), \(children(area).count) children; params \(paramNames(area)); actions \(actions(area))")
    }
    guard let leaf = leaves(longerThan: 40).first else { print("no text leaf"); exit(1) }
    let value = attr(leaf, kAXValueAttribute) as? String ?? ""
    print("\nleaf \(frame(leaf)) value(\(value.count)) \(value.prefix(50).debugDescription)")
    print("  attrs: \(names(leaf))")
    print("  params: \(paramNames(leaf))")
    print("  actions: \(actions(leaf))")
    for (name, p) in [("AXBoundsForRange", range(0, 10)), ("AXStringForRange", range(0, 10)), ("AXRangeForLine", 0 as NSNumber), ("AXLineForIndex", 5 as NSNumber), ("AXTextMarkerForIndex", 5 as NSNumber)] as [(String, AnyObject)] {
        let (err, v) = param(leaf, name, p)
        print("  \(name)(\(describe(p))) → \(err == .success ? describe(v) : "error \(err.rawValue)")")
    }
    guard let mr = param(leaf, "AXTextMarkerRangeForUIElement", leaf).1, CFGetTypeID(mr) == AXTextMarkerRangeGetTypeID() else { print("  no marker range"); exit(1) }
    let start = AXTextMarkerRangeCopyStartMarker(mr as! AXTextMarkerRange), end = AXTextMarkerRangeCopyEndMarker(mr as! AXTextMarkerRange)
    print("  AXTextMarkerRangeForUIElement → the whole paragraph, not the \(value.utf16.count) visible characters:")
    for name in ["AXAttributedStringForTextMarkerRange", "AXStringForTextMarkerRange", "AXBoundsForTextMarkerRange"] {
        let (err, v) = param(leaf, name, mr)
        print("    \(name) → \(err == .success ? describe(v) : "error \(err.rawValue)")")
    }
    print("    AXIndexForTextMarker(start) → \(describe(param(leaf, "AXIndexForTextMarker", start).1)), (end) → \(describe(param(leaf, "AXIndexForTextMarker", end).1))")
    print("    AXUIElementForTextMarker(start) → \(describe(param(leaf, "AXUIElementForTextMarker", start).1))")
    for name in ["AXNextTextMarkerForTextMarker", "AXPreviousTextMarkerForTextMarker", "AXNextLineEndTextMarkerForTextMarker", "AXPreviousLineStartTextMarkerForTextMarker", "AXNextWordEndTextMarkerForTextMarker", "AXParagraphTextMarkerRangeForTextMarker"] {
        let (err, v) = param(leaf, name, start)
        print("    \(name)(start) → \(err == .success ? describe(v) : "error \(err.rawValue)")")
    }
    if let a = marker(param(leaf, "AXNextTextMarkerForTextMarker", start).1), let b = marker(param(leaf, "AXNextTextMarkerForTextMarker", a).1) {
        let r = AXTextMarkerRangeCreate(kCFAllocatorDefault, start, b)
        print("    two characters from the start: \(describe(param(leaf, "AXAttributedStringForTextMarkerRange", r).1)) at \(describe(param(leaf, "AXBoundsForTextMarkerRange", r).1))")
    }
    // Past a block's "\n", two markers share one index; the string from the first still starts with the "\n".
    if let lineEnd = marker(param(leaf, "AXNextLineEndTextMarkerForTextMarker", start).1) {
        var m = lineEnd
        for k in 0..<2 {
            guard let n = marker(param(leaf, "AXNextTextMarkerForTextMarker", m).1) else { break }
            let s = (param(leaf, "AXAttributedStringForTextMarkerRange", AXTextMarkerRangeCreate(kCFAllocatorDefault, lineEnd, n)).1 as? NSAttributedString)?.string ?? "?"
            print("    marker \(k + 1) past the first line's end: index \(describe(param(leaf, "AXIndexForTextMarker", n).1)), string from the line end \(s.debugDescription)")
            m = n
        }
    }
    let t = Date()
    var m = start
    for _ in 0..<200 { guard let nx = marker(param(leaf, "AXNextTextMarkerForTextMarker", m).1) else { break }; m = nx }
    print(String(format: "    200 character steps: %.2f ms each", Date().timeIntervalSince(t) * 1000 / 200))
case "turn":
    func areaState() -> String {
        all(in: window, where: { role($0) == "AXWebArea" }).map { a in
            let l = children(a).filter { role($0) == "AXStaticText" }
            return "\(frame(a)) \(l.count) leaves" + (l.first.map { " \((attr($0, kAXValueAttribute) as? String ?? "").prefix(20).debugDescription)" } ?? "")
        }.joined(separator: " | ")
    }
    func state() -> String { "\(pages()): \(areaState())" }
    func turn(_ action: String) {
        let areas = all(in: window, where: { role($0) == "AXWebArea" })
        guard let leaf = leaves(longerThan: 0).first(where: { leaf in areas.contains { CFEqual($0, attr(leaf, kAXParentAttribute)) } }) else { print("no text leaf in a web area"); return }
        let before = state()
        let t = Date()
        let err = AXUIElementPerformAction(leaf, action as CFString)
        var last = before
        print("\(action) on a leaf → \(err == .success ? "ok" : "error \(err.rawValue)"); the tree over the next 2 s:")
        while Date().timeIntervalSince(t) < 2 {
            Thread.sleep(forTimeInterval: 0.05)
            let s = state()
            if s != last { print(String(format: "  +%4.0f ms: %@", Date().timeIntervalSince(t) * 1000, s)); last = s }
        }
        if last == before { print("  unchanged") }
        Thread.sleep(forTimeInterval: 0.5)
    }
    print("before: \(state())")
    turn("AXScrollRightByPage")
    turn("AXScrollLeftByPage")
default:
    let areas = all(in: window) { role($0) == "AXWebArea" }
    print("\nweb areas: \(areas.count)")
    for a in areas { print("  \(frame(a)) children \(children(a).count), params: \(param(a, "AXTextMarkerRangeForUIElement", a).0 == .success ? "text markers" : "no text markers")") }

    let pdfPages = all(in: window) { role($0) == "AXPage" }
    print("\nPDF pages: \(pdfPages.count) " + pdfPages.map { "\(attr($0, "AXNumberOfCharacters") as? Int ?? -1)" }.joined(separator: " "))
    for (i, p) in pdfPages.prefix(pageLimit).enumerated() {
        let n = attr(p, "AXNumberOfCharacters") as? Int ?? 0
        let text = (param(p, "AXAttributedStringForRange", range(0, n)).1 as? NSAttributedString)?.string ?? "nil"
        print("  page \(i + 1), \(n) characters, bounds for a range: \(param(p, "AXBoundsForRange", range(0, 10)).0 == .success ? "yes" : "no")")
        print("  head: \(text.prefix(300).debugDescription)")
        print("  tail: \(text.suffix(200).debugDescription)")
    }

    let long = leaves(longerThan: 100)
    print("\nlong text leaves: \(long.count)")
    for leaf in long.prefix(3) {
        let value = attr(leaf, kAXValueAttribute) as? String ?? ""
        print("  \(frame(leaf)) \(value.count) characters: \(value.prefix(50).debugDescription)")
        let mid = value.count / 2
        print("    index range \(mid)+20: \((param(leaf, "AXStringForRange", range(mid, 20)).1 as? String).debugDescription) bounds \(describe(param(leaf, "AXBoundsForRange", range(mid, 20)).1))")
        guard let markers = param(leaf, "AXTextMarkerRangeForUIElement", leaf).1 else { print("    no text markers"); continue }
        let plain = param(leaf, "AXStringForTextMarkerRange", markers)
        let attributed = (param(leaf, "AXAttributedStringForTextMarkerRange", markers).1 as? NSAttributedString)?.string
        let said = (plain.1 as? String) ?? attributed ?? ""
        print("    marker range: string \(plain.0 == .success ? "yes" : "no (\(plain.0.rawValue))"), text \(said.hasPrefix(value.prefix(20)) ? "matches the leaf" : "differs: \(said.prefix(50).debugDescription)"), bounds \(describe(param(leaf, "AXBoundsForTextMarkerRange", markers).1))")
    }
}
