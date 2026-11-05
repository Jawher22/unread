import Foundation
import Synchronization

// The pipe protocol between Unread and this helper. Unread's side is
// Sources/Unread/Narrator.swift; change both together.
//
// stdin, one JSON object per line:
//   {"id":1,"text":"A sentence.","lang":"en"}   synthesize ("en" or "fr"); ids are the client's, nonzero
//   {"cancel":1}                                 stop request 1
// Closing stdin quits the helper.
//
// stdout, binary frames: UInt32 id, UInt8 kind, UInt32 payload length (all
// little-endian), then the payload. Every request ends with exactly one of
// done, cancelled or error; audio frames come before it.
//   ready      id 0, once after warm-up. JSON: sampleRate, loadMs, voiceMs, warmupMs
//   audio      Float32 PCM, mono, at sampleRate
//   done       empty
//   cancelled  empty; sent once generation has actually stopped
//   error      UTF-8 message; id 0 is a startup or protocol error
// Logs go to stderr.

enum FrameKind: UInt8 {
    case ready = 0, audio = 1, done = 2, cancelled = 3, error = 4
}

enum Language: String, Sendable {
    case en, fr

    var qwenName: String {
        switch self {
        case .en: "english"
        case .fr: "french"
        }
    }
}

struct SpeakRequest: Sendable {
    let id: UInt32
    let text: String
    let language: Language
}

enum Command: Sendable {
    case speak(SpeakRequest)
    case cancel(UInt32)

    struct Invalid: Error, CustomStringConvertible {
        /// The request it ends, or 0 when there's no telling.
        var id: UInt32 = 0
        let description: String
    }

    static func parse(_ line: String) throws(Invalid) -> Command {
        struct Wire: Decodable {
            var id: UInt32?
            var text: String?
            var lang: String?
            var cancel: UInt32?
        }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: Data(line.utf8))
        } catch {
            throw Invalid(description: "not a command: \(line.prefix(200))")
        }
        if let id = wire.cancel { return .cancel(id) }
        guard let id = wire.id, id != 0, let text = wire.text else {
            throw Invalid(description: "a request needs a nonzero id and text: \(line.prefix(200))")
        }
        // The model says something for any input, up to ~6 s of it for none.
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
            throw Invalid(id: id, description: "nothing to say: \(text.prefix(200))")
        }
        guard let language = Language(rawValue: wire.lang ?? "en") else {
            throw Invalid(id: id, description: "unknown lang \(wire.lang ?? "")")
        }
        return .speak(SpeakRequest(id: id, text: text, language: language))
    }
}

/// Writes frames to the protocol descriptor. Libraries print to stdout, so
/// the protocol runs on a private duplicate and fd 1 is pointed at stderr.
final class FrameWriter: Sendable {
    private let fd: Mutex<Int32>

    /// Moves the protocol off fd 1 before anything else can print to it.
    static func takeStandardOutput() -> FrameWriter {
        let fd = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        signal(SIGPIPE, SIG_IGN)
        return FrameWriter(fd: fd)
    }

    private init(fd: Int32) {
        self.fd = Mutex(fd)
    }

    func send(_ kind: FrameKind, id: UInt32, payload: Data = Data()) {
        var frame = Data(capacity: 9 + payload.count)
        withUnsafeBytes(of: id.littleEndian) { frame.append(contentsOf: $0) }
        frame.append(kind.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        let written = fd.withLock { fd in
            frame.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += n
                }
                return true
            }
        }
        // Unread has gone: nobody is left to read the audio.
        if !written { _exit(0) }
    }

    func send(_ kind: FrameKind, id: UInt32, message: String) {
        send(kind, id: id, payload: Data(message.utf8))
    }

    func send(audio samples: [Float], id: UInt32) {
        send(.audio, id: id, payload: samples.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[narrator] \(message)\n".utf8))
}
