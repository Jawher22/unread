import AVFoundation
import Foundation
import NaturalLanguage

/// `--narrate`: the narrator voice (#62), silent. Times loading, then each
/// sentence: first decoded chunk (silent or not), first audible chunk, total,
/// speed, and whether a player starting at the first chunk would have run dry.
/// Checks the GPU stays unused, and writes the audio to a WAV to listen to.
/// `--voice <id>` reads its language in that preset (#60). `--cancel-test` cancels
/// a long sentence mid-way; `--long-test` says one too long for the talker's memory
/// in one piece; `--switch-test [--cold]` switches through every preset (`--cold`:
/// with its encoded clip deleted from the cache first).
func benchNarrator(_ args: [String]) async {
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    let flagValues = Set(["--out", "--runs", "--chunks", "--voice", "--idle", "--wake", "--lead", "--churn"].compactMap(value))
    let given = args.drop { $0 != "--narrate" }.dropFirst().filter { !$0.hasPrefix("--") && !flagValues.contains($0) }
    let sentences = given.isEmpty ? defaultSentences : Array(given)
    let runs = value("--runs").flatMap(Int.init) ?? 2
    let chunks = value("--chunks").map { $0.split(separator: ",").compactMap { Int($0) } } ?? Narrator.chunkFrames

    let gpuBefore = gpuTime()
    let loading = Date()
    let narrator: Narrator
    do {
        let picked = try value("--voice").map(VoicePreset.named)
        let english = try picked?.language == .english ? picked! : VoicePreset.named(NarratorVoices.defaults[.english]!)
        let french = picked?.language == .french ? picked : NarratorVoices.preset(for: .french)
        print("voices: \(english.id), \(french?.id ?? "the English one for French")")
        narrator = try await Narrator.load(english: english, french: french, chunkFrames: chunks)
    } catch {
        print("load failed: \(error)")
        return
    }
    let s = narrator.startup
    print(String(format: "loaded in %.2f s (engine %.2f s, voice %.2f s, warm-up %.2f s), footprint %.2f GB; chunks %@",
                 Date().timeIntervalSince(loading), s.engine, s.voice, s.warmUp, footprint().now,
                 chunks.map(String.init).joined(separator: ",")))

    if let idle = value("--idle") {
        await idleTest(narrator, waits: idle.split(separator: ",").compactMap { Double($0) },
                       wakes: value("--wake")?.split(separator: ",").map(String.init) ?? ["none"],
                       lead: value("--lead").flatMap(Double.init) ?? 0,
                       churn: value("--churn")?.split(separator: ",").map(String.init) ?? [], evict: args.contains("--evict"))
        return
    }

    let rate = Double(Narrator.sampleRate)
    let tracker = LanguageTracker()
    var results: [Narration] = []
    var recording: [Float] = []
    for run in 0..<runs {
        for text in sentences {
            let language = tracker.language(for: text)
            guard let r = await say(text, language: language, narrator) else { continue }
            results.append(r)
            print(r.line)
            if run == 0 { recording += r.samples + [Float](repeating: 0, count: Int(rate / 2)) }
        }
    }
    summarize(results)

    if args.contains("--cancel-test") { await cancelTest(narrator) }
    if args.contains("--long-test") { await longTest(narrator) }
    if args.contains("--switch-test") { await switchTest(narrator, cold: args.contains("--cold")) }
    let gpuAfter = gpuTime()
    print(String(format: "\npeak memory footprint %.2f GB; GPU: %d clients, %.1f ms of GPU time (%d clients, %.1f ms before loading)",
                 footprint().peak, gpuAfter.clients, gpuAfter.ms, gpuBefore.clients, gpuBefore.ms))

    if let out = value("--out") {
        do {
            try writeWAV(recording, rate: rate, to: URL(fileURLWithPath: out))
            print(String(format: "wrote %@ (%.1f s)", out, Double(recording.count) / rate))
        } catch {
            print("couldn't write \(out): \(error)")
        }
    }
}

private let defaultSentences = [
    "Reading should feel effortless.",
    "The hard part isn't storing things.",
    "Why does this matter?",
    "When a request arrives, the server first checks whether it has already done this work.",
    "If it has, the answer comes back in a few milliseconds; if not, it pays the full cost and remembers the result for next time.",
    "In 1859, Charles Darwin published On the Origin of Species, a book that changed how we understand life on Earth.",
    "She closed the book, looked out at the rain, and smiled.",
    "Long before the first train reached the valley, the people who lived there measured distance in days rather than miles, and a trip to the coast was something a family planned for a whole season.",
    "Il pleuvait depuis le matin, et la ville semblait retenir son souffle.",
    "Bonjour à tous.",
    "La lecture devrait être un plaisir, pas un effort.",
    "Le petit prince est un livre que tout le monde devrait lire, au moins une fois dans sa vie, parce qu'il parle de l'amitié, de l'amour et de ce qui compte vraiment.",
]

