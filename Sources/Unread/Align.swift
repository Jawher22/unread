import FluidAudio
import Foundation

/// Forced alignment (#58): where each word of a known text starts in audio,
/// from a CTC model's per-frame log-probabilities. The text is known, so this
/// finds the likeliest path through its tokens rather than transcribing.
enum CTCAlignment {
    /// The frame each word starts at: its first token's first frame on the
    /// Viterbi path through `blank, t1, blank, t2, …, tn, blank`.
    ///
    /// `logProbs` is frames × `vocabulary`, row-major. With `complete: false`
    /// the audio is still arriving and may stop partway through the text: the
    /// path may end at any token, and a word's start is returned only once
    /// the next word has begun, since the last word under way can still move.
    /// Nil where a word has no tokens, or there are too few frames for the text.
    static func wordStarts(logProbs: [Float], vocabulary: Int, words: [[Int]], blank: Int, complete: Bool = true) -> [Int?] {
        let none = [Int?](repeating: nil, count: words.count)
        let frames = logProbs.count / max(vocabulary, 1)
        var tokens: [Int] = [], wordOf: [Int] = []
        for (w, ids) in words.enumerated() {
            tokens += ids
            wordOf += Array(repeating: w, count: ids.count)
        }
        guard frames > 0, !tokens.isEmpty else { return none }
        // State 2k+1 is token k; even states are blanks.
        let states = 2 * tokens.count + 1
        func label(_ s: Int) -> Int { s % 2 == 0 ? blank : tokens[s / 2] }
        let impossible = -Float.infinity
        var score = [Float](repeating: impossible, count: states)
        var from = [UInt8](repeating: 0, count: frames * states) // 0 stay, 1 from s-1, 2 from s-2
        score[0] = logProbs[label(0)]
        if states > 1 { score[1] = logProbs[label(1)] }
        var next = score
        for t in 1..<max(frames, 1) {
            let row = t * vocabulary
            for s in 0..<states {
                var best = score[s], step: UInt8 = 0
                if s >= 1, score[s - 1] > best { best = score[s - 1]; step = 1 }
                // A token may follow the previous token directly unless they're the same (CTC needs a blank between repeats).
                if s >= 2, s % 2 == 1, label(s) != label(s - 2), score[s - 2] > best { best = score[s - 2]; step = 2 }
                next[s] = best == impossible ? impossible : best + logProbs[row + label(s)]
                from[t * states + s] = step
            }
            swap(&score, &next)
        }
        // A complete text ends on its last token or the blank after it.
        let ends = complete ? Array(max(states - 2, 0)..<states) : Array(0..<states)
        guard var s = ends.max(by: { score[$0] < score[$1] }), score[s] > impossible else { return none }
        var starts = none
        var lastWord = -1
        for t in stride(from: frames - 1, through: 0, by: -1) {
            if s % 2 == 1 {
                let w = wordOf[s / 2]
                starts[w] = t // walking back, the last write is the earliest frame
                if lastWord < 0 { lastWord = w }
            }
            s -= Int(from[t * states + s])
        }
        if !complete {
            // The word the audio stops in may not have reached its real start yet only if it's the last one; drop it.
            for w in words.indices where w >= lastWord { starts[w] = nil }
        }
        // A word whose first token wasn't visited (only possible for the first, when the path starts on a blank) has no start.
        for (w, ids) in words.enumerated() where ids.isEmpty { starts[w] = nil }
        return starts
    }
}

/// The aligner for voices that time no words (the narrator): Parakeet CTC 110M, English only
/// (no CTC model covers French), mel spectrogram on the CPU and encoder on the Neural Engine.
actor Aligner {
    private let spotter: CtcKeywordSpotter
    private let tokenizer: CtcTokenizer
    private let blank: Int
    private let vocabulary: [Int: String]
    private let converter = AudioConverter()

    private init(models: CtcModels, tokenizer: CtcTokenizer) {
        spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        self.tokenizer = tokenizer
        blank = models.vocabulary.count
        vocabulary = models.vocabulary
    }

    static func load() async throws -> Aligner {
        let models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        let tokenizer = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory(for: .ctc110m))
        return Aligner(models: models, tokenizer: tokenizer)
    }

    /// When each display word starts in `samples` (24 kHz), nil where it isn't known.
    /// `complete: false` for audio still streaming: only words the audio is past get a start.
    func starts(display: [Substring], samples: [Float], complete: Bool = true) async throws -> [Int?] {
        let text = display.joined(separator: " ")
        let said = NemoTextNormalizer.normalize(text, language: .english)
            .split(whereSeparator: \.isWhitespace).map(Self.spelling).filter { !$0.isEmpty }
        guard !said.isEmpty, !samples.isEmpty else { return display.map { _ in nil } }
        let result = try await spotter.spotKeywordsWithLogProbs(audioSamples: try converter.resample(samples, from: 24_000), customVocabulary: CustomVocabularyContext(terms: []))
        let vocabulary = result.logProbs.first?.count ?? 0
        let frames = CTCAlignment.wordStarts(logProbs: result.logProbs.flatMap { $0 }, vocabulary: vocabulary,
                                             words: said.map { tokenizer.encode($0) }, blank: blank, complete: complete)
        let saidStarts = frames.map { $0.map { Int(Double($0) * result.frameDuration * 24_000) } }
        return WordTiming.align(display.map(WordTiming.key), said.map(WordTiming.key)).map { $0.flatMap { saidStarts[$0] } }
    }

    /// What the audio says, as the model hears it: the likeliest token each frame, repeats merged,
    /// blanks dropped (greedy CTC). A rough transcript, for `--hear`: what the narrator said for a text.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { return "" }
        let result = try await spotter.spotKeywordsWithLogProbs(audioSamples: try converter.resample(samples, from: 24_000), customVocabulary: CustomVocabularyContext(terms: []))
        var text = "", previous = blank
        for frame in result.logProbs {
            guard let best = frame.indices.max(by: { frame[$0] < frame[$1] }) else { continue }
            if best != previous, best != blank { text += vocabulary[best] ?? "" }
            previous = best
        }
        return text.replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Letters, digits and apostrophes, lowercased: what the tokenizer can spell.
    private static func spelling(_ word: Substring) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }).replacingOccurrences(of: "’", with: "'")
    }
}
