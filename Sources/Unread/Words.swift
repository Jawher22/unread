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

/// A spoken sentence: its audio, and when each display word starts.
struct Speech: Sendable {
    let samples: [Float]
    /// Sample offset into `samples` where each display word starts; nil for a
    /// word the voice doesn't say on its own (punctuation, symbols).
    var wordStarts: [Int?] = []
}

enum WordTiming {
    /// Lowercased letters and digits: what two spellings of a word share.
    static func key<S: StringProtocol>(_ word: S) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
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
