import AppKit
import NaturalLanguage

/// The first sentence, extracted while the hotkey was held and handed to the
/// narrator, so reading can start the moment it's released.
struct PrimedSentence {
    struct Prepared {
        let sentence: Sentence
        /// The reading scope computed with it, so release doesn't pay for it again.
        let scope: ReadingScope?
        let extractMs: Double
        let take: NarratorTake
    }
    /// Nil if there was nothing to read at the aimed paragraph.
    let prepared: Task<Prepared?, Never>

    @MainActor
    static func prepare(_ doc: ReadableDocument, from start: AnyObject, narrator: Narrator,
                        settled: @escaping @MainActor () -> Void = {}) -> PrimedSentence {
        PrimedSentence(prepared: Task { @MainActor () -> Prepared? in
            defer { settled() }
            let found = await AXWorker.shared.run { () -> (Sentence, ReadingScope?, Double)? in
                let t = Date()
                let scope = doc.scope(from: start)
                guard let sentence = doc.sentence(from: start, in: scope) else { return nil }
                return (sentence, scope, LatencyLog.ms(since: t))
            }
            guard let (sentence, scope, extractMs) = found else { return nil }
            let lang = LanguageTracker().language(for: sentence.text) // what a fresh session would pick
            return Prepared(sentence: sentence, scope: scope, extractMs: extractMs,
                            take: NarratorTake(narrator, words: sentence.words[...], language: lang))
        })
    }

    func cancel() {
        let prepared = self.prepared
        Task { @MainActor in await prepared.value?.take.cancel() }
    }
}

/// The quiet between sentences, as a narrator leaves it (#56). The narrator's own quiet before and
/// after the voice is trimmed to `edge` on each side and this pause put between, shorter at faster
/// speeds. The same after a paragraph, heading or list item: a longer pause there lost every blind
/// pair against this one (#80).
enum Pacing {
    /// Seconds from one sentence's last sound to the next one's first, at 1×.
    static let sentence = 0.5
    /// Quiet kept on each side of the voice, so onsets and tails aren't clipped.
    static let edge = 0.05
    /// The player schedules the next sentence during this pause, so it never goes below this.
    static let minPause = 0.12

    /// The pause to put after a sentence, in samples at 24 kHz.
    static func pause(speed: Float) -> Int {
        let quiet = sentence / Double(speed) - 2 * edge
        return Int(max(quiet, minPause) * 24_000)
    }

    static var edgeSamples: Int { Int(edge * 24_000) }
}

/// Reads one document from a starting point to the end. Keeps a few
/// sentences synthesized ahead of the one playing, and keeps the highlight
/// glued to the sentence on screen as the user scrolls.
@MainActor
final class ReadingSession {
    let document: ReadableDocument
    /// The narrator's audio is stretched to the speed as it's played, so a change needs no new synthesis.
    var speed: Float
    let narrator: Narrator
    var onFinish: (() -> Void)?

    private let player: Player
    private let overlay: Overlay
    private let language = LanguageTracker()
    private let lookahead = 3

    private var cursor: AnyObject?
    /// On the player, not yet finished. `first` is the one being spoken; at
    /// most one more sentence is scheduled, in the current one's closing pause.
    private var queued: [Playing] = []
    private struct Playing {
        var sentence: Sentence
        /// Where its speech starts on the player's timeline.
        let start: Int
        /// When each display word starts, in samples from `start`.
        var wordStarts: [Int?]
    }
    /// Asked of the narrator, waiting for the player. Can still be thrown away.
    private var ready: [Ready] = []
    /// Sentences to synthesize before extracting new ones: those thrown away by a voice change,
    /// or held back while a hold has the narrator.
    private var backlog: [Pending] = []
    /// Sentences are numbered as they're extracted and played strictly in order.
    private var nextSeq = 0
    private var nextToPlay = 0
    /// The player has consumed everything handed to it and can take the next sentence.
    private var playerWantsMore = true

    private struct Pending {
        let sentence: Sentence
        let language: NLLanguage
        let seq: Int
    }
    private struct Ready { let pending: Pending; let take: NarratorTake }
    /// Extracting the next sentence, or the narrator synthesizing one (one at a time).
    private var producing = false
    private var inFlight: NarratorTake?
    /// The last sentence the narrator was asked for: the next one of its paragraph carries on from it (#56).
    private var lastNarrated: Pending?
    /// #15: a buffer on the player can't be taken back, so only the sentence playing streams into it.
    private var live: Live?
    private struct Live {
        let pending: Pending
        let take: NarratorTake
        let speed: Float
        var stretch: TimeStretch?
        var fed = 0, said = 0
        var held: [Float] = []
        /// The player's timeline runs on when it runs dry, so a chunk that comes late starts later.
        var runs: [(said: Int, at: Int)] = []
        var voiced = 0
        var reached = Int.min

