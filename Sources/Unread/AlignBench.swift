import AVFoundation
import NaturalLanguage

/// `--align ["sentence"…]`: forced alignment (#58) of the narrator's audio, next to the character
/// estimate it falls back to, and a partial alignment of the first 60% of the audio, as while it
/// streams. No ground truth: Kokoro's word starts were exact (its durations) and were the reference
/// until it was dropped (aligned: median 50 ms off, p95 145 ms). `--align --check` measures a reading end to end.
func benchAlign(_ args: [String]) async {
    if let i = args.firstIndex(of: "--check"), args.indices.contains(i + 2) {
        await checkRecording(URL(fileURLWithPath: args[i + 1]), log: URL(fileURLWithPath: args[i + 2]), verbose: args.contains("--verbose"))
        return
    }
    let given = args.drop { $0 != "--align" }.dropFirst().filter { !$0.hasPrefix("--") }
    let sentences = given.isEmpty ? [
        "The plot sits at the far end of the row, past the water tap and the shed with the green door.",
        "Nobody else wanted it, because the soil there holds water like a sponge.",
        "By May there were four raised beds, a compost bay made from old pallets, and a path of wood chips that squelched underfoot.",
        "A bean glut teaches you to cook in new ways, or at least to freeze things quickly.",
        "The tap at the end of the row runs slowly, and a full can takes almost two minutes to fill.",
        "Cauliflowers sulked for months and then bolted in a single warm afternoon.",
        "In 1859, Charles Darwin published On the Origin of Species — a book that changed how we understand life.",
        "It costs $45.99 (about 40 €) per month, or 10% less if you pay yearly.",
        "Use `fetch()` with well-known APIs, e.g. the U.S. Census API at 3:30 PM.",
        "Kokoro v3 takes about 40 ms plus 1.45 ms per character, so first audio waits for the opening only.",
        "Short.",
        "The real lesson of the plot is patience.",
    ] : Array(given)

    var t = Date()
    let aligner: Aligner
    do { aligner = try await Aligner.load() } catch { print("aligner failed to load: \(error)"); return }
    print(String(format: "aligner loaded in %.2f s", Date().timeIntervalSince(t)))
    _ = try? await aligner.starts(display: ["Warm", "up."], samples: [Float](repeating: 0, count: 24_000))
    func summary(_ name: String, _ errors: [Double]) {
        let abs = errors.map(Swift.abs).sorted()
        guard !abs.isEmpty else { print("\(name): none"); return }
        func q(_ p: Double) -> Double { abs[min(abs.count - 1, Int(Double(abs.count) * p))] }
        let bias = errors.reduce(0, +) / Double(errors.count)
        print(String(format: "%@: %d words, |difference| median %.0f ms, p90 %.0f, p95 %.0f, max %.0f; mean signed %+.0f ms",
                     name, errors.count, q(0.5), q(0.9), q(0.95), abs.last!, bias))
    }

    let narrator: Narrator
    do { narrator = try await Narrator.load(english: try VoicePreset.named("london-storyteller"), french: nil) } catch { print("narrator: \(error)"); return }
    var drift: [Double] = [], partialDrift: [Double] = [], callMs: [Double] = []
    for s in sentences {
        var samples: [Float] = []
        do { for try await chunk in narrator.speak(s, language: .english) { samples += chunk } } catch { print("narrator: \(error)"); continue }
        let display = s.split(separator: " ")
        t = Date()
        guard let aligned = try? await aligner.starts(display: display, samples: samples) else { print("alignment failed: \(s)"); continue }
        let ms = Date().timeIntervalSince(t) * 1000
        callMs.append(ms)
        let quiet = Speech(samples: samples)
        let estimated = WordTiming.estimated(display[...], voiced: quiet.leadingQuiet..<max(quiet.leadingQuiet, samples.count - quiet.trailingQuiet))
        let partial = (try? await aligner.starts(display: display, samples: Array(samples[..<(samples.count * 6 / 10)]), complete: false)) ?? []
        print(String(format: "\n%.0f ms for %.1f s: %@", ms, Double(samples.count) / 24_000, s))
        print("    aligned  estimate  partial")
        for (i, w) in display.enumerated() {
            func cell(_ v: Int?) -> String { v.map { String(format: "%6.2f", Double($0) / 24_000) } ?? "     –" }
            let p = i < partial.count ? partial[i] : nil
            print("    \(cell(aligned[i]))    \(cell(estimated[i]))   \(cell(p))  \(w)")
            if let a = aligned[i], let e = estimated[i] { drift.append(Double(a - e) / 24) }
            if let a = aligned[i], let p { partialDrift.append(Double(p - a) / 24) }
        }
    }
    print("")
    summary("estimate against aligned", drift)
    summary("partial against whole   ", partialDrift)
    let sorted = callMs.sorted()
    if !sorted.isEmpty { print(String(format: "alignment call: median %.0f ms, max %.0f ms", sorted[sorted.count / 2], sorted.last!)) }

    // Both on the Neural Engine: does aligning (once a second, as while a sentence streams) slow the narrator?
    let filler = [Float](repeating: 0, count: 24_000 * 6)
    for contended in [false, true, false, true] {
        var rtf: [Double] = []
        for s in sentences.prefix(4) {
            let busy = contended ? Task {
                while !Task.isCancelled {
                    _ = try? await aligner.starts(display: s.split(separator: " "), samples: filler)
                    try? await Task.sleep(for: .milliseconds(1000))
                }
            } : nil
            t = Date()
            var n = 0
            do { for try await chunk in narrator.speak(s, language: .english) { n += chunk.count } } catch { continue }
            busy?.cancel()
            rtf.append(Date().timeIntervalSince(t) / (Double(n) / 24_000))
        }
        print(String(format: "narrator %@: real-time factor %@", contended ? "aligning every 1 s" : "alone            ",
                     rtf.map { String(format: "%.2f", $0) }.joined(separator: " ")))
    }
}

