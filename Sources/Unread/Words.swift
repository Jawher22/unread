import CoreGraphics
import Foundation

/// Word-level read-along (#20): when each word is spoken, and where it is.
///
/// Both sides are indexed by the sentence's display words (`Sentence.words`:
/// its cleaned text split at spaces), so a timing and a box with the same
/// index belong to the same word.

extension Sentence {
    /// The words the highlight can mark, in reading order.
    var words: [Substring] { text.split(separator: " ") }
}

/// A synthesized sentence: its audio, and when each display word starts.
struct Speech: Sendable {
    let samples: [Float]
    /// Sample offset into `samples` where each display word starts; nil for a
    /// word the voice doesn't say on its own (punctuation, symbols).
    var wordStarts: [Int?] = []
}

enum WordTiming {
    /// One word as the voice said it: where it is in the audio, and how many
    /// phoneme tokens it took (its spoken length).
    struct Spoken: Equatable {
        let samples: Range<Int>
        let phonemes: Int
    }

    /// Kokoro's token ids: 0 is BOS/EOS (also between chunks), 16 is the
    /// space between words, 1…15 are punctuation (pauses), the rest phonemes.
    /// Same ids in the English v3 and French legacy vocabularies.
    private static let boundary: Int32 = 0, space: Int32 = 16, lastPunctuation: Int32 = 15

    /// The spoken words, from the per-token durations. A word runs from its
    /// first token to its last phoneme (a trailing comma's pause isn't part
    /// of it). Groups with no phoneme (a lone "—") are dropped.
    static func spokenWords(ids: [Int32], durations: [Int32], sampleCount: Int) -> [Spoken] {
        guard ids.count == durations.count, !ids.isEmpty else { return [] }
        let frames = durations.reduce(0) { $0 + Int($1) }
        guard frames > 0, sampleCount > 0 else { return [] }
        let perFrame = Double(sampleCount) / Double(frames) // 600 at 24 kHz
        var words: [Spoken] = []
        var frame = 0, phonemes = 0
        var start: Int?, end: Int?
        func close() {
            if let s = start, let e = end, e > s {
                words.append(Spoken(samples: Int(Double(s) * perFrame)..<Int(Double(e) * perFrame), phonemes: phonemes))
            }
            start = nil; end = nil; phonemes = 0
        }
        for (id, d) in zip(ids, durations) {
            if id == boundary || id == space {
                close()
            } else {
                if start == nil { start = frame }
                if id > lastPunctuation { end = frame + Int(d); phonemes += 1 }
            }
            frame += Int(d)
        }
        close()
        return words
    }

    /// Lowercased letters and digits: what two spellings of a word share.
    static func key<S: StringProtocol>(_ word: S) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// When each display word starts, in samples.
    ///
    /// Two steps. The text the voice read (`spokenText`, with numbers and
    /// symbols spelled out: "$45" → "forty five dollars") is matched to the
    /// spoken words by length, since the voice spells acronyms out ("API" →
    /// three words) and runs some French phrases together ("tout le monde" →
    /// one). Then the display words are matched to that text by spelling.
    static func starts(display: [Substring], spoken: [Spoken], spokenText: String?) -> [Int?] {
        guard !display.isEmpty, !spoken.isEmpty else { return display.map { _ in nil } }
        let source = spokenText.map { $0.split(whereSeparator: \.isWhitespace) } ?? display
        let said = source.filter { !key($0).isEmpty }
        guard !said.isEmpty else { return display.map { _ in nil } }
        let saidStarts = group(said, spoken)
        return align(display.map(key), said.map(key)).map { $0.flatMap { saidStarts[$0] } }
    }

    /// Start sample of each written word, by a monotone length-based
    /// alignment (Gale–Church style) of written words to spoken words: one
    /// written word may take up to four spoken words, or up to three written
    /// words share one. Words sharing a spoken word split it by their length.
    static func group(_ written: [Substring], _ spoken: [Spoken]) -> [Int?] {
        let n = written.count, m = spoken.count
        // Expected spoken length: about one phoneme per letter, more for an
        // acronym the voice spells out letter by letter.
        let expected = written.map { w -> Double in
            let letters = Double(key(w).count)
            let isAcronym = w.count >= 2 && w.filter(\.isLetter).count >= 2 && w.allSatisfy { !$0.isLetter || $0.isUppercase }
            return isAcronym ? letters * 2.5 : letters
        }
        // Calibrate letters → phonemes on this sentence.
        let ratio = Double(spoken.reduce(0) { $0 + $1.phonemes }) / max(expected.reduce(0, +), 1)
        let moves: [(a: Int, b: Int, penalty: Double)] = [(1, 1, 0), (1, 2, 0.6), (2, 1, 0.6), (1, 3, 1.0), (3, 1, 1.0), (1, 4, 1.4)]
        let inf = Double.infinity
        var cost = Array(repeating: Array(repeating: inf, count: m + 1), count: n + 1)
        var from = Array(repeating: Array(repeating: -1, count: m + 1), count: n + 1)
        cost[0][0] = 0
        for i in 0...n {
            for j in 0...m where cost[i][j] < inf {
                for (k, mv) in moves.enumerated() where i + mv.a <= n && j + mv.b <= m {
                    let e = expected[i..<(i + mv.a)].reduce(0, +) * ratio
                    let p = Double(spoken[j..<(j + mv.b)].reduce(0) { $0 + $1.phonemes })
                    let c = cost[i][j] + abs(log((p + 1) / (e + 1))) + mv.penalty
                    if c < cost[i + mv.a][j + mv.b] { cost[i + mv.a][j + mv.b] = c; from[i + mv.a][j + mv.b] = k }
                }
            }
        }
        guard cost[n][m] < inf else { return proportional(written, spoken) }
        var out = [Int?](repeating: nil, count: n)
        var i = n, j = m
        while i > 0, j > 0, from[i][j] >= 0 {
            let mv = moves[from[i][j]]
            i -= mv.a; j -= mv.b
            let first = spoken[j].samples
            if mv.a == 1 { out[i] = first.lowerBound; continue }
            // Several written words in one spoken word: split it by letters.
            let lengths = expected[i..<(i + mv.a)], total = max(lengths.reduce(0, +), 1)
            var at = 0.0
            for (k, len) in lengths.enumerated() {
                out[i + k] = first.lowerBound + Int(Double(first.count) * at / total)
                at += len
            }
        }
        return out
    }