        func timeline(_ s: Int) -> Int {
            let run = runs.last { $0.said <= s } ?? runs[0]
            return run.at + s - run.said
        }
    }
    private var cancelled = false
    private var spokeAnything = false
    private let debugSession = ProcessInfo.processInfo.environment["UNREAD_DEBUG_OVERLAY"] != nil
    /// `UNREAD_DEBUG_MOTION=1` logs the voice clock every display frame.
    private let debugMotion = ProcessInfo.processInfo.environment["UNREAD_DEBUG_MOTION"] != nil
    private var following = true
    private var followGraceUntil = Date.distantPast
    private var refresh: Timer?
    /// The voice's position, smoothed for each display frame (#20).
    private var clock = AudioClock()
    /// Numbers the sentences as they're spoken, so the overlay knows a new
    /// one (transition) from the same one measured again (move in place).
    private var sentenceNumber = 0
    /// Where the mark was last drawn, unclipped (AX coordinates).
    private var lastHead: (range: AnyObject, box: CGRect)?
    /// Where the previous sentence's mark ended: the next one's first word glides from there.
    private var entry: (range: AnyObject, box: CGRect)?
    private var loggedWord: (range: AnyObject, index: Int)?
    /// The current sentence's word boxes as last measured, with the line
    /// boxes measured alongside them: when the lines move (scrolling), the
    /// words move by as much, without measuring each word again.
    private var wordBoxes: (range: AnyObject, words: [CGRect?], lines: [CGRect])?
    /// The latest line measurement of the current sentence, and what's visible.
    private var shownLines: (range: AnyObject, lines: [CGRect], visible: CGRect)?
    /// The word mark shown now, so the overlay only changes when it does.
    private var markedWord: (range: AnyObject, frame: WordMarkFrame?, style: HighlightStyle)?
    /// A 10 Hz refresh is in flight on the AX worker; skip ticks until it's back.
    private var refreshing = false
    private var refreshStarted = Date.distantPast
    /// The user scrolling the page being read: the highlight is hidden from the first scroll event, because
    /// measurements lag a scroll (at most 10 a second), so a highlight drawn during one sits on whatever text
    /// slides under it. The page goes on moving after the last event (Chromium animates a wheel scroll for
    /// ~0.3 s), and some apps report where things are late (Aside moves element frames only twice a second),
    /// so the highlight comes back only once measurements taken after the scroll have put it in the same
    /// place for `scrollSettle`, longer than Aside's half-second step.
    ///
    /// A trackpad says how far each event moves the page (momentum included), so when the movement stops the
    /// highlight is drawn at once where it was, moved by as much (`predicted`), and a settled measurement then
    /// confirms it or corrects it (at a page's top or bottom, the page moves less than the fingers).
    private var scrollMonitor: Any?
    private var lastScroll = Date.distantPast
    private var scrollState = ScrollState.steady
    private enum ScrollState {
        /// Measurements are drawn as they come.
        case steady
        /// The user is scrolling: hidden, and adding up how far the page has been moved since it was drawn.
        case scrolling(Gesture)
        /// Drawn from the gesture's distance, until a settled measurement takes over.
        case predicted(range: AnyObject, lines: [CGRect], from: [CGRect], dy: CGFloat, ended: Date)
        /// Hidden until measurements settle (a mouse wheel's steps don't say how far the page moved).
        case settling
    }
    /// Vertical only: a swipe always drifts sideways a little, and pages don't scroll sideways.
    private struct Gesture { let range: AnyObject; let from: [CGRect]; var dy: CGFloat = 0; var precise = true }
    /// How far the page moves on screen per point of trackpad distance: 0.9 on a page zoomed to 90%. Learned
    /// from each prediction a measurement settles, on lines that weren't cut by an edge.
    private var scrollScale: CGFloat = 1
    /// The first position measured after the gesture ended: maybe still from before it (Aside's half-second step).
    /// A different one after that is the app catching up, so it's trusted at once.
    private var afterGesture: [CGRect]?
    /// A page that hits its top or bottom bounces back for about this long after the gesture.
    private static let bounce: TimeInterval = 0.35
    /// Where the current sentence has measured since the scroll, and since when it has measured there.
    private var settling: (range: AnyObject, lines: [CGRect], since: Date)?
    /// The last time a measurement moved, and the shortest gap seen between two moves: how often this app
    /// updates where things are (Aside every 0.5 s; Electron and WebKit at every 0.1 s measurement).
    private var lastMove: (range: AnyObject, lines: [CGRect], at: Date)?
    private var updateStep: TimeInterval?
    private static let gestureEnd: TimeInterval = 0.1
    /// How long a position must hold before it's trusted after a scroll: past the app's update step, and
    /// 0.55 s until a step has been seen.
    private var scrollSettle: TimeInterval { updateStep.map { min(0.55, $0 + 0.15) } ?? 0.55 }
    private var hiddenForScroll: Bool {
        switch scrollState { case .scrolling, .settling: true; case .steady, .predicted: false }
    }
    private var refreshStuckLogged = false
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
    /// What the page has shown of an answer still being written (#17).
    private var growth = Growth()
    private struct Growth {
        /// When text last changed under this reading: a sentence found again after the page rebuilt it, a last
        /// sentence still growing, or new text after the end. Never: the page is static, and the end is the end.
        var changedAt: Date?
        /// The last sentence, held back while it may still be being written, and since when it has read the same.
        var held: (text: String, since: Date)?
        /// Reading reached the end of the text, and is waiting for more.
        var atEnd = false
    }
    /// A last sentence that doesn't end like one is read once it has stayed the same this long.
    private static let settle: TimeInterval = 0.7
    /// After the end of a page that changed, how long to wait for more text since it last changed.
    private static let streamWait: TimeInterval = 6
    private static let recheck: TimeInterval = 0.35
    private(set) var suspendHighlight = false

