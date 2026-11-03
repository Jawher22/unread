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

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    func warm() {
        idleTimer?.invalidate()
        if !engine.isRunning { try? engine.start() }
    }

    func schedule(_ samples: [Float], played: @escaping @Sendable () -> Void) {
        warm()
        let all = samples + gap
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(all.count)) else { return }
        buf.frameLength = AVAudioFrameCount(all.count)
        all.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: all.count) }
        node.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { _ in played() }
        if !isPaused, !node.isPlaying { node.play() }
    }

    func pause() { isPaused = true; node.pause() }
    func resume() { isPaused = false; warm(); node.play() }

    func stop() {
        isPaused = false
        node.stop()
        // Release the audio device after a while so Bluetooth headphones can sleep.
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.stop() }
        }
    }
}
