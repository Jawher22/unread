import AppKit
import ApplicationServices
import ServiceManagement

enum VoiceChoice: String, Codable {
    case kokoro, narrator
    static let key = "voice"
}

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
    private var voiceChoice = UserDefaults.standard.string(forKey: VoiceChoice.key).flatMap(VoiceChoice.init) ?? .kokoro
    private enum NarratorState { case unloaded, loading, ready(Narrator), failed }
    private var narratorState = NarratorState.unloaded
    private var voiceChoiceMenu: NSMenu!
    private var narrator: Narrator? {
        guard voiceChoice == .narrator, case .ready(let n) = narratorState else { return nil }
        return n
    }

    // Aiming state while the key is held.
    private var aimTimer: Timer?
    private var aimDocument: ReadableDocument?
    private var aimResolvedAt = CGPoint(x: -1e6, y: -1e6)
    private var aimTarget: (document: ReadableDocument, start: AnyObject)?
    private var lastTapAt = Date.distantPast

    /// Speculative synthesis of the aimed sentence while the key is held.
    private final class Speculation {
        let element: AXUIElement
        let start: AnyObject
        var primed: PrimedSentence?
        var done = false
        init(element: AXUIElement, start: AnyObject) { self.element = element; self.start = start }
        func matches(_ doc: ReadableDocument, _ start: AnyObject) -> Bool {
            CFEqual(element, doc.element) && CFEqual(self.start, start)
        }
        func claim() -> PrimedSentence? {
            defer { primed = nil }
            return primed
        }
        deinit { primed?.cancel() }
    }
    private var speculation: Speculation?
    /// The paragraph aimed at, and since when. Speculate once it's stable.
    private var steadyAim: (start: AnyObject, since: Date)?
    /// Aiming runs on the AX worker; one lookup in flight at a time, and
    /// results from an earlier hold are dropped.
    private var aimInFlight = false
    private var aimToken = 0
    /// Why the last aim found nothing, logged if the hold ends without a target.
    private var aimMiss: String?
    private let speculateAfter: TimeInterval = 0.08

    private let holdThreshold: TimeInterval = 0.22
    private let previewDelay: TimeInterval = 0.12
    private let doubleTapWindow: TimeInterval = 0.35

    override init() {
        super.init()
        setUpMenu()
        hotkey.onPress = { [weak self] in self?.keyDown() }
        hotkey.onRelease = { [weak self] held in self?.keyUp(held: held) }
        hotkey.onCancel = { [weak self] in
            self?.speculation = nil
            self?.endAiming()
        }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            // Ask Chromium/Electron apps to build their AX tree before we need it.
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                let pid = app.processIdentifier
                AXWorker.shared.async { AX.enableTree(for: pid) }
            }
        }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { AXWorker.shared.async { AX.enableTree(for: pid) } }

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
                if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { AXWorker.shared.async { AX.enableTree(for: pid) } }
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
                loadNarratorIfChosen()
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

    private func loadNarratorIfChosen() {
        guard voiceChoice == .narrator, case .unloaded = narratorState else { return }
        narratorState = .loading
        updateVoiceMenu()
        Task {
            let t = Date()
            do {
                narratorState = .ready(try await Narrator.load(preset: VoicePreset.named("london-storyteller")))
                print(String(format: "[unread] narrator ready in %.1fs", Date().timeIntervalSince(t)))
            } catch {
                narratorState = .failed
                print("[unread] narrator unavailable, reading with Kokoro: \(error)")
            }
            updateVoiceMenu()
            session?.narrator = narrator
        }
    }

    // MARK: Hotkey

    private func keyDown() {
        guard ready else { NSSound.beep(); return }
        player.warm() // open the audio device now, not on release
        aimTarget = nil
        aimDocument = nil
        speculation = nil
        steadyAim = nil
        aimResolvedAt = CGPoint(x: -1e6, y: -1e6)
        aimToken += 1
        aimInFlight = false
        aimMiss = nil
        aimTimer?.invalidate()
        aimTimer = Timer.scheduledTimer(withTimeInterval: previewDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginAiming() }
        }
    }

    private func beginAiming() {
        session?.setAiming(true)
        aim()
        aimTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.aim() }
        }
    }

    private func aim() {
        guard !aimInFlight else { return } // the worker is still on the last frame
        aimInFlight = true
        let token = aimToken
        let p = AX.mouseLocation()
        // Re-resolving the document walks the AX tree; only do it when the
        // pointer has really moved. Paragraph lookup is cheap (and cached).
        let reresolve = aimDocument == nil || hypot(p.x - aimResolvedAt.x, p.y - aimResolvedAt.y) > 40
        let current = aimDocument
        Task { [weak self] in
            let (doc, para, miss) = await AXWorker.shared.run { () -> (ReadableDocument?, (start: AnyObject, bounds: CGRect)?, String?) in
                let doc = reresolve ? DocumentFinder.document(at: p) : current
                let para = doc?.paragraph(at: p)
                return (doc, para, para == nil ? DocumentFinder.whyNothing(at: p, found: doc) : nil)
            }
            guard let self, token == self.aimToken else { return }
            self.aimInFlight = false
            self.aimMiss = miss
            if reresolve { self.aimDocument = doc; self.aimResolvedAt = p }
            self.aimed(doc, para)
        }
    }

    private func aimed(_ doc: ReadableDocument?, _ para: (start: AnyObject, bounds: CGRect)?) {
        if let doc, let para {
            aimTarget = (doc, para.start)
            if let steady = steadyAim, CFEqual(steady.start, para.start) {
                if Date().timeIntervalSince(steady.since) >= speculateAfter { speculate(doc, from: para.start) }
            } else {
                steadyAim = (para.start, Date())
            }
            overlay.show(para.bounds, style: .preview)
        } else {
            aimTarget = nil
            overlay.hide()
        }
    }

    /// Extract and synthesize the first sentence of the aimed paragraph now,
    /// so release → first audio is just scheduling. One job at a time: a stale
    /// job (pointer moved on) finishes before the next starts, so it can delay
    /// a fresh one by at most one sentence.
    private func speculate(_ doc: ReadableDocument, from start: AnyObject) {
        if let s = speculation, s.matches(doc, start) || !s.done { return }
        let spec = Speculation(element: doc.element, start: start)
        speculation = spec
        if narrator != nil { session?.yieldNarrator() }
        spec.primed = PrimedSentence.prepare(doc, from: start, kokoro: voice, narrator: narrator, speed: speed,
                                             settled: { [weak spec] in spec?.done = true })
    }

    private func endAiming() {
        aimTimer?.invalidate()
        aimTimer = nil
        aimToken += 1 // drop any lookup still in flight
        aimInFlight = false
        overlay.hide()
        session?.setAiming(false)
    }

    private func keyUp(held: TimeInterval) {
        guard ready else { return }
        let target = aimTarget
        let spec = speculation
        speculation = nil
        steadyAim = nil
        // Jumping: stop the reading before aiming ends, or it would start the narrator on its next sentence first.
        if held >= holdThreshold, target != nil { session?.stop() }
        endAiming()
        let releasedAt = Date()

        if held >= holdThreshold {
            // Point-and-hold: read from the paragraph we were aiming at.
            if let target {
                let primed = spec.flatMap { $0.matches(target.document, target.start) ? $0.claim() : nil }
                startReading(target.document, from: target.start, releasedAt: releasedAt, gesture: .hold, primed: primed)
            } else {
                // Released before the first lookup came back from the AX worker
                // (a quick hold while it's busy): look once more, at the release point.
                let p = AX.mouseLocation()
                let token = aimToken
                Task { [weak self] in
                    let found = await AXWorker.shared.run { () -> (ReadableDocument, AnyObject)? in
                        guard let doc = DocumentFinder.document(at: p), let para = doc.paragraph(at: p) else { return nil }
                        return (doc, para.start)
                    }
                    guard let self, token == self.aimToken else { return }
                    guard let (doc, start) = found else {
                        let why = await AXWorker.shared.run { DocumentFinder.whyNothing(at: p, found: DocumentFinder.document(at: p)) }
                        print("[unread] hold found nothing to read: \(self.aimMiss ?? why)")
                        return
                    }
                    self.startReading(doc, from: start, releasedAt: releasedAt, gesture: .hold)
                }
            }
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
        let lookupStart = Date()
        let token = aimToken
        Task { [weak self] in
            let (found, why) = await AXWorker.shared.run { () -> ((ReadableDocument, AnyObject)?, String) in
                guard let doc = DocumentFinder.frontDocument() else { return (nil, "no web area or text view in the front window of \(DocumentFinder.frontAppName())") }
                guard let start = doc.firstVisible() else { return (nil, "\(type(of: doc)) in \(DocumentFinder.frontAppName()) has no readable paragraph in view") }
                return ((doc, start), "")
            }
            // A new press since then means the user moved on.
            guard let self, token == self.aimToken, self.session == nil else { return }
            guard let (doc, start) = found else {
                print("[unread] double-tap found nothing to read: \(why)")
                NSSound.beep()
                return
            }
            self.startReading(doc, from: start, releasedAt: releasedAt, gesture: .doubleTap, lookupMs: LatencyLog.ms(since: lookupStart))
        }
    }

    private func startReading(_ doc: ReadableDocument, from start: AnyObject, releasedAt: Date,
                              gesture: LatencyRecord.Gesture, lookupMs: Double? = nil, primed: PrimedSentence? = nil) {
        session?.stop()
        print("[unread] reading \(type(of: doc)) in pid \(AX.pid(doc.element))")
        let app = NSRunningApplication(processIdentifier: AX.pid(doc.element))?.bundleIdentifier
        let timing = LatencyRecord(app: app, gesture: gesture, lookupMs: lookupMs,
                                   speculative: gesture == .hold ? primed != nil : nil)
        let s = ReadingSession(document: doc, start: start, speed: speed, kokoro: voice, narrator: narrator, player: player,
                               overlay: overlay, startedAt: releasedAt, timing: timing, primed: primed)
        s.onFinish = { [weak self, weak s] in
            guard let self, self.session === s else { return }
            self.session = nil
            self.setStatus("Hold ⌃ and point to read")
        }
        session = s
        setStatus("Reading…")
        s.start()
    }

    /// Manual stop (double-tap). The chime confirms it, same as reaching the end.
    private func stopReading() {
        session?.stop()
        session = nil
        player.chime()
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

        let readerItem = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        voiceChoiceMenu = NSMenu()
        for choice in [VoiceChoice.kokoro, .narrator] {
            let item = NSMenuItem(title: "", action: #selector(pickVoiceChoice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            voiceChoiceMenu.addItem(item)
        }
        readerItem.submenu = voiceChoiceMenu
        menu.addItem(readerItem)
        updateVoiceMenu()

        let voiceItem = NSMenuItem(title: "Kokoro English voice", action: nil, keyEquivalent: "")
        let voiceMenu = NSMenu()
        for v in ["af_heart", "af_bella", "af_nicole", "am_michael", "am_fenrir", "bf_emma", "bm_george", "bm_fable"] {
            let item = NSMenuItem(title: v, action: #selector(pickVoice(_:)), keyEquivalent: "")
            item.target = self
            item.state = v == "af_heart" ? .on : .off
            voiceMenu.addItem(item)
        }
        voiceItem.submenu = voiceMenu
        menu.addItem(voiceItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

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

    private func updateVoiceMenu() {
        for item in voiceChoiceMenu.items {
            let choice = (item.representedObject as? String).flatMap(VoiceChoice.init) ?? .kokoro
            item.state = choice == voiceChoice ? .on : .off
            switch (choice, narratorState) {
            case (.kokoro, _): item.title = "Kokoro"
            case (.narrator, .loading): item.title = "Narrator — London storyteller (loading…)"
            case (.narrator, .failed): item.title = "Narrator — London storyteller (unavailable, see log)"
            case (.narrator, _): item.title = "Narrator — London storyteller"
            }
        }
    }

    @objc private func pickVoiceChoice(_ item: NSMenuItem) {
        voiceChoice = (item.representedObject as? String).flatMap(VoiceChoice.init) ?? .kokoro
        UserDefaults.standard.set(voiceChoice.rawValue, forKey: VoiceChoice.key)
        if voiceChoice == .narrator, case .failed = narratorState { narratorState = .unloaded }
        if ready { loadNarratorIfChosen() }
        updateVoiceMenu()
        session?.narrator = narrator
    }

    @objc private func pickVoice(_ item: NSMenuItem) {
        let v = item.title
        item.menu?.items.forEach { $0.state = $0 === item ? .on : .off }
        Task {
            await voice.setEnglishVoice(v)
            session?.kokoroVoiceChanged() // re-voice what's waiting behind the current sentence
        }
    }

    @objc private func openSettings() { SettingsWindow.shared.show() }

    @objc private func quit() { NSApp.terminate(nil) }
}
