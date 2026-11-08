// What a PDF or EPUB reader gives Accessibility (#16): its web areas, its PDF pages and
// their text, and, for the first long text leaves, which range and text-marker calls
// answer with something usable. Read-only: it never focuses, scrolls or selects.
//   swift scripts/reader-probe.swift <pid> [pages]
// Point it at a document opened in the background (`open -g -a Preview file.pdf`).
// Results are in docs/design.md (§6, PDF and EPUB readers).
import AppKit
import ApplicationServices

let pid = pid_t(CommandLine.arguments[1])!
let pageLimit = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 2
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func param(_ e: AXUIElement, _ n: String, _ p: AnyObject) -> (AXError, AnyObject?) {
    var v: AnyObject?
    let r = AXUIElementCopyParameterizedAttributeValue(e, n as CFString, p, &v)
    return (r, v)
}
func role(_ e: AXUIElement) -> String { attr(e, kAXRoleAttribute) as? String ?? "?" }
func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func range(_ location: Int, _ length: Int) -> AXValue { var r = CFRange(location: location, length: length); return AXValueCreate(.cfRange, &r)! }
func box(_ v: AnyObject?) -> String {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return "nil" }
    var r = CGRect.zero
    AXValueGetValue(v as! AXValue, .cgRect, &r)
    return "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
}
func frame(_ e: AXUIElement) -> String {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return "-" }
    var pt = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return "[\(Int(pt.x)),\(Int(pt.y)) \(Int(size.width))x\(Int(size.height))]"
}
func all(in root: AXUIElement, where match: (AXUIElement) -> Bool) -> [AXUIElement] {
    var out: [AXUIElement] = [], queue = [root], seen = 0
    while !queue.isEmpty, seen < 20_000 {
        let e = queue.removeFirst()
        seen += 1
        if match(e) { out.append(e) }
        queue.append(contentsOf: children(e))
    }
    return out
}

let app = AXUIElementCreateApplication(pid)
guard let window = (attr(app, kAXFocusedWindowAttribute) ?? attr(app, kAXMainWindowAttribute)) as! AXUIElement?
        ?? (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first else { print("no window"); exit(1) }
print("window \(attr(window, kAXTitleAttribute) as? String ?? "?") \(frame(window))")

let areas = all(in: window) { role($0) == "AXWebArea" }
print("\nweb areas: \(areas.count)")
for a in areas { print("  \(frame(a)) children \(children(a).count), params: \(param(a, "AXTextMarkerRangeForUIElement", a).0 == .success ? "text markers" : "no text markers")") }

let pages = all(in: window) { role($0) == "AXPage" }
print("\nPDF pages: \(pages.count) " + pages.map { "\(attr($0, "AXNumberOfCharacters") as? Int ?? -1)" }.joined(separator: " "))
for (i, p) in pages.prefix(pageLimit).enumerated() {
    let n = attr(p, "AXNumberOfCharacters") as? Int ?? 0
    let text = (param(p, "AXAttributedStringForRange", range(0, n)).1 as? NSAttributedString)?.string ?? "nil"
    print("  page \(i + 1), \(n) characters, bounds for a range: \(param(p, "AXBoundsForRange", range(0, 10)).0 == .success ? "yes" : "no")")
    print("  head: \(text.prefix(300).debugDescription)")
    print("  tail: \(text.suffix(200).debugDescription)")
}

let leaves = all(in: window) { role($0) == "AXStaticText" && (attr($0, kAXValueAttribute) as? String ?? "").count > 100 }
print("\nlong text leaves: \(leaves.count)")
for leaf in leaves.prefix(3) {
    let value = attr(leaf, kAXValueAttribute) as? String ?? ""
    print("  \(frame(leaf)) \(value.count) characters: \(value.prefix(50).debugDescription)")
    let mid = value.count / 2
    print("    index range \(mid)+20: \((param(leaf, "AXStringForRange", range(mid, 20)).1 as? String).debugDescription) bounds \(box(param(leaf, "AXBoundsForRange", range(mid, 20)).1))")
    guard let markers = param(leaf, "AXTextMarkerRangeForUIElement", leaf).1 else { print("    no text markers"); continue }
    let plain = param(leaf, "AXStringForTextMarkerRange", markers)
    let attributed = (param(leaf, "AXAttributedStringForTextMarkerRange", markers).1 as? NSAttributedString)?.string
    let said = (plain.1 as? String) ?? attributed ?? ""
    print("    marker range: string \(plain.0 == .success ? "yes" : "no (\(plain.0.rawValue))"), text \(said.hasPrefix(value.prefix(20)) ? "matches the leaf" : "differs: \(said.prefix(50).debugDescription)"), bounds \(box(param(leaf, "AXBoundsForTextMarkerRange", markers).1))")
}