    var isPaused: Bool { player.isPaused }

    init(document: ReadableDocument, start: AnyObject, speed: Float, narrator: Narrator, player: Player, overlay: Overlay,
         startedAt: Date, timing: LatencyRecord? = nil, primed: PrimedSentence? = nil) {
        self.document = document
        self.cursor = start
        self.speed = speed
        self.narrator = narrator
        self.player = player
        self.overlay = overlay
        self.startedAt = startedAt
        self.timing = timing
        self.primed = primed
    }

    /// The narrator reads `language` in another preset now (#60): redo what's waiting in the old one.
    func narratorVoiceChanged(_ language: NLLanguage) {
        redo { $0.pending.language == language }
    }

    private func redo(_ stale: (Ready) -> Bool) {
        let dropped = ready.filter(stale)
        ready.removeAll(where: stale)
        for r in dropped {
            r.take.cancel()
            if r.take === inFlight { inFlight = nil; producing = false }
        }
        backlog = (dropped.map(\.pending) + backlog).sorted { $0.seq < $1.seq }
        if debugSession { print("[session] settings changed; \(backlog.count) sentence(s) to synthesize") }
        fill()
    }

    func start() {
        if let primed { consume(primed) } else { fill() }
        refresh = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHighlight() }
        }
        // Every display frame, paced by the screen.
        overlay.setFrameHandler(self) { [weak self] t in self?.tickWord(at: t) }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let at = event.cgEvent?.location // global, top-left origin, like Accessibility's
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY, precise = event.hasPreciseScrollingDeltas
            MainActor.assumeIsolated { self?.userScrolled(at: at, dx: dx, dy: dy, precise: precise) }
        }
    }

    private func userScrolled(at point: CGPoint?, dx: CGFloat, dy: CGFloat, precise: Bool) {
        guard dx != 0 || dy != 0, let point, let shown = shownLines, shown.visible.contains(point) else { return }
        lastScroll = Date()
        settling = nil
        var gesture: Gesture
        if case .scrolling(let g) = scrollState { gesture = g }
        else if case .settling = scrollState { return }
        else { gesture = Gesture(range: shown.range, from: shown.lines) }
        gesture.dy += dy
        gesture.precise = gesture.precise && precise
        scrollState = .scrolling(gesture)
        overlay.hide()
        if markedWord != nil { markedWord = nil; overlay.hideWord() }
    }

    /// The gesture has stopped: draw the highlight where it was, moved as far as the page was.
    private func endGesture() {
        guard case .scrolling(let g) = scrollState, Date().timeIntervalSince(lastScroll) >= Self.gestureEnd else { return }
        guard g.precise, let shown = shownLines, shown.range === g.range, queued.first?.sentence.range === g.range else {
            scrollState = .settling
            print("[unread] \(Self.clock()) scroll: \(g.precise ? "next sentence" : "wheel steps"), waiting for the place to settle")
            return
        }
        let lines = g.from.map { $0.offsetBy(dx: 0, dy: g.dy * scrollScale) }
        print("[unread] \(Self.clock()) scroll: drawn \(Int(g.dy * scrollScale)) px from where it was (\(Int(g.dy)) × \(String(format: "%.2f", scrollScale)))")
        scrollState = .predicted(range: g.range, lines: lines, from: g.from, dy: g.dy, ended: Date())
        afterGesture = nil
        shownLines = (g.range, lines, shown.visible)
        draw(lines, in: shown.visible)
    }

    private func draw(_ lines: [CGRect], in visible: CGRect) {
        let shown = lines.map { $0.intersection(visible) }.filter { !$0.isNull && !$0.isEmpty }
        if shown.isEmpty { overlay.hide(); markedWord = nil } else { overlay.show(shown, style: .reading, id: sentenceNumber) }
    }

    func stop() {
        cancelled = true
        ready.forEach { $0.take.cancel() }
        live?.take.cancel()
        refresh?.invalidate()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        overlay.clearFrameHandler(self)
        player.stop()
        overlay.hide()
    }

    func togglePause() {
        if player.isPaused { player.resume() } else { player.pause() }
    }

    /// While the user is aiming at a new spot, the preview owns the overlay.
    func setAiming(_ aiming: Bool) {
        suspendHighlight = aiming
        if aiming { markedWord = nil; overlay.hideWord() } else { yielding = false; showCurrent(scroll: false); fill() }
    }

    /// The hold's speculation needs the narrator, which says one sentence at a time: stop the
    /// sentence it's synthesizing ahead and start no other until the hold ends. A sentence
    /// streaming into the player can't be stopped without cutting it.
    func yieldNarrator() {
        yielding = true
        if let t = inFlight, live?.take !== t { redo { $0.take === t } }
    }
    private var yielding = false

    // MARK: Pipeline
    //
    // Extraction and highlight measuring run on the AX worker (#12); this
    // class stays on the main actor and only ever touches results.

    /// Start from the sentence prepared during the hold, still streaming or not.
    private func consume(_ p: PrimedSentence) {
        primed = nil
        producing = true
        Task { [weak self] in
            let prepared = await p.prepared.value
            guard let self, !self.cancelled else { prepared?.take.cancel(); return }
            self.producing = false
            guard let prepared else { self.fill(); return } // nothing prepared: start the normal way
            self.scope = prepared.scope
            self.scopeResolved = true
            self.cursor = prepared.sentence.next
            self.lastExtracted = prepared.sentence
            let lang = self.language.language(for: prepared.sentence.text) // keep language stickiness in step
            self.timing?.extractMs = prepared.extractMs
            self.enqueue(self.pending(prepared.sentence, language: lang), take: prepared.take)
        }
    }

    private func fill() {
        guard !cancelled, !producing, ready.count + max(0, queued.count - 1) < lookahead else { return }
        if !backlog.isEmpty {
            producing = true
            synthesize(backlog.removeFirst())
            return
        }
        guard let position = cursor else { if queued.isEmpty, ready.isEmpty { finish() }; return }
        producing = true
        let doc = document, scopeNow = scope, needScope = !scopeResolved, last = lastExtracted
        Task { [weak self] in
            let extractStart = Date()
            let (found, newScope, rebuilt, open) = await AXWorker.shared.run { () -> (Sentence?, ReadingScope?, Bool, Bool) in
                var sc = needScope ? doc.scope(from: position) : scopeNow
                var s = doc.sentence(from: position, in: sc)
                var rebuilt = false
                if s == nil, let last { s = doc.sentence(after: last, scope: &sc); rebuilt = s != nil } // page re-rendered?
                // The last text on the page, not ending like a sentence: it may still be being written.
                let open = s.map { !Self.endsLikeSentence($0.text) && $0.next.flatMap { doc.sentence(from: $0, in: sc) } == nil } ?? false
                return (s, sc, rebuilt, open)
            }
            guard let self, !self.cancelled else { return }
            self.scope = newScope
            self.scopeResolved = true
            let now = Date()
            guard let sentence = found else {
                self.producing = false
                self.growth.atEnd = true
                if let changed = self.growth.changedAt, now.timeIntervalSince(changed) < Self.streamWait {
                    self.fillAgain() // the answer may still be coming
                    return
                }
                self.cursor = nil
                if self.queued.isEmpty, self.ready.isEmpty, self.backlog.isEmpty { self.finish() }
                return
            }
            if rebuilt || self.growth.atEnd { self.growth.changedAt = now }
            self.growth.atEnd = false
            if open {
                if let held = self.growth.held, held.text != sentence.text { self.growth.changedAt = now }
                if self.growth.held?.text != sentence.text { self.growth.held = (sentence.text, now) }
                if let held = self.growth.held, now.timeIntervalSince(held.since) < Self.settle {
                    self.producing = false
                    self.fillAgain()
                    return
                }
            }
            self.growth.held = nil
            self.lastExtracted = sentence
            self.cursor = sentence.next
            if self.timing != nil, self.timing?.extractMs == nil {
                self.timing?.extractMs = LatencyLog.ms(since: extractStart)
            }
            self.synthesize(self.pending(sentence, language: self.language.language(for: sentence.text)))
        }
    }

    private func fillAgain() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recheck) { [weak self] in self?.fill() }
    }

    /// Ends like a finished sentence: ".", "!", "?", "…" or ":", maybe inside closing quotes or brackets.
    nonisolated static func endsLikeSentence(_ text: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]
        guard let last = text.reversed().first(where: { !$0.isWhitespace && !closers.contains($0) }) else { return false }
        return ".!?…:".contains(last)
    }

    /// Number the next sentence.
    private func pending(_ sentence: Sentence, language: NLLanguage) -> Pending {
        defer { nextSeq += 1 }
        if nextSeq == 0 { timing?.chars = sentence.text.count }
        return Pending(sentence: sentence, language: language, seq: nextSeq)
    }

    /// Ask the narrator for it, unless a hold has the narrator: then it waits in `backlog`.
    private func synthesize(_ pending: Pending) {
        guard !yielding else {
            producing = false
            backlog = (backlog + [pending]).sorted { $0.seq < $1.seq }
            return
        }
        let previous = lastNarrated.flatMap { p in
            p.seq == pending.seq - 1 && p.language == pending.language ? p.sentence.text : nil
        }
        enqueue(pending, take: NarratorTake(narrator, words: pending.sentence.words[...], language: pending.language, after: previous))
    }

    private func enqueue(_ pending: Pending, take: NarratorTake) {
        guard !cancelled else { take.cancel(); return }
        ready.append(Ready(pending: pending, take: take))
        ready.sort { $0.pending.seq < $1.pending.seq }
        lastNarrated = pending
        take.onArrival = { [weak self, weak take] in if let self, let take { self.arrived(take) } }
        if !take.streamed { inFlight = take; producing = true }
        scheduleNext()
        fill()
    }

    private func arrived(_ take: NarratorTake) {
        guard !cancelled else { return }
        if debugSession {
            let piece = live?.take === take ? live?.pending : ready.first { $0.take === take }?.pending
            print(String(format: "[take] #%d (%d chars) %.0f ms: %d samples%@", piece?.seq ?? -1, piece?.sentence.text.count ?? 0,
                         Date().timeIntervalSince(take.started) * 1000, take.samples.count, take.isComplete ? " complete" : ""))
        }
        if take.streamed, take === inFlight { inFlight = nil; producing = false }
        if live?.take === take { feed() } else { scheduleNext() }
        if take.streamed { fill() }
    }

    /// Hand the next sentence to the player, if it's ready and the player has
    /// consumed the previous one's speech (it's now in its closing pause).
    /// One still streaming plays as it arrives, once `Narrator.prebuffer` of it is in.
    private func scheduleNext() {
        while !cancelled, live == nil, playerWantsMore, let next = ready.first, next.pending.seq == nextToPlay {
            let piece = next.pending, take = next.take
            guard take.isComplete else {
                guard take.samples.count >= Narrator.prebuffer(characters: take.characters, speed: speed, pace: take.pace) else { return }
                ready.removeFirst()
                nextToPlay += 1
                goLive(piece, take)
                return
            }
            ready.removeFirst()
            nextToPlay += 1
            // Without the voice's own lead-in: the pause before it is `Pacing`'s.
            let speech = take.speech(speed: speed).trimmingLeadingQuiet(keep: Pacing.edgeSamples)
            guard !speech.samples.isEmpty else { continue } // nothing said (synthesis failed): skip it
            playerWantsMore = false
            spokeAnything = true
            let samples = speech.trimmingTrailingQuiet(keep: Pacing.edgeSamples).samples
            let ending = sentenceEnding(piece, speed: speed)
            if debugSession {
                print(String(format: "[session] playing #%d at %.2g× (%.1fs +%.2fs) %@", piece.seq, speed, Double(samples.count) / 24_000,
                             Double(Pacing.pause(speed: speed)) / 24_000, piece.sentence.text.prefix(40).debugDescription))
            }
            let start = player.schedule(samples, ending: ending, consumed: consumedCallback())
            logScheduled(piece, from: start, to: start + samples.count, ending: ending)
            let index = place(piece, at: start)
            for (word, s) in zip(piece.sentence.words.indices, speech.wordStarts) { queued[index].wordStarts[word] = s }
            firstAudio(samples, synthMs: LatencyLog.ms(since: take.started))
        }
    }

    private func sentenceEnding(_ piece: Pending, speed: Float) -> Player.Ending {
        .sentence(pause: Pacing.pause(speed: speed), played: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.sentenceFinished() } }
        })
    }

    private func consumedCallback() -> @Sendable () -> Void {
        { [weak self] in DispatchQueue.main.async { MainActor.assumeIsolated { self?.speechConsumed() } } }
    }

    private func place(_ piece: Pending, at start: Int) -> Int {
        queued.append(Playing(sentence: piece.sentence, start: start, wordStarts: piece.sentence.words.map { _ in nil }))
        if queued.count == 1 { showCurrent(scroll: true) }
        return queued.count - 1
    }

    private func goLive(_ piece: Pending, _ take: NarratorTake) {
        take.live = true
        playerWantsMore = false
        spokeAnything = true
        live = Live(pending: piece, take: take, speed: speed, stretch: speed == 1 ? nil : TimeStretch(rate: Double(speed)))
        if debugSession {
            print(String(format: "[session] streaming #%d at %.2g× from %.2fs of audio %@", piece.seq, speed,
                         Double(take.samples.count) / 24_000, piece.sentence.text.prefix(40).debugDescription))
        }
        feed()
    }

    private func feed() {
        guard var l = live else { return }
        let piece = l.pending, complete = l.take.isComplete
        let arrived = Array(l.take.samples[l.fed...])
        l.fed = l.take.samples.count
        var out = l.held
        if var stretch = l.stretch {
            out += stretch.push(arrived)
            if complete { out += stretch.finish() }
            l.stretch = stretch
        } else {
            out += arrived
        }
        let quiet = Speech(samples: out).trailingQuiet, edge = Pacing.edgeSamples
        let keep = out.count - (complete ? max(quiet - edge, 0) : quiet)
        var said = Array(out[..<keep])
        l.held = Array(out[keep...])
        guard !said.isEmpty || complete else {
            // Nothing new to play, but an alignment may have come in.
            if !l.runs.isEmpty { retime(&l, index: queued.count - 1, end: max(predictedEnd(l), l.said)) }
            live = l
            return
        }
        if said.isEmpty { said = [0] }
        let ending: Player.Ending = complete ? sentenceEnding(piece, speed: l.speed) : .more(pause: [])
        let consumed: @Sendable () -> Void = complete ? consumedCallback() : { @Sendable in }
        let start = player.schedule(said, ending: ending, consumed: consumed)
        let first = l.runs.isEmpty
        if first {
            l.voiced = Speech(samples: said).leadingQuiet
        } else if start != l.timeline(l.said) {
            print(String(format: "[unread] %@ underrun: sentence #%d at %.2g× waited %.0f ms for audio, %.1f s in",
                         Date.now.formatted(date: .omitted, time: .standard), piece.seq, l.speed,
                         Double(start - l.timeline(l.said)) / 24, Double(l.said) / 24_000))
        }
        if first || start != l.timeline(l.said) { l.runs.append((l.said, start)) }
        l.said += said.count
        let index = first ? place(piece, at: start) : queued.count - 1
        retime(&l, index: index, end: complete ? l.said - min(quiet, edge) : max(predictedEnd(l), l.said))
        if first { firstAudio(said, synthMs: LatencyLog.ms(since: l.take.started)) }
        if complete {
            logScheduled(piece, from: l.runs[0].at, to: l.timeline(l.said), ending: ending)
            live = nil
        } else {
            live = l
        }
    }

    /// Where a live sentence's voice should end, from the voice's pace, until it has all arrived.
    private func predictedEnd(_ l: Live) -> Int {
        l.voiced + Int(Double(l.take.characters) / l.take.pace / Double(l.speed) * 24_000)
    }

    /// The live sentence's word starts as the take now times them (aligned as far as it has been, #58).
    /// Words the mark has reached keep their start, so it never steps back as the timing is revised
    /// (the player reports no position while paused; the mark draws `lead` ahead).
    private func retime(_ l: inout Live, index: Int, end: Int) {
        let base = queued[index].start
        if let p = player.position { l.reached = max(l.reached, p - base + HighlightSettings.shared.style.lead.rawValue * 24) }
        for (word, s) in zip(l.pending.sentence.words.indices, l.take.wordStarts(voiced: l.voiced..<max(l.voiced, end), speed: l.speed)) {
            if let old = queued[index].wordStarts[word], old <= l.reached { continue }
            queued[index].wordStarts[word] = s.map { l.timeline($0) - base }
        }
    }

    private var loggedFirstAudio = false

    /// `synthMs`: from asking the narrator to playing.
    private func firstAudio(_ samples: [Float], synthMs: Double) {
        guard !loggedFirstAudio else { return }
        loggedFirstAudio = true
        let ms = LatencyLog.ms(since: startedAt), voiceAt = Double(Speech(samples: samples).leadingQuiet) / 24
        if debugSession { print(String(format: "[session] first audio %.0f ms after start, the voice %.0f ms into it", ms, voiceAt)) }
        guard var t = timing else { return }
        // Measured after scheduling: that's when the buffer is queued on a running engine.
        t.firstAudioMs = ms
        t.outputLatencyMs = (player.outputLatency * 1000).rounded()
        t.synthMs = synthMs
        timing = nil
        print(String(format: "[unread] first audio %.0f ms after release (%@, extract %.0f, synth %.0f, +%.0f device)",
                     t.firstAudioMs!, t.gesture.rawValue, t.extractMs ?? 0, t.synthMs ?? 0, t.outputLatencyMs!))
        LatencyLog.append(t)
    }

    private func logScheduled(_ piece: Pending, from: Int, to: Int, ending: Player.Ending) {
        guard debugSession else { return }
        let pause = switch ending {
        case .sentence(let pause, _): pause
        case .more(let pause): pause.count
        }
        print("[sched] #\(piece.seq) speech \(from)..\(to) pause \(pause)")
    }

    private func speechConsumed() {
        guard !cancelled else { return }
        playerWantsMore = true
        scheduleNext()
        fill()
    }

    private func sentenceFinished() {
        guard !cancelled, !queued.isEmpty else { return }
        if debugSession {
            let done = queued[0]
            print("[session] finished \(done.sentence.text.prefix(40).debugDescription), \(queued.count - 1) queued")
            // On the player's timeline, as `--record` writes it: `--align --check` compares them with the recording.
            let starts = done.wordStarts.map { $0.map { String(format: "%.3f", Double(done.start + $0) / 24_000) } ?? "-" }
            print("[timing] \(starts.joined(separator: ",")) | \(done.sentence.text)")
        }
        queued.removeFirst()
        markedWord = nil // the next sentence's first word takes over the mark
        sentenceNumber += 1
        entry = nil
        if let last = lastHead, let next = queued.first { entry = (next.sentence.range, last.box) }
        if queued.isEmpty {
            overlay.hide()
            if cursor == nil, !producing, live == nil, ready.isEmpty, backlog.isEmpty { finish() }
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
        var words: [CGRect?]?
        var visible: CGRect?
        var relocated: Sentence?
        var triedRelocate = false
        var scrolled = false
        var diagnosis: String?
    }

    /// `wantWords`: also measure each word's box (once per sentence, and
    /// again if the text reflowed).
    private func measure(_ sentence: Sentence, relocate: Bool, scrollIfNeeded: Bool, wantWords: Bool) async -> Measured {
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
            else if wantWords || m.relocated != nil || m.scrolled { m.words = doc.words(of: current) }
            return m
        }
    }

    private func showCurrent(scroll: Bool) {
        guard !suspendHighlight, let current = queued.first?.sentence else {
            if suspendHighlight { print("[highlight] skipped: suspended while aiming") }
            return
        }
        highlightToken += 1
        let token = highlightToken
        let scrollIfNeeded = scroll && following
        let measuredAt = Date()
        Task { [weak self] in
            guard let m = await self?.measure(current, relocate: true, scrollIfNeeded: scrollIfNeeded, wantWords: true), let self else { return }
            guard !self.cancelled, token == self.highlightToken, !self.suspendHighlight,
                  self.queued.first?.sentence.range === current.range else { return }
            let label = current.text.prefix(40).debugDescription
            if let fresh = m.relocated {
                self.queued[0].sentence = fresh
                print("[highlight] \(label): page re-rendered, found it again")
            }
            if m.scrolled { self.followGraceUntil = Date().addingTimeInterval(0.8) }
            guard let bounds = Self.union(m.lines), let visible = m.visible else {
                print("[highlight] \(label) → no box: \(m.diagnosis ?? "")")
                self.overlay.hide()
                self.markedWord = nil
                return
            }
            if !visible.intersects(bounds) { print("[highlight] \(label) → off screen \(bounds), visible \(visible), following: \(self.following)") }
            else {
                let words = m.words.map { w in ", \(w.compactMap { $0 }.count)/\(w.count) word boxes" } ?? ""
                print("[highlight] \(label) → \(m.lines.count) line(s)\(words)")
            }
            self.show(m, in: visible, measuredAt: measuredAt)
        }
    }

    private func refreshHighlight() {
        if refreshing, Date().timeIntervalSince(refreshStarted) > 1, !refreshStuckLogged {
            refreshStuckLogged = true
            print("[unread] \(Self.clock()) highlight: a refresh has waited over 1 s for the Accessibility worker")
        }
        endGesture()
        guard !suspendHighlight, !refreshing, let current = queued.first?.sentence else { return }
        refreshing = true
        refreshStarted = Date()
        let token = highlightToken
        // Relocating walks the tree; not more than twice a second.
        let mayRelocate = Date().timeIntervalSince(lastRelocateAttempt) > 0.5
        let wantWords = wordBoxes?.range !== current.range
        Task { [weak self] in
            guard let m = await self?.measure(current, relocate: mayRelocate, scrollIfNeeded: false, wantWords: wantWords), let self else { return }
            self.refreshing = false
            self.refreshStuckLogged = false
            let started = self.refreshStarted
            self.logRefresh(m, took: Date().timeIntervalSince(started), current: current)
            if m.triedRelocate { self.lastRelocateAttempt = Date() }
            guard !self.cancelled, token == self.highlightToken, !self.suspendHighlight,
                  self.queued.first?.sentence.range === current.range else { return }
            if let fresh = m.relocated { self.queued[0].sentence = fresh }
            guard let bounds = Self.union(m.lines), let visible = m.visible else { return }
            // If the user scrolled the sentence away, stop dragging the page
            // back; resume following once it's on screen again.
            if Date() > self.followGraceUntil { self.following = visible.intersects(bounds) }
            self.show(m, in: visible, measuredAt: started)
        }
    }

    /// Scrolling investigation (Aside): each refresh that moves the highlight, loses it, or is slow, with the time.
    private func logRefresh(_ m: Measured, took: TimeInterval, current: Sentence) {
        let before = shownLines.flatMap { $0.range === current.range ? Self.union($0.lines) : nil }
        let now = Self.union(m.lines)
        let ms = Int(took * 1000)
        switch (before, now) {
        case (_, nil): print("[unread] \(Self.clock()) highlight refresh: no box (\(ms) ms)")
        case (let b?, let n?) where abs(b.minY - n.minY) > 2 || abs(b.height - n.height) > 2:
            print("[unread] \(Self.clock()) highlight refresh: \(Int(b.minY))→\(Int(n.minY)), \(Int(n.height)) tall, visible \(m.visible.map { "\(Int($0.minY))–\(Int($0.maxY))" } ?? "?") (\(ms) ms)")
        default: if ms > 250 { print("[unread] \(Self.clock()) highlight refresh: slow, \(ms) ms") }
        }
    }

    nonisolated static func clock() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    /// Draw the sentence's lines, clipped to the visible part of the
    /// document, and keep the word boxes in step with them.
    private func show(_ m: Measured, in visible: CGRect, measuredAt: Date) {
        guard let range = queued.first?.sentence.range else { return }
        if let words = m.words {
            wordBoxes = (range, words, m.lines)
        } else if let known = wordBoxes, known.range === range, !Self.sameShape(known.lines, m.lines) {
            wordBoxes = nil // reflowed: measure the words again on the next refresh
        }
        if m.scrolled { entry = nil } // the page moved: there's no gliding from where the last word was
        if let last = lastMove, last.range === range, !Self.sameRects(last.lines, m.lines) {
            let gap = measuredAt.timeIntervalSince(last.at)
            if gap > 0.05 { updateStep = min(updateStep ?? gap, gap) }
        }
        if lastMove.map({ $0.range !== range || !Self.sameRects($0.lines, m.lines) }) ?? true { lastMove = (range, m.lines, measuredAt) }
        switch scrollState {
        case .steady: break
        case .scrolling: return
        case .predicted(let predictedRange, let predicted, let from, let dy, let ended):
            guard predictedRange === range else { // the next sentence: nothing predicted for it
                scrollState = .settling
                overlay.hide()
                return show(m, in: visible, measuredAt: measuredAt)
            }
            guard measuredAt > lastScroll else { return }
            let off = (Self.union(m.lines)?.minY ?? 0) - (Self.union(predicted)?.minY ?? 0)
            let caughtUp = afterGesture.map { !Self.sameRects($0, m.lines) } ?? false
            if afterGesture == nil { afterGesture = m.lines }
            if Self.sameRects(predicted, m.lines, within: 3) { // confirmed
                print("[unread] \(Self.clock()) scroll: predicted place confirmed (\(Int(off)) px)")
            } else {
                // Corrected once the app has caught up: it moved since the gesture ended, or it has held still.
                guard (caughtUp && measuredAt.timeIntervalSince(ended) >= Self.bounce) || settled(range, m.lines, measuredAt) else { return }
                print("[unread] \(Self.clock()) scroll: predicted place corrected by \(Int(off)) px after \(Int(Date().timeIntervalSince(lastScroll) * 1000)) ms")
            }
            learnScale(from: from, to: m.lines, dy: dy, visible: visible)
        case .settling:
            guard measuredAt > lastScroll, settled(range, m.lines, measuredAt) else { return }
        }
        scrollState = .steady
        settling = nil
        shownLines = (range, m.lines, visible)
        draw(m.lines, in: visible)
    }

    private func learnScale(from: [CGRect], to: [CGRect], dy: CGFloat, visible: CGRect) {
        guard abs(dy) >= 40, let a = Self.union(from), let b = Self.union(to), abs(a.height - b.height) < 2,
              a.minY > visible.minY + 1, a.maxY < visible.maxY - 1, b.minY > visible.minY + 1, b.maxY < visible.maxY - 1 else { return }
        // A page zoomed between 75% and 125%; anything else ran into the page's top or bottom.
        let scale = (b.minY - a.minY) / dy
        guard scale > 0.75, scale < 1.25 else { return }
        scrollScale = (scrollScale + scale) / 2
        print("[unread] \(Self.clock()) scroll: the page moves \(String(format: "%.2f", scale))× the trackpad's distance")
    }

    /// The sentence has measured in the same place for `scrollSettle`, longer than Aside's half-second step.
    private func settled(_ range: AnyObject, _ lines: [CGRect], _ measuredAt: Date) -> Bool {
        if let s = settling, s.range === range, Self.sameRects(s.lines, lines) {
            return Date().timeIntervalSince(s.since) >= scrollSettle
        }
        settling = (range, lines, measuredAt)
        return false
    }

    /// Mark the word being heard at display time `t`, styled as chosen in
    /// Settings. Its box is the one measured with the sentence, moved by as
    /// much as the sentence's lines have moved since. Paused: the mark holds.
    private func tickWord(at t: CFTimeInterval) {
        let raw = player.position
        let position = clock.position(raw, at: t)
        if debugMotion, let raw, let position { print(String(format: "[frame] %.4f raw %d smooth %d", t, raw, position)) }
        guard !suspendHighlight, !hiddenForScroll, let playing = queued.first, let position,
              let words = wordBoxes, words.range === playing.sentence.range,
              let lines = shownLines, lines.range === playing.sentence.range,
              let from = words.lines.first, let to = lines.lines.first else { return }
        let style = HighlightSettings.shared.style
        let offset = position - playing.start
        let boxes = words.words.map { $0?.offsetBy(dx: to.minX - from.minX, dy: to.minY - from.minY) }
        let entry = self.entry.flatMap { $0.range === playing.sentence.range ? $0.box : nil }
        var shown: WordMarkFrame?
        if let mark = WordMark.frame(style, starts: playing.wordStarts, boxes: boxes, at: offset, entry: entry) {
            lastHead = (playing.sentence.range, mark.head.rect)
            let visible = lines.visible
            func clipped(_ s: MarkShape) -> MarkShape? {
                let r = s.rect.intersection(visible)
                guard !r.isNull, !r.isEmpty else { return nil }
                var c = s
                c.rect = r
                c.tail = s.tail.map { max($0, visible.minX) }
                return c
            }
            guard let head = clipped(mark.head) else {
                if markedWord != nil { markedWord = nil; overlay.hideWord() } // scrolled out of view
                return
            }
            shown = WordMarkFrame(head: head, ghost: mark.ghost.flatMap(clipped))
        }
        if let m = markedWord, m.range === playing.sentence.range, m.frame == shown, m.style == style { return }
        if debugSession, let index = WordTiming.current(playing.wordStarts, at: offset),
           loggedWord?.index != index || loggedWord?.range !== playing.sentence.range {
            loggedWord = (playing.sentence.range, index)
            print(String(format: "[word] %5.2fs into the sentence (due %.2fs): %@", Double(offset) / 24_000,
                         Double(playing.wordStarts[index] ?? 0) / 24_000, String(playing.sentence.words[index]).debugDescription))
        }
        markedWord = (playing.sentence.range, shown, style)
        overlay.showWord(shown)
    }

    nonisolated private static func sameRects(_ a: [CGRect], _ b: [CGRect], within d: CGFloat = 1) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0.minX - $1.minX) < d && abs($0.minY - $1.minY) < d && abs($0.height - $1.height) < d }
    }

    /// Same number of lines, each the same size: moved, not reflowed.
    nonisolated private static func sameShape(_ a: [CGRect], _ b: [CGRect]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0.width - $1.width) < 1 && abs($0.height - $1.height) < 1 }
    }

    nonisolated private static func union(_ lines: [CGRect]) -> CGRect? { lines.dropFirst().reduce(lines.first) { $0?.union($1) } }
}
