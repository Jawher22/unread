import AppKit
import QuartzCore

/// A click-through layer above every app, used to draw highlights directly
/// on top of whatever the user is reading.
@MainActor
final class Overlay {
    enum Style { case preview, reading }

    private var panels: [NSPanel] = []
    private var layers: [CAShapeLayer] = []
    /// Rects per panel last shown, to decide whether the shape can glide.
    private var shownCounts: [Int] = []

    init() {
        rebuild()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    private func rebuild() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        layers = []
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            let layer = CAShapeLayer()
            layer.fillRule = .nonZero // overlapping line boxes fill once, no darker seams
            layer.opacity = 0
            view.layer?.addSublayer(layer)
            panel.contentView = view
            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            panels.append(panel)
            layers.append(layer)
        }
        shownCounts = Array(repeating: 0, count: layers.count)
    }

    /// Show a highlight around `axRect` (AX coordinates).
    func show(_ axRect: CGRect, style: Style) { show([axRect], style: style) }

    /// Show a highlight made of several boxes (a sentence's lines), drawn as
    /// one shape. Moving between highlights with the same number of boxes
    /// animates, so the highlight glides from sentence to sentence.
    /// `UNREAD_DEBUG_OVERLAY=1` logs every highlight change.
    private let debug = ProcessInfo.processInfo.environment["UNREAD_DEBUG_OVERLAY"] != nil
    private var lastLogged = ""

    func show(_ axRects: [CGRect], style: Style) {
        if debug {
            let line = "\(style) " + axRects.map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" }.joined(separator: " ")
            if line != lastLogged { print(String(format: "[overlay %.2f] show ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) + line); lastLogged = line }
        }
        guard !axRects.isEmpty else { hide(); return }
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let cocoa = axRects.map {
            CGRect(x: $0.minX, y: primaryHeight - $0.maxY, width: $0.width, height: $0.height).insetBy(dx: -4, dy: -2)
        }
        for (i, (panel, layer)) in zip(panels, layers).enumerated() {
            let mine = cocoa.filter { panel.frame.intersects($0) }
            guard !mine.isEmpty else { hide(layer); shownCounts[i] = 0; continue }
            let path = CGMutablePath()
            for r in mine {
                path.addRoundedRect(in: r.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY), cornerWidth: 5, cornerHeight: 5)
            }
            let accent = NSColor.controlAccentColor
            CATransaction.begin()
            // Paths only morph cleanly between the same number of boxes; otherwise jump.
            let glide = layer.opacity > 0 && shownCounts[i] == mine.count
            CATransaction.setAnimationDuration(glide ? 0.18 : 0)
            CATransaction.setDisableActions(!glide)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            layer.path = path
            switch style {
            case .preview:
                layer.fillColor = accent.withAlphaComponent(0.08).cgColor
                layer.strokeColor = accent.withAlphaComponent(0.55).cgColor
                layer.lineWidth = 1.5
            case .reading:
                layer.fillColor = NSColor.systemYellow.withAlphaComponent(0.22).cgColor
                layer.strokeColor = nil
                layer.lineWidth = 0
            }
            CATransaction.commit()
            shownCounts[i] = mine.count
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            layer.opacity = 1
            CATransaction.commit()
        }
    }

    func hide() {
        if debug, lastLogged != "hidden" { print(String(format: "[overlay %.2f] hide", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))); lastLogged = "hidden" }
        layers.forEach(hide)
        shownCounts = shownCounts.map { _ in 0 }
    }

    private func hide(_ layer: CAShapeLayer) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        layer.opacity = 0
        CATransaction.commit()
    }
}
