import Foundation
import NaturalLanguage
import Synchronization

/// A narrator voice (#60): a short clip of the voice and its exact
/// transcript, which the narrator clones so every sentence sounds the same.
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

    /// Resources/Voices/london-storyteller.json, from Unread.app or the repo.
    static func named(_ name: String) throws -> VoicePreset {
        let file = "Voices/\(name).json"
        guard let url = NarratorFiles.locate(bundled: Bundle.main.resourceURL?.appendingPathComponent(file), repo: "Resources/\(file)") else {
            throw Narrator.Failure.missing("voice \(name)")
        }
        return try load(url)
    }
}

/// The narrator voice (#57): Qwen3-TTS in the `unread-narrator` helper
/// process, warm after `launch`, streaming each sentence's audio in chunks.
/// The pipe protocol is described in Narrator/Sources/unread-narrator/Protocol.swift.
final class Narrator: Sendable {
    /// What the helper reported once warm.
    struct Startup: Decodable, Sendable {
        let sampleRate: Int
        let loadMs: Int
        let voiceMs: Int
        let warmupMs: Int
    }

    enum Failure: Error, CustomStringConvertible {
        case missing(String)
        case helper(String)
        case exited(Int32)
        case cancelled

        var description: String {
            switch self {
            case .missing(let what): "narrator: \(what) not found"
            case .helper(let message): "narrator: \(message)"
            case .exited(let status): "narrator: helper exited (status \(status))"
            case .cancelled: "narrator: cancelled"
            }
        }
    }

    /// One sentence's audio. `chunks` yields Float samples at the startup's
    /// sample rate, finishes when the sentence is done, and throws
    /// `Failure.cancelled` after `cancel(id)`, or another `Failure`. Dropping
    /// `chunks` cancels the request too.
    struct Request: Sendable {
        let id: UInt32
        let chunks: AsyncThrowingStream<[Float], Error>
    }

    private enum Kind: UInt8 {
        case ready = 0, audio = 1, done = 2, cancelled = 3, error = 4
    }

    let startup: Startup
    let pid: Int32
    /// The helper's stdin; -1 once stopped, so a late write can't land in a reused descriptor.
    private let input: Mutex<Int32>
    /// Shared with the thread reading the helper's output, which must not
    /// keep the Narrator alive: dropping it is what stops the helper.
    private let requests = Requests()

    /// Starts the helper and returns once it has loaded the model, encoded
    /// the voice and warmed up: ~3 s, ~13 s the first time a new build runs.
    static func launch(voice: VoicePreset) async throws -> Narrator {
        guard let helper = NarratorFiles.locate(
            bundled: Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("unread-narrator"),
            repo: "Narrator/.build/release/unread-narrator"
        ) else { throw Failure.missing("unread-narrator (scripts/build-narrator.sh)") }

        let process = Process()
        process.executableURL = helper
        process.arguments = ["--ref-audio", voice.audio.path, "--ref-text", voice.transcript]
        let toHelper = Pipe(), fromHelper = Pipe()
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        try process.run()

        // Close-on-exec, so another helper launched later doesn't inherit them.
        let input = fcntl(toHelper.fileHandleForWriting.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        let output = fcntl(fromHelper.fileHandleForReading.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        // A write to a helper that has died must fail, not raise SIGPIPE in Unread.
        _ = fcntl(input, F_SETNOSIGPIPE, 1)
        try? toHelper.fileHandleForWriting.close()
        try? fromHelper.fileHandleForReading.close()

        let first = await withCheckedContinuation { done in
            Thread.detachNewThread { done.resume(returning: Frame.read(output)) }
        }
        if let first, first.kind == .ready, let startup = try? JSONDecoder().decode(Startup.self, from: first.payload) {
            let narrator = Narrator(startup: startup, pid: process.processIdentifier, input: input)
            let requests = narrator.requests
            Thread.detachNewThread { requests.receive(output, process: process) }
            return narrator
        }
        close(input)
        close(output)
        if first != nil { process.terminate() }
        process.waitUntilExit()
        if let first, first.kind == .error { throw Failure.helper(String(decoding: first.payload, as: UTF8.self)) }
        throw Failure.exited(process.terminationStatus)
    }

    private init(startup: Startup, pid: Int32, input: Int32) {
        self.startup = startup
        self.pid = pid
        self.input = Mutex(input)
    }

    deinit {
        stop()
    }

    func speak(_ text: String, language: NLLanguage) -> Request {
        struct Wire: Encodable { let id: UInt32; let text: String; let lang: String }
        let (chunks, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        // The request is written under the lock that numbers it, so requests
        // reach the helper, which runs them in arrival order, in id order.
        let id: UInt32? = requests.state.withLock { state in
            if let ended = state.ended {
                continuation.finish(throwing: ended)
                return nil
            }
            let id = state.nextID
            state.nextID += 1
            state.open[id] = continuation
            send(try? JSONEncoder().encode(Wire(id: id, text: text, lang: language == .french ? "fr" : "en")))
            return id
        }
        guard let id else { return Request(id: 0, chunks: chunks) }
        continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason { self?.cancel(id) }
        }
        return Request(id: id, chunks: chunks)
    }

    /// Stops a request. Its chunks end with `Failure.cancelled` once the
    /// helper has stopped generating.
    func cancel(_ id: UInt32) {
        send(Data("{\"cancel\":\(id)}".utf8))
    }

    /// Quits the helper (it exits when its input closes), freeing the model's memory.
    func stop() {
        input.withLock { fd in
            if fd >= 0 { close(fd) }
            fd = -1
        }
    }

    private func send(_ json: Data?) {
        guard var line = json else { return }
        line.append(UInt8(ascii: "\n"))
        input.withLock { input in
            guard input >= 0 else { return }
            line.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = write(input, buffer.baseAddress! + offset, buffer.count - offset)
                    if n < 0, errno == EINTR { continue }
                    if n <= 0 { return } // The helper is gone; receive() reports it.
                    offset += n
                }
            }
        }
    }

