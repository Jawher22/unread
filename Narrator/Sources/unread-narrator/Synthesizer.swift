import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS
import Synchronization

/// Qwen3-TTS Base cloning one reference clip. The clip is encoded once per
/// language at startup, so a request pays only for its own text.
struct Synthesizer: Sendable {
    static let streamingInterval = 0.16

    let model: Qwen3TTSModel
    private let voices: [Language: Qwen3TTSModel.Qwen3TTSReferenceConditioning]

    init(model: Qwen3TTSModel, refAudio: URL, refText: String) throws {
        let (_, audio) = try loadAudioArray(from: refAudio, sampleRate: model.sampleRate)
        var voices: [Language: Qwen3TTSModel.Qwen3TTSReferenceConditioning] = [:]
        for language in [Language.en, .fr] {
            voices[language] = try model.prepareReferenceConditioning(refAudio: audio, refText: refText, language: language.qwenName)
        }
        self.model = model
        self.voices = voices
    }

    /// The audio for `text`, chunk by chunk. Dropping `chunks` cancels the
    /// generation; `exited` says when it has really stopped.
    func generate(_ text: String, _ language: Language) -> (chunks: AsyncThrowingStream<AudioGeneration, Error>, exited: GenerationExit) {
        let (exited, onExit) = AsyncStream<Never>.makeStream()
        let chunks = GenerationExit.Sentinel.$current.withValue(GenerationExit.Sentinel(onExit)) {
            model.generateStream(
                text: text,
                conditioning: voices[language]!,
                generationParameters: model.defaultGenerationParameters,
                streamingInterval: Self.streamingInterval
            )
        }
        return (chunks, GenerationExit(stream: exited))
    }

    func warmUp() async throws {
        let (chunks, exited) = generate("Ready to read.", .en)
        if await exited.wait(timeout: .milliseconds(20)) {
            throw GenerationExit.Unobservable()
        }
        for try await _ in chunks {}
        _ = await exited.wait(timeout: .seconds(5))
    }

    /// Streams one request's audio to Unread and ends it with done, cancelled
    /// or error, sent only once the generation has stopped.
    func speak(_ request: SpeakRequest, to writer: FrameWriter) async {
        if Task.isCancelled { return writer.send(.cancelled, id: request.id) }
        let (chunks, exited) = generate(request.text, request.language)
        var failure: Error?
        do {
            for try await event in chunks {
                if case .audio(let chunk) = event {
                    writer.send(audio: chunk.asArray(Float.self), id: request.id)
                }
            }
        } catch {
            failure = error
        }
        let cancelled = Task.isCancelled
        // This task may be cancelled, which would cut the wait short.
        let stopped = await Task { await exited.wait(timeout: .seconds(5)) }.value
        if !stopped { log("request \(request.id): generation still running 5 s after it ended") }
        if cancelled {
            writer.send(.cancelled, id: request.id)
        } else if let failure {
            writer.send(.error, id: request.id, message: "\(failure)")
        } else {
            writer.send(.done, id: request.id)
        }
    }
}

/// When the library's generation task has exited. mlx-audio-swift runs each
/// generation in its own unstructured Task and cancels it when the stream is
/// dropped, but gives no way to wait for it, and the cancelled task resets
/// the shared speech decoder on its way out, which would corrupt a generation
/// started meanwhile. Unstructured tasks inherit task-local values, so that
/// task holds the only reference to a Sentinel and releases it as it ends.
struct GenerationExit: Sendable {
    final class Sentinel: Sendable {
        @TaskLocal static var current: Sentinel?
        private let onExit: AsyncStream<Never>.Continuation
        init(_ onExit: AsyncStream<Never>.Continuation) { self.onExit = onExit }
        deinit { onExit.finish() }
    }

    let stream: AsyncStream<Never>

    /// The library no longer runs generation in a task that inherits task
    /// locals, so a cancel can't wait for it. Found by the warm-up.
    struct Unobservable: Error, CustomStringConvertible {
        let description = "can't tell when a generation ends (did mlx-audio-swift change how it runs one?)"
    }

    /// False if the generation was still running after `timeout`.
    func wait(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream {}
                return !Task.isCancelled
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let stopped = await group.next()!
            group.cancelAll()
            return stopped
        }
    }
}

/// The request being generated and the ones queued behind it, so a cancel
/// reaches a request wherever it is.
final class Jobs: Sendable {
    private struct State {
        var queued: [UInt32: Bool] = [:]
        var running: (id: UInt32, task: Task<Void, Never>)?
    }

    private let state = Mutex(State())

    func enqueue(_ id: UInt32) {
        state.withLock { $0.queued[id] = false }
    }

    func cancel(_ id: UInt32) {
        state.withLock { state in
            if let running = state.running, running.id == id {
                running.task.cancel()
            } else if state.queued[id] != nil {
                state.queued[id] = true
            }
        }
    }

    func run(_ id: UInt32, _ body: @escaping @Sendable () async -> Void) async {
        let task = Task { await body() }
        let cancelled = state.withLock { state in
            state.running = (id, task)
            return state.queued.removeValue(forKey: id) ?? false
        }
        if cancelled { task.cancel() }
        await task.value
        state.withLock { $0.running = nil }
    }
}
