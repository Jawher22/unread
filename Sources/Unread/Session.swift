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
        let words: Range<Int>
        let take: Take
        let synthMs: Double
    }
    /// Nil if there was nothing to read at the aimed paragraph.
    let prepared: Task<Prepared?, Never>

    @MainActor
    static func prepare(_ doc: ReadableDocument, from start: AnyObject, kokoro: Voice, narrator: Narrator?, speed: Float,
                        settled: @escaping @MainActor () -> Void = {}) -> PrimedSentence {
        PrimedSentence(prepared: Task { @MainActor () -> Prepared? in
            let found = await AXWorker.shared.run { () -> (Sentence, ReadingScope?, Double)? in
                let t = Date()
                let scope = doc.scope(from: start)
                guard let sentence = doc.sentence(from: start, in: scope) else { return nil }
                return (sentence, scope, LatencyLog.ms(since: t))
            }
            guard let (sentence, scope, extractMs) = found else { settled(); return nil }
            let lang = LanguageTracker().language(for: sentence.text) // what a fresh session would pick
            let t = Date()
            if let narrator {
                defer { settled() }
                return Prepared(sentence: sentence, scope: scope, extractMs: extractMs, words: sentence.words.indices,
                                take: .narrator(NarratorTake(narrator, text: sentence.text, language: lang)), synthMs: 0)
            }
            let opening = OpeningClause.of(sentence)
            let speech = try? await kokoro.synthesize(OpeningClause.text(of: sentence, saying: opening), language: lang, speed: speed)
            settled()
            return Prepared(sentence: sentence, scope: scope, extractMs: extractMs, words: opening,
                            take: .kokoro(speech ?? Speech(samples: []), speed: speed), synthMs: LatencyLog.ms(since: t))
        })
    }

    func cancel() {
        let prepared = self.prepared
        Task { @MainActor in await prepared.value?.take.cancel() }
    }
}

/// Where to cut a reading's first sentence so the voice starts on its
/// opening clause while the rest is synthesized (#14). Kokoro doesn't
/// stream, so time to first audio grows with the length of what it's given.
enum OpeningClause {
    /// Split only if the rest is at least this long: synthesis takes
    /// ~40 ms + 1.45 ms per character (`--bench --split`), so this saves 90 ms or more.
    static let minRestChars = 60
    /// The opening clause is this many words, as close to `target` as the
    /// sentence's clause breaks allow.
    static let words = 4...14, target = 9

    /// The display words to synthesize first: the opening clause of a long
    /// sentence, or all of it.
    static func of(_ sentence: Sentence) -> Range<Int> {
        let all = sentence.words
        let cuts = words.filter { k in
            k < all.count && endsClause(all[k - 1]) && sentence.text(of: k..<all.count).count >= minRestChars
        }
        return cuts.min { abs($0 - target) < abs($1 - target) }.map { 0..<$0 } ?? all.indices
    }

    /// The opening clause is synthesized with this many of the following
    /// words, which are cut off: said alone, a clause ends falling like a
    /// sentence; with words after it, it ends as a comma does (`--bench --split`).
    static let lookahead = 3

    /// The text to synthesize for `words` of `sentence`: with the lookahead
    /// when more of the sentence follows.
    static func text(of sentence: Sentence, saying words: Range<Int>) -> String {
        sentence.text(of: words.lowerBound..<min(words.upperBound + lookahead, sentence.words.count))
    }

    /// A word a clause ends with: a trailing comma, semicolon, colon or dash
    /// (past closing quotes and brackets), or a dash on its own.
    static func endsClause(_ word: Substring) -> Bool {
        guard let last = word.last(where: { !"\"'”’»)]".contains($0) }) else { return false }
        return ",;:—–".contains(last) || word == "-"
    }
}

