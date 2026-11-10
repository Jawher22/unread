import Foundation
import NaturalLanguage

/// What the narrator said in each reading, kept to judge its delivery in real use the way `--eval` judges
/// fixed passages: `~/Library/Logs/Unread/readings/<start>/`, one WAV a sentence as the narrator made it
/// (unstretched, its quiet trimmed to `Pacing.edge` as reading plays it) and a line each in `sentences.jsonl`
/// (text, voice, speed, whether it carried on from the sentence before). `scripts/eval.sh readings` scores them.
/// The newest `kept` readings stay.
final class ReadingRecorder: Sendable {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Unread/readings")
    static let kept = 40

    private let root: URL
    private let dir: URL
    private let app: String?
    private let queue = DispatchQueue(label: "unread.recorder", qos: .utility)

    init(app: String?, root: URL = ReadingRecorder.folder) {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
        self.root = root
        self.app = app
        dir = root.appendingPathComponent(stamp.string(from: Date()))
    }

    @MainActor
    func record(seq: Int, text: String, language: NLLanguage, take: NarratorTake, speed: Float, live: Bool) {
        let samples = take.samples, report = take.report, spoken = take.spokenText
        if let start = report?.start, start != .carried, start != .noneBefore || seq > 0 {
            print("[unread] fresh performance at sentence #\(seq): \(start.rawValue)")
        }
        queue.async { [self] in
            let speech = Speech(samples: samples).trimmingLeadingQuiet(keep: Pacing.edgeSamples)
                .trimmingTrailingQuiet(keep: Pacing.edgeSamples)
            let name = String(format: "%04d.wav", seq)
            do {
                if !FileManager.default.fileExists(atPath: dir.path) { try begin() }
                try writeWAV(speech.samples, rate: Double(Narrator.sampleRate), to: dir.appendingPathComponent(name))
                let line: [String: Any] = [
                    "seq": seq, "file": name, "text": text, "spoken": spoken, "language": language.rawValue,
                    "voice": report?.voice ?? "", "start": report?.start.rawValue ?? "", "parts": report?.parts ?? 0,
                    "stop": report?.stop ?? "", "seconds": Double(speech.samples.count) / Double(Narrator.sampleRate),
                    "speed": (Double(speed) * 100).rounded() / 100, "live": live, "app": app ?? "",
                    "date": ISO8601DateFormatter().string(from: Date()),
                ]
                var data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
                data.append(0x0A)
                let log = try FileHandle(forWritingTo: dir.appendingPathComponent("sentences.jsonl"))
                defer { try? log.close() }
                try log.seekToEnd()
                try log.write(contentsOf: data)
            } catch {
                print("[unread] couldn't record sentence #\(seq): \(error)")
            }
        }
    }

    /// Makes this reading's folder, and drops the oldest past `kept`.
    private func begin() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("sentences.jsonl").path, contents: nil)
        let readings = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter(\.hasDirectoryPath).sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in readings.dropFirst(Self.kept) { try? FileManager.default.removeItem(at: old) }
    }
}
