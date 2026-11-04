import AVFoundation
import FluidAudio
import NaturalLanguage

/// Owns the TTS models. Kept loaded and warm for the app's lifetime: the
/// first synthesis after load compiles for the Neural Engine and is slow,
/// every one after that is a few tens of milliseconds.
actor Voice {
    private let english = KokoroAneManager(variant: .english, version: .v3)
    private var french: KokoroAneManager?
    private(set) var englishVoice = "af_heart"

    func prepareEnglish() async throws {
        try await english.initialize(preloadVoices: [englishVoice])
        _ = try await english.synthesizeDetailed(text: "Ready to read.", voice: englishVoice)
    }

    /// French lives on Kokoro's legacy pipeline (v3 is English/JA/ZH only).
    func prepareFrench() async throws {
        let m = KokoroAneManager(variant: .french)
        try await m.initialize()
        _ = try await m.synthesizeDetailed(text: "Bonjour.")
        french = m
    }

    func setEnglishVoice(_ v: String) { englishVoice = v }

    /// Audio for `text`, with when each of its words (split at spaces) starts.
    func synthesize(_ text: String, language: NLLanguage, speed: Float) async throws -> Speech {
        let r = language == .french && french != nil
            ? try await french!.synthesizeDetailed(text: text, voice: "ff_siwis", speed: speed)
            : try await english.synthesizeDetailed(text: text, voice: englishVoice, speed: speed)
        let spoken = WordTiming.spokenWords(ids: r.inputIds, durations: r.predictedDurations, sampleCount: r.samples.count)
        let display = text.split(separator: " ")
        return Speech(samples: r.samples, wordStarts: WordTiming.starts(display: display, spoken: spoken, spokenText: r.normalizedText))
    }

    /// The voice's own view of a sentence, for `--words`.
    func spokenWords(_ text: String, language: NLLanguage) async throws -> (normalized: String?, phonemes: String, words: [WordTiming.Spoken]) {
        let r = language == .french && french != nil
            ? try await french!.synthesizeDetailed(text: text, voice: "ff_siwis")
            : try await english.synthesizeDetailed(text: text, voice: englishVoice)
        return (r.normalizedText, r.phonemes, WordTiming.spokenWords(ids: r.inputIds, durations: r.predictedDurations, sampleCount: r.samples.count))
    }
}

/// Picks English or French per sentence, but sticky: short or ambiguous
/// sentences keep the current language so a stray "Paris" doesn't flip it.
final class LanguageTracker {
    private(set) var current: NLLanguage = .english

    func language(for text: String) -> NLLanguage {
        guard text.count >= 24 else { return current }
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.english, .french]
        r.processString(text)
        let fr = r.languageHypotheses(withMaximum: 2)[.french] ?? 0
        if fr > 0.8 { current = .french } else if fr < 0.2 { current = .english }
        return current
    }
}

/// Gapless playback of synthesized sentences. The engine is started the
/// moment the hotkey goes down, so audio is ready before the key comes up.
@MainActor
final class Player {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var idleTimer: Timer?
    private(set) var isPaused = false
    /// Breath between sentences.
    private let gap = [Float](repeating: 0, count: 24_000 * 12 / 100)
    /// Two soft, overlapping bell-like notes (E5 → B5), quiet and short.
    private lazy var chimeBuffer: AVAudioPCMBuffer? = {
        let rate = 24_000.0, length = Int(rate * 0.6)
        var samples = [Float](repeating: 0, count: length)
        for (freq, start, amp) in [(659.25, 0.0, 0.10), (987.77, 0.11, 0.08)] {
            let first = Int(start * rate)
            for i in first..<length {
                let t = Double(i - first) / rate
                let envelope = min(t / 0.006, 1) * exp(-t / 0.12) // 6 ms attack, gentle decay
                // A quiet octave partial makes it a bell rather than a beep.
                let tone = sin(2 * .pi * freq * t) + 0.25 * sin(4 * .pi * freq * t)
                samples[i] += Float(amp * envelope * tone)
            }
        }
        return buffer(samples)
    }()