private struct Narration {
    let text: String
    let language: NLLanguage
    let samples: [Float]
    let firstDecode: Double
    let firstAudible: Double
    let total: Double
    /// How long a player that started at the first chunk would have waited for audio, in seconds.
    let stall: Double
    let report: Narrator.Report?

    var audio: Double { Double(samples.count) / Double(Narrator.sampleRate) }
    var factor: Double { total / audio }
    var pace: Double { Double(text.count) / audio }
    var pitch: Int? { median(pitchTrack(samples, samples.indices).map(Double.init)).map { Int($0) } }

    var line: String {
        let peak = samples.lazy.map(abs).max() ?? 0
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
        return String(format: "[%@] decode %4.0f  audible %4.0f  total %5.0f ms  %5.2f s  RTF %.2f  %4.1f c/s  lead %.2f s  stall %3.0f ms  peak %.2f rms %.3f  F0 %@ Hz  %@%@  %@",
                      language == .french ? "fr" : "en", firstDecode * 1000, firstAudible * 1000, total * 1000, audio, factor,
                      pace, report?.leadingSilence ?? .nan, stall * 1000, peak, rms, pitch.map(String.init) ?? "–",
                      report?.stop ?? "?", (report?.parts ?? 1) > 1 ? " \(report!.parts) parts" : "", String(text.prefix(36)))
    }
}

private func say(_ text: String, language: NLLanguage, _ narrator: Narrator) async -> Narration? {
    let start = Date()
    var samples: [Float] = []
    var first: Double?
    var playedUntil = 0.0, stall = 0.0
    do {
        for try await chunk in narrator.speak(text, language: language) {
            let now = Date().timeIntervalSince(start)
            first = first ?? now
            if now > playedUntil { stall += samples.isEmpty ? 0 : now - playedUntil; playedUntil = now }
            playedUntil += Double(chunk.count) / Double(Narrator.sampleRate)
            samples += chunk
        }
    } catch {
        print("  failed: \(error)  \(text.prefix(50))")
        return nil
    }
    let total = Date().timeIntervalSince(start)
    let report = await narrator.lastReport
    return Narration(text: text, language: language, samples: samples, firstDecode: report?.firstDecode ?? .nan,
                  firstAudible: first ?? .nan, total: total, stall: stall, report: report)
}

private func summarize(_ results: [Narration]) {
    guard !results.isEmpty else { return }
    func stats(_ name: String, _ values: [Double], unit: Double = 1000) -> String {
        String(format: "%@ median %.0f, p90 %.0f, range %.0f–%.0f", name, (median(values) ?? .nan) * unit,
               percentile(values, 0.9) * unit, (values.min() ?? .nan) * unit, (values.max() ?? .nan) * unit)
    }
    print("\nover \(results.count) sentences:")
    print("  " + stats("first decoded chunk (ms):", results.map(\.firstDecode)))
    print("  " + stats("first audible chunk (ms):", results.map(\.firstAudible)))
    print("  " + stats("leading silence generated (ms):", results.compactMap { $0.report?.leadingSilence }))
    print(String(format: "  RTF median %.2f, worst %.2f; %d of %d would stall a player, worst %.0f ms",
                 median(results.map(\.factor)) ?? .nan, results.map(\.factor).max() ?? .nan,
                 results.filter { $0.stall > 0 }.count, results.count, (results.map(\.stall).max() ?? 0) * 1000))
    let paces = results.map(\.pace)
    print(String(format: "  pace median %.1f c/s, range %.1f–%.1f", median(paces) ?? .nan, paces.min() ?? .nan, paces.max() ?? .nan))
    var seen = Set<String>()
    for r in results where (r.pace < 13 || r.pace > 16) && seen.insert(r.text).inserted {
        print(String(format: "    outside 13–16 c/s: %.1f  %@", r.pace, String(r.text.prefix(50))))
    }
    for language in [NLLanguage.english, .french] {
        let f0 = results.filter { $0.language == language }.compactMap(\.pitch).map(Double.init)
        guard !f0.isEmpty else { continue }
        print(String(format: "  F0 per sentence (%@): median %.0f Hz, range %.0f–%.0f",
                     language.rawValue, median(f0) ?? .nan, f0.min() ?? .nan, f0.max() ?? .nan))
    }
}

