import AppKit
import QuartzCore

/// A click-through layer above every app, used to draw highlights directly
/// on top of whatever the user is reading.
@MainActor
final class Overlay {
    enum Style { case preview, reading }

    private var panels: [NSPanel] = []
    private var layers: [CALayer] = []

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
            let layer = CALayer()
            layer.cornerRadius = 6
            layer.cornerCurve = .continuous
            layer.opacity = 0
            view.layer?.addSublayer(layer)
            panel.contentView = view
            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            panels.append(panel)
            layers.append(layer)
        }
    }

    /// Show a highlight around `axRect` (AX coordinates). Moving between
    /// rects animates, so the highlight glides from sentence to sentence.
    func show(_ axRect: CGRect, style: Style) {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let cocoa = CGRect(x: axRect.minX, y: primaryHeight - axRect.maxY, width: axRect.width, height: axRect.height)
            .insetBy(dx: -4, dy: -2)
        for (panel, layer) in zip(panels, layers) {
            guard panel.frame.intersects(cocoa) else { hide(layer); continue }
            let local = cocoa.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
            let accent = NSColor.controlAccentColor
            CATransaction.begin()
            CATransaction.setAnimationDuration(layer.opacity == 0 ? 0 : 0.18)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            layer.frame = local
            switch style {
            case .preview:
                layer.backgroundColor = accent.withAlphaComponent(0.08).cgColor
                layer.borderColor = accent.withAlphaComponent(0.55).cgColor
                layer.borderWidth = 1.5
            case .reading:
                layer.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.22).cgColor
                layer.borderWidth = 0
            }
            CATransaction.commit()
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            layer.opacity = 1
            CATransaction.commit()
        }
    }

    func hide() { layers.forEach(hide) }

    private func hide(_ layer: CALayer) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        layer.opacity = 0
        CATransaction.commit()
    }
}