    init(muted: Bool = false) {
        engine.attach(node)
        if muted { engine.mainMixerNode.outputVolume = 0 }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    func warm() {
        idleTimer?.invalidate()
        if !engine.isRunning { try? engine.start() }
    }

    /// What follows a piece of speech.
    enum Ending {
        /// The breath that closes a sentence; `played` fires once it's heard.
        case sentence(played: @Sendable () -> Void)
        /// More of the same sentence, after `pause`: the clause break the
        /// piece ends with (#14).
        case clause(pause: [Float])
    }

    /// Schedule one piece of speech and the pause after it. `consumed` fires
    /// when the speech has been handed to the hardware (the pause is still
    /// ahead, so there's time to schedule what follows gaplessly).
    ///
    /// The session schedules one piece at a time on purpose: a buffer on the
    /// node can't be taken back, so audio waiting here couldn't follow a
    /// speed or voice change (#15).
    ///
    /// Returns where the speech starts on the player's timeline (see `position`).
    @discardableResult
    func schedule(_ samples: [Float], ending: Ending, consumed: @escaping @Sendable () -> Void) -> Int {
        warm()
        guard let speech = buffer(samples) else { return queueEnd }
        let (pause, played): ([Float], (@Sendable () -> Void)?)
        switch ending {
        case .sentence(let p): (pause, played) = (gap, p)
        case .clause(let p): (pause, played) = (p, nil)
        }
        let start = claim(samples.count + pause.count)
        node.scheduleBuffer(speech, completionCallbackType: .dataConsumed) { _ in consumed() }
        if let pause = buffer(pause) {
            node.scheduleBuffer(pause, completionCallbackType: .dataPlayedBack) { _ in played?() }
        }
        if !isPaused, !node.isPlaying { node.play() }
        return start
    }

    /// Where the audio queued on the node ends, in samples on its timeline.
    private var queueEnd = 0
    /// The node reports no time while paused; where it stood when paused.
    private var pausedAt: Int?

    /// Buffers play back to back; one scheduled after the node ran dry starts
    /// now. Reserve `count` samples from whichever is later.
    @discardableResult
    private func claim(_ count: Int) -> Int {
        let start = max(queueEnd, renderedPosition ?? pausedAt ?? 0)
        queueEnd = start + count
        return start
    }

    /// The sample on the player's timeline being rendered now (24 kHz). The
    /// timeline keeps running when the node runs out of audio, stops while
    /// paused (and reports nil), and restarts at 0 after `stop`.
    private var renderedPosition: Int? {
        guard let t = node.lastRenderTime, let p = node.playerTime(forNodeTime: t) else { return nil }
        return Int((Double(p.sampleTime) * 24_000 / p.sampleRate).rounded())
    }

    /// The sample being heard now, on the timeline `schedule` returns starts
    /// on: what's rendered minus the output's latency (Bluetooth adds ~150 ms).
    /// Nil while paused or stopped.
    var position: Int? {
        renderedPosition.map { $0 - Int(outputLatency * 24_000) }
    }

    /// The end-of-reading chime, through the same engine as speech so it
    /// follows the same output and volume.
    func chime() {
        guard let chimeBuffer else { return }
        warm()
        claim(Int(chimeBuffer.frameLength))
        node.scheduleBuffer(chimeBuffer)
        node.play()
        releaseDeviceLater()
    }

    private func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buf
    }

    /// Output device latency, as the engine reports it (Bluetooth adds a lot).
    var outputLatency: TimeInterval { engine.outputNode.presentationLatency }

    func pause() { pausedAt = renderedPosition; isPaused = true; node.pause() }
    func resume() { isPaused = false; warm(); node.play(); pausedAt = nil }

    func stop() {
        isPaused = false
        node.stop() // also resets the timeline to 0
        queueEnd = 0
        pausedAt = nil
        releaseDeviceLater()
    }

    /// Release the audio device after a while so Bluetooth headphones can sleep.
    private func releaseDeviceLater() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.stop() }
        }
    }
}

extension Speech {
    /// Peak level below which a 10 ms window counts as quiet.
    static let quietLevel: Float = 0.01
    static let window = 240

    /// Quiet samples at the start of the audio (Kokoro leads every chunk with ~0.3 s).
    var leadingQuiet: Int { quietRuns(in: 0..<samples.count).first.map { $0.lowerBound == 0 ? $0.count : 0 } ?? 0 }
    /// Quiet samples at the end of the audio (Kokoro ends every chunk with ~0.5 s).
    var trailingQuiet: Int { quietRuns(in: 0..<samples.count).last.map { $0.upperBound == samples.count ? $0.count : 0 } ?? 0 }

    /// The first `words` display words of this speech, cut where the voice
    /// pauses before the next word: the speech, and that pause (#14). With
    /// no pause there, it's cut at the quietest moment, with no pause.
    func cut(beforeWord words: Int) -> (speech: Speech, pause: [Float]) {
        let from = wordStarts.prefix(words).last { $0 != nil }.flatMap { $0 } ?? 0
        // Word starts run a little behind the voice; look just past the next one.
        let next = wordStarts.dropFirst(words).first { $0 != nil }.flatMap { $0 }.map { $0 + Self.window * 10 }
        let range = from..<min(next ?? samples.count, samples.count)
        let cut: Range<Int>
        if let pause = quietRuns(in: range).max(by: { $0.count < $1.count }), pause.count >= Self.window * 2 {
            cut = pause
        } else {
            let quietest = stride(from: range.lowerBound, to: range.upperBound, by: Self.window).min { a, b in
                peak(a) < peak(b)
            } ?? range.upperBound
            cut = quietest..<quietest
        }
        return (Speech(samples: Array(samples[..<cut.lowerBound]), wordStarts: Array(wordStarts.prefix(words))), Array(samples[cut]))
    }

    /// The same speech without the quiet it starts with, but for the last
    /// `keep` samples before the voice.
    func trimmingLeadingQuiet(keep: Int) -> Speech {
        let cut = max(leadingQuiet - keep, 0)
        guard cut > 0 else { return self }
        return Speech(samples: Array(samples[cut...]), wordStarts: wordStarts.map { $0.map { max($0 - cut, 0) } })
    }

    /// Stretches of quiet windows in `range`.
    func quietRuns(in range: Range<Int>) -> [Range<Int>] {
        var runs: [Range<Int>] = [], start: Int?
        let end = min(range.upperBound, samples.count)
        for w in stride(from: max(range.lowerBound, 0), to: end, by: Self.window) {
            if peak(w) < Self.quietLevel { start = start ?? w } else if let s = start { runs.append(s..<w); start = nil }
        }
        if let s = start { runs.append(s..<end) }
        return runs
    }

    private func peak(_ window: Int) -> Float {
        samples[window..<min(window + Self.window, samples.count)].reduce(0) { max($0, abs($1)) }
    }
}