/// The quiet between sentences, as a narrator leaves it (#56): short inside
/// a paragraph, longer where one ends. Each piece of speech comes with its
/// own padding (Kokoro: ~0.3 s before the voice, ~0.5 s after, so every
/// sentence used to be followed by ~0.9 s). It's trimmed to `edge` on each
/// side and this pause put between, shorter at faster speeds.
enum Pacing {
    /// Seconds from one sentence's last sound to the next one's first, at 1×.
    static let sentence = 0.5, block = 1.0
    /// Quiet kept on each side of the voice, so onsets and tails aren't clipped.
    static let edge = 0.05
    /// The player schedules the next sentence during this pause, so it never goes below this.
    static let minPause = 0.12

    /// The pause to put after `sentence`, in samples at 24 kHz.
    static func pause(after sentence: Sentence, speed: Float) -> Int {
        let quiet = (sentence.endsBlock ? block : self.sentence) / Double(speed) - 2 * edge
        return Int(max(quiet, minPause) * 24_000)
    }

    static var edgeSamples: Int { Int(edge * 24_000) }
    static var edgeQuiet: [Float] { [Float](repeating: 0, count: edgeSamples) }
}

extension Sentence {
    /// The text of some of its display words.
    func text(of words: Range<Int>) -> String {
        words == self.words.indices ? text : self.words[words].joined(separator: " ")
    }
}

/// Reads one document from a starting point to the end. Keeps a few
/// sentences synthesized ahead of the one playing, and keeps the highlight
/// glued to the sentence on screen as the user scrolls.
@MainActor
final class ReadingSession {
    let document: ReadableDocument
    var speed: Float { didSet { if speed != oldValue { redo(\.take.isKokoro) } } }
    var narrator: Narrator? { didSet { if narrator !== oldValue { redo { _ in true } } } }
    var onFinish: (() -> Void)?

    private let kokoro: Voice
    private let player: Player
    private let overlay: Overlay
    private let language = LanguageTracker()
    private let lookahead = 3

    private var cursor: AnyObject?
    /// On the player, not yet finished. `first` is the one being spoken; at
    /// most one more piece is scheduled, in the current one's closing pause.
    private var queued: [Playing] = []
    private struct Playing {
        var sentence: Sentence
        /// Where its speech starts on the player's timeline.
        let start: Int
        /// The last piece of it scheduled (it's re-measured, so this is its identity).
        var lastSeq: Int
        /// When each display word starts, in samples from `start`. A split
        /// sentence's later words are filled in when the rest is scheduled.
        var wordStarts: [Int?]
    }
    /// Synthesized, waiting for the player. Can still be thrown away.
    private var ready: [Ready] = []
    /// Pieces to synthesize before extracting new sentences: the rest of a
    /// split first sentence, and audio thrown away by a speed or voice change.
    private var backlog: [Pending] = []
    /// Bumped by a speed or voice change; audio from an older generation is redone.
    private var generation = 0
    /// Pieces are numbered as they're extracted and played strictly in order.
    private var nextSeq = 0
    private var nextToPlay = 0
    /// The player has consumed everything handed to it and can take the next piece.
    private var playerWantsMore = true

    /// A sentence, or part of it, synthesized as one piece: a long first
    /// sentence is said as its opening clause and then the rest (#14).
    private struct Pending {
        let sentence: Sentence
        let language: NLLanguage
        let seq: Int
        /// The display words this piece says.
        let words: Range<Int>
        var text: String { OpeningClause.text(of: sentence, saying: words) }
        /// What the narrator says: not Kokoro's lookahead words, since streamed audio is on
        /// the player before it could be cut after them.
        var narrated: String { sentence.text(of: words) }
        var endsSentence: Bool { words.upperBound == sentence.words.count }
    }
    private struct Ready { let pending: Pending; let take: Take }
    /// Extracting or synthesizing the next sentence (one at a time).
    private var producing = false
    private var inFlight: NarratorTake?
    /// #15: a buffer on the player can't be taken back, so only the piece playing streams into it.
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