/// `--idle 0,60,600`: waits each many seconds, then says a short sentence, as a hold after a pause would.
/// Each line shows the sentence's stages, the page faults it took and how much of the mapped model
/// files was still in memory, to tell paging from a cold Neural Engine. `--wake none,both` cycles
/// through what ⌃ going down does first (`Narrator.wake`: none, prefetch, warm, both), `--lead S`
/// seconds before the sentence is asked for (the hold's speculation starts ~0.3 s after ⌃ goes down).
/// `--churn file,…` reads those files during each wait, as a build or a browser churns the file cache.
/// `--evict` drops the narrator's mapped pages after each wait, as memory pressure does.
private func idleTest(_ narrator: Narrator, waits: [Double], wakes: [String], lead: Double, churn: [String], evict: Bool) async {
    let probes = ["Paragraph pauses.", "The narrator is ready.", "She closed the book and smiled."]
    var groups: [String: (UInt64, Int)] = [:]
    for r in MappedFiles.regions() {
        let key = r.path.contains("e5bundlecache") ? "Core ML compiled programs" : r.path.contains("fluidaudio") ? "Kokoro"
            : r.path.replacingOccurrences(of: Narrator.modelDirectory.path + "/", with: "").split(separator: "/").prefix(2).joined(separator: "/")
        groups[key, default: (0, 0)].0 += r.size
        groups[key, default: (0, 0)].1 += MappedFiles.resident([r]).bytes
    }
    for (key, (size, resident)) in groups.sorted(by: { $0.value.0 > $1.value.0 }) where size > 4_000_000 {
        print(String(format: "  mapped %6.0f MB, %3.0f%% in memory  %@", Double(size) / 1e6, Double(resident) * 100 / Double(size), key))
    }
    for (i, wait) in waits.enumerated() {
        if i % wakes.count == 0 {
            print(String(format: "  working set %.0f MB of the narrator's %.0f MB mapped", Double(narrator.workingSet.bytes) / 1e6,
                         Double(narrator.workingSet.regions.reduce(0) { $0 + Int($1.size) }) / 1e6))
        }
        let waited = Date()
        if wait > 0, !churn.isEmpty { readThrough(churn) }
        let left = wait - Date().timeIntervalSince(waited)
        if left > 0 { try? await Task.sleep(for: .seconds(left)) }
        if evict, wait > 0 { narrator.workingSet.evict() }
        let regions = MappedFiles.regions()
        let before = MappedFiles.resident(regions)
        let wake = wakes[i % wakes.count]
        let faults = pageFaults()
        if wake != "none" { narrator.wake(prefetch: wake != "warm", warm: wake != "prefetch") }
        if lead > 0 { try? await Task.sleep(for: .seconds(lead)) }
        let atAsk = MappedFiles.resident(regions)
        guard let r = await say(probes[(i / wakes.count) % probes.count], language: .english, narrator) else { continue }
        let after = pageFaults()
        let t = r.report?.timings, frames = max(r.report?.frames ?? 1, 1)
        print(String(format: "idle %4.0f s  %-8@ mapped %3.0f%%→%3.0f%% of %.2f GB  key-down→audible %4.0f ms  prefill %4.0f  %3.0f ms/frame  vocoder %4.0f  page-ins %5d  ",
                     wait, wake as NSString, Double(before.bytes) * 100 / Double(max(before.of, 1)), Double(atAsk.bytes) * 100 / Double(max(atAsk.of, 1)),
                     Double(before.of) / 1e9, (lead + r.firstAudible) * 1000, (t?.prefill ?? .nan) * 1000,
                     (t?.loop ?? .nan) * 1000 / Double(frames), (t?.vocoder ?? .nan) * 1000, after.pageIns - faults.pageIns) + r.line)
    }
}

private func readThrough(_ files: [String]) {
    var buffer = [UInt8](repeating: 0, count: 8 << 20)
    for file in files {
        let fd = open(file, O_RDONLY)
        guard fd >= 0 else { continue }
        while read(fd, &buffer, buffer.count) > 0 {}
        close(fd)
    }
}

/// This process's page-ins (major faults, read from disk) and all faults so far.
private func pageFaults() -> (pageIns: Int, faults: Int) {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return ok == 0 ? (Int(info.ri_pageins), Int(usage.ru_minflt + usage.ru_majflt)) : (-1, -1)
}

