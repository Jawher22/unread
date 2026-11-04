import Foundation

/// One line per reading start in ~/Library/Logs/Unread/latency.jsonl.
/// Timings only, never the text being read.
struct LatencyRecord: Codable {
    enum Gesture: String, Codable { case hold, doubleTap = "double-tap" }

    var date = Date()
    var app: String?
    var gesture: Gesture
    /// Finding the document and start point after release. Holds resolve it
    /// while the key is down, so this is only on the critical path for double-tap.
    var lookupMs: Double?
    /// Extracting the first sentence (AX text walk).
    var extractMs: Double?
    /// Synthesizing what became first audio: the first sentence, or its
    /// opening clause when it was split.
    var synthMs: Double?
    /// Release → first buffer scheduled on the player.
    var firstAudioMs: Double?
    /// Output device latency reported by the engine (large on Bluetooth).
    /// Heard audio ≈ firstAudioMs + outputLatencyMs.
    var outputLatencyMs: Double?
    /// Length of the first sentence, in characters.
    var chars: Int?
    /// Length of the text synthesized first (the opening clause and a few
    /// words of lookahead), when the sentence was split so the voice could
    /// start on it while the rest was synthesized (#14).
    var openingChars: Int?
    /// Whether first audio came from speculative synthesis during the hold (#5).
    var speculative: Bool?
}

enum LatencyLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Unread/latency.jsonl")

    static func ms(since start: Date) -> Double { (Date().timeIntervalSince(start) * 1000).rounded() }

    static func append(_ record: LatencyRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    static func load() -> [LatencyRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(LatencyRecord.self, from: Data($0.utf8)) }
    }

    /// `Unread --stats`: p50 / p95 / max per stage, per gesture and per app.
    static func printStats() {
        let records = load()
        guard let first = records.first?.date else {
            print("no latency records yet (\(url.path))")
            return
        }
        print("\(records.count) readings since \(first.formatted(date: .abbreviated, time: .shortened))  (\(url.path))\n")
        print(row("ms", "n", "p50", "p95", "max"))
        func stage(_ name: String, _ values: [Double?]) {
            let v = values.compactMap { $0 }.sorted()
            guard !v.isEmpty else { return }
            print(row(name, "\(v.count)", fmt(percentile(v, 0.5)), fmt(percentile(v, 0.95)), fmt(v.last!)))
        }
        stage("release → first audio", records.map(\.firstAudioMs))
        for g in [LatencyRecord.Gesture.hold, .doubleTap] {
            stage("  \(g.rawValue)", records.filter { $0.gesture == g }.map(\.firstAudioMs))
        }
        let spec = records.filter { $0.speculative != nil }
        if !spec.isEmpty {
            stage("  speculative hit", spec.filter { $0.speculative == true }.map(\.firstAudioMs))
            stage("  speculative miss", spec.filter { $0.speculative == false }.map(\.firstAudioMs))
        }
        // Splitting started being logged with `openingChars` (#14).
        let sinceSplit = records.drop { $0.openingChars == nil }
        if !sinceSplit.isEmpty {
            stage("  first sentence split", sinceSplit.filter { $0.openingChars != nil }.map(\.firstAudioMs))
            stage("  first sentence whole", sinceSplit.filter { $0.openingChars == nil }.map(\.firstAudioMs))
        }
        stage("lookup (double-tap)", records.map(\.lookupMs))
        stage("extract first sentence", records.map(\.extractMs))
        stage("synthesize first sentence", records.map(\.synthMs))
        stage("output device latency", records.map(\.outputLatencyMs))

        print("\nrelease → first audio, by app")
        let byApp = Dictionary(grouping: records) { $0.app ?? "unknown" }
        for (app, rs) in byApp.sorted(by: { $0.value.count > $1.value.count }) {
            stage("  \(app)", rs.map(\.firstAudioMs))
        }
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
    }
    private static func fmt(_ v: Double) -> String { String(format: "%.0f", v) }
    private static func row(_ name: String, _ cols: String...) -> String {
        name.padding(toLength: 34, withPad: " ", startingAt: 0) + cols.map { $0.leftPad(6) }.joined()
    }
}

private extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