    private final class Requests: Sendable {
        struct State {
            var nextID: UInt32 = 1
            var open: [UInt32: AsyncThrowingStream<[Float], Error>.Continuation] = [:]
            /// Set once the helper is gone; every later request fails with it.
            var ended: Failure?
        }

        let state = Mutex(State())

        /// The helper's frames, on a thread of their own until it exits.
        func receive(_ output: Int32, process: Process) {
            while let frame = Frame.read(output) {
                let continuation = state.withLock { state in
                    frame.kind == .audio ? state.open[frame.id] : state.open.removeValue(forKey: frame.id)
                }
                switch frame.kind {
                case .audio:
                    continuation?.yield(frame.payload.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
                case .done:
                    continuation?.finish()
                case .cancelled:
                    continuation?.finish(throwing: Failure.cancelled)
                case .error where frame.id == 0:
                    print("[unread] narrator: \(String(decoding: frame.payload, as: UTF8.self))")
                case .error:
                    continuation?.finish(throwing: Failure.helper(String(decoding: frame.payload, as: UTF8.self)))
                case .ready:
                    break
                }
            }
            close(output)
            // A frame that doesn't parse leaves the stream out of step: end the helper too.
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            let failure = Failure.exited(process.terminationStatus)
            print("[unread] \(failure)")
            let open = state.withLock { state in
                state.ended = failure
                defer { state.open = [:] }
                return state.open.values
            }
            for continuation in open { continuation.finish(throwing: failure) }
        }
    }

    private struct Frame {
        let id: UInt32
        let kind: Kind
        let payload: Data

        /// The next frame, or nil once the helper has closed its output.
        static func read(_ fd: Int32) -> Frame? {
            guard let header = readExactly(fd, 9) else { return nil }
            let id = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
            let length = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 5, as: UInt32.self)) }
            guard let kind = Kind(rawValue: header[4]), let payload = readExactly(fd, Int(length)) else { return nil }
            return Frame(id: id, kind: kind, payload: payload)
        }

        private static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
            var data = Data(count: count)
            var offset = 0
            while offset < count {
                let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + offset, count - offset) }
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return nil }
                offset += n
            }
            return data
        }
    }
}

enum NarratorFiles {
    /// `bundled` inside Unread.app, else `repo` in the checkout a dev build
    /// runs from (found by walking up from the executable).
    static func locate(bundled: URL?, repo: String) -> URL? {
        let fm = FileManager.default
        if let bundled, fm.fileExists(atPath: bundled.path) { return bundled }
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        while let current = dir, current.path != "/" {
            let candidate = current.appendingPathComponent(repo)
            if fm.fileExists(atPath: candidate.path) { return candidate }
            dir = current.deletingLastPathComponent()
        }
        return nil
    }
}
