import AppKit
import ApplicationServices

/// Where all Accessibility work runs (#12). AX calls are synchronous IPC
/// into the target app: tens of milliseconds on a busy Chromium page, up to
/// the 0.25 s timeout on a hung one. Documents are confined to this serial
/// queue; the main thread only draws the overlay and handles the hotkey.
final class AXWorker: @unchecked Sendable {
    static let shared = AXWorker()
    private let queue = DispatchQueue(label: "unread.ax", qos: .userInitiated)

    func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    func async(_ work: @escaping () -> Void) { queue.async(execute: work) }
}

/// An AXUIElement usable as a dictionary key (CFEqual / CFHash identity).
struct AXKey: Hashable {
    let element: AXUIElement
    static func == (a: AXKey, b: AXKey) -> Bool { CFEqual(a.element, b.element) }
    func hash(into h: inout Hasher) { h.combine(CFHash(element)) }
}

/// Thin helpers over the Accessibility C API. All coordinates are AX
/// coordinates: global, origin at the top-left of the primary screen.
enum AX {
    static let systemWide: AXUIElement = {
        let e = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(e, 0.25)
        return e
    }()

    static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    static func param(_ e: AXUIElement, _ name: String, _ p: AnyObject) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyParameterizedAttributeValue(e, name as CFString, p, &v) == .success ? v : nil
    }

    static func role(_ e: AXUIElement) -> String? { attr(e, kAXRoleAttribute) as? String }
    static func subrole(_ e: AXUIElement) -> String? { attr(e, kAXSubroleAttribute) as? String }
    static func parent(_ e: AXUIElement) -> AXUIElement? { element(attr(e, kAXParentAttribute)) }
    static func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

    static func element(_ v: AnyObject?) -> AXUIElement? {
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func pid(_ e: AXUIElement) -> pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(e, &p)
        return p
    }

    static func element(at point: CGPoint) -> AXUIElement? {
        var e: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &e) == .success else { return nil }
        return e
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
        var o = CGPoint.zero, z = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &o)
        AXValueGetValue(s as! AXValue, .cgSize, &z)
        return CGRect(origin: o, size: z)
    }

    static func rect(_ v: AnyObject?) -> CGRect? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &r), r.width > 0, r.height > 0 else { return nil }
        return r
    }

    static func pointValue(_ p: CGPoint) -> AXValue {
        var p = p
        return AXValueCreate(.cgPoint, &p)!
    }

    static func rangeValue(_ r: NSRange) -> AXValue {
        var cf = CFRange(location: r.location, length: r.length)
        return AXValueCreate(.cfRange, &cf)!
    }

    static func rectValue(_ r: CGRect) -> AXValue {
        var r = r
        return AXValueCreate(.cgRect, &r)!
    }

    /// Chromium and Electron only build their accessibility tree once a
    /// client asks for it, and recent Chromium switches it off again after a
    /// while without use (auto-disable). The flag can't be read back (it
    /// always reads false), so judge by the tree itself: switched off, the
    /// app's "focused window" comes back as a stub (an AXApplication, not an
    /// AXWindow). Re-enable only then, and at most every 10 s: setting the
    /// flag restarts Chromium's tree build, so setting it repeatedly means the
    /// tree never finishes.
    private static var enabledAt: [pid_t: Date] = [:]
    static func enableTree(for pid: pid_t) {
        guard pid > 0, pid != getpid() else { return }
        if let last = enabledAt[pid] {
            guard Date().timeIntervalSince(last) > 10, !treeLooksAlive(pid) else { return }
            print("[unread] accessibility tree of pid \(pid) was switched off; re-enabling")
        } else if treeLooksAlive(pid, strict: true) {
            // Already on (another client, or a previous run of Unread): leave
            // it alone rather than restart its build.
            enabledAt[pid] = .distantPast
            return
        }
        enabledAt[pid] = Date()
        let app = AXUIElementCreateApplication(pid)
        // Deliberately not AXEnhancedUserInterface: it breaks window
        // animations in some apps. Chromium/Electron honour this one.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// `strict` (first contact): the tree must already contain a web area. A
    /// Chromium window whose tree was never built still shows an AXWindow with
    /// native groups, just no web content. (Native apps fail this too, and
    /// setting the flag on them is harmless.)
    private static func treeLooksAlive(_ pid: pid_t, strict: Bool = false) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let window = element(attr(app, kAXFocusedWindowAttribute)) ?? element(attr(app, kAXMainWindowAttribute))
                ?? (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first else {
            return !strict // no window to judge by (or not a windowed app)
        }
        guard role(window) == kAXWindowRole else { return false }
        return !strict || find(in: window, maxNodes: 300) { _, r in r == "AXWebArea" } != nil
    }

    static func mouseLocation() -> CGPoint {
        let m = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: m.x, y: primaryHeight - m.y)
    }

    /// Depth-first (document order) search, bounded, for the first element matching `match`.
    static func firstInOrder(in root: AXUIElement, maxNodes: Int, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
        var stack = [root]
        var seen = 0
        while let e = stack.popLast(), seen < maxNodes {
            seen += 1
            if match(e) { return e }
            stack.append(contentsOf: children(e).reversed())
        }
        return nil
    }

    /// Breadth-first search, bounded, for the first element matching `match`.
    static func find(in root: AXUIElement, maxNodes: Int = 4000, _ match: (AXUIElement, String) -> Bool) -> AXUIElement? {
        var queue = [root]
        var seen = 0
        while !queue.isEmpty, seen < maxNodes {
            let e = queue.removeFirst()
            seen += 1
            if let r = role(e), match(e, r) { return e }
            queue.append(contentsOf: children(e))
        }
        return nil
    }
}
