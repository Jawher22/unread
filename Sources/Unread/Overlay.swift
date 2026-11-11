import AppKit
import QuartzCore

/// Click-through panels the highlight is drawn in; the drawing itself is `HighlightLayers`, shared with the demo
/// in Settings. A reading draws in one panel the size of the window being read, at the normal window level and
/// ordered just above that window (`attach`), so it moves with the window and windows above it cover it. The
/// aiming preview, and a reading whose window isn't known, draw in one panel per screen above every app.
@MainActor
final class Overlay {
    /// `loading`: the aimed paragraph from a hold's release until the voice starts.
    enum Style { case preview, loading, reading }

    private struct Surface { let panel: NSPanel; let layers: HighlightLayers }
    private var screens: [Surface] = []
    /// The window being read and the panel just above it. Rects drawn there are relative to the window's top-left.
    private var attached: (window: CGWindowID, surface: Surface, frame: CGRect)?
    /// Panels of windows no longer read, kept on screen until their highlight has faded.
    private var fading: [Surface] = []
    /// `UNREAD_DEBUG_OVERLAY=1` logs every highlight change.
    private let debug = ProcessInfo.processInfo.environment["UNREAD_DEBUG_OVERLAY"] != nil
    private var lastLogged = ""
    private var style: HighlightStyle { HighlightSettings.shared.style }
    /// Draws every display frame while something moves or a reading is on.
    private var ticker: DisplayTicker?
    /// The reading session moves the word mark, once per frame, before drawing.
    private var frameHandler: (owner: ObjectIdentifier, tick: (CFTimeInterval) -> Void)?

    /// False in dev modes (`--simulate` without `--show-highlight`): the panels are fully transparent, so a test
    /// run never draws on the user's screen, while everything behind them (layers, frame ticks, the debug log) runs as usual.
    private let visible: Bool

