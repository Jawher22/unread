import Foundation
import NaturalLanguage

enum Take {
    case kokoro(Speech, speed: Float)
    case narrator(NarratorTake)

    var isKokoro: Bool { if case .kokoro = self { true } else { false } }

    @MainActor func cancel() {
        if case .narrator(let take) = self { take.cancel() }
    }
}

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
    private let words: [Substring]
    private let aligner: Aligner?
    /// Where each word starts in `samples`, by forced alignment (#58); nil where not known (yet).
    private var aligned: [Int?] = []
    /// Samples the latest alignment covered, and whether one is running on a stream.
    private var alignedThrough = 0, aligning = false
    private var task: Task<Void, Never>?

    init(_ narrator: Narrator, text: String, words: ArraySlice<Substring>, language: NLLanguage) {
        let stream = narrator.speak(text, language: language)
        pace = narrator.pace(for: language)
        self.words = Array(words)
        aligner = language == .english ? narrator.aligner : nil
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
            if let aligner = self.aligner, let starts = try? await aligner.starts(display: self.words, samples: self.samples) {
                guard !Task.isCancelled else { return }
                (self.aligned, self.alignedThrough) = (starts, .max)
            }
            self.isComplete = true
            self.onArrival?()
        }
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
            let starts = try? await aligner.starts(display: self?.words ?? [], samples: heard, complete: false)
            guard let self else { return }
            self.aligning = false
            if let starts, heard.count > self.alignedThrough {
                (self.aligned, self.alignedThrough) = (starts, heard.count)
                self.onArrival?()
            }
            self.alignIfDue()
        }
    }

    /// When each word starts, in samples of the audio stretched to `speed`: aligned as far as the
    /// alignment reached, the rest spread by characters from there to the end of `voiced`.
    func wordStarts(voiced: Range<Int>, speed: Float) -> [Int?] {
        let scaled = aligned.map { $0.map { Int(Double($0) / Double(speed)) } }
        guard let last = scaled.lastIndex(where: { $0 != nil }), let from = scaled[last] else {
            return WordTiming.estimated(words[...], voiced: voiced)
        }
        return Array(scaled[...last]) + WordTiming.estimated(words[last...], voiced: from..<max(from, voiced.upperBound)).dropFirst()
    }

    func speech(speed: Float) -> Speech {
        var samples = self.samples
        if speed != 1 {
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
