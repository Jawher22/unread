import AppKit

/// Watches a modifier key (⌃ Control by default) held on its own: press,
/// release, and "the user was actually doing something else" cancellation.
@MainActor
final class ModifierHotkey {
    var onPress: () -> Void = {}
    var onRelease: (_ heldFor: TimeInterval) -> Void = { _ in }
    var onCancel: () -> Void = {}

    private let keyCodes: Set<UInt16>
    private let flag: NSEvent.ModifierFlags
    private var isDown = false
    private var cancelled = false
    private var pressedAt = Date()
    private var monitors: [Any] = []

    /// 59 = left control, 62 = right control (MacBook keyboards only have
    /// the left one). 58/61 = option, 55/54 = command.
    init(keyCodes: Set<UInt16> = [59, 62], flag: NSEvent.ModifierFlags = .control) {
        self.keyCodes = keyCodes
        self.flag = flag
        // Mouse and scroll events matter too: ⌃-click is a right-click and
        // ⌃-scroll is zoom. Neither should start reading.
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }) { monitors.append(l) }
    }

    private func handle(_ e: NSEvent) {
        if e.type == .flagsChanged, keyCodes.contains(e.keyCode) {
            let down = e.modifierFlags.contains(flag)
            let othersHeld = !e.modifierFlags.intersection([.command, .option, .shift, .function]).isEmpty
            if down, !isDown {
                isDown = true
                cancelled = othersHeld // ⌃ added to an existing chord, not a solo press
                pressedAt = Date()
                if !cancelled { onPress() }
            } else if !down, isDown {
                isDown = false
                if !cancelled { onRelease(Date().timeIntervalSince(pressedAt)) }
            }
            return
        }
        // Anything else while ours is held means it's a chord (⌃C, ⌃⌘…),
        // a ⌃-click, or a ⌃-scroll zoom: not a request to read.
        if isDown, !cancelled {
            cancelled = true
            onCancel()
        }
    }
}
