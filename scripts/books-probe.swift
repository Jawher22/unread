// What Apple Books gives Accessibility (#87): the window's tree, what each text leaf answers, how
// text markers step through the chapter, the lines of a paragraph with their boxes, and whether
// a page-turn action works. Read-only except `turn`, which turns one spread forward and back.
//   swift scripts/books-probe.swift <pid> [tree|calls|lines|turn]
// Point it at a book opened in the background (`open -g book.epub`); Books may be hidden.
// Results are in docs/design.md (§6, PDF and EPUB readers).
import AppKit
import ApplicationServices

setbuf(stdout, nil)
let pid = pid_t(CommandLine.arguments[1])!
let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "tree"
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
print("window \(attr(window, kAXTitleAttribute) as? String ?? "?") \(frame(window)), Books hidden: \(NSRunningApplication(processIdentifier: pid)?.isHidden ?? false)")
func leaves() -> [AXUIElement] { all(in: window) { role($0) == "AXStaticText" && (attr($0, kAXValueAttribute) as? String ?? "").count > 40 } }
func pages() -> String {
    all(in: window) { role($0) == "AXStaticText" && ((attr($0, kAXDescriptionAttribute) as? String) ?? "").hasPrefix("Page") }
        .map { attr($0, kAXDescriptionAttribute) as? String ?? "" }.joined(separator: ", ")
}

switch mode {
case "tree":
    func dump(_ e: AXUIElement, depth: Int) {
        let sub = (attr(e, kAXSubroleAttribute) as? String).map { "/\($0)" } ?? ""
        let value = (attr(e, kAXValueAttribute) as? String).map { " value=\($0.prefix(50).debugDescription)(\($0.count))" } ?? ""
        let desc = (attr(e, kAXDescriptionAttribute) as? String).flatMap { $0.isEmpty ? nil : " desc=\($0.prefix(30).debugDescription)" } ?? ""
        let kids = children(e)
        print(String(repeating: "  ", count: depth) + "\(role(e))\(sub) \(frame(e))\(desc)\(value) kids=\(kids.count)")
        for k in kids { dump(k, depth: depth + 1) }
    }
    dump(window, depth: 0)
case "calls":
    for area in all(in: window, where: { role($0) == "AXWebArea" }) {
        print("\nweb area \(frame(area)), \(children(area).count) children; params \(paramNames(area)); actions \(actions(area))")
    }
    guard let leaf = leaves().first else { print("no text leaf"); exit(1) }
    let value = attr(leaf, kAXValueAttribute) as? String ?? ""
    print("\nleaf \(frame(leaf)) value(\(value.count)) \(value.prefix(50).debugDescription)")
    print("  attrs: \(names(leaf))")
    print("  params: \(paramNames(leaf))")
    print("  actions: \(actions(leaf))")
    let n = value.utf16.count
    for (name, p) in [("AXBoundsForRange", range(0, 10)), ("AXStringForRange", range(0, 10)), ("AXRangeForLine", 0 as NSNumber), ("AXLineForIndex", 5 as NSNumber), ("AXTextMarkerForIndex", 5 as NSNumber)] as [(String, AnyObject)] {
        let (err, v) = param(leaf, name, p)
        print("  \(name)(\(describe(p))) → \(err == .success ? describe(v) : "error \(err.rawValue)")")
    }
    guard let mr = param(leaf, "AXTextMarkerRangeForUIElement", leaf).1, CFGetTypeID(mr) == AXTextMarkerRangeGetTypeID() else { print("  no marker range"); exit(1) }
    let start = AXTextMarkerRangeCopyStartMarker(mr as! AXTextMarkerRange), end = AXTextMarkerRangeCopyEndMarker(mr as! AXTextMarkerRange)
    print("  AXTextMarkerRangeForUIElement → the whole paragraph, not the \(n) visible characters:")
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
    let t = Date()
    var m = start
    for _ in 0..<200 { guard let nx = marker(param(leaf, "AXNextTextMarkerForTextMarker", m).1) else { break }; m = nx }
    print(String(format: "    200 character steps: %.2f ms each", Date().timeIntervalSince(t) * 1000 / 200))
case "lines":
    guard let leaf = leaves().first, let mr = param(leaf, "AXTextMarkerRangeForUIElement", leaf).1, CFGetTypeID(mr) == AXTextMarkerRangeGetTypeID() else { print("no text leaf"); exit(1) }
    func idx(_ m: AXTextMarker) -> Int { (param(leaf, "AXIndexForTextMarker", m).1 as? NSNumber)?.intValue ?? -1 }
    func str(_ a: AXTextMarker, _ b: AXTextMarker) -> String { (param(leaf, "AXAttributedStringForTextMarkerRange", AXTextMarkerRangeCreate(kCFAllocatorDefault, a, b)).1 as? NSAttributedString)?.string ?? "?" }
    func box(_ a: AXTextMarker, _ b: AXTextMarker) -> String { describe(param(leaf, "AXBoundsForTextMarkerRange", AXTextMarkerRangeCreate(kCFAllocatorDefault, a, b)).1) }
    var s = AXTextMarkerRangeCopyStartMarker(mr as! AXTextMarkerRange)
    let end = AXTextMarkerRangeCopyEndMarker(mr as! AXTextMarkerRange)
    print("paragraph [\(idx(s)), \(idx(end))): \(str(s, end).prefix(60).debugDescription)")
    print("each line: [start index, end index) string(length) box | first character's box. A line's string drops the wrap space before it,")
    print("whose index its start marker reports; at a hyphenation wrap the marker before the first letter sits at the end of the line before.")
    for k in 0..<400 {
        guard let e = marker(param(leaf, "AXNextLineEndTextMarkerForTextMarker", s).1), idx(e) > idx(s) else { break }
        let t = str(s, e)
        let first = marker(param(leaf, "AXNextTextMarkerForTextMarker", s).1).map { "\(box(s, $0)) \(str(s, $0).debugDescription)" } ?? "-"
        print("  \(k): [\(idx(s)), \(idx(e))) \(t.prefix(40).debugDescription)(\(t.count)) \(box(s, e)) | \(first)")
        if t.hasPrefix("\n") || CFEqual(e, end) { break }
        s = e
    }
case "turn":
    func state() -> String { "\(pages()): " + leaves().map { "\(frame($0)) \((attr($0, kAXValueAttribute) as? String ?? "").prefix(20).debugDescription)" }.joined(separator: " | ") }
    func turn(_ action: String) {
        guard let leaf = leaves().first else { print("no text leaf"); return }
        let before = state()
        let t = Date()
        let err = AXUIElementPerformAction(leaf, action as CFString)
        var changed: Int?
        for i in 0..<40 { Thread.sleep(forTimeInterval: 0.05); if state() != before { changed = (i + 1) * 50; break } }
        print("\(action) on a leaf → \(err == .success ? "ok" : "error \(err.rawValue)") in \(Int(Date().timeIntervalSince(t) * 1000)) ms, tree changed after \(changed.map { "\($0) ms" } ?? "never (2 s)")\n  now: \(state())")
        Thread.sleep(forTimeInterval: 1)
    }
    print("before: \(state())")
    turn("AXScrollRightByPage")
    turn("AXScrollLeftByPage")
default: print("modes: tree, calls, lines, turn")
}
