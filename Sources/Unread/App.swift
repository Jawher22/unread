import AppKit
import ApplicationServices
import ServiceManagement

/// The interaction:
///   hold ⌃ Control → the paragraph under the pointer lights up
///   release        → read from that paragraph to the end
///   tap            → idle: nothing (a stray tap must never start talking)
///                    reading: pause / resume
///   double-tap     → idle: read from the top of what's visible
///                    reading: stop
@MainActor
final class AppController: NSObject {
    private let overlay = Overlay()
    private let player = Player()
    private let voice = Voice()
    private let hotkey = ModifierHotkey()
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var accessibilityItem: NSMenuItem!
    private var loginItem: NSMenuItem?
    private var trustTimer: Timer?

    private var session: ReadingSession?
    private var ready = false
    private var speed: Float = 1.0

    // Aiming state while the key is held.
    private var aimTimer: Timer?
    private var aimDocument: ReadableDocument?
    private var aimResolvedAt = CGPoint(x: -1e6, y: -1e6)
    private var aimTarget: (document: ReadableDocument, start: AnyObject)?
    private var lastTapAt = Date.distantPast

    private let holdThreshold: TimeInterval = 0.22
    private let previewDelay: TimeInterval = 0.12
    private let doubleTapWindow: TimeInterval = 0.35

    override init() {
        super.init()
        setUpMenu()
        hotkey.onPress = { [weak self] in self?.keyDown() }
        hotkey.onRelease = { [weak self] held in self?.keyUp(held: held) }
        hotkey.onCancel = { [weak self] in self?.endAiming() }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            // Ask Chromium/Electron apps to build their AX tree before we need it.
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                MainActor.assumeIsolated { AX.enableTree(for: app.processIdentifier) }
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication { AX.enableTree(for: front.processIdentifier) }

        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        print("[unread] accessibility trusted: \(trusted)")
        if !trusted { waitForAccessibility() }
        configureLoginItemOnFirstRun()
        loadModels()
    }

    // MARK: Permissions

