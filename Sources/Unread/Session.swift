import AppKit
import NaturalLanguage

/// The first sentence, extracted and synthesized while the hotkey was held,
/// so reading can start the moment it's released.
struct PrimedSentence {
    struct Prepared {
        let sentence: Sentence
        /// The reading scope computed with it, so release doesn't pay for it again.
        let scope: ReadingScope?
        let extractMs: Double
        let samples: [Float]?
        let synthMs: Double
    }
    /// Nil if there was nothing to read at the aimed paragraph.
    let prepared: Task<Prepared?, Never>
}

/// Reads one document from a starting point to the end. Keeps a few
/// sentences synthesized ahead of the one playing, and keeps the highlight
/// glued to the sentence on screen as the user scrolls.
@MainActor
final class ReadingSession {
    let document: ReadableDocument
    var speed: Float
    var onFinish: (() -> Void)?

    private let voice: Voice
    private let player: Player
    private let overlay: Overlay
    private let language = LanguageTracker()
    private let lookahead = 3

    private var cursor: AnyObject?
    /// Scheduled, not yet finished. `first` is the one being spoken.
    private var queued: [Sentence] = []
    /// Extracting or synthesizing the next sentence (one at a time).
    private var producing = false
    private var cancelled = false
    private var spokeAnything = false
    private let debugSession = ProcessInfo.processInfo.environment["UNREAD_DEBUG_OVERLAY"] != nil
    private var following = true
    private var followGraceUntil = Date.distantPast
    private var refresh: Timer?
    /// A 10 Hz refresh is in flight on the AX worker; skip ticks until it's back.
    private var refreshing = false
    /// Newer highlight requests win over older ones still in flight.
    private var highlightToken = 0
    private let startedAt: Date
    /// Filled in as the first sentence goes through the pipeline, written
    /// once at first audio, then nil.
    private var timing: LatencyRecord?
    private var primed: PrimedSentence?
    /// The article / main area this reading stays in, and what it skips (#10).
    private var scope: ReadingScope?
    private var scopeResolved = false
    /// The last sentence extracted, to find our place again if the page
    /// rebuilds its elements under us.
    private var lastExtracted: Sentence?
    private var lastRelocateAttempt = Date.distantPast
    private(set) var suspendHighlight = false

    var isPaused: Bool { player.isPaused }

    init(document: ReadableDocument, start: AnyObject, speed: Float, voice: Voice, player: Player, overlay: Overlay, startedAt: Date, timing: LatencyRecord? = nil, primed: PrimedSentence? = nil) {
        self.document = document
        self.cursor = start
        self.speed = speed
        self.voice = voice
        self.player = player
        self.overlay = overlay
        self.startedAt = startedAt
        self.timing = timing
        self.primed = primed
    }

