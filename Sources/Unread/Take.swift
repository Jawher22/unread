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
    private(set) var isComplete = false
    let started = Date()
    /// Characters a second at 1× in the voice saying it.
    let pace: Double
    var onArrival: (() -> Void)?
    private var task: Task<Void, Never>?

    init(_ narrator: Narrator, text: String, language: NLLanguage) {
        let stream = narrator.speak(text, language: language)
        pace = narrator.pace(for: language)
        task = Task { [weak self] in
            do {
                for try await chunk in stream {
                    guard let self else { return }
                    self.samples += chunk
                    self.onArrival?()
                }
            } catch {
                print("[narrator] \(error)")
            }
            guard let self, !Task.isCancelled else { return }
            self.isComplete = true
            self.onArrival?()
        }
    }

    func cancel() {
        task?.cancel()
        onArrival = nil
    }

    func speech(words: ArraySlice<Substring>, speed: Float) -> Speech {
        var samples = self.samples
        if speed != 1 {
            var stretch = TimeStretch(rate: Double(speed))
            samples = stretch.push(samples) + stretch.finish()
        }
        let quiet = Speech(samples: samples), from = quiet.leadingQuiet
        return Speech(samples: samples, wordStarts: WordTiming.estimated(words, voiced: from..<max(from, samples.count - quiet.trailingQuiet)))
    }
}

extension WordTiming {
    /// The narrator times no words. Until #58 aligns them to its audio, each word starts at its share of the characters.
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
