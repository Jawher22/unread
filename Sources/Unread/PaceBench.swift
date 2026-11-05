import Foundation
import NaturalLanguage
import QwenANE

/// `--pace`: each voice's natural pace at 1× on one passage, silent. Speaking rate is characters
/// per second of voice (each sentence's own leading and trailing quiet left out, pauses inside it
/// kept); articulation rate leaves out pauses inside sentences too (quiet of 150 ms or more).
/// Also the narrator cloned from its reference clip time-compressed by `TimeStretch`
/// (`--reference-stretch 1.15,1.25`), and how close each one's voice is to the clip's (cosine of
/// the speaker encoder's embeddings). `--out DIR` writes the passage read by each, with `Pacing`'s
/// pauses, plus the narrator stretched to `--speeds 1.15,1.3`.
func benchPace(_ args: [String]) async {
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    func list(_ flag: String) -> [Double] { value(flag)?.split(separator: ",").compactMap { Double($0) } ?? [] }
    let out = value("--out").map { URL(fileURLWithPath: $0) }
    if let out { try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }

    let kokoro = Voice()
    do { try await kokoro.prepareEnglish() } catch { print("kokoro failed to load: \(error)"); return }
    var takes: [(name: String, sentences: [[Float]])] = []
    var kokoroSentences: [[Float]] = []
    for text in passage {
        kokoroSentences.append((try? await kokoro.synthesize(text, language: .english, speed: 1))?.samples ?? [])
    }
    takes.append(("kokoro 1.0x", kokoroSentences))

    let shipped: VoicePreset
    do { shipped = try VoicePreset.named("london-storyteller") } catch { print("\(error)"); return }
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("unread-pace-\(getpid())")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    var presets: [(name: String, preset: VoicePreset)] = [("storyteller 1.0x as shipped", shipped)]
    for rate in list("--reference-stretch") {
        do {
            let preset = try stretchedPreset(shipped, rate: rate, in: scratch)
            presets.append((String(format: "storyteller cloned from %gx reference", rate), preset))
            if let out { try FileManager.default.copyItem(at: preset.audio, to: out.appendingPathComponent(String(format: "reference clip at %gx.wav", rate))) }
        } catch { print("couldn't stretch the reference to \(rate)x: \(error)") }
    }
    if let out { try? FileManager.default.copyItem(at: shipped.audio, to: out.appendingPathComponent("reference clip as shipped.wav")) }

    for (name, preset) in presets {
        do {
            let narrator = try await Narrator.load(english: preset, french: nil)
            var sentences: [[Float]] = []
            for text in passage {
                var samples: [Float] = []
                for try await chunk in narrator.speak(text, language: .english) { samples += chunk }
                let stop = await narrator.lastReport?.stop ?? "?"
                if stop != "eos" { print("  \(name): \"\(text.prefix(30))…\" stopped on \(stop)") }
                sentences.append(samples)
            }
            takes.append((name, sentences))
        } catch { print("\(name): \(error)") }
    }

    let clip = (try? readWAV(shipped.audio)) ?? []
    let reference = (try? speakerEmbedding(clip)) ?? []
    let clipRate = rate(shipped.transcript, clip)
    print(String(format: "reference clip: speaking %.1f c/s, articulation %.1f c/s, F0 %@ Hz (%d characters, %.2f s with its quiet)",
                 clipRate.speaking, clipRate.articulation, medianPitch(clip), shipped.transcript.count, Double(clip.count) / 24_000))
    print("\npassage: \(passage.count) sentences, \(passage.joined().count) characters")
    for take in takes {
        let r = rate(passage, take.sentences)
        let joined = join(take.sentences, speed: 1)
        let limit = QwenVoicePrep.encoderLimitSamples(modelsDirectory: Narrator.modelDirectory)
        let similarity = (try? speakerEmbedding(Array(joined.prefix(limit)))).map { cosine($0, reference) }
        let f0 = medianPitch(take.sentences.flatMap { $0 })
        print(String(format: "%-40@ speaking %4.1f c/s  articulation %4.1f c/s  pauses inside sentences %.2f s  F0 %@ Hz  voice vs clip %@",
                     take.name as NSString, r.speaking, r.articulation, r.pauses, f0, similarity.map { String(format: "%.3f", $0) } ?? "–"))
        if let out { write(joined, to: out.appendingPathComponent(take.name + ".wav")) }
    }
    if let out, let narrator = takes.first(where: { $0.name.hasSuffix("as shipped") }) {
        for speed in list("--speeds") {
            write(join(narrator.sentences, speed: speed), to: out.appendingPathComponent(String(format: "storyteller at %gx stretch.wav", speed)))
        }
        print("wrote \(out.path)")
    }
    try? FileManager.default.removeItem(at: scratch)
}

