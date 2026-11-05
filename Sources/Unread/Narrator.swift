import Foundation
import NaturalLanguage
import QwenANE
import Synchronization

/// A designed voice the narrator clones (#60): a ~5 s clip and its transcript.
struct VoicePreset: Sendable {
    let name: String
    let description: String
    let transcript: String
    let audio: URL

    static func load(_ url: URL) throws -> VoicePreset {
        struct File: Decodable { let name, description, transcript, audio: String }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        return VoicePreset(name: file.name, description: file.description, transcript: file.transcript,
                           audio: url.deletingLastPathComponent().appendingPathComponent(file.audio))
    }

    /// Resources/Voices/<name>.json, from Unread.app or the checkout a dev build runs from.
    static func named(_ name: String) throws -> VoicePreset {
        let file = "Voices/\(name).json"
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(file), fm.fileExists(atPath: bundled.path) {
            return try load(bundled)
        }
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        while let current = dir, current.path != "/" {
            let candidate = current.appendingPathComponent("Resources/\(file)")
            if fm.fileExists(atPath: candidate.path) { return try load(candidate) }
            dir = current.deletingLastPathComponent()
        }
        throw Narrator.Failure.voiceMissing(name)
    }
}

/// The narrator voice (#62): Qwen3-TTS 1.7B Base cloning a preset, on the
/// Neural Engine through Core ML, in-process like Kokoro. Load once and keep
/// it: loading takes ~2 s, and the first load of a new binary path compiles
/// for the Neural Engine for about a minute.
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
    }

    static let sampleRate = 24_000
    /// Frames (80 ms each) per decoded chunk, the last repeating. Short at first for an early start,
    /// then growing no faster than synthesis gets ahead of playback (it runs at ~0.7× real time).
    /// The first size repeats until the voice starts (`ANEVocoder.speechStarted`), so the chunk with
    /// the onset can hold under 100 ms of audio; a second short one follows it. `[2, 4, 8, 12]` ran
    /// dry after the first chunk in 24 of 24 sentences, this in 2 (`--narrate --chunks`).
    static let chunkFrames = [2, 2, 3, 4, 6, 9, 12]
    /// A sentence is split when the talker's 1024-slot memory can't hold its prompt and audio at
    /// 1.5 frames a character (8.3 characters a second; the voice runs at 11–18).
    static let framesPerCharacter = 1.5
    static let maxPartCharacters = 200

    private let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let engine: QwenANEEngine
    private let voice: QwenVoiceFiles
    private let chunkFrames: [Int]
    nonisolated let startup: Startup
    private(set) var lastReport: Report?

    /// The model set from scripts/fetch-narrator.sh. `UNREAD_NARRATOR_MODEL` overrides the folder.
    /// The revision scripts/fetch-narrator.sh downloads and writes to the set's `.complete`.
    static let modelRevision = "552e9512c4618570df2b1b9c4a34373c018e0674"

    static var modelDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["UNREAD_NARRATOR_MODEL"] { return URL(fileURLWithPath: dir) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Unread/models/Qwen3-TTS-1.7B-Base-ANE")
    }

    /// Loads the model, encodes the preset's clip (cached after the first time) and warms both languages.
    static func load(preset: VoicePreset, chunkFrames: [Int] = chunkFrames) async throws -> Narrator {
        try await withCheckedThrowingContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(with: Result { try Narrator(preset: preset, models: modelDirectory, chunkFrames: chunkFrames) })
            }
        }
    }

    private init(preset: VoicePreset, models: URL, chunkFrames: [Int]) throws {
        let complete = try? String(contentsOf: models.appendingPathComponent(".complete"), encoding: .utf8)
        guard complete?.trimmingCharacters(in: .whitespacesAndNewlines) == Self.modelRevision else {
            throw Failure.modelMissing(models, revision: Self.modelRevision)
        }
        queue = DispatchSerialQueue(label: "unread.narrator", qos: .userInitiated)
        self.chunkFrames = chunkFrames
        var t = Date()
        engine = try QwenANEEngine(modelsDirectory: models)
        let engineTime = Date().timeIntervalSince(t)
        t = Date()
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Unread/narrator-voices")
            .appendingPathComponent(preset.audio.deletingPathExtension().lastPathComponent)
        voice = try QwenVoicePrep.prepared(referenceWAV: Data(contentsOf: preset.audio), transcript: preset.transcript,
                                           cacheDirectory: cache, modelsDirectory: models, kind: .qwen17)
        let voiceTime = Date().timeIntervalSince(t)
        t = Date()
        // Each language has its own prompt rows and talker memory prefix; build both now. Streaming too,
        // so the trimmer and every chunk size's first call are behind us.
        for language in ["en", "fr"] {
            _ = try engine.render(text: "Ready.", voice: voice, seed: 1, maxFrames: 3, chunkFrames: chunkFrames,
                                  language: language, onAudio: { _ in })
        }
        startup = Startup(engine: engineTime, voice: voiceTime, warmUp: Date().timeIntervalSince(t))
    }

    /// One sentence's audio at 24 kHz, streamed as it's synthesized, starting ~50 ms before the
    /// voice. Sentences are synthesized in the order they're asked for. Cancelling the consuming
    /// task, or dropping the stream, stops synthesis within a frame.
    nonisolated func speak(_ text: String, language: NLLanguage) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { stream in
            let flag = CancelFlag()
            stream.onTermination = { _ in flag.cancel() }
            // Straight onto the actor's queue: a Task per call could reach the actor out of order.
            queue.async { self.assumeIsolated { $0.synthesize(text, language: language == .french ? "fr" : "en", flag: flag, into: stream) } }
        }
    }

    /// Returns once nothing is being synthesized.
    func idle() {}

    private func synthesize(_ text: String, language: String, flag: CancelFlag,
                            into stream: AsyncThrowingStream<[Float], Error>.Continuation) {
        lastReport = nil
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
            stream.finish(throwing: Failure.nothingToSay)
            return
        }
        guard !flag.isCancelled else { stream.finish(); return }
        let start = Date()
        let firstDecode = Mutex<Double?>(nil)
        engine.onDecode = { firstDecode.withLock { $0 = $0 ?? Date().timeIntervalSince(start) } }
        defer { engine.onDecode = nil }
        let session = QwenTalkSession(engine: engine, voice: voice, language: language, seedText: text)
        let parts = parts(of: text, language: language)
        var leading = 0.0, stop = ""
        do {
            for (i, part) in parts.enumerated() {
                let r = try session.render(part, chunkFrames: chunkFrames, cancelled: { flag.isCancelled },
                                           onAudio: { stream.yield($0) })
                if i == 0 { leading = r.silenceBefore.leading }
                stop = r.stopReason.rawValue
                if r.stopReason == .cancelled { break }
            }
            stream.finish()
        } catch {
            stream.finish(throwing: error)
        }
        lastReport = Report(firstDecode: firstDecode.withLock { $0 }, leadingSilence: leading, parts: parts.count, stop: stop)
    }

    /// `text` whole, or in clause-sized parts when the talker's memory can't hold it.
    private func parts(of text: String, language: String) -> [String] {
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
