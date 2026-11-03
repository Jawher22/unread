import AppKit

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments

// Launched as Unread.app (Finder, login item), stdout goes nowhere. Keep the
// [unread] log lines in ~/Library/Logs/Unread/unread.log instead.
let devMode = args.contains { $0.hasPrefix("--") }
if !devMode, isatty(STDOUT_FILENO) == 0, Bundle.main.bundleIdentifier != nil {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Unread")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let log = dir.appendingPathComponent("unread.log").path
    if freopen(log, "a", stdout) != nil { setvbuf(stdout, nil, _IOLBF, 0) }
    _ = freopen(log, "a", stderr)
    print("[unread] --- launched \(Date())")
}

if args.contains("--stats") {
    LatencyLog.printStats()
    exit(0)
}

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

if args.contains("--axtree"), let i = args.firstIndex(of: "--axtree"), args.indices.contains(i + 1), let pid = pid_t(args[i + 1]) {
    // Dump an app's web area as role[/subrole] "text", for studying how each
    // engine exposes markup. `--axtree <pid>`
    MainActor.assumeIsolated {
        AX.enableTree(for: pid)
        let axApp = AXUIElementCreateApplication(pid)
        guard let window = (AX.attr(axApp, kAXWindowsAttribute) as? [AXUIElement])?.first,
              let root = AX.find(in: window, { _, role in role == "AXWebArea" }) else { print("no web area"); exit(1) }
        func dump(_ e: AXUIElement, _ depth: Int) {
            guard depth < 14 else { return }
            let role = AX.role(e) ?? "?"
            let sub = (AX.attr(e, kAXSubroleAttribute) as? String).map { "/\($0)" } ?? ""
            let text = ((AX.attr(e, kAXValueAttribute) as? String) ?? (AX.attr(e, kAXTitleAttribute) as? String) ?? "")
                .replacingOccurrences(of: "\n", with: "⏎").prefix(50)
            print(String(repeating: "  ", count: depth) + role + sub + (text.isEmpty ? "" : "  \"\(text)\""))
            AX.children(e).forEach { dump($0, depth + 1) }
        }
        dump(root, 0)
    }
    exit(0)
}

if let i = args.firstIndex(of: "--at"), args.indices.contains(i + 1) {
    // What would a hold at this point (AX coordinates) pick? `--at 700,300`
    let xy = args[i + 1].split(separator: ",").compactMap { Double($0) }
    let point = CGPoint(x: xy[0], y: xy[1])
    MainActor.assumeIsolated {
        func describe(_ e: AXUIElement?) -> String {
            guard let e else { return "nil" }
            let text = ((AX.attr(e, kAXValueAttribute) as? String) ?? "").prefix(60).debugDescription
            return "\(AX.role(e) ?? "?") \(AX.frame(e).map { "\($0)" } ?? "-") \(text)"
        }
        let hit = AX.element(at: point)
        print("hit:  \(describe(hit))")
        if let hit { print("leaf: \(describe(WebDocument.textLeaf(in: hit, at: point)))") }
        guard let doc = DocumentFinder.document(at: point) else { print("no document"); exit(1) }
        if let para = doc.paragraph(at: point), let s = doc.sentence(from: para.start) {
            print("paragraph box: \(para.bounds)")
            print("first sentence: \(s.text.prefix(80).debugDescription)")
            print("lines: \(doc.lines(of: s))")
        } else { print("no paragraph") }
    }
    exit(0)
}

if args.contains("--extract") {
    // Print what we'd read, without speaking.
    //   --extract                     front window, from the first visible paragraph, 12 sentences
    //   --extract --pid N --from-start  any app's main window (no focus needed), whole document
    //   --limit N                     stop after N sentences
    //   --lines                       also print each sentence's line boxes
    func value(after flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    let pid = value(after: "--pid").flatMap { pid_t($0) }
    let fromStart = args.contains("--from-start")
    let limit = value(after: "--limit").flatMap { Int($0) } ?? (fromStart ? 500 : 12)
    MainActor.assumeIsolated {
        let t = Date()
        let found = pid.map { DocumentFinder.document(inApp: $0) } ?? DocumentFinder.frontDocument()
        guard let doc = found else { print("no document in \(pid.map { "pid \($0)" } ?? "front window")"); exit(1) }
        print("doc: \(type(of: doc)) found in \(Int(Date().timeIntervalSince(t) * 1000)) ms, visible: \(doc.visibleRect().map { "\($0)" } ?? "nil")")
        var pos = fromStart ? doc.documentStart() : doc.firstVisible()
        var n = 0
        let t2 = Date()
        while let p = pos, n < limit, let s = doc.sentence(from: p) {
            let b = doc.bounds(of: s).map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" } ?? "no bounds"
            print("  \(n). \(b)  \(fromStart ? Substring(s.text) : s.text.prefix(90))")
            if args.contains("--lines") {
                print("     lines " + doc.lines(of: s).map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" }.joined(separator: " "))
            }
            pos = s.next
            n += 1
        }
        print("\(n) sentences walked in \(Int(Date().timeIntervalSince(t2) * 1000)) ms")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MainActor.assumeIsolated { AppController() }
app.run()
