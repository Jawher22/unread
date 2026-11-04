// Which Accessibility mechanism scrolls a native text view to a character range
// without touching the selection, the caret or focus (#13)? Tries each one from the
// top of the text and prints the view's state before and after.
//   swift scripts/native-scroll-probe.swift <pid> [window title text] [target index]
// It sets the selection and scrolls, so point it only at a document of your own:
// a fixture host (build/fixture-host-native <file>) or a scratch TextEdit document
// opened with `open -g -a TextEdit <file>`. Results are in docs/design.md (§6).
import AppKit
import ApplicationServices

let pid = pid_t(CommandLine.arguments[1])!
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func param(_ e: AXUIElement, _ n: String, _ p: AnyObject) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyParameterizedAttributeValue(e, n as CFString, p, &v) == .success ? v : nil }
func role(_ e: AXUIElement) -> String? { attr(e, kAXRoleAttribute) as? String }
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func range(_ v: AnyObject?) -> CFRange? { guard let v else { return nil }; var r = CFRange(); return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil }
func rangeValue(_ l: Int, _ n: Int) -> AXValue { var r = CFRange(location: l, length: n); return AXValueCreate(.cfRange, &r)! }
func rect(_ v: AnyObject?) -> CGRect? { guard let v else { return nil }; var r = CGRect.zero; return AXValueGetValue(v as! AXValue, .cgRect, &r) ? r : nil }
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var o = CGPoint.zero, z = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &o); AXValueGetValue(s as! AXValue, .cgSize, &z)
    return CGRect(origin: o, size: z)
}
func find(_ root: AXUIElement, _ r: String) -> AXUIElement? {
    var q = [root]
    while !q.isEmpty { let e = q.removeFirst(); if role(e) == r { return e }; q += children(e) }
    return nil
}
func settable(_ e: AXUIElement, _ n: String) -> Bool { var b = DarwinBoolean(false); AXUIElementIsAttributeSettable(e, n as CFString, &b); return b.boolValue }
func actions(_ e: AXUIElement) -> [String] { var a: CFArray?; AXUIElementCopyActionNames(e, &a); return (a as? [String]) ?? [] }

let app = AXUIElementCreateApplication(pid)
let wanted = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
// A window on another Space is missing from AXWindows but is still the main window.
let windows = ((attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []) + [attr(app, kAXMainWindowAttribute)].compactMap { $0.map { $0 as! AXUIElement } }
guard let window = windows.first(where: { wanted.isEmpty || ((attr($0, kAXTitleAttribute) as? String) ?? "").contains(wanted) }),
      let textArea = find(window, kAXTextAreaRole), let scrollArea = find(window, kAXScrollAreaRole) else {
    print("no window with a scrolling text area\(wanted.isEmpty ? "" : " titled like \(wanted.debugDescription)")"); exit(1)
}
print("window: \((attr(window, kAXTitleAttribute) as? String) ?? "?")")
let bar = attr(scrollArea, kAXVerticalScrollBarAttribute).map { $0 as! AXUIElement }
let length = (attr(textArea, kAXValueAttribute) as! String).utf16.count
let target = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : length * 2 / 3
let targetLen = 40

print("text area actions: \(actions(textArea))")
print("scroll area actions: \(actions(scrollArea))")
print("scroll bar: \(bar.map { "\(role($0) ?? "?") actions \(actions($0)) value settable \(settable($0, kAXValueAttribute))" } ?? "none")")
print("settable on text area: visibleCharRange \(settable(textArea, kAXVisibleCharacterRangeAttribute)), selectedRange \(settable(textArea, kAXSelectedTextRangeAttribute))")
print("length \(length), target \(target)")

struct State: CustomStringConvertible {
    var visible: CFRange?
    var selection: CFRange?
    var bar: Double?
    var inView: Bool
    var front: String?
    var appFrontmost: Bool?
    var focusedIsText: Bool
    var description: String {
        "visible \(visible.map { "\($0.location)+\($0.length)" } ?? "-") sel \(selection.map { "\($0.location)+\($0.length)" } ?? "-") bar \(bar.map { String(format: "%.3f", $0) } ?? "-") targetInView \(inView) front \(front ?? "-") appFrontmost \(appFrontmost.map(String.init) ?? "-") focusedText \(focusedIsText)"
    }
}
func state() -> State {
    let b = rect(param(textArea, kAXBoundsForRangeParameterizedAttribute, rangeValue(target, targetLen)))
    let view = frame(scrollArea)
    let focused = attr(app, kAXFocusedUIElementAttribute).map { CFEqual($0, textArea) } ?? false
    return State(visible: range(attr(textArea, kAXVisibleCharacterRangeAttribute)), selection: range(attr(textArea, kAXSelectedTextRangeAttribute)),
                 bar: bar.flatMap { (attr($0, kAXValueAttribute) as? NSNumber)?.doubleValue },
                 inView: b.map { view?.contains($0) ?? false } ?? false,
                 front: NSWorkspace.shared.frontmostApplication?.localizedName,
                 appFrontmost: (attr(app, kAXFrontmostAttribute) as? Bool), focusedIsText: focused)
}
func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
func reset() {
    // Back to the top, with a selection near the start to see whether it moves.
    AXUIElementSetAttributeValue(textArea, kAXSelectedTextRangeAttribute as CFString, rangeValue(10, 5))
    if let bar { AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, 0 as NSNumber) }
    settle()
}

let mechanisms: [(String, () -> AXError)] = [
    ("AXScrollToVisible on text area", { AXUIElementPerformAction(textArea, "AXScrollToVisible" as CFString) }),
    ("AXScrollToShowDescendant on scroll area", { AXUIElementSetAttributeValue(scrollArea, "AXScrollToShowDescendant" as CFString, textArea) }),
    ("set AXVisibleCharacterRange", { AXUIElementSetAttributeValue(textArea, kAXVisibleCharacterRangeAttribute as CFString, rangeValue(target, targetLen)) }),
    ("set scroll bar AXValue", {
        guard let bar, let doc = frame(textArea), let view = frame(scrollArea),
              let b = rect(param(textArea, kAXBoundsForRangeParameterizedAttribute, rangeValue(target, targetLen))) else { return .failure }
        let scrollable = doc.height - view.height
        let offset = b.minY - doc.minY - view.height / 3
        return AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, max(0, min(1, offset / scrollable)) as NSNumber)
    }),
    ("set selection only", { AXUIElementSetAttributeValue(textArea, kAXSelectedTextRangeAttribute as CFString, rangeValue(target, 0)) }),
    ("set selection then restore", {
        let old = attr(textArea, kAXSelectedTextRangeAttribute)!
        let e = AXUIElementSetAttributeValue(textArea, kAXSelectedTextRangeAttribute as CFString, rangeValue(target, 0))
        AXUIElementSetAttributeValue(textArea, kAXSelectedTextRangeAttribute as CFString, old)
        return e
    }),
    ("AXScrollDownByPage on scroll area", { AXUIElementPerformAction(scrollArea, "AXScrollDownByPage" as CFString) }),
]

for (name, run) in mechanisms {
    reset()
    let before = state()
    let t = Date()
    let err = run()
    let ms = Date().timeIntervalSince(t) * 1000
    settle()
    let after = state()
    print("\n== \(name): \(err.rawValue == 0 ? "ok" : "error \(err.rawValue)") in \(String(format: "%.1f", ms)) ms")
    print("   before: \(before)")
    print("   after:  \(after)")
}
reset()
