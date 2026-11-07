import Foundation
import NaturalLanguage

/// A sentence the narrator says: its audio as it streams, and when each word starts, aligned as it comes (#58).
@MainActor
final class NarratorTake {
    private(set) var samples: [Float] = []
    /// All its audio has arrived: the narrator is free for the next sentence.
    private(set) var streamed = false
    /// Streamed, and its words timed: ready to be played whole.
    private(set) var isComplete = false
    let started = Date()
    /// Characters a second at 1× in the voice saying it.
    let pace: Double
    var onArrival: (() -> Void)?
    /// Set while it streams into the player: what has arrived is aligned as it comes, for the word mark.
    var live = false { didSet { alignIfDue() } }
    /// The sentence's display words, and what the narrator is given for them (#18).
    private let words: [Substring]
    private let spoken: Speakable
    /// Characters the narrator says: what its pace measures, for the prebuffer and the predicted end.
    var characters: Int { spoken.text.count }
    private let aligner: Aligner?
    /// Where each spoken word starts in `samples`, by forced alignment (#58); nil where not known (yet).
    private var aligned: [Int?] = []
    /// Samples the latest alignment covered, and whether one is running on a stream.
    private var alignedThrough = 0, aligning = false
    private var task: Task<Void, Never>?
    /// A cue's sound (#24): the same length at every speed.
    private let fixedLength: Bool

    /// `words`: the sentence's display words; the narrator is given them made sayable (`Speakable`).
    /// `after`: the sentence before it in the same paragraph, for the narrator to carry on from (#56).
    init(_ narrator: Narrator, words: ArraySlice<Substring>, language: NLLanguage, after previous: String? = nil) {
        let spoken = Speakable(Array(words), language: language)
        let stream = narrator.speak(spoken.text, language: language, after: previous.map { Speakable($0, language: language).text })
        pace = narrator.pace(for: language)
        self.words = Array(words)
        self.spoken = spoken
        aligner = language == .english ? narrator.aligner : nil
        fixedLength = false
        task = Task { [weak self] in
            do {
                for try await chunk in stream {
                    guard let self else { return }
                    self.samples += chunk
                    self.onArrival?()
                    self.alignIfDue()
                }
            } catch {
                print("[narrator] \(error)")
            }
            guard let self, !Task.isCancelled else { return }
            self.streamed = true
            self.onArrival?()
            if let aligner = self.aligner, let starts = try? await aligner.starts(display: self.spoken.words, samples: self.samples) {
                guard !Task.isCancelled else { return }
                (self.aligned, self.alignedThrough) = (starts, .max)
            }
            self.isComplete = true
            self.onArrival?()
        }
    }

    /// A cue: nothing said, its sound complete from the start.
    init(cue sound: [Float]) {
        samples = sound
        streamed = true
        isComplete = true
        pace = Narrator.pace
        words = []
        spoken = Speakable([], language: .english)
        aligner = nil
        fixedLength = true
    }

    func cancel() {
        task?.cancel()
        onArrival = nil
    }

    /// A live take is aligned again each time ~0.75 s more of it has arrived (an alignment takes ~70 ms).
    private func alignIfDue() {
        guard live, !streamed, !aligning, let aligner, samples.count - alignedThrough >= 18_000 else { return }
        aligning = true
        let heard = samples
        Task { [weak self] in
            let starts = try? await aligner.starts(display: self?.spoken.words ?? [], samples: heard, complete: false)
            guard let self else { return }
            self.aligning = false
            if let starts, heard.count > self.alignedThrough {
                (self.aligned, self.alignedThrough) = (starts, heard.count)
                self.onArrival?()
            }
            self.alignIfDue()
        }
    }

    /// When each display word starts, in samples of the audio stretched to `speed`: the spoken words
    /// aligned as far as the alignment reached, the rest spread by characters from there to the end
    /// of `voiced`; a display word starts with its first spoken word, and one that isn't said has none.
    func wordStarts(voiced: Range<Int>, speed: Float) -> [Int?] {
        spoken.displayStarts(spokenStarts(voiced: voiced, speed: speed), displayCount: words.count)
    }

    private func spokenStarts(voiced: Range<Int>, speed: Float) -> [Int?] {
        let said = spoken.words[...]
        let scaled = aligned.map { $0.map { Int(Double($0) / Double(speed)) } }
        guard let last = scaled.lastIndex(where: { $0 != nil }), let from = scaled[last] else {
            return WordTiming.estimated(said, voiced: voiced)
        }
        return Array(scaled[...last]) + WordTiming.estimated(said[last...], voiced: from..<max(from, voiced.upperBound)).dropFirst()
    }

    func speech(speed: Float) -> Speech {
        var samples = self.samples
        if speed != 1, !fixedLength {
            var stretch = TimeStretch(rate: Double(speed))
            samples = stretch.push(samples) + stretch.finish()
        }
        let quiet = Speech(samples: samples), from = quiet.leadingQuiet
        return Speech(samples: samples, wordStarts: wordStarts(voiced: from..<max(from, samples.count - quiet.trailingQuiet), speed: speed))
    }
}

extension WordTiming {
    /// Each word starts at its share of the characters: the narrator's words where alignment (#58) hasn't reached, or in French.
    static func estimated(_ words: ArraySlice<Substring>, voiced: Range<Int>) -> [Int?] {
        let weights = words.map { $0.count + 1 }
        let total = Double(max(weights.reduce(0, +), 1))
        var before = 0
        return weights.map { w in
            defer { before += w }
            return voiced.lowerBound + Int(Double(voiced.count) * Double(before) / total)
        }
    }
}
