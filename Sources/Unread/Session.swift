import AppKit
import NaturalLanguage

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
    private var synthesizing = false
    private var cancelled = false
    private var spokeAnything = false
    private var following = true
    private var followGraceUntil = Date.distantPast
    private var refresh: Timer?
    private let startedAt: Date
    /// Filled in as the first sentence goes through the pipeline, written
    /// once at first audio, then nil.
    private var timing: LatencyRecord?
    private(set) var suspendHighlight = false

    var isPaused: Bool { player.isPaused }

    init(document: ReadableDocument, start: AnyObject, speed: Float, voice: Voice, player: Player, overlay: Overlay, startedAt: Date, timing: LatencyRecord? = nil) {
        self.document = document
        self.cursor = start
        self.speed = speed
        self.voice = voice
        self.player = player
        self.overlay = overlay
        self.startedAt = startedAt
        self.timing = timing
    }

    func start() {
        fill()
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

    private func fill() {
        guard !cancelled, !synthesizing, queued.count < lookahead else { return }
        let extractStart = Date()
        guard let position = cursor, let sentence = document.sentence(from: position) else {
            cursor = nil
            if queued.isEmpty { finish() }
            return
        }
        if timing != nil, timing?.extractMs == nil {
            timing?.extractMs = LatencyLog.ms(since: extractStart)
            timing?.chars = sentence.text.count
        }
        cursor = sentence.next
        synthesizing = true
        let lang = language.language(for: sentence.text)
        let speed = self.speed
        let voice = self.voice
        Task { [weak self] in
            let synthStart = Date()
            let samples = try? await voice.synthesize(sentence.text, language: lang, speed: speed)
            self?.enqueue(sentence, samples: samples, synthMs: LatencyLog.ms(since: synthStart))
        }
    }

    private func enqueue(_ sentence: Sentence, samples: [Float]?, synthMs: Double) {
        synthesizing = false
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
        queued.removeFirst()
        if queued.isEmpty {
            overlay.hide()
            if cursor == nil, !synthesizing { finish() }
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

    private func showCurrent(scroll: Bool) {
        guard !suspendHighlight, let current = queued.first else { return }
        guard var bounds = document.bounds(of: current), let visible = document.visibleRect() else {
            overlay.hide(); return
        }
        if scroll, following, !visible.contains(bounds) {
            document.scrollIntoView(current)
            followGraceUntil = Date().addingTimeInterval(0.8)
            bounds = document.bounds(of: current) ?? bounds
        }
        let shown = bounds.intersection(visible)
        if shown.isNull || shown.isEmpty { overlay.hide() } else { overlay.show(shown, style: .reading) }
    }

    private func refreshHighlight() {
        guard !suspendHighlight, let current = queued.first,
              let bounds = document.bounds(of: current), let visible = document.visibleRect() else { return }
        // If the user scrolled the sentence away, stop dragging the page
        // back; resume following once it's on screen again.
        if Date() > followGraceUntil { following = visible.intersects(bounds) }
        let shown = bounds.intersection(visible)
        if shown.isNull || shown.isEmpty { overlay.hide() } else { overlay.show(shown, style: .reading) }
    }
}
