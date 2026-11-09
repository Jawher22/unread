import AppKit

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

/// Where a display word is on screen: its box on each line it's set on, in reading order. A word
/// hyphenated at a line end ("Eventu-" / "ally") has two, so the mark can move to the second line
/// when the voice does.
struct WordBox: Equatable {
    struct Part: Equatable {
        var rect: CGRect
        /// How many of the word's letters are on this line.
        var letters: Int
    }
    var parts: [Part]

    init(_ rect: CGRect) { parts = [Part(rect: rect, letters: 1)] }
    init(parts: [Part]) { self.parts = parts }

    var rects: [CGRect] { parts.map(\.rect) }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> WordBox {
        WordBox(parts: parts.map { Part(rect: $0.rect.offsetBy(dx: dx, dy: dy), letters: $0.letters) })
    }
}

enum WordBoxes {
    /// Boxes for the display words, from pieces of on-screen text measured
    /// in reading order (word ranges, which may carry leading spaces and
    /// punctuation, or include text the display dropped, like "[1]").
    ///
    /// Display text is the on-screen text minus some characters, so its
    /// letters are matched as a subsequence of the pieces' letters; a display
    /// word gets the union of the pieces its letters fall in on each line.
    /// A piece without a box (it couldn't be measured) still holds its letters, so they aren't
    /// matched to the pieces after it; a word whose letters are all in such pieces has no box.
    static func assign(display: [Substring], pieces: [(text: String, rect: CGRect?)]) -> [WordBox?] {
        var stream: [(Character, Int)] = []
        for (p, piece) in pieces.enumerated() {
            for c in piece.text.lowercased() where c.isLetter || c.isNumber { stream.append((c, p)) }
        }
        var out = [WordBox?](repeating: nil, count: display.count)
        var k = 0
        for (i, word) in display.enumerated() {
            var probe = k, parts: [WordBox.Part] = []
            for c in word.lowercased() where c.isLetter || c.isNumber {
                // Bounded resync: a dropped citation or URL is short.
                let from = probe
                while probe < stream.count, probe - from < 200, stream[probe].0 != c { probe += 1 }
                // Not there (its piece couldn't be measured): leave this word
                // without a box and match the next one from the same place.
                guard probe < stream.count, stream[probe].0 == c else { parts = []; probe = -1; break }
                defer { probe += 1 }
                guard let r = pieces[stream[probe].1].rect else { continue }
                if let last = parts.last, WordMark.sameLine(last.rect, r) {
                    parts[parts.count - 1] = WordBox.Part(rect: last.rect.union(r), letters: last.letters + 1)
                } else {
                    parts.append(WordBox.Part(rect: r, letters: 1))
                }
            }
            guard probe >= 0 else { continue }
            if !parts.isEmpty { out[i] = WordBox(parts: parts) }
            k = probe
        }
        return out
    }
}

/// The band a line's glyphs fill, from the bottom of its text up by the font's ascent and descent.
///
/// WebKit, and Books through its iOS bridge, measure a range as the union of the carets at its ends.
/// On a block's first line a caret is the font's height, on the glyphs; on every later line it
/// reaches up to the line above's text bottom, leading included: 22 px then 40 at `line-height: 2`
/// in 20 px Georgia, 27 then 32 in Books. Its bottom is the text's either way. A box keeps its
/// bottom and is cut to the band, and the boxes on a line share one band, so a mark moving along it
/// doesn't bob.
enum GlyphBand {
    /// Ascent plus descent, as WebKit rounds them: 22 for 20 px Georgia. A font that isn't
    /// installed (a web font, a book's) is taken as 1.15 em, about what text faces measure.
    static func height(font name: String?, size: CGFloat) -> CGFloat {
        guard size > 0 else { return 0 }
        // The system UI font comes as ".SFNS-Regular"; asked for by that name, CoreText hands back Times New Roman.
        let system = name?.hasPrefix(".") == true ? NSFont.systemFont(ofSize: size, weight: name!.contains("Bold") ? .bold : .regular) : nil
        if let font = system ?? name.flatMap({ NSFont(name: $0, size: size) }) { return (font.ascender).rounded() + (-font.descender).rounded() }
        return (size * 1.15).rounded()
    }

    /// The boxes cut to a band of `height` (never taller than they are), each keeping its left and
    /// right edges, every box on a line on that line's band. Lines are told by their bottoms.
    static func fit(_ boxes: [CGRect], height: CGFloat) -> [CGRect] {
        guard height > 0 else { return boxes }
        var lines: [(bottoms: [CGFloat], tallest: CGFloat, members: [Int])] = []
        for (i, b) in boxes.enumerated() {
            if let l = lines.firstIndex(where: { abs(median($0.bottoms) - b.maxY) < height / 2 }) {
                lines[l].bottoms.append(b.maxY)
                lines[l].tallest = max(lines[l].tallest, b.height)
                lines[l].members.append(i)
            } else {
                lines.append(([b.maxY], b.height, [i]))
            }
        }
        var out = boxes
        for line in lines {
            let bottom = median(line.bottoms), h = min(height, line.tallest)
            for i in line.members { out[i] = CGRect(x: boxes[i].minX, y: bottom - h, width: boxes[i].width, height: h) }
        }
        return out
    }

    private static func median(_ xs: [CGFloat]) -> CGFloat { xs.sorted()[xs.count / 2] }
}
