import Foundation
import MLX
import MLXAudioTTS

// unread-narrator --ref-audio clip.wav --ref-text "Its exact transcript." [--model dir|repo-id]
// Unread's narrator voice (#57): loads the model, stays warm, and streams
// audio for one sentence at a time over the pipe protocol in Protocol.swift.

let writer = FrameWriter.takeStandardOutput()

func fail(_ message: String) -> Never {
    log(message)
    writer.send(.error, id: 0, message: message)
    _exit(1)
}

func option(_ name: String) -> String? {
    let args = CommandLine.arguments
    return args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
}

guard let refAudio = option("--ref-audio"), let refText = option("--ref-text") else {
    fail("usage: unread-narrator --ref-audio clip.wav --ref-text \"transcript\" [--model dir|repo-id]")
}
let modelSpec = option("--model") ?? "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"

// In Unread.app the helper is Contents/MacOS/unread-narrator and its Metal
// library is in Contents/Resources; in a dev build mlx finds it alongside.
let bundledMetallib = Bundle.main.executableURL!.deletingLastPathComponent()
    .appendingPathComponent("../Resources/mlx.metallib").standardizedFileURL
if FileManager.default.fileExists(atPath: bundledMetallib.path) {
    GPU.metallib = bundledMetallib
}

struct Ready: Encodable {
    let sampleRate: Int
    let loadMs: Int
    let voiceMs: Int
    let warmupMs: Int
}

func milliseconds(since start: ContinuousClock.Instant) -> Int {
    Int((ContinuousClock.now - start) / .milliseconds(1))
}

// Read stdin from the start, so the helper quits if Unread does while it loads.
let jobs = Jobs()
let (requests, incoming) = AsyncStream<SpeakRequest>.makeStream()
Thread.detachNewThread {
    while let line = readLine() {
        guard !line.isEmpty else { continue }
        do throws(Command.Invalid) {
            switch try Command.parse(line) {
            case .speak(let request):
                jobs.enqueue(request.id)
                incoming.yield(request)
            case .cancel(let id):
                jobs.cancel(id)
            }
        } catch {
            log("\(error)")
            writer.send(.error, id: error.id, message: "\(error)")
        }
    }
    // Unread closed the pipe or quit. _exit skips mlx's static destructors,
    // which can crash while a generation is still on the GPU.
    _exit(0)
}

let synthesizer: Synthesizer
do {
    var start = ContinuousClock.now
    let model = try await Qwen3TTSModel.fromModelDirectory(try ModelStaging.stage(modelSpec))
    let loadMs = milliseconds(since: start)
    start = .now
    synthesizer = try Synthesizer(model: model, refAudio: URL(fileURLWithPath: refAudio), refText: refText)
    let voiceMs = milliseconds(since: start)
    start = .now
    try await synthesizer.warmUp()
    let ready = Ready(sampleRate: model.sampleRate, loadMs: loadMs, voiceMs: voiceMs, warmupMs: milliseconds(since: start))
    log("ready: load \(ready.loadMs) ms, voice \(ready.voiceMs) ms, warm-up \(ready.warmupMs) ms")
    writer.send(.ready, id: 0, payload: try JSONEncoder().encode(ready))
} catch {
    fail("startup failed: \(error)")
}

for await request in requests {
    await jobs.run(request.id) { await synthesizer.speak(request, to: writer) }
}
