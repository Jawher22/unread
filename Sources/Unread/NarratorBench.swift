import AVFoundation
import Foundation
import NaturalLanguage

/// `--narrate`: the narrator helper as Unread sees it (#57). Silent. Times the
/// helper's startup, then each sentence from writing the request to reading
/// its first audio frame, and writes the audio to a WAV to listen to.
/// `--cancel-test` cancels a long sentence after its first chunk, `--kill-test`
/// kills the helper mid-sentence.
func benchNarrator(_ args: [String]) async {
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    let flagValues = Set(["--out", "--runs"].compactMap(value))
    let given = args.drop { $0 != "--narrate" }.dropFirst().filter { !$0.hasPrefix("--") && !flagValues.contains($0) }
    let sentences = given.isEmpty ? [
        "When a request arrives, the server first checks whether it has already done this work.",
        "If it has, the answer comes back in a few milliseconds; if not, it pays the full cost and remembers the result for next time.",
        "The hard part isn't storing things.",
        "Reading should feel effortless.",
        "In 1859, Charles Darwin published On the Origin of Species, a book that changed how we understand life on Earth.",
        "Il pleuvait depuis le matin, et la ville semblait retenir son souffle.",
    ] : Array(given)
    let runs = value("--runs").flatMap(Int.init) ?? 2

    let launched = Date()
    let narrator: Narrator
    do {
        narrator = try await Narrator.launch(voice: VoicePreset.named("london-storyteller"))
    } catch {
        print("launch failed: \(error)")
        return
    }
    let s = narrator.startup
    print(String(format: "helper ready in %.2f s (load %d ms, voice %d ms, warm-up %d ms), pid %d",
                 Date().timeIntervalSince(launched), s.loadMs, s.voiceMs, s.warmupMs, narrator.pid))

    let rate = Double(narrator.startup.sampleRate)
    let tracker = LanguageTracker()
    var firsts: [Double] = [], factors: [Double] = []
    var recording: [Float] = []
    for run in 0..<runs {
        for text in sentences {
            let language = tracker.language(for: text)
            let start = Date()
            var first: Double?
            var samples: [Float] = []
            do {
                for try await chunk in narrator.speak(text, language: language).chunks {
                    if first == nil { first = Date().timeIntervalSince(start) * 1000 }
                    samples += chunk
                }
            } catch {
                print("  failed: \(error)  \(text.prefix(50))")
                continue
            }
            let total = Date().timeIntervalSince(start)
            let audio = Double(samples.count) / rate
            let peak = samples.lazy.map(abs).max() ?? 0
            let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
            firsts.append(first ?? .nan)
            factors.append(total / audio)
            print(String(format: "[%@] first %4.0f ms  total %5.0f ms  %5.2f s audio  RTF %.2f  %4.1f chars/s  peak %.2f rms %.3f  %@",
                         language == .french ? "fr" : "en", first ?? .nan, total * 1000, audio, total / audio,
                         Double(text.count) / audio, peak, rms, String(text.prefix(40))))
            if run == 0 { recording += samples + [Float](repeating: 0, count: Int(rate / 2)) }
        }
    }
    func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }
    print(String(format: "\nfirst audio over %d sentences: median %.0f ms, p90 %.0f ms, range %.0f–%.0f ms; RTF median %.2f",
                 firsts.count, percentile(firsts, 0.5), percentile(firsts, 0.9), firsts.min() ?? .nan, firsts.max() ?? .nan,
                 percentile(factors, 0.5)))

    if args.contains("--cancel-test") { await cancelTest(narrator) }
    print(String(format: "helper peak memory footprint: %.2f GB", peakFootprint(narrator.pid)))
    if args.contains("--kill-test") { await killTest(narrator) }

    if let out = value("--out") {
        do {
            try writeWAV(recording, rate: rate, to: URL(fileURLWithPath: out))
            print(String(format: "wrote %@ (%.1f s)", out, Double(recording.count) / rate))
        } catch {
            print("couldn't write \(out): \(error)")
        }
    }
    narrator.stop()
}

private let longSentence = "Long before the first train reached the valley, the people who lived there measured distance not in miles but in days, and a journey to the coast was something a family planned for a whole season, packing bread, letters and patience for the road."

/// Cancel a long sentence after its first chunk: how long until the helper
/// confirms it stopped, and whether the next request still works.
private func cancelTest(_ narrator: Narrator) async {
    print("\ncancel test")
    let request = narrator.speak(longSentence, language: .english)
    var cancelledAt: Date?
    var after = 0
    do {
        for try await _ in request.chunks {
            if cancelledAt == nil {
                cancelledAt = Date()
                narrator.cancel(request.id)
            } else {
                after += 1
            }
        }
        print("  not cancelled: the sentence finished")
    } catch Narrator.Failure.cancelled {
        print(String(format: "  cancelled after the first chunk: confirmed in %.0f ms, %d chunks arrived meanwhile",
                     Date().timeIntervalSince(cancelledAt ?? Date()) * 1000, after))
    } catch {
        print("  failed: \(error)")
    }
    let start = Date()
    var first: Double?, count = 0
    do {
        for try await chunk in narrator.speak("The next sentence still works.", language: .english).chunks {
            if first == nil { first = Date().timeIntervalSince(start) * 1000 }
            count += chunk.count
        }
        print(String(format: "  next request: first audio %.0f ms, %.2f s audio", first ?? .nan, Double(count) / Double(narrator.startup.sampleRate)))
    } catch {
        print("  next request failed: \(error)")
    }
}

/// Kill the helper mid-sentence: the request must fail, not hang, and later
/// requests fail at once.
private func killTest(_ narrator: Narrator) async {
    print("\nkill test")
    let request = narrator.speak(longSentence, language: .english)
    var killedAt: Date?
    do {
        for try await _ in request.chunks {
            if killedAt == nil {
                killedAt = Date()
                kill(narrator.pid, SIGKILL)
            }
        }
        print("  request finished without an error")
    } catch {
        print(String(format: "  request failed %.0f ms after the kill: %@", Date().timeIntervalSince(killedAt ?? Date()) * 1000, "\(error)"))
    }
    let start = Date()
    do {
        for try await _ in narrator.speak("Anyone there?", language: .english).chunks {}
        print("  next request succeeded?")
    } catch {
        print(String(format: "  next request failed in %.1f ms: %@", Date().timeIntervalSince(start) * 1000, "\(error)"))
    }
}

/// The most physical memory the process has used, GPU buffers included.
private func peakFootprint(_ pid: Int32) -> Double {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return ok == 0 ? Double(info.ri_lifetime_max_phys_footprint) / 1e9 : .nan
}

private func writeWAV(_ samples: [Float], rate: Double, to url: URL) throws {
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
}
