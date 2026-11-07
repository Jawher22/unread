import Foundation
import QwenANE

/// `--eval PASSAGES --out DIR`: each passage (`PASSAGES/<id>.txt`: a sentence a line, a blank line between
/// paragraphs) read at 1× the way a reading says it (#75): sayable text (#18), each sentence carried on from
/// the one before (#56), its quiet trimmed to `Pacing.edge`, `Pacing`'s pause between.
/// Writes `DIR/<id>.wav` and `DIR/run.json`. Silent.
///
/// `--paragraph` gives the narrator each paragraph as one text (#79), split only where the talker can't hold it.
/// `--temperature`, `--top-k`, `--repetition`: the first codebook's sampling (#76). `--voice id`: the preset.
/// `--seed-salt S`: other takes of the same passages, for more blind pairs.
/// `--speed X`: played at X the way reading plays it (each take time-stretched, `Pacing`'s pauses divided by X).
/// `--reference-stretch R`: the voice cloned from its clip time-compressed R×, which makes the model itself faster.
/// `--stretch Y`: the take's stretch, when it isn't X. `--squeeze P`: quiet inside a take (150 ms or more) cut to 1/P of it, not under 120 ms.
func benchEval(_ args: [String]) async {
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    guard let input = value("--eval"), let output = value("--out") else {
        print("usage: --eval PASSAGES --out DIR [--paragraph] [--temperature T] [--top-k K] [--repetition R] [--voice id] [--seed-salt S] [--speed X] [--stretch Y] [--squeeze P] [--reference-stretch R]")
        return
    }
    let defaults = QwenSampling()
    let sampling = QwenSampling(temperature: value("--temperature").flatMap(Double.init) ?? defaults.temperature,
                                topK: value("--top-k").flatMap(Int.init) ?? defaults.topK,
                                repetition: value("--repetition").flatMap(Float.init) ?? defaults.repetition)
    let wholeParagraphs = args.contains("--paragraph")
    let voice = value("--voice") ?? NarratorVoices.defaults[.english]!
    let speed = value("--speed").flatMap(Float.init) ?? 1
    let referenceStretch = value("--reference-stretch").flatMap(Double.init) ?? 1
    let stretchRate = value("--stretch").flatMap(Double.init) ?? Double(speed)
    let squeeze = value("--squeeze").flatMap(Double.init) ?? 1
    let inputs = URL(fileURLWithPath: input), out = URL(fileURLWithPath: output)
    let files = ((try? FileManager.default.contentsOfDirectory(at: inputs, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !files.isEmpty else { print("no passages in \(input)"); return }

    let narrator: Narrator
    do {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var preset = try VoicePreset.named(voice)
        if referenceStretch != 1 {
            let clips = out.appendingPathComponent("reference")
            try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
            preset = try stretchedPreset(preset, rate: referenceStretch, in: clips)
        }
        narrator = try await Narrator.load(english: preset, french: nil, sampling: sampling, seedSalt: value("--seed-salt") ?? "")
    } catch { print("\(error)"); return }

    var passages: [[String: Any]] = []
    for file in files {
        let id = file.deletingPathExtension().lastPathComponent
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            .filter { !$0.isEmpty }
        var audio: [Float] = [], parts = 0, stops: [String] = []
        let start = Date()
        var previous: String?
        for paragraph in paragraphs {
            let said = (wholeParagraphs ? [paragraph.joined(separator: " ")] : paragraph).map { Speakable($0, language: .english).text }
            for sentence in said {
                var samples: [Float] = []
                do {
                    for try await chunk in narrator.speak(sentence, language: .english, after: previous) { samples += chunk }
                } catch { print("\(id): \(error)"); continue }
                previous = sentence
                if let report = await narrator.lastReport { parts += report.parts; stops.append(report.stop) }
                if squeeze != 1 { samples = squeezed(samples, by: squeeze) }
                if stretchRate != 1 {
                    var stretch = TimeStretch(rate: stretchRate)
                    samples = stretch.push(samples) + stretch.finish()
                }
                audio += Speech(samples: samples).trimmingLeadingQuiet(keep: Pacing.edgeSamples)
                    .trimmingTrailingQuiet(keep: Pacing.edgeSamples).samples
                audio += [Float](repeating: 0, count: Pacing.pause(speed: speed))
            }
        }
        let synthesis = Date().timeIntervalSince(start), seconds = Double(audio.count) / Double(Narrator.sampleRate)
        do { try writeWAV(audio, rate: Double(Narrator.sampleRate), to: out.appendingPathComponent("\(id).wav")) } catch { print("\(id): \(error)") }
        print(String(format: "%@  %.1f s of audio in %.1f s, %d parts, stops: %@", id, seconds, synthesis, parts,
                     Dictionary(stops.map { ($0, 1) }, uniquingKeysWith: +).map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ")))
        passages.append(["id": id, "seconds": seconds, "synthesis": synthesis, "parts": parts, "stops": stops])
    }
    let run: [String: Any] = [
        "voice": voice, "paragraph": wholeParagraphs, "speed": Double(speed), "stretch": stretchRate, "squeeze": squeeze, "referenceStretch": referenceStretch, "seedSalt": value("--seed-salt") ?? "", "date": ISO8601DateFormatter().string(from: Date()),
        "sampling": ["temperature": sampling.temperature, "topK": sampling.topK, "repetition": Double(sampling.repetition)],
        "passages": passages,
    ]
    if let json = try? JSONSerialization.data(withJSONObject: run, options: [.prettyPrinted, .sortedKeys]) {
        try? json.write(to: out.appendingPathComponent("run.json"))
    }
    print("wrote \(passages.count) passages to \(output)")
}

/// Each quiet run inside the voice (150 ms or more) shortened to 1/`factor` of it, never under 120 ms, cut from its middle.
private func squeezed(_ samples: [Float], by factor: Double) -> [Float] {
    let speech = Speech(samples: samples), rate = Double(Narrator.sampleRate)
    var out: [Float] = [], at = 0
    for run in speech.quietRuns(in: 0..<samples.count) where run.lowerBound > 0 && run.upperBound < samples.count {
        guard Double(run.count) >= 0.15 * rate else { continue }
        let keep = max(Int(Double(run.count) / factor), Int(0.12 * rate))
        guard keep < run.count else { continue }
        let mid = run.lowerBound + keep / 2
        out += samples[at..<mid]
        at = mid + run.count - keep
    }
    return out + samples[at...]
}
