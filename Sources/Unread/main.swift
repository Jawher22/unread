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
        // --pid N: use that app's window even if it isn't on top (fixture hosts).
        let pinned = args.firstIndex(of: "--pid").flatMap { args.indices.contains($0 + 1) ? pid_t(args[$0 + 1]) : nil }
        guard let doc = pinned.map({ DocumentFinder.document(inApp: $0) }) ?? DocumentFinder.document(at: point) else { print("no document"); exit(1) }
        guard let para = doc.paragraph(at: point) else { print("no paragraph"); exit(1) }
        print("paragraph box: \(para.bounds)")
        let scope = doc.scope(from: para.start)
        // Walk on like a reading session would, so a missing highlight on
        // later sentences shows up here too.
        var pos: AnyObject? = para.start
        for n in 0..<6 {
            guard let p = pos, let s = doc.sentence(from: p, in: scope) else { break }
            print("  \(n). \(s.text.prefix(70).debugDescription)")
            print("     lines \(doc.lines(of: s))")
            pos = s.next
        }
    }
    exit(0)
}

if let i = args.firstIndex(of: "--simulate"), args.indices.contains(i + 1) {
    // Read from a point exactly like a hold does, but muted, then quit:
    // `--simulate 700,450 [seconds]`. With UNREAD_DEBUG_OVERLAY=1 it logs
    // every highlight change. Draws the real highlight on screen.
    let xy = args[i + 1].split(separator: ",").compactMap { Double($0) }
    let seconds = args.indices.contains(i + 2) ? Double(args[i + 2]) ?? 12 : 12
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        // Main-thread stall meter (#12): a 10 ms timer; any late tick means the
        // main thread (overlay drawing, hotkey) was busy for that long.
        var lastTick = Date(), worst = 0.0, over50 = 0, over16 = 0, measuring = false
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            let gap = Date().timeIntervalSince(lastTick) * 1000 - 10
            lastTick = Date()
            guard measuring else { return }
            worst = max(worst, gap)
            if gap > 16 { over16 += 1 }
            if gap > 50 { over50 += 1 }
        }
        func report() { print(String(format: "[stall] main thread: worst %.0f ms, %d ticks > 16 ms, %d > 50 ms", worst, over16, over50)) }
        let overlay = Overlay(), player = Player(muted: true), voice = Voice()
        let point = CGPoint(x: xy[0], y: xy[1])
        guard let doc = DocumentFinder.document(at: point), let para = doc.paragraph(at: point) else { print("nothing at point"); exit(1) }
        Task { @MainActor in
            try? await voice.prepareEnglish()
            // --primed: start from a pre-synthesized first sentence, like a hold does (#5).
            var primed: PrimedSentence?
            if args.contains("--primed") {
                let start = para.start
                primed = PrimedSentence(prepared: Task { @MainActor () -> PrimedSentence.Prepared? in
                    let extracted = await AXWorker.shared.run { () -> (Sentence, ReadingScope?)? in
                        let scope = doc.scope(from: start)
                        return doc.sentence(from: start, in: scope).map { ($0, scope) }
                    }
                    guard let (first, scope) = extracted else { return nil }
                    let samples = try? await voice.synthesize(first.text, language: .english, speed: 1.3)
                    return .init(sentence: first, scope: scope, extractMs: 0, samples: samples, synthMs: 0)
                })
            }
            let s = ReadingSession(document: doc, start: para.start, speed: 1.3, voice: voice, player: player, overlay: overlay,
                                   startedAt: Date(), primed: primed)
            s.onFinish = { print("[session] finished"); report(); exit(0) }
            measuring = true
            lastTick = Date()
            // --speed-change-at T: switch to 1.75× after T seconds (#15).
            if let j = args.firstIndex(of: "--speed-change-at"), args.indices.contains(j + 1), let at = Double(args[j + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { print("[simulate] speed → 1.75×"); s.speed = 1.75 }
            }
            s.start()
            _ = s // keep alive
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { s.stop(); report(); exit(0) }
        }
    }
    app.run()
}

if args.contains("--extract") {
    // Print what we'd read, without speaking.
    //   --extract                     front window, from the first visible paragraph, 12 sentences
    //   --extract --pid N --from-start  any app's main window (no focus needed), whole document
    //   --limit N                     stop after N sentences
    //   --lines                       also print each sentence's line boxes
    //   --from-text "…"               start at the first sentence containing this text (like pointing there)
    //   --slow                        pause 1.6 s per sentence (pages that re-render), then measure, like a reading would
    func value(after flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    let pid = value(after: "--pid").flatMap { pid_t($0) }
    let fromStart = args.contains("--from-start")
    let limit = value(after: "--limit").flatMap { Int($0) } ?? (fromStart ? 500 : 12)
    MainActor.assumeIsolated {
        let t = Date()
        let found = pid.map { DocumentFinder.document(inApp: $0) } ?? DocumentFinder.frontDocument()
        guard let doc = found else { print("no document in \(pid.map { "pid \($0)" } ?? "front window")"); exit(1) }
        print("doc: \(type(of: doc)) found in \(Int(Date().timeIntervalSince(t) * 1000)) ms, visible: \(doc.visibleRect().map { "\($0)" } ?? "nil")")
        let slow = args.contains("--slow")
        func findStart() -> AnyObject? {
            var pos = fromStart || value(after: "--from-text") != nil ? doc.documentStart() : doc.firstVisible()
            if let needle = value(after: "--from-text") {
                while let p = pos, let s = doc.sentence(from: p), !s.text.contains(needle) { pos = s.next }
            }
            return pos
        }
        var pos = findStart()
        if pos == nil { print("nothing to read"); exit(1) }
        var scope = pos.flatMap { doc.scope(from: $0) }
        var n = 0
        var last: Sentence?
        let t2 = Date()
        while n < limit {
            var next = pos.flatMap { doc.sentence(from: $0, in: scope) }
            if next == nil, let l = last { next = doc.sentence(after: l, scope: &scope) }
            if next == nil, last == nil, let again = findStart() { pos = again; scope = doc.scope(from: again); next = doc.sentence(from: again, in: scope) }
            guard var s = next else { break }
            if slow {
                Thread.sleep(forTimeInterval: 1.6)
                if doc.lines(of: s).isEmpty, let fresh = doc.relocate(s) { s = fresh }
            }
            last = s
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
