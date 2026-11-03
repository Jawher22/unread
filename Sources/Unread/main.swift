import AppKit

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments

if args.contains("--bench") {
    // Silent: time model load and per-sentence synthesis, no audio output.
    let sentences = [
        "The quick brown fox jumps over the lazy dog.",
        "In 1859, Charles Darwin published On the Origin of Species, a book that changed how we understand life on Earth.",
        "Reading should feel effortless.",
        "Le petit prince est un livre que tout le monde devrait lire au moins une fois dans sa vie.",
    ]
    let done = DispatchSemaphore(value: 0)
    Task {
        let voice = Voice()
        var t = Date()
        do { try await voice.prepareEnglish() } catch { print("english load failed: \(error)") }
        print(String(format: "english load+warm: %.2fs", Date().timeIntervalSince(t)))
        t = Date()
        do { try await voice.prepareFrench() } catch { print("french load failed: \(error)") }
        print(String(format: "french load+warm: %.2fs", Date().timeIntervalSince(t)))
        let tracker = LanguageTracker()
        for s in sentences {
            let lang = tracker.language(for: s)
            for run in 0..<3 {
                let t0 = Date()
                let samples = (try? await voice.synthesize(s, language: lang, speed: 1)) ?? []
                let ms = Date().timeIntervalSince(t0) * 1000
                let audio = Double(samples.count) / 24_000
                if run == 2 { print(String(format: "[%@] %5.0f ms for %.2fs audio (%.0fx realtime)  %@", lang.rawValue, ms, audio, audio * 1000 / ms, String(s.prefix(40)))) }
            }
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

if args.contains("--extract") {
    // Print what we'd read from the front window, without speaking.
    MainActor.assumeIsolated {
        let t = Date()
        guard let doc = DocumentFinder.frontDocument() else { print("no document in front window"); exit(1) }
        print("doc: \(type(of: doc)) found in \(Int(Date().timeIntervalSince(t) * 1000)) ms, visible: \(doc.visibleRect().map { "\($0)" } ?? "nil")")
        var pos = doc.firstVisible()
        var n = 0
        let t2 = Date()
        while let p = pos, n < 12, let s = doc.sentence(from: p) {
            let b = doc.bounds(of: s).map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" } ?? "no bounds"
            print("  \(n). \(b)  \(s.text.prefix(90))")
            pos = s.next
            n += 1
        }
        print("12 sentences walked in \(Int(Date().timeIntervalSince(t2) * 1000)) ms")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MainActor.assumeIsolated { AppController() }
app.run()