    init(document: ReadableDocument, start: AnyObject, speed: Float, kokoro: Voice, narrator: Narrator?, player: Player, overlay: Overlay,
         startedAt: Date, timing: LatencyRecord? = nil, primed: PrimedSentence? = nil) {
        self.document = document
        self.cursor = start
        self.speed = speed
        self.kokoro = kokoro
        self.narrator = narrator
        self.player = player
        self.overlay = overlay
        self.startedAt = startedAt
        self.timing = timing
        self.primed = primed
        self.primedSpeed = speed
    }

    func kokoroVoiceChanged() { redo(\.take.isKokoro) }

    private func redo(_ stale: (Ready) -> Bool) {
        generation += 1
        let dropped = ready.filter(stale)
        ready.removeAll(where: stale)
        for r in dropped {
            r.take.cancel()
            if case .narrator(let t) = r.take, t === inFlight { inFlight = nil; producing = false }
        }
        backlog = (dropped.map(\.pending) + backlog).sorted { $0.seq < $1.seq }
        if debugSession { print("[session] settings changed; \(backlog.count) piece(s) to synthesize") }
        fill()
    }

    func start() {
        if let primed { consume(primed) } else { fill() }
        refresh = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHighlight() }
        }
        // Every display frame, paced by the screen.
        overlay.setFrameHandler(self) { [weak self] t in self?.tickWord(at: t) }
    }

    func stop() {
        cancelled = true
        ready.forEach { $0.take.cancel() }
        live?.take.cancel()
        refresh?.invalidate()
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
        guard narrator != nil else { return }
        yielding = true
        if let t = inFlight, live?.take !== t { redo { if case .narrator(let r) = $0.take { r === t } else { false } } }
    }
    private var yielding = false

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
            guard let self, !self.cancelled else { prepared?.take.cancel(); return }
            self.producing = false
            guard let prepared else { self.fill(); return } // nothing prepared: start the normal way
            self.scope = prepared.scope
            self.scopeResolved = true
            self.cursor = prepared.sentence.next
            self.lastExtracted = prepared.sentence
            let lang = self.language.language(for: prepared.sentence.text) // keep language stickiness in step
            self.timing?.extractMs = prepared.extractMs
            let usable = switch prepared.take {
            case .kokoro: self.narrator == nil && self.speed == self.primedSpeed
            case .narrator: self.narrator != nil
            }
            guard usable else {
                prepared.take.cancel()
                self.backlog += self.pieces(of: prepared.sentence, language: lang, opening: self.opening(of: prepared.sentence))
                self.fill()
                return
            }
            let pieces = self.pieces(of: prepared.sentence, language: lang, opening: prepared.words)
            self.backlog += pieces.dropFirst()
            self.enqueue(pieces[0], take: prepared.take, synthMs: prepared.synthMs)
        }
    }

    /// The words a reading's first piece says: Kokoro starts on the opening clause of a long
    /// sentence (#14). The narrator streams, so it doesn't need to: its first audible chunk
    /// takes as long for 31 characters as for 194 (`--narrate`), and a clause said alone
    /// would lose the intonation it carries across the sentence.
    private func opening(of sentence: Sentence) -> Range<Int> {
        narrator == nil ? OpeningClause.of(sentence) : sentence.words.indices
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
                if self.queued.isEmpty, self.ready.isEmpty, self.backlog.isEmpty { self.finish() }
                return
            }
            self.lastExtracted = sentence
            self.cursor = sentence.next
            if self.timing != nil, self.timing?.extractMs == nil {
                self.timing?.extractMs = LatencyLog.ms(since: extractStart)
            }
            // Only the first sentence is split: later ones are synthesized
            // while earlier ones play.
            let first = self.nextSeq == 0
            let pieces = self.pieces(of: sentence, language: self.language.language(for: sentence.text),
                                     opening: first ? self.opening(of: sentence) : sentence.words.indices)
            self.backlog += pieces.dropFirst()
            self.synthesize(pieces[0])
        }
    }

    /// Number the pieces a sentence is said in: all of it, or `opening` and then the rest.
    private func pieces(of sentence: Sentence, language: NLLanguage, opening: Range<Int>) -> [Pending] {
        let all = sentence.words.indices
        let parts = opening == all || opening.isEmpty ? [all] : [opening, opening.upperBound..<all.upperBound]
        if nextSeq == 0, timing != nil {
            timing?.chars = sentence.text.count
            if parts.count > 1 { timing?.openingChars = OpeningClause.text(of: sentence, saying: opening).count }
        }
        return parts.map { words in
            defer { nextSeq += 1 }
            return Pending(sentence: sentence, language: language, seq: nextSeq, words: words)
        }
    }

    /// Synthesize at the current settings. If they change before it's done,
    /// the piece goes back into `backlog` instead of playing.
    private func synthesize(_ pending: Pending) {
        if let narrator {
            guard !yielding else {
                producing = false
                backlog = (backlog + [pending]).sorted { $0.seq < $1.seq }
                return
            }
            enqueue(pending, take: .narrator(NarratorTake(narrator, text: pending.narrated, language: pending.language)), synthMs: 0)
            return
        }
        let generation = self.generation, speed = self.speed, kokoro = self.kokoro
        Task { [weak self] in
            let synthStart = Date()
            let speech = try? await kokoro.synthesize(pending.text, language: pending.language, speed: speed)
            guard let self, !self.cancelled else { return }
            self.producing = false
            guard generation == self.generation else {
                self.backlog = (self.backlog + [pending]).sorted { $0.seq < $1.seq }
                self.fill()
                return
            }
            // Nothing to say (synthesis failed): keep its place so order holds, then skip it.
            self.enqueue(pending, take: .kokoro(speech ?? Speech(samples: []), speed: speed), synthMs: LatencyLog.ms(since: synthStart))
        }
    }

    private func enqueue(_ pending: Pending, take: Take, synthMs: Double) {
        guard !cancelled else { take.cancel(); return }
        ready.append(Ready(pending: pending, take: take))
        ready.sort { $0.pending.seq < $1.pending.seq }
        switch take {
        case .kokoro: if timing != nil, timing?.synthMs == nil { timing?.synthMs = synthMs }
        case .narrator(let t):
            t.onArrival = { [weak self, weak t] in if let self, let t { self.arrived(t) } }
            if !t.isComplete { inFlight = t; producing = true }
        }
        scheduleNext()
        fill()
    }

    private func arrived(_ take: NarratorTake) {
        guard !cancelled else { return }
        if debugSession {
            let piece = live?.take === take ? live?.pending : ready.first { if case .narrator(let t) = $0.take { t === take } else { false } }?.pending
            print(String(format: "[take] #%d (%d chars) %.0f ms: %d samples%@", piece?.seq ?? -1, piece?.text.count ?? 0,
                         Date().timeIntervalSince(take.started) * 1000, take.samples.count, take.isComplete ? " complete" : ""))
        }
        if take.isComplete, take === inFlight { inFlight = nil; producing = false }
        if live?.take === take { feed() } else { scheduleNext() }
        if take.isComplete { fill() }
    }

    /// Hand the next piece to the player, if it's ready and the player has
    /// consumed the previous one's speech (it's now in its closing pause).
    private func scheduleNext() {
        while !cancelled, live == nil, playerWantsMore, let next = ready.first, next.pending.seq == nextToPlay {
            let piece = next.pending
            let whole: Speech, speed: Float
            switch next.take {
            case .kokoro(let speech, let s): (whole, speed) = (speech, s)
            case .narrator(let take) where take.isComplete:
                (whole, speed) = (take.speech(words: piece.sentence.words[piece.words], speed: self.speed), self.speed)
            case .narrator(let take):
                guard take.samples.count >= Narrator.prebuffer(characters: piece.narrated.count, speed: self.speed) else { return }
                ready.removeFirst()
                nextToPlay += 1
                goLive(piece, take)
                return
            }
            ready.removeFirst()
            nextToPlay += 1
            let continues = piece.words.lowerBound > 0 && queued.last?.lastSeq == piece.seq - 1
            // Without the voice's lead-in: the pause before it is `Pacing`'s, or the
            // opening clause's own when this is the rest of a split sentence (#14).
            let speech = whole.trimmingLeadingQuiet(keep: Pacing.edgeSamples)
            // Nothing to say: skip it, unless the sentence playing needs it to end.
            guard !speech.samples.isEmpty || (continues && piece.endsSentence) else { continue }
            playerWantsMore = false
            spokeAnything = true
            let samples: [Float], ending: Player.Ending
            if piece.endsSentence || !next.take.isKokoro {
                // The rest of a split sentence follows a narrator piece after `Pacing.edge`, scheduled during it.
                let said = speech.trimmingTrailingQuiet(keep: piece.endsSentence ? Pacing.edgeSamples : 0).samples
                samples = said.isEmpty ? [0] : said
                ending = piece.endsSentence ? sentenceEnding(piece, speed: speed) : .clause(pause: Pacing.edgeQuiet)
            } else {
                // Cut off the lookahead. The clause's own pause gives the slack to schedule the rest gaplessly.
                let (clause, pause) = speech.cut(beforeWord: piece.words.count)
                samples = clause.samples
                ending = .clause(pause: pause)
            }
            if debugSession {
                let after: String
                switch ending {
                case .sentence(let pause, _): after = String(format: "+%.2fs%@", Double(pause) / 24_000, piece.sentence.endsBlock ? " ¶" : "")
                case .clause(let pause): after = String(format: "+%.2fs clause", Double(pause.count) / 24_000)
                }
                print(String(format: "[session] playing #%d at %.2g× (%.1fs %@) %@", piece.seq, speed,
                             Double(samples.count) / 24_000, after, piece.text.prefix(40).debugDescription))
            }
            let start = player.schedule(samples, ending: ending, consumed: consumedCallback())
            logScheduled(piece, from: start, to: start + samples.count, ending: ending)
            let last = place(piece, at: start, continues: continues), shift = start - queued[last].start
            for (word, s) in zip(piece.words, speech.wordStarts) { queued[last].wordStarts[word] = s.map { $0 + shift } }
            switch next.take {
            case .kokoro: firstAudio(samples, voice: .kokoro)
            case .narrator(let take): firstAudio(samples, voice: .narrator, synthMs: LatencyLog.ms(since: take.started))
            }
        }
    }

    private func sentenceEnding(_ piece: Pending, speed: Float) -> Player.Ending {
        .sentence(pause: Pacing.pause(after: piece.sentence, speed: speed), played: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.sentenceFinished() } }
        })
    }

    private func consumedCallback() -> @Sendable () -> Void {
        { [weak self] in DispatchQueue.main.async { MainActor.assumeIsolated { self?.speechConsumed() } } }
    }

    private func place(_ piece: Pending, at start: Int, continues: Bool) -> Int {
        if !continues {
            queued.append(Playing(sentence: piece.sentence, start: start, lastSeq: piece.seq, wordStarts: piece.sentence.words.map { _ in nil }))
            if queued.count == 1 { showCurrent(scroll: true) }
        }
        queued[queued.count - 1].lastSeq = piece.seq
        return queued.count - 1
    }

    private func goLive(_ piece: Pending, _ take: NarratorTake) {
        playerWantsMore = false
        spokeAnything = true
        live = Live(pending: piece, take: take, speed: speed, stretch: speed == 1 ? nil : TimeStretch(rate: Double(speed)))
        if debugSession {
            print(String(format: "[session] streaming #%d at %.2g× from %.2fs of audio %@", piece.seq, speed,
                         Double(take.samples.count) / 24_000, piece.text.prefix(40).debugDescription))
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
        let quiet = Speech(samples: out).trailingQuiet, edge = piece.endsSentence ? Pacing.edgeSamples : 0
        let keep = out.count - (complete ? max(quiet - edge, 0) : quiet)
        var said = Array(out[..<keep])
        l.held = Array(out[keep...])
        guard !said.isEmpty || complete else { live = l; return }
        if said.isEmpty { said = [0] }
        let ending: Player.Ending = !complete ? .clause(pause: []) : piece.endsSentence ? sentenceEnding(piece, speed: l.speed) : .clause(pause: Pacing.edgeQuiet)
        let consumed: @Sendable () -> Void = complete ? consumedCallback() : { @Sendable in }
        let start = player.schedule(said, ending: ending, consumed: consumed)
        let first = l.runs.isEmpty
        if first {
            l.voiced = Speech(samples: said).leadingQuiet
        } else if start != l.timeline(l.said) {
            if debugSession { print(String(format: "[session] underrun: #%d waited %.0f ms for audio", piece.seq, Double(start - l.timeline(l.said)) / 24)) }
        }
        if first || start != l.timeline(l.said) { l.runs.append((l.said, start)) }
        l.said += said.count
        let index = first ? place(piece, at: start, continues: piece.words.lowerBound > 0 && queued.last?.lastSeq == piece.seq - 1) : queued.count - 1
        let predicted = l.voiced + Int(Double(piece.narrated.count) / Narrator.pace / Double(l.speed) * 24_000)
        let end = complete ? l.said - min(quiet, edge) : max(predicted, l.said)
        let base = queued[index].start
        // Words the mark has reached keep their start, so it never steps back as the estimate grows
        // (the player reports no position while paused; the mark draws `lead` ahead).
        if let p = player.position { l.reached = max(l.reached, p - base + HighlightSettings.shared.style.lead.rawValue * 24) }
        for (word, s) in zip(piece.words, WordTiming.estimated(piece.sentence.words[piece.words], voiced: l.voiced..<max(l.voiced, end))) {
            if let old = queued[index].wordStarts[word], old <= l.reached { continue }
            queued[index].wordStarts[word] = s.map { l.timeline($0) - base }
        }
        if first { firstAudio(said, voice: .narrator, synthMs: LatencyLog.ms(since: l.take.started)) }
        if complete {
            logScheduled(piece, from: l.runs[0].at, to: l.timeline(l.said), ending: ending)
            live = nil
        } else {
            live = l
        }
    }

    private var loggedFirstAudio = false

    /// `synthMs`: the narrator's, from asking to playing; Kokoro's was recorded when it was synthesized.
    private func firstAudio(_ samples: [Float], voice: VoiceChoice, synthMs: Double? = nil) {
        guard !loggedFirstAudio else { return }
        loggedFirstAudio = true
        let ms = LatencyLog.ms(since: startedAt), voiceAt = Double(Speech(samples: samples).leadingQuiet) / 24
        if debugSession { print(String(format: "[session] first audio %.0f ms after start, the voice %.0f ms into it", ms, voiceAt)) }
        guard var t = timing else { return }
        // Measured after scheduling: that's when the buffer is queued on a running engine.
        t.firstAudioMs = ms
        t.outputLatencyMs = (player.outputLatency * 1000).rounded()
        t.voice = voice
        if let synthMs { t.synthMs = synthMs }
        timing = nil
        print(String(format: "[unread] first audio %.0f ms after release (%@%@, extract %.0f, synth %.0f, +%.0f device)",
                     t.firstAudioMs!, t.gesture.rawValue, voice == .narrator ? ", narrator" : "", t.extractMs ?? 0, t.synthMs ?? 0, t.outputLatencyMs!))
        LatencyLog.append(t)
    }

    private func logScheduled(_ piece: Pending, from: Int, to: Int, ending: Player.Ending) {
        guard debugSession else { return }
        let pause = switch ending {
        case .sentence(let pause, _): pause
        case .clause(let pause): pause.count
        }
        print("[sched] #\(piece.seq) speech \(from)..\(to) pause \(pause)\(piece.sentence.endsBlock && piece.endsSentence ? " ¶" : "")")
    }

    private func speechConsumed() {
        guard !cancelled else { return }
        playerWantsMore = true
        scheduleNext()
        fill()
    }

    private func sentenceFinished() {
        guard !cancelled, !queued.isEmpty else { return }
        if debugSession { print("[session] finished \(queued[0].sentence.text.prefix(40).debugDescription), \(queued.count - 1) queued") }
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
            self.show(m, in: visible)
        }
    }

    private func refreshHighlight() {
        guard !suspendHighlight, !refreshing, let current = queued.first?.sentence else { return }
        refreshing = true
        let token = highlightToken
        // Relocating walks the tree; not more than twice a second.
        let mayRelocate = Date().timeIntervalSince(lastRelocateAttempt) > 0.5
        let wantWords = wordBoxes?.range !== current.range
        Task { [weak self] in
            guard let m = await self?.measure(current, relocate: mayRelocate, scrollIfNeeded: false, wantWords: wantWords), let self else { return }
            self.refreshing = false
            if m.triedRelocate { self.lastRelocateAttempt = Date() }
            guard !self.cancelled, token == self.highlightToken, !self.suspendHighlight,
                  self.queued.first?.sentence.range === current.range else { return }
            if let fresh = m.relocated { self.queued[0].sentence = fresh }
            guard let bounds = Self.union(m.lines), let visible = m.visible else { return }
            // If the user scrolled the sentence away, stop dragging the page
            // back; resume following once it's on screen again.
            if Date() > self.followGraceUntil { self.following = visible.intersects(bounds) }
            self.show(m, in: visible)
        }
    }

    /// Draw the sentence's lines, clipped to the visible part of the
    /// document, and keep the word boxes in step with them.
    private func show(_ m: Measured, in visible: CGRect) {
        guard let range = queued.first?.sentence.range else { return }
        if let words = m.words {
            wordBoxes = (range, words, m.lines)
        } else if let known = wordBoxes, known.range === range, !Self.sameShape(known.lines, m.lines) {
            wordBoxes = nil // reflowed: measure the words again on the next refresh
        }
        if m.scrolled { entry = nil } // the page moved: there's no gliding from where the last word was
        shownLines = (range, m.lines, visible)
        let shown = m.lines.map { $0.intersection(visible) }.filter { !$0.isNull && !$0.isEmpty }
        if shown.isEmpty { overlay.hide(); markedWord = nil } else { overlay.show(shown, style: .reading, id: sentenceNumber) }
    }

    /// Mark the word being heard at display time `t`, styled as chosen in
    /// Settings. Its box is the one measured with the sentence, moved by as
    /// much as the sentence's lines have moved since. Paused: the mark holds.
    private func tickWord(at t: CFTimeInterval) {
        let raw = player.position
        let position = clock.position(raw, at: t)
        if debugMotion, let raw, let position { print(String(format: "[frame] %.4f raw %d smooth %d", t, raw, position)) }
        guard !suspendHighlight, let playing = queued.first, let position,
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

    /// Same number of lines, each the same size: moved, not reflowed.
    nonisolated private static func sameShape(_ a: [CGRect], _ b: [CGRect]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0.width - $1.width) < 1 && abs($0.height - $1.height) < 1 }
    }

    nonisolated private static func union(_ lines: [CGRect]) -> CGRect? { lines.dropFirst().reduce(lines.first) { $0?.union($1) } }
}