    init(visible: Bool = true) {
        self.visible = visible
        rebuild()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuild()
                if let frame = self?.attached?.frame { self?.follow(frame) } // the same place, flipped against new screens
            }
        }
        // Activating the app being read raises its window above the panel.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.orderAboveWindow() }
        }
    }

    private func makePanel(_ axFrame: CGRect, level: NSWindow.Level) -> Surface {
        let frame = Self.cocoa(axFrame)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.alphaValue = visible ? 1 : 0
        // On one Space, the one it was made on: swiping to another desktop slides the highlight away with
        // the page it's on, instead of leaving it over the new one. `claimActiveSpace` moves it where a hold starts.
        // `.transient` keeps a normal-level panel out of Mission Control.
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        panel.setFrame(frame, display: false)
        return Surface(panel: panel, layers: HighlightLayers(in: view.layer!))
    }

    private func rebuild() {
        screens.forEach { $0.panel.orderOut(nil) }
        screens = NSScreen.screens.map { screen in
            let s = makePanel(Self.ax(screen.frame), level: .statusBar)
            s.panel.orderFrontRegardless()
            return s
        }
        let running = ticker?.isRunning ?? false
        ticker?.stop()
        // Frames paced by the main screen's display (120 Hz on ProMotion).
        ticker = screens.first.map { s in DisplayTicker(view: s.panel.contentView!) { [weak self] t in self?.frame(t) } }
        if running { ticker?.start() }
    }

    // MARK: The window being read

    /// Draw the reading highlight in a panel over `window`, which is at `frame` now.
    func attach(to window: CGWindowID, at frame: CGRect) {
        if attached?.window == window { follow(frame); return }
        detach()
        attached = (window, makePanel(frame, level: .normal), frame)
        log(String(format: "attached to window %d at (%d,%d %dx%d)", window, Int(frame.minX), Int(frame.minY), Int(frame.width), Int(frame.height)))
        orderAboveWindow()
    }

    /// The window moved or was resized: the panel goes with it, and what it shows moves along.
    func follow(_ frame: CGRect) {
        guard let a = attached else { return }
        attached?.frame = frame
        let to = Self.cocoa(frame)
        guard a.surface.panel.frame != to else { return }
        a.surface.panel.setFrame(to, display: false)
        log(String(format: "window at (%d,%d %dx%d)", Int(frame.minX), Int(frame.minY), Int(frame.width), Int(frame.height)), precise: true)
    }

    /// Order the panel just above the window being read, if that window is on screen: on attaching, on each
    /// hold, when an app activates, and when the window comes back or is found above the panel.
    func orderAboveWindow() {
        guard let a = attached, let place = WindowPlace.of(a.window), place.onScreen else { return }
        if !a.surface.panel.isOnActiveSpace { // the window is here now, the panel on the Space it was made on
            a.surface.panel.orderOut(nil)
            attached = (a.window, makePanel(place.frame, level: .normal), place.frame)
        }
        attached!.surface.panel.order(.above, relativeTo: Int(a.window))
        log("ordered above window \(a.window)")
    }

    /// The panel's window number, for `WindowWatch` to check the order.
    var attachedPanel: CGWindowID? { attached.map { CGWindowID($0.surface.panel.windowNumber) } }

    /// The reading is over: its panel goes once its highlight has faded.
    func detach() {
        guard let a = attached else { return }
        attached = nil
        a.surface.layers.hide(at: now)
        fading.append(a.surface)
        changed()
    }

    // MARK: Drawing

    /// Puts the screen panels on the current Space (a hold starting there), making them afresh if they're on another,
    /// and the reading's panel back above its window.
    func claimActiveSpace() {
        if screens.contains(where: { !$0.panel.isOnActiveSpace }) { rebuild() }
        orderAboveWindow()
    }

    /// Called every frame until `clearFrameHandler`, with the frame's display time.
    func setFrameHandler(_ owner: AnyObject, _ tick: @escaping (CFTimeInterval) -> Void) {
        frameHandler = (ObjectIdentifier(owner), tick)
        ticker?.start()
    }

    func clearFrameHandler(_ owner: AnyObject) {
        if frameHandler?.owner == ObjectIdentifier(owner) { frameHandler = nil }
    }

    private func frame(_ t: CFTimeInterval) {
        frameHandler?.tick(t)
        var moving = false
        for s in screens + (attached.map { [$0.surface] } ?? []) where s.layers.render(at: t) { moving = true }
        fading.removeAll { s in
            if s.layers.render(at: t) { moving = true; return false }
            s.panel.orderOut(nil)
            return true
        }
        if !moving, frameHandler == nil { ticker?.stop() }
    }

    private func changed() { ticker?.start() }
    private var now: CFTimeInterval { CACurrentMediaTime() }

    /// Show a highlight around `axRect` (AX coordinates).
    func show(_ axRect: CGRect, style kind: Style) { show([axRect], style: kind) }

    /// A sentence's lines (or the aimed paragraph). The same `id` again moves it in place; a new one transitions
    /// to it. The preview is in AX coordinates; a reading's lines are relative to its window's top-left once
    /// `attach`ed, else in AX coordinates too.
    func show(_ rects: [CGRect], style kind: Style, id: Int? = nil) {
        log("show \(kind) " + rects.map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" }.joined(separator: " "))
        guard !rects.isEmpty else { hide(); return }
        let layerKind: HighlightLayers.Kind = switch kind { case .preview: .preview; case .loading: .loading; case .reading: .reading }
        if kind == .reading, let a = attached {
            screens.forEach { $0.layers.hideSentence(at: now) }
            let mine = rects.map { local($0, in: a.surface) }
            a.surface.layers.showSentence(mine, kind: layerKind, style: style, id: id, at: now)
        } else {
            attached?.surface.layers.hideSentence(at: now)
            for s in screens {
                let mine = rects.map { local($0, in: s) }.filter { s.panel.contentView!.bounds.intersects($0) }
                if mine.isEmpty { s.layers.hideSentence(at: now) } else { s.layers.showSentence(mine, kind: layerKind, style: style, id: id, at: now) }
            }
        }
        changed()
    }

    /// The voice has started: the loading box goes (the reading's highlight takes its place).
    func endLoading() {
        screens.forEach { $0.layers.hideLoading(at: now) }
        changed()
    }

    func hide() {
        log("hide")
        (screens + (attached.map { [$0.surface] } ?? [])).forEach { $0.layers.hide(at: now) }
        changed()
    }

    /// The word mark (#20) for this frame, in a reading's coordinates (see `show`); nil: none.
    func showWord(_ frame: WordMarkFrame?) {
        for s in attached.map({ [$0.surface] }) ?? screens {
            guard let frame else { s.layers.showWord(nil, style: style, at: now); continue }
            let origin = attached == nil ? s.panel.frame.minX : 0
            func mine(_ shape: MarkShape) -> MarkShape {
                var m = shape
                m.rect = local(shape.rect, in: s)
                m.tail = shape.tail.map { $0 - origin }
                return m
            }
            let head = mine(frame.head)
            guard s.panel.contentView!.bounds.intersects(head.rect) else { s.layers.showWord(nil, style: style, at: now); continue }
            s.layers.showWord(WordMarkFrame(head: head, ghost: frame.ghost.map(mine)), style: style, at: now)
        }
        changed()
    }

    func hideWord() {
        (screens + (attached.map { [$0.surface] } ?? [])).forEach { $0.layers.hideWord(at: now) }
        changed()
    }

    /// Into the panel's layer (origin bottom-left of the panel): from AX coordinates (origin top-left of the
    /// primary screen) for a screen panel, from the window's top-left for the reading's panel.
    private func local(_ r: CGRect, in s: Surface) -> CGRect {
        let height = s.panel.frame.height
        if attached?.surface.panel === s.panel { return CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height) }
        let top = Self.ax(s.panel.frame).minY
        return CGRect(x: r.minX - s.panel.frame.minX, y: height - (r.maxY - top), width: r.width, height: r.height)
    }

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
    /// AX (top-left origin) ⇄ Cocoa (bottom-left origin) screen rects; the flip is its own inverse.
    private static func cocoa(_ ax: CGRect) -> NSRect { NSRect(x: ax.minX, y: primaryHeight - ax.maxY, width: ax.width, height: ax.height) }
    private static func ax(_ cocoa: NSRect) -> CGRect { Self.cocoa(cocoa) }

    /// `precise`: the panel following its window, many a second, timed to the ms and not counted as a change.
    private func log(_ line: String, precise: Bool = false) {
        guard debug, precise || line != lastLogged else { return }
        if !precise { lastLogged = line }
        let t = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)
        print(String(format: precise ? "[overlay %.3f] " : "[overlay %.2f] ", t) + line)
    }
}