private let passage = [
    "The lighthouse keeper climbed the stairs every evening, one hundred and twelve of them, counting under his breath.",
    "At the top he trimmed the wick, polished the great lens, and wrote the weather in a small leather book.",
    "Ships he would never meet passed in the dark, guided by a light he had made.",
    "Most nights nothing happened at all, and that was exactly the point.",
    "In the morning he walked down again, made tea, and slept while the sea went on without him.",
]

private struct Rate { let speaking, articulation, pauses: Double }

private func rate(_ text: String, _ samples: [Float]) -> Rate { rate([text], [samples]) }

private func rate(_ texts: [String], _ takes: [[Float]]) -> Rate {
    var voiced = 0, pauses = 0
    for samples in takes {
        let speech = Speech(samples: samples)
        let span = speech.leadingQuiet..<max(speech.leadingQuiet, samples.count - speech.trailingQuiet)
        voiced += span.count
        pauses += speech.quietRuns(in: span).filter { $0.count >= 3_600 }.reduce(0) { $0 + $1.count }
    }
    let characters = Double(texts.joined().count)
    return Rate(speaking: characters / (Double(voiced) / 24_000), articulation: characters / (Double(voiced - pauses) / 24_000),
                pauses: Double(pauses) / 24_000)
}

/// The sentences as Unread plays them at `speed`: stretched, each with `Pacing.edge` of quiet a side, `Pacing.sentence` apart.
private func join(_ takes: [[Float]], speed: Double) -> [Float] {
    let edge = Pacing.edgeSamples
    let pause = Int(max(Pacing.sentence / speed - 2 * Pacing.edge, Pacing.minPause) * 24_000)
    var out: [Float] = []
    for samples in takes {
        var s = samples
        if speed != 1 { var stretch = TimeStretch(rate: speed); s = stretch.push(s) + stretch.finish() }
        let speech = Speech(samples: s)
        let from = max(speech.leadingQuiet - edge, 0), to = min(s.count - speech.trailingQuiet + edge, s.count)
        if from < to { out += s[from..<to] }
        out += [Float](repeating: 0, count: pause)
    }
    return out
}

private func medianPitch(_ samples: [Float]) -> String {
    let track = pitchTrack(samples, samples.indices).sorted()
    return track.isEmpty ? "–" : String(track[track.count / 2])
}

/// The preset with its clip time-compressed by `rate` (pitch kept), written to `dir`.
private func stretchedPreset(_ preset: VoicePreset, rate: Double, in dir: URL) throws -> VoicePreset {
    var stretch = TimeStretch(rate: rate)
    let clip = try readWAV(preset.audio)
    let audio = dir.appendingPathComponent(String(format: "%@-%gx.wav", preset.audio.deletingPathExtension().lastPathComponent, rate))
    try writeWAV(stretch.push(clip) + stretch.finish(), rate: 24_000, to: audio)
    return VoicePreset(id: audio.deletingPathExtension().lastPathComponent, name: preset.name, language: preset.language,
                       summary: preset.summary, description: preset.description, transcript: preset.transcript,
                       audio: audio, preview: nil, pace: preset.pace)
}

private func speakerEmbedding(_ samples: [Float]) throws -> [Float] {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("unread-speaker-\(getpid()).wav")
    defer { try? FileManager.default.removeItem(at: file) }
    try writeWAV(samples, rate: 24_000, to: file)
    return try QwenVoicePrep.prepare(referenceWAV: Data(contentsOf: file), transcript: "x",
                                     modelsDirectory: Narrator.modelDirectory, kind: .qwen17).spkEmbedding
}

private func cosine(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return .nan }
    let dot = zip(a, b).reduce(0) { $0 + Double($1.0 * $1.1) }
    let na = a.reduce(0) { $0 + Double($1 * $1) }.squareRoot(), nb = b.reduce(0) { $0 + Double($1 * $1) }.squareRoot()
    return dot / (na * nb)
}

private func write(_ samples: [Float], to url: URL) {
    do { try writeWAV(samples, rate: 24_000, to: url) } catch { print("couldn't write \(url.path): \(error)") }
}