private let longSentence = "Long before the first train reached the valley, the people who lived there measured distance not in miles but in days, and a journey to the coast was something a family planned for a whole season, packing bread, letters and patience for the road."

/// Cancel a long sentence after its first second of audio: how long until the
/// narrator is free, and whether the next sentence still works.
private func cancelTest(_ narrator: Narrator) async {
    print("\ncancel test")
    var heard = 0
    var cancelledAt = Date()
    do {
        for try await chunk in narrator.speak(longSentence, language: .english) {
            heard += chunk.count
            if heard >= Narrator.sampleRate {
                cancelledAt = Date()
                break
            }
        }
    } catch {
        print("  failed: \(error)")
    }
    await narrator.idle()
    let report = await narrator.lastReport
    print(String(format: "  cancelled after %.2f s of audio: free again %.0f ms later (stop: %@)",
                 Double(heard) / Double(Narrator.sampleRate), Date().timeIntervalSince(cancelledAt) * 1000, report?.stop ?? "?"))
    if let r = await say("The next sentence still works.", language: .english, narrator) { print("  next: " + r.line) }

    // Ask for three at once, as reading will (the next sentence while one plays): they must come in order.
    let started = Date()
    let streams = ["One.", "Two, a little longer.", "Three."].map { narrator.speak($0, language: .english) }
    let finished = await withTaskGroup(of: (Int, Double).self) { group in
        for (i, stream) in streams.enumerated() {
            group.addTask {
                do { for try await _ in stream {} } catch {}
                return (i, Date().timeIntervalSince(started))
            }
        }
        return await group.reduce(into: []) { $0.append($1) }.sorted { $0.1 < $1.1 }.map(\.0)
    }
    print("  three asked at once finished in order \(finished.map { $0 + 1 })")
}

/// Switch to each preset in turn, then say a sentence in it: what the switch cost, and whether
/// the sentence after it starts as fast as one in a voice already in use.
private func switchTest(_ narrator: Narrator, cold: Bool) async {
    print("\nswitch test" + (cold ? " (clips encoded afresh)" : ""))
    let lines: [NLLanguage: String] = [.english: "When a request arrives, the server first checks whether it has already done this work.",
                                       .french: "Il pleuvait depuis le matin, et la ville semblait retenir son souffle."]
    var costs: [(clone: Double, warm: Double, first: Double, again: Double)] = []
    for preset in VoicePreset.all {
        if cold { try? FileManager.default.removeItem(at: Narrator.cacheDirectory(preset)) }
        let cost: Narrator.Switch?
        do { cost = try await narrator.use(preset) } catch { print("  \(preset.id): \(error)"); continue }
        guard let cost, let line = lines[preset.language],
              let first = await say(line, language: preset.language, narrator),
              let again = await say(line, language: preset.language, narrator) else { continue }
        let fromSwitch = cost.clone + cost.warm + first.firstAudible
        costs.append((cost.clone, cost.warm, first.firstAudible, again.firstAudible))
        print(String(format: "  %@ %-22@ clone %4.0f ms  warm %4.0f ms  first audible %4.0f ms (%4.0f ms from the switch), again %4.0f ms",
                     preset.language.rawValue, preset.id, cost.clone * 1000, cost.warm * 1000, first.firstAudible * 1000,
                     fromSwitch * 1000, again.firstAudible * 1000))
    }
    guard !costs.isEmpty else { return }
    func m(_ v: [Double]) -> Double { (median(v) ?? .nan) * 1000 }
    print(String(format: "  over %d switches, medians: clone %.0f ms (max %.0f), warm %.0f ms (max %.0f), first audible after %.0f ms, again %.0f ms",
                 costs.count, m(costs.map(\.clone)), (costs.map(\.clone).max() ?? 0) * 1000, m(costs.map(\.warm)),
                 (costs.map(\.warm).max() ?? 0) * 1000, m(costs.map(\.first)), m(costs.map(\.again))))
}

/// A sentence too long for the talker's 1024-slot memory in one piece.
private func longTest(_ narrator: Narrator) async {
    print("\nlong sentence test")
    let text = [longSentence,
                "and long after it came, the old people still said the coast was three days away",
                "and they still packed bread, letters and patience as if nothing had changed",
                "because a road is not only a distance but a habit, and habits outlast the reasons for them",
                "so that even their grandchildren, who took the train every week and thought nothing of it, would sometimes stop at the station and count the days on their fingers before remembering that the sea was now only an hour away, which was a kind of loss that nobody had a word for."]
        .joined(separator: ", ").replacingOccurrences(of: "road., ", with: "road, ")
    if let r = await say(text, language: .english, narrator) {
        print(String(format: "  %d characters: ", text.count) + r.line)
    }
}

