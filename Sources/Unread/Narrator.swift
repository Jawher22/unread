import Foundation
import NaturalLanguage
import QwenANE
import Synchronization

/// The narrator voice (#62): Qwen3-TTS 1.7B Base cloning a preset (#60), one
/// per language, on the Neural Engine through Core ML, in-process like Kokoro.
/// Load once and keep it: loading takes ~2 s, and the first load of a new
/// binary path compiles for the Neural Engine for about a minute.
///
/// Synthesis blocks for about the length of the audio, so the actor runs on
/// its own serial queue rather than the cooperative pool.
actor Narrator {
    enum Failure: Error, CustomStringConvertible {
        case modelMissing(URL, revision: String)
        case voiceMissing(String)
        case nothingToSay

        var description: String {
            switch self {
            case .modelMissing(let dir, let revision):
                "narrator: no model at revision \(revision.prefix(8)) in \(dir.path); run scripts/fetch-narrator.sh"
            case .voiceMissing(let name): "narrator: voice preset \(name) not found"
            case .nothingToSay: "narrator: no letters or digits to say"
            }
        }
    }

    /// Seconds each loading step took.
    struct Startup: Sendable {
        let engine: Double
        let voice: Double
        let warmUp: Double
    }

    /// How the last sentence went, for `--narrate`.
    struct Report: Sendable {
        /// Seconds from the start of synthesis to the first decoded chunk, silent or not.
        let firstDecode: Double?
        /// Quiet the model generated before the voice, in seconds (first part).
        let leadingSilence: Double
        let parts: Int
        let stop: String
        /// The first part's stages, and how many frames it made.
        let timings: QwenTimings?
        let frames: Int
    }

    static let sampleRate = 24_000
    /// Frames (80 ms each) per decoded chunk, the last repeating. Short at first for an early start,
    /// then growing no faster than synthesis gets ahead of playback (it runs at ~0.7× real time).
    /// The first size repeats until the voice starts (`ANEVocoder.speechStarted`), so the chunk with
    /// the onset can hold under 100 ms of audio; a second short one follows it. `[2, 4, 8, 12]` ran
    /// dry after the first chunk in 24 of 24 sentences, `[2, 2, 3, 4, 6, 9, 12]` in 2 (`--narrate --chunks`).
    /// Capped at 4 frames, a streamed sentence arrives evenly enough to be played sped up: a 12-frame
    /// chunk takes ~650 ms to make. Speed is unchanged (`--narrate`: RTF 0.74 vs 0.72). Replaying the
    /// chunk arrivals of ~50 sentences read with `--simulate`, a player starting 0.1 s in at 1× ran
    /// dry in 2 of 49 (worst 7 ms) instead of 4 of 48 (worst 186 ms), and at 1.3× in 25 instead of 48.
    static let chunkFrames = [2, 2, 3, 4]
    /// A sentence is split when the talker's 1024-slot memory can't hold its prompt and audio at
    /// 1.5 frames a character (8.3 characters a second; the voice runs at 11–18).
    static let framesPerCharacter = 1.5
    static let maxPartCharacters = 200

    /// Characters a second at 1× for a preset that wasn't measured, and seconds of synthesis per
    /// second of audio (`--narrate`, §7).
    static let pace = 14.9, realTimeFactor = 0.75
    /// Audio a streamed piece needs before it starts playing, in samples at 1×: 0.1 s of playback
    /// at 1×, 0.2 s at 1.2×, 0.3 s at 1.4×, since sped up it drains faster than the chunks come;
    /// and past ~1.3×, where playback outruns synthesis, enough that the stream ends just as
    /// playback catches up (`audio` arrives in `audio * realTimeFactor` and plays in `audio / speed`).
    /// Replaying the chunk arrivals of 49 sentences, none ran dry at 1.15–2× (2 at 1×, by ≤ 7 ms),
    /// for a median 0.1 s more before first audio at 1.15×, 0.2 s at 1.3×, 0.36 s at 1.5×, 0.95 s at 2×.
    static func prebuffer(characters: Int, speed: Float, pace: Double) -> Int {
        let speed = Double(speed), audio = Double(characters) / pace
        let playback: Double = 0.1 + 0.5 * max(speed - 1, 0), catchUp: Double = audio * (1 - 1 / (speed * realTimeFactor))
        return Int(max(playback * speed, catchUp) * Double(sampleRate))
    }

    private let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let engine: QwenANEEngine
    /// A preset ready to speak: its clip encoded.
    private struct Clone { let preset: VoicePreset; let files: QwenVoiceFiles }
    /// By the engine's language code. French is read in the English voice if it has none.
    private var voices: [String: Clone]
    private let paces: Mutex<[String: Double]>
    private let chunkFrames: [Int]
    nonisolated let startup: Startup
    nonisolated let workingSet: WorkingSet
    /// Times its English words (#58): the model reports none. Nil if it couldn't load; words are then estimated.
    nonisolated var aligner: Aligner? { alignerSlot.withLock { $0 } }
    private let alignerSlot = Mutex<Aligner?>(nil)
    private(set) var lastReport: Report?

    /// The model set from scripts/fetch-narrator.sh. `UNREAD_NARRATOR_MODEL` overrides the folder.
    /// The revision scripts/fetch-narrator.sh downloads and writes to the set's `.complete`.
    static let modelRevision = "552e9512c4618570df2b1b9c4a34373c018e0674"

    static var modelDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["UNREAD_NARRATOR_MODEL"] { return URL(fileURLWithPath: dir) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Unread/models/Qwen3-TTS-1.7B-Base-ANE")
    }

    /// The model set is on disk at the revision this build reads.
    nonisolated static func isInstalled(at models: URL = modelDirectory) -> Bool {
        let complete = try? String(contentsOf: models.appendingPathComponent(".complete"), encoding: .utf8)
        return complete?.trimmingCharacters(in: .whitespacesAndNewlines) == modelRevision
    }

    /// Loads the model, encodes each preset's clip (cached after the first time) and warms both languages.
    /// Loads the aligner alongside (~0.2 s; its first load downloads ~100 MB and compiles for about 50 s).
    static func load(english: VoicePreset, french: VoicePreset?, chunkFrames: [Int] = chunkFrames) async throws -> Narrator {
        async let aligner = loadAligner()
        let narrator = try await withCheckedThrowingContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(with: Result { try Narrator(english: english, french: french, models: modelDirectory, chunkFrames: chunkFrames) })
            }
        }
        let loaded = await aligner
        narrator.alignerSlot.withLock { $0 = loaded }
        return narrator
    }

    private static func loadAligner() async -> Aligner? {
        do { return try await Aligner.load() } catch {
            print("[narrator] no word timing, words are estimated: \(error)")
            return nil
        }
    }

    private init(english: VoicePreset, french: VoicePreset?, models: URL, chunkFrames: [Int]) throws {
        guard Self.isInstalled(at: models) else { throw Failure.modelMissing(models, revision: Self.modelRevision) }
        queue = DispatchSerialQueue(label: "unread.narrator", qos: .userInitiated)
        self.chunkFrames = chunkFrames
        let mappedBefore = Set(MappedFiles.regions().map(\.address))
        var t = Date()
        engine = try QwenANEEngine(modelsDirectory: models)
        let engineTime = Date().timeIntervalSince(t)
        t = Date()
        var voices = ["en": try Self.clone(english, models: models)]
        if let french { voices["fr"] = try Self.clone(french, models: models) }
        let voiceTime = Date().timeIntervalSince(t)
        t = Date()
        for language in ["en", "fr"] {
            try Self.warm(engine, (voices[language] ?? voices["en"]!).files, language: language, chunkFrames: chunkFrames)
        }
        self.voices = voices
        paces = Mutex(voices.compactMapValues(\.preset.pace))
        startup = Startup(engine: engineTime, voice: voiceTime, warmUp: Date().timeIntervalSince(t))
        workingSet = WorkingSet(MappedFiles.regions().filter { !mappedBefore.contains($0.address) })
        workingSet.note()
    }

    /// The preset's clip encoded for the model: about a second the first time, then read back from a cache.
    private static func clone(_ preset: VoicePreset, models: URL) throws -> Clone {
        let files = try QwenVoicePrep.prepared(referenceWAV: Data(contentsOf: preset.audio), transcript: preset.transcript,
                                               cacheDirectory: cacheDirectory(preset), modelsDirectory: models, kind: .qwen17)
        return Clone(preset: preset, files: files)
    }

    static func cacheDirectory(_ preset: VoicePreset) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Unread/narrator-voices")
            .appendingPathComponent(preset.audio.deletingPathExtension().lastPathComponent)
    }

    /// Each voice and language has its own prompt rows, talker memory prefix and vocoder priming:
    /// build them with a line nobody hears. Streaming too, so the trimmer and every chunk size's
    /// first call are behind us.
    private static func warm(_ engine: QwenANEEngine, _ voice: QwenVoiceFiles, language: String, chunkFrames: [Int]) throws {
        _ = try engine.render(text: "Ready.", voice: voice, seed: 1, maxFrames: 3, chunkFrames: chunkFrames,
                              language: language, onAudio: { _ in })
    }

    /// What a switch cost, in seconds: encoding the clip (or reading it back), and warming the voice.
    struct Switch: Sendable {
        let clone: Double
        let warm: Double
    }

    /// Reads the preset's language in `preset` from the next sentence asked for on. The sentence
    /// being synthesized finishes first, in the old voice. Nil when it's the voice already.
    func use(_ preset: VoicePreset) throws -> Switch? {
        let language = Self.code(preset.language)
        guard voices[language]?.preset.id != preset.id else { return nil }
        var t = Date()
        let clone = try Self.clone(preset, models: Self.modelDirectory)
        let cloneTime = Date().timeIntervalSince(t)
        t = Date()
        try Self.warm(engine, clone.files, language: language, chunkFrames: chunkFrames)
        voices[language] = clone
        paces.withLock { $0[language] = preset.pace }
        return Switch(clone: cloneTime, warm: Date().timeIntervalSince(t))
    }

    /// Characters a second at 1× in the voice that reads `language`.
    nonisolated func pace(for language: NLLanguage) -> Double {
        paces.withLock { $0[Self.code(language)] } ?? Self.pace
    }

    private static func code(_ language: NLLanguage) -> String { language == .french ? "fr" : "en" }

    /// One sentence's audio at 24 kHz, streamed as it's synthesized, starting ~50 ms before the
    /// voice. Sentences are synthesized in the order they're asked for. Cancelling the consuming
    /// task, or dropping the stream, stops synthesis within a frame.
    ///
    /// `after`: the sentence before it in the same paragraph. If that was the last one said, and
    /// in full, this one carries on from it (#56): the talker hears its text and audio before this
    /// one's, as it does between the parts of a long sentence, so the paragraph is one performance.
    nonisolated func speak(_ text: String, language: NLLanguage, after previous: String? = nil) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { stream in
            let flag = CancelFlag()
            stream.onTermination = { _ in flag.cancel() }
            // Straight onto the actor's queue: a Task per call could reach the actor out of order.
            queue.async { self.assumeIsolated { $0.synthesize(text, language: Self.code(language), after: previous, flag: flag, into: stream) } }
        }
    }

    /// The session the last sentence was said in, kept for the next one to carry on from.
    private var lastSaid: (text: String, language: String, voice: String, session: QwenTalkSession)?

    /// Returns once nothing is being synthesized.
    func idle() {}

    /// ⌃ went down: a sentence may be asked for soon. After a while unused, the narrator's
    /// first sentence is slow (`--narrate --idle`): macOS has dropped its mapped files, and the
    /// Neural Engine has gone cold. Read the files back in the background, and warm up with a
    /// 4-frame line if it's been idle (two vocoder calls: its first-chunk and later-chunk programs),
    /// so the hold's speculation starts warm.
    nonisolated func wake(prefetch: Bool = true, warm: Bool = true) {
        if prefetch { DispatchQueue.global(qos: .userInitiated).async { self.workingSet.prefetch() } }
        if warm { queue.async { self.assumeIsolated { $0.rewarm() } } }
    }

    /// Seconds idle after which a sentence starts measurably slower (prefill ~2× at 10 s).
    static let coldAfter: TimeInterval = 5
    private var lastActive = Date()

    private func rewarm() {
        guard Date().timeIntervalSince(lastActive) > Self.coldAfter else { return }
        _ = try? engine.render(text: "Ready.", voice: (voices[lastLanguage] ?? voices["en"]!).files, seed: 1, maxFrames: 4, chunkFrames: [2],
                               language: lastLanguage, onAudio: { _ in })
        lastActive = Date()
    }
    private var lastLanguage = "en"

    private func synthesize(_ text: String, language: String, after previous: String?, flag: CancelFlag,
                            into stream: AsyncThrowingStream<[Float], Error>.Continuation) {
        lastReport = nil
        let carried = lastSaid
        lastSaid = nil
        defer {
            lastActive = Date()
            lastLanguage = language
            DispatchQueue.global(qos: .utility).async { [workingSet] in workingSet.note() }
        }
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
            stream.finish(throwing: Failure.nothingToSay)
            return
        }
        guard !flag.isCancelled else { stream.finish(); return }
        let start = Date()
        let firstDecode = Mutex<Double?>(nil)
        engine.onDecode = { firstDecode.withLock { $0 = $0 ?? Date().timeIntervalSince(start) } }
        defer { engine.onDecode = nil }
        let clone = voices[language] ?? voices["en"]!, voice = clone.files
        let session: QwenTalkSession
        if let previous, let carried, carried.text == previous, carried.language == language, carried.voice == clone.preset.id {
            session = carried.session
        } else {
            session = QwenTalkSession(engine: engine, voice: voice, language: language, seedText: text)
        }
        let parts = parts(of: text, voice: voice, language: language)
        var leading = 0.0, stop = "", timings: QwenTimings?, frames = 0
        do {
            for (i, part) in parts.enumerated() {
                let r = try session.render(part, chunkFrames: chunkFrames, cancelled: { flag.isCancelled },
                                           onAudio: { stream.yield($0) })
                if i == 0 { leading = r.silenceBefore.leading; timings = r.timings; frames = r.frames }
                stop = r.stopReason.rawValue
                if r.stopReason == .cancelled { break }
            }
            if stop != QwenStopReason.cancelled.rawValue { lastSaid = (text, language, clone.preset.id, session) }
            stream.finish()
        } catch {
            stream.finish(throwing: error)
        }
        lastReport = Report(firstDecode: firstDecode.withLock { $0 }, leadingSilence: leading, parts: parts.count, stop: stop,
                            timings: timings, frames: frames)
    }

    /// `text` whole, or in clause-sized parts when the talker's memory can't hold it.
    private func parts(of text: String, voice: QwenVoiceFiles, language: String) -> [String] {
        let needed = Int(Double(text.count) * Self.framesPerCharacter)
        if let room = try? engine.maxFrames(text: text, voice: voice, language: language), room >= needed { return [text] }
        return QwenReadRules.split(text, maxPartChars: Self.maxPartCharacters)
    }
}

private final class CancelFlag: Sendable {
    private let value = Atomic<Bool>(false)
    var isCancelled: Bool { value.load(ordering: .relaxed) }
    func cancel() { value.store(true, ordering: .relaxed) }
}
