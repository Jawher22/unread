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

    func synthesize(_ text: String, language: NLLanguage, speed: Float) async throws -> [Float] {
        if language == .french, let french {
            return try await french.synthesizeDetailed(text: text, voice: "ff_siwis", speed: speed).samples
        }
        return try await english.synthesizeDetailed(text: text, voice: englishVoice, speed: speed).samples
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

    /// Schedule one sentence and the pause after it. `consumed` fires when the
    /// speech has been handed to the hardware (the pause is still ahead, so
    /// there's ~120 ms to schedule the next sentence gaplessly); `played` when
    /// the pause has been heard too.
    ///
    /// The session schedules one sentence at a time on purpose: a buffer
    /// on the node can't be taken back, so audio waiting here couldn't follow a
    /// speed or voice change (#15).
    func schedule(_ samples: [Float], consumed: @escaping @Sendable () -> Void, played: @escaping @Sendable () -> Void) {
        warm()
        guard let speech = buffer(samples), let pause = buffer(gap) else { return }
        node.scheduleBuffer(speech, completionCallbackType: .dataConsumed) { _ in consumed() }
        node.scheduleBuffer(pause, completionCallbackType: .dataPlayedBack) { _ in played() }
        if !isPaused, !node.isPlaying { node.play() }
    }

    /// The end-of-reading chime, through the same engine as speech so it
    /// follows the same output and volume.
    func chime() {
        guard let chimeBuffer else { return }
        warm()
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

    func pause() { isPaused = true; node.pause() }
    func resume() { isPaused = false; warm(); node.play() }

    func stop() {
        isPaused = false
        node.stop()
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
