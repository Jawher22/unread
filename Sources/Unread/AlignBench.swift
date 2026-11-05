import AVFoundation
import NaturalLanguage

/// `--align [--narrator] ["sentence"…]`: forced alignment (#58) against Kokoro's own word timing,
/// which is exact (its durations), next to the character estimate the narrator used before.
/// `--narrator` also aligns the narrator's audio (no ground truth: aligned against estimated).
func benchAlign(_ args: [String]) async {
    if let i = args.firstIndex(of: "--check"), args.indices.contains(i + 2) {
        await checkRecording(URL(fileURLWithPath: args[i + 1]), log: URL(fileURLWithPath: args[i + 2]))
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

    let voice = Voice()
    do { try await voice.prepareEnglish() } catch { print("Kokoro failed to load: \(error)"); return }
    var t = Date()
    let aligner: Aligner
    do { aligner = try await Aligner.load() } catch { print("aligner failed to load: \(error)"); return }
    print(String(format: "aligner loaded in %.2f s", Date().timeIntervalSince(t)))
    _ = try? await aligner.starts(display: ["Warm", "up."], samples: [Float](repeating: 0, count: 24_000))

    var alignedErrors: [Double] = [], estimatedErrors: [Double] = [], partialErrors: [Double] = []
    var missing = 0, words = 0, callMs: [Double] = []
    for s in sentences {
        guard let speech = try? await voice.synthesize(s, language: .english, speed: 1) else { print("synthesis failed: \(s)"); continue }
        let display = s.split(separator: " ")
        t = Date()
        guard let aligned = try? await aligner.starts(display: display, samples: speech.samples) else { print("alignment failed: \(s)"); continue }
        let ms = Date().timeIntervalSince(t) * 1000
        callMs.append(ms)
        let quiet = Speech(samples: speech.samples)
        let estimated = WordTiming.estimated(display[...], voiced: quiet.leadingQuiet..<max(quiet.leadingQuiet, speech.samples.count - quiet.trailingQuiet))
        // Streaming: the first 60% of the audio, as a live sentence has it partway.
        let cut = speech.samples.count * 6 / 10
        let partial = (try? await aligner.starts(display: display, samples: Array(speech.samples[..<cut]), complete: false)) ?? []
        print(String(format: "\n%.0f ms for %.1f s: %@", ms, Double(speech.samples.count) / 24_000, s))
        print("      truth  aligned  estimate  partial")
        for (i, w) in display.enumerated() {
            let truth = speech.wordStarts[i]
            func cell(_ v: Int?) -> String { v.map { String(format: "%6.2f", Double($0) / 24_000) } ?? "     –" }
            let p = i < partial.count ? partial[i] : nil
            print("    \(cell(truth))   \(cell(aligned[i]))    \(cell(estimated[i]))   \(cell(p))  \(w)")
            guard let truth else { continue }
            words += 1
            if let a = aligned[i] { alignedErrors.append(Double(a - truth) / 24) } else { missing += 1 }
            if let e = estimated[i] { estimatedErrors.append(Double(e - truth) / 24) }
            if let p { partialErrors.append(Double(p - truth) / 24) }
        }
    }
    func summary(_ name: String, _ errors: [Double]) {
        let abs = errors.map(Swift.abs).sorted()
        guard !abs.isEmpty else { print("\(name): none"); return }
        func q(_ p: Double) -> Double { abs[min(abs.count - 1, Int(Double(abs.count) * p))] }
        let bias = errors.reduce(0, +) / Double(errors.count)
        print(String(format: "%@: %d words, |error| median %.0f ms, p90 %.0f, p95 %.0f, max %.0f; mean signed %+.0f ms",
                     name, errors.count, q(0.5), q(0.9), q(0.95), abs.last!, bias))
    }
    print("\nagainst Kokoro's own word starts (\(words) words, \(missing) without an aligned start):")
    summary("aligned  ", alignedErrors)
    summary("estimated", estimatedErrors)
    summary("partial  ", partialErrors)
    let sorted = callMs.sorted()
    if !sorted.isEmpty { print(String(format: "alignment call: median %.0f ms, max %.0f ms", sorted[sorted.count / 2], sorted.last!)) }

    guard args.contains("--narrator") else { return }
    let narrator: Narrator
    do { narrator = try await Narrator.load(english: try VoicePreset.named("london-storyteller"), french: nil) } catch { print("narrator: \(error)"); return }
    var drift: [Double] = []
    for s in sentences.prefix(6) {
        var samples: [Float] = []
        do { for try await chunk in narrator.speak(s, language: .english) { samples += chunk } } catch { print("narrator: \(error)"); continue }
        let display = s.split(separator: " ")
        t = Date()
        guard let aligned = try? await aligner.starts(display: display, samples: samples) else { continue }
        let ms = Date().timeIntervalSince(t) * 1000
        let quiet = Speech(samples: samples)
        let estimated = WordTiming.estimated(display[...], voiced: quiet.leadingQuiet..<max(quiet.leadingQuiet, samples.count - quiet.trailingQuiet))
        print(String(format: "\nnarrator, %.0f ms for %.1f s: %@", ms, Double(samples.count) / 24_000, s))
        for (i, w) in display.enumerated() {
            func cell(_ v: Int?) -> String { v.map { String(format: "%6.2f", Double($0) / 24_000) } ?? "     –" }
            print("    \(cell(aligned[i]))    \(cell(estimated[i]))  \(w)")
            if let a = aligned[i], let e = estimated[i] { drift.append(Double(a - e) / 24) }
        }
    }
    summary("\nnarrator: aligned against estimated", drift)

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
/// the session's timing end to end (stretch, live runs, trims), not the aligner.
func checkRecording(_ wav: URL, log: URL) async {
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
        guard from < to, let heard = try? await aligner.starts(display: s.text.split(separator: " "), samples: Array(audio[from..<to])) else { continue }
        var worst = 0.0, sum = 0.0, n = 0
        for (scheduled, h) in zip(s.starts, heard) {
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
}
