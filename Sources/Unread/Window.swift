import AppKit
import CoreGraphics

/// Where the window being read is, as the window server knows it (AX coordinates: top-left of the primary screen).
struct WindowPlace: Equatable, Sendable {
    var frame: CGRect
    /// On this Space, not minimized or hidden.
    var onScreen: Bool

    /// One window-server query, ~0.1 ms. Any thread.
    static func of(_ id: CGWindowID) -> WindowPlace? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let bounds = info[kCGWindowBounds as String].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) })
        else { return nil }
        return WindowPlace(frame: bounds, onScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }

    /// Whether `window` is in front of `panel` on screen. Any thread.
    static func isAbove(_ window: CGWindowID, _ panel: CGWindowID) -> Bool {
        let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], panel) as? [[String: Any]] ?? []
        return above.contains { ($0[kCGWindowNumber as String] as? Int).map(CGWindowID.init) == window }
    }
}

/// Polls one window's place off the main thread and reports each change on the main actor. Accessibility
/// says a window moved only once a drag is over, so the window server is asked: 120 times a second while a mouse
/// button is down or the window moved in the last half second (a drag, an animated tiling move), else 30. Every
/// tenth of a second it also checks that the window hasn't been raised above the highlight's panel.
final class WindowWatch: @unchecked Sendable {
    let id: CGWindowID
    private let queue = DispatchQueue(label: "unread.window-watch", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    // On `queue`.
    private var last: WindowPlace?
    private var movedAt = -Double.infinity
    private var checkedOrderAt = -Double.infinity
    private var interval = 0.0
    private var panel: CGWindowID?
    private let changed: @MainActor (WindowPlace) -> Void
    private let raised: @MainActor () -> Void
    private static let fast = 1.0 / 120, slow = 1.0 / 30

    init(_ id: CGWindowID, changed: @escaping @MainActor (WindowPlace) -> Void, raised: @escaping @MainActor () -> Void) {
        self.id = id
        self.changed = changed
        self.raised = raised
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        queue.async { self.pace(Self.slow) }
        t.resume()
    }

    /// The panel the highlight is drawn in, to keep above the window; nil: none.
    func keepBelow(_ panel: CGWindowID?) { queue.async { self.panel = panel } }

    func stop() { queue.sync { timer?.cancel(); timer = nil } }

    deinit { timer?.cancel() }

    private func pace(_ every: Double) {
        guard every != interval else { return }
        interval = every
        timer?.schedule(deadline: .now() + every, repeating: every, leeway: .milliseconds(every == Self.fast ? 1 : 4))
    }

    private func poll() {
        let now = CACurrentMediaTime()
        let place = WindowPlace.of(id) ?? WindowPlace(frame: last?.frame ?? .zero, onScreen: false)
        if place != last {
            if let last, last.frame != place.frame { movedAt = now }
            last = place
            let changed = changed
            DispatchQueue.main.async { MainActor.assumeIsolated { changed(place) } }
        }
        if now - checkedOrderAt >= 0.1 {
            checkedOrderAt = now
            if place.onScreen, let panel, WindowPlace.isAbove(id, panel) {
                let raised = raised
                DispatchQueue.main.async { MainActor.assumeIsolated { raised() } }
            }
        }
        pace(now - movedAt < 0.5 || CGEventSource.buttonState(.combinedSessionState, button: .left) ? Self.fast : Self.slow)
    }
}