    /// The key monitors are dead until Accessibility is granted. Poll for the
    /// grant and bring them up as soon as it lands, so no relaunch is needed.
    private func waitForAccessibility() {
        accessibilityItem.isHidden = false
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.trustTimer?.invalidate()
                self.trustTimer = nil
                self.accessibilityItem.isHidden = true
                self.hotkey.start()
                if let front = NSWorkspace.shared.frontmostApplication { AX.enableTree(for: front.processIdentifier) }
                print("[unread] accessibility granted")
            }
        }
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: Launch at login

    /// Only meaningful when running as Unread.app (not the bare dev binary).
    private var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    /// The first time the app runs as a bundle, turn launch-at-login on: it's
    /// a background utility, it should just be there. The menu toggle wins after that.
    private func configureLoginItemOnFirstRun() {
        let key = "loginItemConfigured"
        guard isBundled, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setLaunchAtLogin(true)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            print("[unread] launch at login \(on ? "register" : "unregister") failed: \(error)")
        }
        updateLoginItem()
    }

    private func updateLoginItem() {
        guard let loginItem else { return }
        switch SMAppService.mainApp.status {
        case .enabled: loginItem.state = .on; loginItem.title = "Launch at Login"
        case .requiresApproval: loginItem.state = .mixed; loginItem.title = "Launch at Login (approve in System Settings)"
        default: loginItem.state = .off; loginItem.title = "Launch at Login"
        }
    }

    @objc private func toggleLaunchAtLogin() {
        switch SMAppService.mainApp.status {
        case .enabled: setLaunchAtLogin(false)
        case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
        default: setLaunchAtLogin(true)
        }
    }

    // MARK: Models

    private func loadModels() {
        setStatus("Loading voice… (first run downloads the model)")
        Task {
            let t = Date()
            do {
                try await voice.prepareEnglish()
                ready = true
                print(String(format: "[unread] English voice ready in %.1fs", Date().timeIntervalSince(t)))
                setStatus("Hold ⌃ and point to read")
            } catch {
                print("[unread] failed to load English voice: \(error)")
                setStatus("Voice failed to load — see terminal")
            }
            do {
                try await voice.prepareFrench()
                print("[unread] French voice ready")
            } catch {
                print("[unread] French voice unavailable: \(error)")
            }
        }
    }

    // MARK: Hotkey

    private func keyDown() {
        guard ready else { NSSound.beep(); return }
        player.warm() // open the audio device now, not on release
        aimTarget = nil
        aimDocument = nil
        aimResolvedAt = CGPoint(x: -1e6, y: -1e6)
        aimTimer?.invalidate()
        aimTimer = Timer.scheduledTimer(withTimeInterval: previewDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginAiming() }
        }
    }

    private func beginAiming() {
        session?.setHighlightSuspended(true)
        aim()
        aimTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.aim() }
        }
    }

    private func aim() {
        let p = AX.mouseLocation()
        // Re-resolving the document walks the AX tree; only do it when the
        // pointer has really moved. Paragraph lookup is cheap, do it every frame.
        if aimDocument == nil || hypot(p.x - aimResolvedAt.x, p.y - aimResolvedAt.y) > 40 {
            aimDocument = DocumentFinder.document(at: p)
            aimResolvedAt = p
        }
        if let doc = aimDocument, let para = doc.paragraph(at: p) {
            aimTarget = (doc, para.start)
            overlay.show(para.bounds, style: .preview)
        } else {
            aimTarget = nil
            overlay.hide()
        }
    }

    private func endAiming() {
        aimTimer?.invalidate()
        aimTimer = nil
        overlay.hide()
        session?.setHighlightSuspended(false)
    }

    private func keyUp(held: TimeInterval) {
        guard ready else { return }
        let target = aimTarget
        endAiming()
        let releasedAt = Date()

        if held >= holdThreshold {
            // Point-and-hold: read from the paragraph we were aiming at.
            if let target { startReading(target.document, from: target.start, releasedAt: releasedAt) }
            return
        }

        // Tap. A double-tap consumes both taps, so a third quick tap starts a
        // new sequence instead of undoing what the double-tap just did.
        let isDoubleTap = releasedAt.timeIntervalSince(lastTapAt) < doubleTapWindow
        lastTapAt = isDoubleTap ? .distantPast : releasedAt
        if let session {
            if isDoubleTap {
                stopReading()
            } else {
                session.togglePause()
                setStatus(session.isPaused ? "Paused — tap ⌃ to resume" : "Reading…")
            }
            return
        }
        guard isDoubleTap else { return } // idle single tap: deliberately nothing
        guard let doc = DocumentFinder.frontDocument(), let start = doc.firstVisible() else {
            print("[unread] nothing readable in the front window")
            NSSound.beep()
            return
        }
        startReading(doc, from: start, releasedAt: releasedAt)
    }

    private func startReading(_ doc: ReadableDocument, from start: AnyObject, releasedAt: Date) {
        session?.stop()
        print("[unread] reading \(type(of: doc)) in pid \(AX.pid(doc.element))")
        let s = ReadingSession(document: doc, start: start, speed: speed, voice: voice, player: player, overlay: overlay, startedAt: releasedAt)
        s.onFinish = { [weak self, weak s] in
            guard let self, self.session === s else { return }
            self.session = nil
            self.setStatus("Hold ⌃ and point to read")
        }
        session = s
        setStatus("Reading…")
        s.start()
    }

    private func stopReading() {
        session?.stop()
        session = nil
        setStatus("Hold ⌃ and point to read")
    }

    // MARK: Menu

    private func setUpMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Unread")
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        accessibilityItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessibilityItem.target = self
        accessibilityItem.isHidden = true
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())

        let speedItem = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        for s: Float in [0.9, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0] {
            let item = NSMenuItem(title: String(format: "%.2g×", s), action: #selector(pickSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s
            item.state = s == speed ? .on : .off
            speedMenu.addItem(item)
        }
        speedItem.submenu = speedMenu
        menu.addItem(speedItem)

        let voiceItem = NSMenuItem(title: "English voice", action: nil, keyEquivalent: "")
        let voiceMenu = NSMenu()
        for v in ["af_heart", "af_bella", "af_nicole", "am_michael", "am_fenrir", "bf_emma", "bm_george", "bm_fable"] {
            let item = NSMenuItem(title: v, action: #selector(pickVoice(_:)), keyEquivalent: "")
            item.target = self
            item.state = v == "af_heart" ? .on : .off
            voiceMenu.addItem(item)
        }
        voiceItem.submenu = voiceMenu
        menu.addItem(voiceItem)

        menu.addItem(.separator())
        if isBundled {
            let item = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            loginItem = item
            updateLoginItem()
        }
        let quit = NSMenuItem(title: "Quit Unread", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func setStatus(_ text: String) { statusLine.title = text }

    @objc private func pickSpeed(_ item: NSMenuItem) {
        speed = item.representedObject as? Float ?? 1
        session?.speed = speed
        item.menu?.items.forEach { $0.state = $0 === item ? .on : .off }
    }

    @objc private func pickVoice(_ item: NSMenuItem) {
        let v = item.title
        item.menu?.items.forEach { $0.state = $0 === item ? .on : .off }
        Task { await voice.setEnglishVoice(v) }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
