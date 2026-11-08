import AVFoundation
import NaturalLanguage

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
    /// The cue for what a reading walks past without saying (#24, #26): two soft, muted taps on one low
    /// note (G4), the second quieter, 0.24 s. Picked by ear from three; nothing like the chime's rising bell.
    static let cueSound: [Float] = {
        let rate = 24_000.0
        var samples = [Float](repeating: 0, count: Int(rate * 0.24))
        // About as loud as speech (a speech window's peak is ~0.25): at 0.11 it went unheard on a laptop's speakers.
        for (start, amp) in [(0.0, 0.26), (0.09, 0.18)] {
            let first = Int(start * rate)
            for i in first..<min(first + Int(rate * 0.14), samples.count) {
                let t = Double(i - first) / rate
                let envelope = min(t / 0.004, 1) * exp(-t / 0.04)
                samples[i] += Float(amp * envelope * (sin(2 * .pi * 392 * t) + 0.35 * sin(2 * .pi * 784 * t)))
            }
        }
        return samples
    }()

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

    private var recording: AVAudioFile?

    /// Also write everything the player outputs, silences included, to `url`
    /// (`--simulate … --record`: hear pacing and voices without playing them).
    func record(to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in try? file.write(from: buffer) }
        recording = file
    }

    func finishRecording() {
        node.removeTap(onBus: 0)
        recording?.close()
        recording = nil
    }

    func warm() {
        idleTimer?.invalidate()
        if !engine.isRunning { try? engine.start() }
    }

    /// What follows a piece of speech.
    enum Ending {
        /// The quiet that closes a sentence (`Pacing`); `played` fires once it's heard.
        case sentence(pause: Int, played: @Sendable () -> Void)
        /// More of the same sentence follows, after `pause`: the next chunk of a
        /// sentence streaming into the player.
        case more(pause: [Float])
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
        case .sentence(let samples, let p): (pause, played) = ([Float](repeating: 0, count: samples), p)
        case .more(let p): (pause, played) = (p, nil)
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

    /// Quiet samples at the start of the audio.
    var leadingQuiet: Int { quietRuns(in: 0..<samples.count).first.map { $0.lowerBound == 0 ? $0.count : 0 } ?? 0 }
    /// Quiet samples at the end of the audio.
    var trailingQuiet: Int { quietRuns(in: 0..<samples.count).last.map { $0.upperBound == samples.count ? $0.count : 0 } ?? 0 }

    /// The same speech without the quiet it starts with, but for the last
    /// `keep` samples before the voice.
    func trimmingLeadingQuiet(keep: Int) -> Speech {
        let cut = max(leadingQuiet - keep, 0)
        guard cut > 0 else { return self }
        return Speech(samples: Array(samples[cut...]), wordStarts: wordStarts.map { $0.map { max($0 - cut, 0) } })
    }

    /// The same speech without the quiet it ends with, but for the first `keep` samples after the voice.
    func trimmingTrailingQuiet(keep: Int) -> Speech {
        let cut = max(trailingQuiet - keep, 0)
        guard cut > 0 else { return self }
        return Speech(samples: Array(samples.dropLast(cut)), wordStarts: wordStarts)
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