/// `--align --check out.wav session.log`: the word starts a reading scheduled (`[timing]` lines, logged
/// with `UNREAD_DEBUG_OVERLAY=1`) against an alignment of what `--simulate --record` heard. Checks
/// the session's timing end to end (stretch, live runs, trims), not the aligner. `--verbose`: every word, scheduled and heard.
func checkRecording(_ wav: URL, log: URL, verbose: Bool = false) async {
    guard let file = try? AVAudioFile(forReading: wav),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: buffer)) != nil, file.processingFormat.sampleRate == 24_000 else { print("can't read \(wav.path) at 24 kHz"); return }
    let audio = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.hasPrefix("[timing] ") }
    let sentences: [(starts: [Double?], text: Substring)] = lines.compactMap { line in
        let parts = line.dropFirst("[timing] ".count).split(separator: " | ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (parts[0].split(separator: ",").map { Double($0) }, parts[1])
    }
    guard let aligner = try? await Aligner.load() else { print("aligner failed to load"); return }
    var errors: [Double] = []
    for (k, s) in sentences.enumerated() {
        guard let first = s.starts.compactMap({ $0 }).first else { continue }
        // From a little before its first word to the next sentence's first word.
        let from = max(Int((first - 0.3) * 24_000), 0)
        let next = sentences.dropFirst(k + 1).lazy.compactMap { $0.starts.compactMap { $0 }.first }.first
        let to = min(next.map { Int($0 * 24_000) } ?? audio.count, audio.count)
        // Aligned as reading aligns it: the words the narrator was given (#18), mapped back to the page's.
        let display = s.text.split(separator: " "), spoken = Speakable(display, language: .english)
        guard from < to, let said = try? await aligner.starts(display: spoken.words, samples: Array(audio[from..<to])) else { continue }
        let heard = spoken.displayStarts(said, displayCount: display.count)
        var worst = 0.0, sum = 0.0, n = 0
        for (i, (scheduled, h)) in zip(s.starts, heard).enumerated() {
            if verbose {
                print(String(format: "    %@  %@  %@", scheduled.map { String(format: "%6.2f", $0) } ?? "     –",
                             h.map { String(format: "%6.2f", Double(from + $0) / 24_000) } ?? "     –", String(display[i])))
            }
            guard let scheduled, let h else { continue }
            let e = (scheduled - Double(from + h) / 24_000) * 1000
            errors.append(e); sum += e; n += 1
            if abs(e) > abs(worst) { worst = e }
        }
        print(String(format: "%3d words, mean %+4.0f ms, worst %+4.0f ms: %@", n, n > 0 ? sum / Double(n) : 0, worst, String(s.text.prefix(60))))
    }
    let abs = errors.map(Swift.abs).sorted()
    guard !abs.isEmpty else { print("no words to compare"); return }
    print(String(format: "\nscheduled against heard: %d words, |error| median %.0f ms, p95 %.0f, max %.0f; mean signed %+.0f ms",
                 abs.count, abs[abs.count / 2], abs[min(abs.count - 1, abs.count * 95 / 100)], abs.last!, errors.reduce(0, +) / Double(errors.count)))
    // The mark moves `lead` before the scheduled start (Settings, "Mark ahead of voice"). A mark is
    // noticed late from 45 ms after the word is heard, early from 125 ms before (ITU BT.1359).
    for lead in HighlightStyle.Lead.allCases {
        let shown = errors.map { $0 - Double(lead.rawValue) }
        let late = shown.filter { $0 > 45 }.count, early = shown.filter { $0 < -125 }.count
        print(String(format: "mark ahead by %3d ms%@: %4.1f%% of words noticeably late (> 45 ms), %4.1f%% noticeably early (> 125 ms)",
                     lead.rawValue, lead == HighlightStyle.standard.lead ? " (default)" : "          ",
                     100 * Double(late) / Double(shown.count), 100 * Double(early) / Double(shown.count)))
    }
}

