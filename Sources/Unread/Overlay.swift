import AppKit
import QuartzCore

/// A click-through layer above every app, used to draw highlights directly
/// on top of whatever the user is reading. One panel per screen; the drawing
/// itself is `HighlightLayers`, shared with the demo in Settings.
@MainActor
final class Overlay {
    enum Style { case preview, reading }

    private var panels: [(panel: NSPanel, layers: HighlightLayers)] = []
    /// `UNREAD_DEBUG_OVERLAY=1` logs every highlight change.
    private let debug = ProcessInfo.processInfo.environment["UNREAD_DEBUG_OVERLAY"] != nil
    private var lastLogged = ""
    private var style: HighlightStyle { HighlightSettings.shared.style }
    /// Draws every display frame while something moves or a reading is on.
    private var ticker: DisplayTicker?
    /// The reading session moves the word mark, once per frame, before drawing.
    private var frameHandler: (owner: ObjectIdentifier, tick: (CFTimeInterval) -> Void)?

    init() {
        rebuild()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    private func rebuild() {
        panels.forEach { $0.panel.orderOut(nil) }
        panels = NSScreen.screens.map { screen in
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            panel.contentView = view
            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            return (panel, HighlightLayers(in: view.layer!))
        }
        let running = ticker?.isRunning ?? false
        ticker?.stop()
        // Frames paced by the main screen's display (120 Hz on ProMotion).
        ticker = panels.first.map { p in DisplayTicker(view: p.panel.contentView!) { [weak self] t in self?.frame(t) } }
        if running { ticker?.start() }
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
        for p in panels where p.layers.render(at: t) { moving = true }
        if !moving, frameHandler == nil { ticker?.stop() }
    }

    private func changed() { ticker?.start() }
    private var now: CFTimeInterval { CACurrentMediaTime() }

    /// Show a highlight around `axRect` (AX coordinates).
    func show(_ axRect: CGRect, style kind: Style) { show([axRect], style: kind) }

    /// A sentence's lines (or the aimed paragraph), in AX coordinates. The
    /// same `id` again moves it in place; a new one transitions to it.
    func show(_ axRects: [CGRect], style kind: Style, id: Int? = nil) {
        if debug {
            let line = "\(kind) " + axRects.map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" }.joined(separator: " ")
            if line != lastLogged { print(String(format: "[overlay %.2f] show ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) + line); lastLogged = line }
        }
        guard !axRects.isEmpty else { hide(); return }
        for p in panels {
            let mine = axRects.map { local($0, in: p.panel) }.filter { p.panel.contentView!.bounds.intersects($0) }
            if mine.isEmpty { p.layers.hideSentence(at: now) } else { p.layers.showSentence(mine, kind: kind == .preview ? .preview : .reading, style: style, id: id, at: now) }
        }
        changed()
    }

    func hide() {
        if debug, lastLogged != "hidden" { print(String(format: "[overlay %.2f] hide", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))); lastLogged = "hidden" }
        panels.forEach { $0.layers.hide(at: now) }
        changed()
    }

    /// The word mark (#20) for this frame, in AX coordinates; nil: none.
    func showWord(_ frame: WordMarkFrame?) {
        for p in panels {
            guard let frame else { p.layers.showWord(nil, style: style, at: now); continue }
            let bounds = p.panel.contentView!.bounds
            func mine(_ s: MarkShape) -> MarkShape {
                var m = s
                m.rect = local(s.rect, in: p.panel)
                m.tail = s.tail.map { $0 - p.panel.frame.minX }
                return m
            }
            let head = mine(frame.head)
            guard bounds.intersects(head.rect) else { p.layers.showWord(nil, style: style, at: now); continue }
            p.layers.showWord(WordMarkFrame(head: head, ghost: frame.ghost.map(mine)), style: style, at: now)
        }
        changed()
    }

    func hideWord() {
        panels.forEach { $0.layers.hideWord(at: now) }
        changed()
    }

    /// AX coordinates (origin top-left of the primary screen) → the panel's
    /// layer (origin bottom-left of its screen).
    private func local(_ ax: CGRect, in panel: NSPanel) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: ax.minX - panel.frame.minX, y: primaryHeight - ax.maxY - panel.frame.minY, width: ax.width, height: ax.height)
    }
}