    func start() {
        if let primed { consume(primed) } else { fill() }
        refresh = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHighlight() }
        }
    }

    func stop() {
        cancelled = true
        refresh?.invalidate()
        player.stop()
        overlay.hide()
    }

    func togglePause() {
        if player.isPaused { player.resume() } else { player.pause() }
    }

    /// While the user is aiming at a new spot, the preview owns the overlay.
    func setHighlightSuspended(_ suspended: Bool) {
        suspendHighlight = suspended
        if !suspended { showCurrent(scroll: false) }
    }

    // MARK: Pipeline
    //
    // Extraction and highlight measuring run on the AX worker (#12); this
    // class stays on the main actor and only ever touches results.

    /// Start from the sentence prepared during the hold. If synthesis is
    /// still running, wait for it rather than queueing a second job behind it.
    private func consume(_ p: PrimedSentence) {
        primed = nil
        producing = true
        Task { [weak self] in
            let prepared = await p.prepared.value
            guard let self, !self.cancelled else { return }
            self.producing = false
            guard let prepared else { self.fill(); return } // nothing prepared: start the normal way
            self.scope = prepared.scope
            self.scopeResolved = true
            self.cursor = prepared.sentence.next
            self.lastExtracted = prepared.sentence
            _ = self.language.language(for: prepared.sentence.text) // keep language stickiness in step
            self.timing?.extractMs = prepared.extractMs
            self.timing?.chars = prepared.sentence.text.count
            self.enqueue(prepared.sentence, samples: prepared.samples, synthMs: prepared.synthMs)
        }
    }

    private func fill() {
        guard !cancelled, !producing, queued.count < lookahead else { return }
        guard let position = cursor else { if queued.isEmpty { finish() }; return }
        producing = true
        let doc = document, scopeNow = scope, needScope = !scopeResolved, last = lastExtracted
        Task { [weak self] in
            let extractStart = Date()
            let (found, newScope) = await AXWorker.shared.run { () -> (Sentence?, ReadingScope?) in
                var sc = needScope ? doc.scope(from: position) : scopeNow
                var s = doc.sentence(from: position, in: sc)
                if s == nil, let last { s = doc.sentence(after: last, scope: &sc) } // page re-rendered?
                return (s, sc)
            }
            guard let self, !self.cancelled else { return }
            self.scope = newScope
            self.scopeResolved = true
            guard let sentence = found else {
                self.producing = false
                self.cursor = nil
                if self.queued.isEmpty { self.finish() }
                return
            }
            self.lastExtracted = sentence
            self.cursor = sentence.next
            if self.timing != nil, self.timing?.extractMs == nil {
                self.timing?.extractMs = LatencyLog.ms(since: extractStart)
                self.timing?.chars = sentence.text.count
            }
            let lang = self.language.language(for: sentence.text)
            let synthStart = Date()
            let samples = try? await self.voice.synthesize(sentence.text, language: lang, speed: self.speed)
            guard !self.cancelled else { return }
            self.producing = false
            self.enqueue(sentence, samples: samples, synthMs: LatencyLog.ms(since: synthStart))
        }
    }

    private func enqueue(_ sentence: Sentence, samples: [Float]?, synthMs: Double) {
        guard !cancelled else { return }
        guard let samples, !samples.isEmpty else { fill(); return }
        queued.append(sentence)
        spokeAnything = true
        if queued.count == 1 { showCurrent(scroll: true) }
        player.schedule(samples) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.sentenceFinished() } }
        }
        if var t = timing {
            // Measured after scheduling: that's when the buffer is queued on a running engine.
            t.firstAudioMs = LatencyLog.ms(since: startedAt)
            t.synthMs = synthMs
            t.outputLatencyMs = (player.outputLatency * 1000).rounded()
            timing = nil
            print(String(format: "[unread] first audio %.0f ms after release (%@, extract %.0f, synth %.0f, +%.0f device)",
                         t.firstAudioMs!, t.gesture.rawValue, t.extractMs ?? 0, synthMs, t.outputLatencyMs!))
            LatencyLog.append(t)
        }
        fill()
    }

    private func sentenceFinished() {
        guard !cancelled, !queued.isEmpty else { return }
        if debugSession { print("[session] finished \(queued[0].text.prefix(40).debugDescription), \(queued.count - 1) queued") }
        queued.removeFirst()
        if queued.isEmpty {
            overlay.hide()
            if cursor == nil, !producing { finish() }
        } else {
            showCurrent(scroll: true)
        }
        fill()
    }

    /// Natural end: a soft chime says "that's all", so a quiet room doesn't
    /// read as "did it stall?". (A manual stop chimes too, from the app; a
    /// jump doesn't, because reading carries on.)
    private func finish() {
        guard !cancelled else { return }
        stop()
        if spokeAnything { player.chime() }
        onFinish?()
    }

    // MARK: Highlight

    /// One highlight measurement, done on the AX worker.
    private struct Measured {
        var lines: [CGRect] = []
        var visible: CGRect?
        var relocated: Sentence?
        var triedRelocate = false
        var scrolled = false
        var diagnosis: String?
    }

    private func measure(_ sentence: Sentence, relocate: Bool, scrollIfNeeded: Bool) async -> Measured {
        let doc = document
        return await AXWorker.shared.run {
            var m = Measured()
            var current = sentence
            m.lines = doc.lines(of: current)
            // The page may have rebuilt its elements under us: find it again.
            if m.lines.isEmpty, relocate {
                m.triedRelocate = true
                if let fresh = doc.relocate(current) { m.relocated = fresh; current = fresh; m.lines = doc.lines(of: fresh) }
            }
            m.visible = doc.visibleRect()
            if scrollIfNeeded, let v = m.visible, let u = Self.union(m.lines), !v.contains(u) {
                doc.scrollIntoView(current)
                m.scrolled = true
                let moved = doc.lines(of: current)
                if !moved.isEmpty { m.lines = moved }
            }
            if m.lines.isEmpty { m.diagnosis = doc.linesDiagnosis(of: current) }
            return m
        }
    }

    private func showCurrent(scroll: Bool) {
        guard !suspendHighlight, let current = queued.first else {
            if suspendHighlight { print("[highlight] skipped: suspended while aiming") }
            return
        }
        highlightToken += 1
        let token = highlightToken
        let scrollIfNeeded = scroll && following
        Task { [weak self] in
            guard let m = await self?.measure(current, relocate: true, scrollIfNeeded: scrollIfNeeded), let self else { return }
            guard !self.cancelled, token == self.highlightToken, !self.suspendHighlight,
                  self.queued.first?.range === current.range else { return }
            let label = current.text.prefix(40).debugDescription
            if let fresh = m.relocated {
                self.queued[0] = fresh
                print("[highlight] \(label): page re-rendered, found it again")
            }
            if m.scrolled { self.followGraceUntil = Date().addingTimeInterval(0.8) }
            guard let bounds = Self.union(m.lines), let visible = m.visible else {
                print("[highlight] \(label) → no box: \(m.diagnosis ?? "")")
                self.overlay.hide()
                return
            }
            if !visible.intersects(bounds) { print("[highlight] \(label) → off screen \(bounds), visible \(visible), following: \(self.following)") }
            else { print("[highlight] \(label) → \(m.lines.count) line(s)") }
            self.show(m.lines, in: visible)
        }
    }

    private func refreshHighlight() {
        guard !suspendHighlight, !refreshing, let current = queued.first else { return }
        refreshing = true
        let token = highlightToken
        // Relocating walks the tree; not more than twice a second.
        let mayRelocate = Date().timeIntervalSince(lastRelocateAttempt) > 0.5
        Task { [weak self] in
            guard let m = await self?.measure(current, relocate: mayRelocate, scrollIfNeeded: false), let self else { return }
            self.refreshing = false
            if m.triedRelocate { self.lastRelocateAttempt = Date() }
            guard !self.cancelled, token == self.highlightToken, !self.suspendHighlight,
                  self.queued.first?.range === current.range else { return }
            if let fresh = m.relocated { self.queued[0] = fresh }
            guard let bounds = Self.union(m.lines), let visible = m.visible else { return }
            // If the user scrolled the sentence away, stop dragging the page
            // back; resume following once it's on screen again.
            if Date() > self.followGraceUntil { self.following = visible.intersects(bounds) }
            self.show(m.lines, in: visible)
        }
    }

    /// Draw the sentence's lines, clipped to the visible part of the document.
    private func show(_ lines: [CGRect], in visible: CGRect) {
        let shown = lines.map { $0.intersection(visible) }.filter { !$0.isNull && !$0.isEmpty }
        if shown.isEmpty { overlay.hide() } else { overlay.show(shown, style: .reading) }
    }

    nonisolated private static func union(_ lines: [CGRect]) -> CGRect? { lines.dropFirst().reduce(lines.first) { $0?.union($1) } }
}