/// `--hear ["sentence"…] [--voice id] [--raw]`: what the narrator says for each sentence, silent. It
/// says the sentence as reading gives it (`Speakable`; `--raw`: as written), and the aligner's model
/// transcribes the audio (greedy CTC, so expect the odd misheard word). For technical text (#18).
func benchHear(_ args: [String]) async {
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    let flagValues = Set(["--voice"].compactMap(value))
    let given = args.drop { $0 != "--hear" }.dropFirst().filter { !$0.hasPrefix("--") && !flagValues.contains($0) }
    let sentences = given.isEmpty ? hearCases : Array(given)
    let narrator: Narrator, aligner: Aligner
    do {
        narrator = try await Narrator.load(english: try VoicePreset.named(value("--voice") ?? NarratorVoices.defaults[.english]!), french: nil)
        aligner = try await Aligner.load()
    } catch { print("\(error)"); return }
    for s in sentences {
        let given = args.contains("--raw") ? s : Speakable(s, language: .english).text
        var samples: [Float] = []
        do { for try await chunk in narrator.speak(given, language: .english) { samples += chunk } } catch { print("narrator: \(error)"); continue }
        let heard = (try? await aligner.transcribe(samples)) ?? "?"
        print(String(format: "\n%5.1f s  %@", Double(samples.count) / 24_000, s) + (given == s ? "" : "\n         given: \(given)")
              + "\n         heard: \(heard)")
    }
}

/// Technical writing as it appears in blogs and LLM replies.
private let hearCases = [
    "Rename user_id to account_id in the config.",
    "Call getUserName() before the request.",
    "Run it with --dry-run and the --verbose flag.",
    "Edit Sources/Unread/App.swift and restart the app.",
    "The model has 82M parameters and runs at 2.2 s per page.",
    "Version v3.5 replaced v3.4.1 in May.",
    "It takes ~250 ms, e.g. on an M1, i.e. most Macs.",
    "See #48 and PR #73 for the details.",
    "It's 3× faster vs. the old one, at 1.2× speed.",
    "Set CORS_ORIGIN to * and restart the API.",
    "The p95 latency dropped from 1.4s to 380ms.",
    "On 2026-11-05 we shipped it at 10:30 AM.",
    "Use JSON over HTTP, not XML over gRPC.",
    "Read docs/design.md, section 4.2, then the README.",
    "It costs $45.99 a month, or 10% less yearly.",
    "The cache hit rate went from 40% to 92.5%.",
    "Use a->b and x => y, but never a != b.",
    "Install it with npm install --save-dev typescript@5.4.",
]