private func median(_ values: [Double]) -> Double? { values.isEmpty ? nil : percentile(values, 0.5) }

private func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
}

/// This process's memory footprint now and at its peak, in GB.
private func footprint() -> (now: Double, peak: Double) {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return ok == 0 ? (Double(info.ri_phys_footprint) / 1e9, Double(info.ri_lifetime_max_phys_footprint) / 1e9) : (.nan, .nan)
}

/// GPU clients this process opened and their accumulated GPU time, from the GPU driver's registry entries.
func gpuTime() -> (clients: Int, ms: Double) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    process.arguments = ["-r", "-c", "AGXDeviceUserClient", "-l"]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return (-1, .nan) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let me = "\"IOUserClientCreator\" = \"pid \(getpid()),"
    var clients = 0, nanoseconds = 0.0
    for entry in String(decoding: data, as: UTF8.self).components(separatedBy: "+-o ") where entry.contains(me) {
        clients += 1
        for match in entry.matches(of: #/"accumulatedGPUTime"=(\d+)/#) { nanoseconds += Double(match.1) ?? 0 }
    }
    return (clients, nanoseconds / 1e6)
}

func writeWAV(_ samples: [Float], rate: Double, to url: URL) throws {
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
}

/// `--stretch-check`: at every menu speed, `TimeStretch` gives the same output whole, in odd
/// chunks and a sample at a time, of the expected length, with no step in a stretched sine.
func stretchCheck() -> Bool {
    var noise = SystemRandomNumberGenerator()
    var inputs: [(String, [Float])] = [
        ("noise", (0..<50_000).map { _ in Float.random(in: -0.5...0.5, using: &noise) }),
        ("sine", (0..<120_000).map { Float(0.5 * sin(2 * Double.pi * 220 * Double($0) / 24_000)) }),
    ]
    if let clip = try? VoicePreset.named(NarratorVoices.defaults[.english]!).audio, let speech = try? readWAV(clip) { inputs.append(("voice", speech)) }
    func stretch(_ x: [Float], _ rate: Double, pieces: [Int]) -> [Float] {
        var s = TimeStretch(rate: rate), out: [Float] = [], i = 0, k = 0
        while i < x.count {
            let n = min(pieces[k % pieces.count], x.count - i)
            out += s.push(Array(x[i..<i + n]))
            i += n
            k += 1
        }
        return out + s.finish()
    }
    var ok = true
    for rate in [0.9, 1.15, 1.2, 1.3, 1.5, 1.75, 2.0] {
        for (name, x) in inputs {
            let whole = stretch(x, rate, pieces: [x.count])
            let same = stretch(x, rate, pieces: [3840, 1920, 2880, 7680, 5]) == whole && (name == "voice" || stretch(x, rate, pieces: [1]) == whole)
            let length = whole.count == Int((Double(x.count) / rate).rounded())
            var smooth = true
            if name == "sine" {
                let body = whole[2000..<(whole.count - 2000)]
                smooth = zip(body, body.dropFirst()).allSatisfy { abs($0 - $1) < 0.03 } // the sine's own step is 0.029
            }
            ok = ok && same && length && smooth
            print(String(format: "%.2f× %@: %@", rate, name, same && length && smooth ? "ok" : "FAIL (same \(same), length \(length), smooth \(smooth))"))
        }
    }
    print(ok ? "PASS" : "FAIL")
    return ok
}

func readWAV(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

/// Pitch in Hz of each voiced 40 ms frame of `range`, at 24 kHz.
func pitchTrack(_ x: [Float], _ range: Range<Int>) -> [Int] {
    let frame = 960, lo = 24_000 / 400, hi = 24_000 / 70
    var out: [Int] = []
    for f in stride(from: max(range.lowerBound, 0), to: min(range.upperBound, x.count) - frame - hi, by: frame) {
        let energy = x[f..<(f + frame)].reduce(0) { $0 + $1 * $1 }
        guard energy > 0.5 else { continue }
        var best = 0, bestR: Float = 0
        for lag in lo...hi {
            var r: Float = 0
            for i in 0..<frame { r += x[f + i] * x[f + i + lag] }
            if r > bestR { bestR = r; best = lag }
        }
        if bestR > 0.3 * energy { out.append(24_000 / best) }
    }
    return out
}