    /// Fallback: written words spread over the speech by their length.
    private static func proportional(_ written: [Substring], _ spoken: [Spoken]) -> [Int?] {
        let lengths = written.map { max(key($0).count, 1) }
        let total = lengths.reduce(0, +)
        let first = spoken.first!.samples.lowerBound, span = Double(spoken.last!.samples.upperBound - first)
        var at = 0
        return lengths.map { len in defer { at += len }; return first + Int(span * Double(at) / Double(total)) }
    }

    /// For each display word, the index of the first said word that belongs
    /// to it, or nil. Needleman–Wunsch on spelling with unit costs; a word
    /// that doesn't match exactly ("$45" for "forty five dollars") then
    /// starts right after the previous word's, since that's where the voice
    /// starts saying it.
    static func align(_ shown: [String], _ said: [String]) -> [Int?] {
        let n = shown.count, m = said.count
        // A word without letters ("—", "&") can be skipped for free: it may or may not be said.
        func gapCost(_ i: Int) -> Int { shown[i].isEmpty ? 0 : 1 }
        func subCost(_ i: Int, _ j: Int) -> Int { shown[i] == said[j] ? 0 : 1 }
        var cost = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: 1, through: n, by: 1) { cost[i][0] = cost[i - 1][0] + gapCost(i - 1) }
        for j in 0...m { cost[0][j] = j }
        for i in stride(from: 1, through: n, by: 1) {
            for j in stride(from: 1, through: m, by: 1) {
                cost[i][j] = min(cost[i - 1][j - 1] + subCost(i - 1, j - 1), cost[i - 1][j] + gapCost(i - 1), cost[i][j - 1] + 1)
            }
        }
        var out = [Int?](repeating: nil, count: n)
        var i = n, j = m
        while i > 0, j > 0 {
            if cost[i][j] == cost[i - 1][j - 1] + subCost(i - 1, j - 1) {
                out[i - 1] = j - 1; i -= 1; j -= 1
            } else if cost[i][j] == cost[i - 1][j] + gapCost(i - 1) {
                i -= 1
            } else {
                j -= 1
            }
        }
        // Inexact words start where the previous word's said words end, as
        // long as that's before the next exact match.
        let exact = (0..<n).map { i in out[i].map { shown[i] == said[$0] } ?? false }
        var used = -1 // last said word taken by an earlier display word
        for i in 0..<n {
            if exact[i] { used = out[i]!; continue }
            guard !shown[i].isEmpty else { out[i] = nil; continue }
            let nextExact = (i + 1..<n).first { exact[$0] }.map { out[$0]! } ?? m
            if used + 1 < nextExact {
                let own = out[i] ?? used + 1
                out[i] = used + 1
                used = max(used + 1, own)
            } else {
                out[i] = nil
            }
        }
        return out
    }

    /// The display word being spoken `offset` samples into the sentence:
    /// the last one that has started. Nil before the first word.
    static func current(_ starts: [Int?], at offset: Int) -> Int? {
        var found: Int?
        for (i, s) in starts.enumerated() {
            guard let s else { continue }
            if s <= offset { found = i } else { break }
        }
        return found
    }
}

enum WordBoxes {
    /// Boxes for the display words, from pieces of on-screen text measured
    /// in reading order (word ranges, which may carry leading spaces and
    /// punctuation, or include text the display dropped, like "[1]").
    ///
    /// Display text is the on-screen text minus some characters, so its
    /// letters are matched as a subsequence of the pieces' letters; a display
    /// word gets the union of the pieces its letters fall in.
    static func assign(display: [Substring], pieces: [(text: String, rect: CGRect)]) -> [CGRect?] {
        var stream: [(Character, Int)] = []
        for (p, piece) in pieces.enumerated() {
            for c in piece.text.lowercased() where c.isLetter || c.isNumber { stream.append((c, p)) }
        }
        var out = [CGRect?](repeating: nil, count: display.count)
        var k = 0
        for (i, word) in display.enumerated() {
            var probe = k, box: CGRect?
            for c in word.lowercased() where c.isLetter || c.isNumber {
                // Bounded resync: a dropped citation or URL is short.
                let from = probe
                while probe < stream.count, probe - from < 200, stream[probe].0 != c { probe += 1 }
                // Not there (its piece couldn't be measured): leave this word
                // without a box and match the next one from the same place.
                guard probe < stream.count, stream[probe].0 == c else { box = nil; probe = -1; break }
                let r = pieces[stream[probe].1].rect
                box = box.map { $0.union(r) } ?? r
                probe += 1
            }
            guard probe >= 0 else { continue }
            out[i] = box
            k = probe
        }
        return out
    }
}
