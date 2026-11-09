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

    /// Inside a hold's speculation (`PrimedSentence`): a document mustn't wait there for content still loading,
    /// since the hold's lookups queue behind it on this queue. AXWorker only.
    nonisolated(unsafe) static var speculating = false
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

    /// Accessibility calls made, each a message to the app (`--at` counts what a lookup costs). Not synchronized:
    /// AXWorker's count, or a dev mode's.
    nonisolated(unsafe) static var calls = 0

    static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        calls &+= 1
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    static func param(_ e: AXUIElement, _ name: String, _ p: AnyObject) -> AnyObject? {
        var v: AnyObject?
        calls &+= 1
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

    /// `v` as an `AXValue`, checked by its type rather than force-cast.
    private static func axValue(_ v: AnyObject?) -> AXValue? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(v, to: AXValue.self)
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = axValue(attr(e, kAXPositionAttribute)), let s = axValue(attr(e, kAXSizeAttribute)) else { return nil }
        var o = CGPoint.zero, z = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &o), AXValueGetValue(s, .cgSize, &z) else { return nil }
        return CGRect(origin: o, size: z)
    }

    static func rect(_ v: AnyObject?) -> CGRect? {
        guard let v = axValue(v) else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(v, .cgRect, &r), r.width > 0, r.height > 0 else { return nil }
        return r
    }

    static func range(_ v: AnyObject?) -> NSRange? {
        guard let v = axValue(v) else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v, .cfRange, &r), r.location >= 0, r.length >= 0 else { return nil }
        return NSRange(location: r.location, length: r.length)
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
        // Not AXEnhancedUserInterface here: held at true, AppKit animates every window move.
        // Electron honours this one; Chromium browsers refuse it and get `pulseScreenReader`.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// What a page with no text positions can expect from `pulseScreenReader`.
    enum Pulse {
        /// Pulsed at this time: Chromium switches ~2.05 s later, if it still works this way.
        case sent(Date)
        /// Pulsed under 10 s ago and the positions are gone again: ask again then.
        case later(Date)
        /// Not to be pulsed: not built on Chromium, VoiceOver is on, or another assistive tool holds the flag.
        case never
    }

    /// Chromium browsers (Aside, Chrome, Arc, Dia) build inline text boxes, so text ranges have bounds, only in
    /// their screen-reader mode, which only AXEnhancedUserInterface turns on. Held at true, that flag makes AppKit
    /// animate every window move. Chromium counts the requests (+1 per true, −1 per false), re-arms a 2 s timer on
    /// each, and when it fires with the count above 0 sets it to 0 and switches complete + screen-reader mode on
    /// for the whole process, for good. So true, true, false back to back: the count goes 1, 2, 1, the mode comes
    /// on 2.05 s later, and AppKit's flag ends at 0. A false while the count is 0 switches the mode off at once:
    /// never send one alone. All three calls answer −25208 (not implemented), from AppKit's super; they still
    /// take effect. Electron gets AXManualAccessibility instead: it gives its positions (~1–3 s later), and Electron
    /// doesn't answer the pulse alike in every release (44 ignores it). `enableTree` leaves a tree another client
    /// woke alone, and that tree has no positions (T3 Code on 2026-11-09).
    private static var pulsedAt: [pid_t: Date] = [:]
    /// For the fixture host (`--pulse-electron`): Electron 39 answers the pulse as Chrome does.
    nonisolated(unsafe) static var pulsesElectron = false

    static func pulseScreenReader(_ pid: pid_t) -> Pulse {
        guard let engine = chromium(pid), !NSWorkspace.shared.isVoiceOverEnabled else { return .never }
        let now = Date()
        if let last = pulsedAt[pid] {
            if now < last + 4 { return .sent(last) }
            if now < last + 10 { return .later(last + 10) }
        }
        let app = AXUIElementCreateApplication(pid)
        if engine == .electron, !pulsesElectron {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            calls &+= 1
            enabledAt[pid] = now
            pulsedAt[pid] = now
            print("[unread] pid \(pid) gives no text positions; asked Electron for its full tree (AXManualAccessibility)")
            return .sent(now)
        }
        if enhancedUserInterface(app) { return .never }
        let flag = "AXEnhancedUserInterface" as CFString
        AXUIElementSetAttributeValue(app, flag, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, flag, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, flag, kCFBooleanFalse)
        calls &+= 3
        // Something else set it between our calls: one more on, off leaves the count as it was and the flag at 0.
        if enhancedUserInterface(app) {
            AXUIElementSetAttributeValue(app, flag, kCFBooleanTrue)
            AXUIElementSetAttributeValue(app, flag, kCFBooleanFalse)
            calls &+= 2
        }
        pulsedAt[pid] = now
        print("[unread] pid \(pid) gives no text positions; asked for Chromium's screen-reader mode (AXEnhancedUserInterface on, on, off)")
        return .sent(now)
    }

    /// The positions didn't come after a pulse: this Chromium may no longer work that way. Logged once per process.
    private static var pulseFailed: Set<pid_t> = []
    static func pulseDidNotWork(_ pid: pid_t) {
        guard pulseFailed.insert(pid).inserted else { return }
        print("[unread] the screen-reader pulse gave pid \(pid) no text positions; highlighting whole text blocks, and asking again in a minute")
    }

    private static func enhancedUserInterface(_ app: AXUIElement) -> Bool { (attr(app, "AXEnhancedUserInterface") as? Bool) ?? false }

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

    /// Chromium browsers (Aside, Chrome, Arc…) refuse AXManualAccessibility (−25205) and build a
    /// page's tree only once a client walks into the window, and switch it off again when it goes
    /// unused. Their window stays an AXWindow with the browser's own controls, so `treeLooksAlive`
    /// can't tell. After Aside relaunched, every hold hit an empty AXScrollArea where the page was.
    /// So when a window holds no web area, walk it (that is what wakes the page) and wait up to
    /// `timeout` for one to appear; at most every 2 s per app, so pointing at the browser's
    /// toolbar doesn't hold up the aim loop.
    private static var wokenAt: [pid_t: Date] = [:]
    static func wakeWebArea(in window: AXUIElement, timeout: TimeInterval = 1.5) -> AXUIElement? {
        let pid = pid(window)
        guard isChromium(pid) else { return nil }
        let webArea: (AXUIElement, String) -> Bool = { _, r in r == "AXWebArea" }
        if let area = find(in: window, maxNodes: 600, webArea) { return area }
        guard Date().timeIntervalSince(wokenAt[pid] ?? .distantPast) > 2 else { return nil }
        wokenAt[pid] = Date()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            if let area = find(in: window, maxNodes: 600, webArea) {
                print("[unread] woke the page's accessibility tree in pid \(pid)")
                return area
            }
        }
        return nil
    }

    enum Chromium { case electron, browser }
    /// Built on Chromium: Electron apps and Chromium browsers ship their engine as
    /// `Contents/Frameworks/<name> Framework.framework`, Electron's named so.
    private static var engines: [pid_t: Chromium?] = [:]
    static func chromium(_ pid: pid_t) -> Chromium? {
        if let known = engines[pid] { return known }
        let frameworks = NSRunningApplication(processIdentifier: pid)?.bundleURL?.appendingPathComponent("Contents/Frameworks")
        let names = frameworks.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
        let engine: Chromium? = names.contains("Electron Framework.framework") ? .electron
            : names.contains { $0.hasSuffix(" Framework.framework") } ? .browser : nil
        engines[pid] = engine
        return engine
    }
    static func isChromium(_ pid: pid_t) -> Bool { chromium(pid) != nil }

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
