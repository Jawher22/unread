import Foundation
import NaturalLanguage

/// `--bench --split`: what splitting a long first sentence buys (#14).
/// Synthesis time against length, then for each long sentence the opening
/// clause against the whole, joined the way the session plays it: the pause
/// at the join, the intonation either side of it, and the word timing.
func benchSplit(_ voice: Voice) async {
    func timed(_ text: String, _ lang: NLLanguage, runs: Int = 5) async -> (ms: Double, speech: Speech) {
        var times: [Double] = [], speech = Speech(samples: [])
        for _ in 0..<runs {
            let t = Date()
            speech = (try? await voice.synthesize(text, language: lang, speed: 1)) ?? Speech(samples: [])
            times.append(Date().timeIntervalSince(t) * 1000)
        }
        return (times.sorted()[runs / 2], speech)
    }
    func ms(_ samples: Int) -> Double { Double(samples) / 24 }

    let long = "When the first sentence of a reading is long, the voice has to wait for all of it to be synthesized, because the model does not stream its audio, and so the listener hears nothing at all for a third of a second or more after letting go of the key, which feels slow next to the short sentences."
    print("\nsynthesis time vs length (median of 5)")
    let words = long.split(separator: " ")
    for n in [3, 6, 9, 12, 16, 20, 25, 30, 40, 50, words.count] where n <= words.count {
        let text = words[..<n].joined(separator: " ")
        let (t, s) = await timed(text, .english)
        print(String(format: "  %3d chars %3d words  %4.0f ms  %5.2fs audio", text.count, n, t, Double(s.samples.count) / 24_000))
    }

    let sentences: [(NLLanguage, String)] = [
        (.english, "In 1859, Charles Darwin published On the Origin of Species, a book that changed how we understand life on Earth and our place in it."),
        (.english, "Kokoro doesn't stream, so a long first sentence of forty words or more delays the first audio by three hundred milliseconds or more after the key is released."),
        (.english, "The fix is simple: synthesize the opening clause first and start playback with it, then synthesize the rest while the opening clause is playing."),
        (.english, "Our approach — measuring first, then deciding — kept the threshold honest, and the numbers showed that synthesis time grows steadily with the length of the text."),
        (.english, "If you have ever waited for a page to load, you know that a few hundred milliseconds is enough to notice, and enough to break the feeling that the tool is instant."),
        (.english, "Chromium reports each wrapped line as a paragraph and joins blocks with no separator, which is why sentences are cut from a window of six hundred characters."),
        (.french, "Le petit prince est un livre que tout le monde devrait lire, au moins une fois dans sa vie, parce qu'il parle de l'amitié, de l'amour et de ce qui compte vraiment."),
        (.french, "Quand la première phrase est longue, la voix doit attendre qu'elle soit entièrement synthétisée avant de commencer à parler."),
    ]
    print("\nopening clause vs whole sentence (median of 5)")
    for (lang, text) in sentences {
        let sentence = Sentence(text: text, range: NSNull(), next: nil)
        let opening = OpeningClause.of(sentence), k = opening.upperBound
        let (wholeMs, w) = await timed(text, lang)
        print("\n[\(lang.rawValue)] \(text.count) chars: \(text)")
        guard k < sentence.words.count else { print(String(format: "  not split; whole %.0f ms", wholeMs)); continue }
        let headText = OpeningClause.text(of: sentence, saying: opening)
        let (headMs, h) = await timed(headText, lang)
        let (restMs, r) = await timed(OpeningClause.text(of: sentence, saying: k..<sentence.words.count), lang)
        print(String(format: "  first audio waits for: whole %.0f ms → opening %.0f ms (%d chars: \"%@\"); rest %.0f ms, during %.1fs of opening audio",
                     wholeMs, headMs, headText.count, headText, restMs, Double(h.samples.count) / 24_000))
        // Joined the way the session plays it.
        let (clause, pause) = h.cut(beforeWord: opening.count)
        let rest = r.trimmingLeadingQuiet(keep: Pacing.edgeSamples)
        let offset = clause.samples.count + pause.count
        let joined = Speech(samples: clause.samples + pause + rest.samples,
                            wordStarts: clause.wordStarts + rest.wordStarts.map { $0.map { $0 + offset } })
        func pauseBefore(_ s: Speech, _ word: Int) -> Int {
            let from = s.wordStarts[..<word].last { $0 != nil }.flatMap { $0 } ?? 0
            let to = (s.wordStarts[word] ?? from) + Speech.window * 10
            return s.quietRuns(in: from..<to).map(\.count).max() ?? 0
        }
        print(String(format: "  pause at the join %.0f ms; in the whole sentence %.0f ms; without cutting and trimming %.0f ms",
                     ms(pauseBefore(joined, k)), ms(pauseBefore(w, k)), ms(h.trailingQuiet + r.leadingQuiet)))
        let lastWord = clause.wordStarts[..<k].lastIndex { $0 != nil }
        let (_, alone) = await timed(sentence.text(of: opening), lang, runs: 1)
        if let i = lastWord, let a = joined.wordStarts[i], let b = w.wordStarts[i], let wa = w.wordStarts[k], let c = alone.wordStarts[i] {
            print("  pitch (Hz) of \"\(sentence.words[i])\": joined " + pitch(joined.samples, a..<clause.samples.count)
                  + " · whole " + pitch(w.samples, b..<wa)
                  + " · clause said alone " + pitch(alone.samples, c..<(alone.samples.count - alone.trailingQuiet)))
        }
        if let a = joined.wordStarts[k], let b = w.wordStarts[k] {
            let next = k + 1 < sentence.words.count ? (joined.wordStarts[k + 1], w.wordStarts[k + 1]) : (nil, nil)
            print("  pitch (Hz) of \"\(sentence.words[k])\": joined " + pitch(joined.samples, a..<(next.0 ?? a + 4_800))
                  + " · whole " + pitch(w.samples, b..<(next.1 ?? b + 4_800)))
        }
        print(String(format: "  length joined %.2fs, whole %.2fs; words without a start: joined %d, whole %d of %d",
                     Double(joined.samples.count) / 24_000, Double(w.samples.count) / 24_000,
                     joined.wordStarts.filter { $0 == nil }.count, w.wordStarts.filter { $0 == nil }.count, sentence.words.count))
    }
}

/// Pitch contour of `range`, one estimate per 40 ms voiced frame
/// (autocorrelation, 70–400 Hz; expect the odd octave error).
private func pitch(_ x: [Float], _ range: Range<Int>) -> String {
    let frame = 960, lo = 24_000 / 400, hi = 24_000 / 70
    var out: [String] = []
    for f in stride(from: max(range.lowerBound, 0), to: min(range.upperBound, x.count) - frame - hi, by: frame) {
        let energy = x[f..<(f + frame)].reduce(0) { $0 + $1 * $1 }
        guard energy > 0.5 else { continue }
        var best = 0, bestR: Float = 0
        for lag in lo...hi {
            var r: Float = 0
            for i in 0..<frame { r += x[f + i] * x[f + i + lag] }
            if r > bestR { bestR = r; best = lag }
        }
        if bestR > 0.3 * energy { out.append(String(24_000 / best)) }
    }
    return out.isEmpty ? "–" : out.joined(separator: "→")
}
