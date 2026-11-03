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
    /// Changing it re-synthesizes everything not yet playing (#15).
    var speed: Float { didSet { if speed != oldValue { settingsChanged() } } }
    var onFinish: (() -> Void)?

    private let voice: Voice
    private let player: Player
    private let overlay: Overlay
    private let language = LanguageTracker()
    private let lookahead = 3

    private var cursor: AnyObject?
    /// On the player, not yet finished. `first` is the one being spoken; at
    /// most one more is scheduled, in the current one's closing pause.
    private var queued: [Sentence] = []
    /// Synthesized, waiting for the player. Can still be thrown away.
    private var ready: [Ready] = []
    /// Sentences to synthesize again after a speed or voice change, before
    /// extracting new ones.
    private var redo: [Pending] = []
    /// Bumped by a speed or voice change; audio from an older generation is redone.
    private var generation = 0
    /// Sentences are numbered as they're extracted and played strictly in order.
    private var nextSeq = 0
    private var nextToPlay = 0
    /// The player has consumed everything handed to it and can take the next sentence.
    private var playerWantsMore = true

    private struct Pending { let sentence: Sentence; let language: NLLanguage; let seq: Int }
    private struct Ready { let pending: Pending; let samples: [Float]; let speed: Float }
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
    /// The speed the primed sentence was synthesized at.
    private let primedSpeed: Float
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
        self.primedSpeed = speed
    }

    /// Speed or voice changed: keep the sentence that's playing, throw away
    /// the audio waiting behind it and synthesize those sentences again.
    /// A synthesis already running is redone when it finishes.
    func settingsChanged() {
        generation += 1
        redo = (ready.map(\.pending) + redo).sorted { $0.seq < $1.seq }
        ready = []
        if debugSession { print("[session] settings changed; redoing \(redo.count) sentence(s)") }
        fill()
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
            let lang = self.language.language(for: prepared.sentence.text) // keep language stickiness in step
            self.timing?.extractMs = prepared.extractMs
            self.timing?.chars = prepared.sentence.text.count
            let pending = Pending(sentence: prepared.sentence, language: lang, seq: self.nextSeq)
            self.nextSeq += 1
            if self.speed != self.primedSpeed {
                // The speed changed during the hold: synthesize the first sentence again.
                self.redo.append(pending)
                self.fill()
                return
            }
            self.enqueue(pending, samples: prepared.samples, speed: self.speed, synthMs: prepared.synthMs)
        }
    }

    private func fill() {
        guard !cancelled, !producing, ready.count + max(0, queued.count - 1) < lookahead else { return }
        if !redo.isEmpty {
            producing = true
            synthesize(redo.removeFirst())
            return
        }
        guard let position = cursor else { if queued.isEmpty, ready.isEmpty { finish() }; return }
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
                if self.queued.isEmpty, self.ready.isEmpty, self.redo.isEmpty { self.finish() }
                return
            }
            self.lastExtracted = sentence
            self.cursor = sentence.next
            if self.timing != nil, self.timing?.extractMs == nil {
                self.timing?.extractMs = LatencyLog.ms(since: extractStart)
                self.timing?.chars = sentence.text.count
            }
            let pending = Pending(sentence: sentence, language: self.language.language(for: sentence.text), seq: self.nextSeq)
            self.nextSeq += 1
            self.synthesize(pending)
        }
    }

    /// Synthesize at the current settings. If they change before it's done,
    /// the sentence goes back into `redo` instead of playing.
    private func synthesize(_ pending: Pending) {
        let generation = self.generation, speed = self.speed, voice = self.voice
        Task { [weak self] in
            let synthStart = Date()
            let samples = try? await voice.synthesize(pending.sentence.text, language: pending.language, speed: speed)
            guard let self, !self.cancelled else { return }
            self.producing = false
            guard generation == self.generation else {
                self.redo = (self.redo + [pending]).sorted { $0.seq < $1.seq }
                self.fill()
                return
            }
            self.enqueue(pending, samples: samples, speed: speed, synthMs: LatencyLog.ms(since: synthStart))
        }
    }

    private func enqueue(_ pending: Pending, samples: [Float]?, speed: Float, synthMs: Double) {
        guard !cancelled else { return }
        // Nothing to say (synthesis failed): keep its place so order holds, then skip it.
        ready.append(Ready(pending: pending, samples: samples ?? [], speed: speed))
        ready.sort { $0.pending.seq < $1.pending.seq }
        if timing != nil, timing?.synthMs == nil { timing?.synthMs = synthMs }
        scheduleNext()
        fill()
    }

    /// Hand the next sentence to the player, if it's ready and the player has
    /// consumed the previous one's speech (it's now in its closing pause).
    private func scheduleNext() {
        while !cancelled, playerWantsMore, let next = ready.first, next.pending.seq == nextToPlay {
            ready.removeFirst()
            nextToPlay += 1
            guard !next.samples.isEmpty else { continue }
            playerWantsMore = false
            queued.append(next.pending.sentence)
            spokeAnything = true
            if debugSession {
                print(String(format: "[session] playing #%d at %.2g× (%.1fs) %@", next.pending.seq, next.speed,
                             Double(next.samples.count) / 24_000, next.pending.sentence.text.prefix(40).debugDescription))
            }
            if queued.count == 1 { showCurrent(scroll: true) }
            player.schedule(next.samples, consumed: { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.speechConsumed() } }
            }, played: { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.sentenceFinished() } }
            })
            if var t = timing {
                // Measured after scheduling: that's when the buffer is queued on a running engine.
                t.firstAudioMs = LatencyLog.ms(since: startedAt)
                t.outputLatencyMs = (player.outputLatency * 1000).rounded()
                timing = nil
                print(String(format: "[unread] first audio %.0f ms after release (%@, extract %.0f, synth %.0f, +%.0f device)",
                             t.firstAudioMs!, t.gesture.rawValue, t.extractMs ?? 0, t.synthMs ?? 0, t.outputLatencyMs!))
                LatencyLog.append(t)
            }
        }
    }

    private func speechConsumed() {
        guard !cancelled else { return }
        playerWantsMore = true
        scheduleNext()
        fill()
    }

    private func sentenceFinished() {
        guard !cancelled, !queued.isEmpty else { return }
        if debugSession { print("[session] finished \(queued[0].text.prefix(40).debugDescription), \(queued.count - 1) queued") }
        queued.removeFirst()
        if queued.isEmpty {
            overlay.hide()
            if cursor == nil, !producing, ready.isEmpty, redo.isEmpty { finish() }
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
