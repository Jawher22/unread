import AppKit
import SwiftUI

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
                let samples = (try? await voice.synthesize(s, language: lang, speed: 1))?.samples ?? []
                let ms = Date().timeIntervalSince(t0) * 1000
                let audio = Double(samples.count) / 24_000
                if run == 2 { print(String(format: "[%@] %5.0f ms for %.2fs audio (%.0fx realtime)  %@", lang.rawValue, ms, audio, audio * 1000 / ms, String(s.prefix(40)))) }
            }
        }
        if args.contains("--split") { await benchSplit(voice) }
        done.signal()
    }
    done.wait()
    exit(0)
}

if args.contains("--stretch-check") {
    // Silent: the narrator's time stretch at every menu speed. Exit 1 on failure.
    exit(stretchCheck() ? 0 : 1)
}

if args.contains("--narrate") {
    // Silent: the narrator voice's load, first audio and speed per sentence (#62).
    // `--narrate ["sentence"…] [--out file.wav] [--runs N] [--chunks 2,3,4] [--cancel-test] [--long-test]`
    let done = DispatchSemaphore(value: 0)
    Task {
        await benchNarrator(args)
        done.signal()
    }
    done.wait()
    exit(0)
}

if args.contains("--pace") {
    // Silent: each voice's natural pace, and the narrator cloned from a time-compressed clip.
    // `--pace [--reference-stretch 1.15,1.25] [--out DIR] [--speeds 1.15,1.3]`
    let done = DispatchSemaphore(value: 0)
    Task {
        await benchPace(args)
        done.signal()
    }
    done.wait()
    exit(0)
}

if let i = args.firstIndex(of: "--words") {
    // Silent: when each word of a sentence starts (#20), as the voice times it.
    // `--words ["sentence"…]`; without sentences, a built-in set of hard cases.
    let given = args[(i + 1)...].filter { !$0.hasPrefix("--") }
    let sentences = given.isEmpty ? [
        "The quick brown fox jumps over the lazy dog.",
        "In 1859, Charles Darwin published On the Origin of Species — a book that changed how we understand life.",
        "It costs $45.99 (about 40 €) per month, or 10% less if you pay yearly.",
        "Use `fetch()` with well-known APIs, e.g. the U.S. Census API at 3:30 PM.",
        "Le petit prince est un livre que tout le monde devrait lire au moins une fois dans sa vie.",
    ] : Array(given)
    let done = DispatchSemaphore(value: 0)
    Task {
        let voice = Voice()
        do { try await voice.prepareEnglish(); try await voice.prepareFrench() } catch { print("load failed: \(error)") }
        let tracker = LanguageTracker()
        for s in sentences {
            let lang = tracker.language(for: s)
            guard let raw = try? await voice.spokenWords(s, language: lang),
                  let speech = try? await voice.synthesize(s, language: lang, speed: 1) else { print("synthesis failed"); continue }
            let display = s.split(separator: " ")
            let said = (raw.normalized ?? "").split(whereSeparator: \.isWhitespace).filter { !WordTiming.key($0).isEmpty }
            let mode = said.count == raw.words.count ? "one to one" : "\(said.count) normalized words for \(raw.words.count) spoken"
            print("\n[\(lang.rawValue)] \(s)")
            print("  normalized: \(raw.normalized ?? "nil")")
            print("  phonemes:   \(raw.phonemes)")
            print("  \(display.count) display words, \(raw.words.count) spoken words, \(mode)")
            // Phoneme groups as the voice spaced them, against their times (punctuation-only groups are dropped there too).
            let groups = raw.phonemes.split(separator: " ").filter { $0.contains { !$0.isPunctuation } }
            print("  spoken: " + zip(raw.words, groups.count == raw.words.count ? groups.map(String.init) : raw.words.map { _ in "?" })
                .map { String(format: "%.2f %@", Double($0.0.samples.lowerBound) / 24_000, $0.1) }.joined(separator: " · "))
            for (w, start) in zip(display, speech.wordStarts) {
                print("    " + (start.map { String(format: "%6.2fs", Double($0) / 24_000) } ?? "     – ") + "  \(w)")
            }
            print(String(format: "    %6.2fs  (end)", Double(speech.samples.count) / 24_000))
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

if let i = args.firstIndex(of: "--settings-snapshot"), args.indices.contains(i + 1) {
    // Render the Settings window to a PNG, off-screen, after `seconds` of the
    // demo playing: `--settings-snapshot out.png [seconds] [--dark] [--tab voices|highlight]`.
    // For checking the window's layout without screen recording.
    let out = args[i + 1]
    let seconds = args.indices.contains(i + 2) ? Double(args[i + 2]) ?? 1.5 : 1.5
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if let t = args.firstIndex(of: "--tab"), args.indices.contains(t + 1) { UserDefaults.standard.set(args[t + 1], forKey: SettingsTab.key) }
    MainActor.assumeIsolated {
        HighlightDemoView.fixedTime = seconds
        let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        w.styleMask = [.titled, .closable]
        w.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        w.orderFront(nil)
        if args.contains("--dark") { w.appearance = NSAppearance(named: .darkAqua) }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let view = w.contentView!
            let size = view.bounds.size
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            print("wrote \(out) (\(Int(size.width))x\(Int(size.height)))")
            exit(0)
        }
    }
    app.run()
}

if let i = args.firstIndex(of: "--highlight-frames"), args.indices.contains(i + 1) {
    // Draw the Settings demo frame by frame, off-screen, to review motion:
    // `--highlight-frames out.png|out.gif [from] [to] [--style mark=tail,motion=continuous,lead=50]
    //  [--dark] [--speed 1.3] [--fps 60] [--zoom x,y,w,h]`. A .png is a contact sheet; a .gif plays.
    let out = args[i + 1]
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    let numbers = args[(i + 2)...].prefix { Double($0) != nil }.compactMap(Double.init)
    let from = numbers.first ?? 0, to = numbers.dropFirst().first ?? from + 1
    let fps = value("--fps").flatMap(Double.init) ?? (out.hasSuffix(".gif") ? 50 : 30)
    var style = HighlightStyle.standard
    if let spec = value("--style") {
        var dict = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(style))) as? [String: Any] ?? [:]
        for pair in spec.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { dict[kv[0]] = Int(kv[1]).map { $0 as Any } ?? kv[1] }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let parsed = try? JSONDecoder().decode(HighlightStyle.self, from: data) else { print("bad --style \(spec)"); exit(2) }
        style = parsed
    }
    let zoom = value("--zoom").map { $0.split(separator: ",").compactMap { Double($0) } }.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
    NSApplication.shared.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        HighlightDemoView.fixedTime = from
        let demo = HighlightDemoView()
        demo.frame = NSRect(x: 0, y: 0, width: 600, height: 150)
        let w = NSWindow(contentRect: demo.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = demo
        w.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        w.orderFront(nil)
        demo.dark = args.contains("--dark")
        demo.speed = value("--speed").flatMap(Double.init) ?? 1.3
        demo.style = style
        demo.layoutSubtreeIfNeeded()
        var frames: [(t: Double, image: CGImage)] = []
        var t = 0.0
        while t <= to + 1e-9 {
            demo.render(at: t) // from 0, so every transition's state builds up as it would live
            if t >= from - 1e-9 {
                let rep = demo.bitmapImageRepForCachingDisplay(in: demo.bounds)!
                demo.cacheDisplay(in: demo.bounds, to: rep)
                var image = rep.cgImage!
                if let zoom {
                    let scale = CGFloat(image.width) / demo.bounds.width
                    let crop = CGRect(x: zoom.minX * scale, y: zoom.minY * scale, width: zoom.width * scale, height: zoom.height * scale)
                    image = image.cropping(to: crop) ?? image
                }
                frames.append((t, image))
            }
            t += 1 / fps
        }
        let url = URL(fileURLWithPath: out)
        if out.hasSuffix(".gif") {
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, frames.count, nil) else { exit(1) }
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for f in frames {
                CGImageDestinationAddImage(dest, f.image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
            }
            CGImageDestinationFinalize(dest)
        } else {
            // Contact sheet: frames top to bottom, each labelled with its time.
            let fw = frames[0].image.width, fh = frames[0].image.height, label = 44
            let ctx = CGContext(data: nil, width: fw + label, height: fh * frames.count, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: fw + label, height: fh * frames.count))
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            for (n, f) in frames.enumerated() {
                let y = fh * (frames.count - 1 - n)
                ctx.draw(f.image, in: CGRect(x: label, y: y, width: fw, height: fh))
                (String(format: "%.2f", f.t) as NSString).draw(at: NSPoint(x: 3, y: y + fh / 2 - 7), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)])
            }
            NSGraphicsContext.current = nil
            let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        print("wrote \(out): \(frames.count) frames, \(String(format: "%.2f", from))–\(String(format: "%.2f", to)) s")
        exit(0)
    }
}

if args.contains("--axtree"), let i = args.firstIndex(of: "--axtree"), args.indices.contains(i + 1), let pid = pid_t(args[i + 1]) {
    // Dump an app's web area as role[/subrole] "text", for studying how each
    // engine exposes markup. `--axtree <pid>`
    MainActor.assumeIsolated {
        AX.enableTree(for: pid)
        let axApp = AXUIElementCreateApplication(pid)
        guard let window = AX.element(AX.attr(axApp, kAXFocusedWindowAttribute)) ?? AX.element(AX.attr(axApp, kAXMainWindowAttribute))
                ?? (AX.attr(axApp, kAXWindowsAttribute) as? [AXUIElement])?.first,
              let root = AX.find(in: window, { _, role in role == "AXWebArea" }) else { print("no web area"); exit(1) }
        let frames = args.contains("--frames")
        func dump(_ e: AXUIElement, _ depth: Int) {
            guard depth < 40 else { return }
            let role = AX.role(e) ?? "?"
            let sub = (AX.attr(e, kAXSubroleAttribute) as? String).map { "/\($0)" } ?? ""
            let text = ((AX.attr(e, kAXValueAttribute) as? String) ?? (AX.attr(e, kAXTitleAttribute) as? String) ?? "")
                .replacingOccurrences(of: "\n", with: "⏎").prefix(50)
            let box = frames ? AX.frame(e).map { "  [\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))]" } ?? "" : ""
            let desc = frames ? (AX.attr(e, kAXRoleDescriptionAttribute) as? String).map { "  <\($0)>" } ?? "" : ""
            print(String(repeating: "  ", count: depth) + role + sub + (text.isEmpty ? "" : "  \"\(text)\"") + box + desc)
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
    // `--simulate 700,450 [seconds] [--pid N]`. With UNREAD_DEBUG_OVERLAY=1 it
    // logs every highlight and word-mark change. Draws the real highlight on screen.
    // `--record out.wav` writes what the player outputs, pauses included; `--speed X` reads at X (default 1.3).
    let xy = args[i + 1].split(separator: ",").compactMap { Double($0) }
    let seconds = args.indices.contains(i + 2) ? Double(args[i + 2]) ?? 12 : 12
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        // Main-thread stall meter (#12): a 10 ms timer; any late tick means the
        // main thread (overlay drawing, hotkey) was busy for that long.
        var lastTick = Date(), worst = 0.0, worstAt = 0.0, over50 = 0, over16 = 0, measuring = false, measuredFrom = Date()
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            let gap = Date().timeIntervalSince(lastTick) * 1000 - 10
            lastTick = Date()
            guard measuring else { return }
            if gap > worst { worst = gap; worstAt = Date().timeIntervalSince(measuredFrom) }
            if gap > 16 { over16 += 1 }
            if gap > 50 { over50 += 1 }
        }
        func report() { print(String(format: "[stall] main thread: worst %.0f ms, %d ticks > 16 ms, %d > 50 ms; the worst %.1f s in", worst, over16, over50, worstAt)) }
        let overlay = Overlay(), player = Player(muted: true), voice = Voice()
        func value(after flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        let speed = value(after: "--speed").flatMap(Float.init) ?? 1.3
        if let path = value(after: "--record") {
            do { try player.record(to: URL(fileURLWithPath: path)) } catch { print("can't record to \(path): \(error)"); exit(1) }
        }
        @MainActor func done() {
            player.finishRecording()
            report()
            let gpu = gpuTime()
            print(String(format: "[simulate] GPU: %d clients, %.1f ms", gpu.clients, gpu.ms))
            exit(0)
        }
        let point = CGPoint(x: xy[0], y: xy[1])
        // --pid N: read that app's document from the top instead (fixture hosts sit behind other windows).
        let pinned = args.firstIndex(of: "--pid").flatMap { args.indices.contains($0 + 1) ? pid_t(args[$0 + 1]) : nil }
        let found: (ReadableDocument, AnyObject)?
        if let pinned {
            found = DocumentFinder.document(inApp: pinned).flatMap { d in d.documentStart().map { (d, $0) } }
        } else {
            found = DocumentFinder.document(at: point).flatMap { d in d.paragraph(at: point).map { (d, $0.start) } }
        }
        guard let (doc, startAt) = found else { print("nothing at point"); exit(1) }
        let para = (start: startAt, ())
        Task { @MainActor in
            try? await voice.prepareEnglish()
            // --voice narrator: read with the narrator (#62), as the menu's Voice choice does.
            // --voice-change-at T: switch between it and Kokoro after T seconds (#15).
            var narrator: Narrator?
            let switchAt = value(after: "--voice-change-at").flatMap(Double.init)
            if value(after: "--voice") == "narrator" || switchAt != nil {
                let t = Date()
                do {
                    narrator = try await Narrator.load(english: VoicePreset.named(NarratorVoices.defaults[.english]!),
                                                     french: NarratorVoices.preset(for: .french))
                    print(String(format: "[simulate] narrator loaded in %.1fs", Date().timeIntervalSince(t)))
                } catch {
                    print("[simulate] narrator unavailable, reading with Kokoro: \(error)")
                }
            }
            let reader = value(after: "--voice") == "narrator" ? narrator : nil
            // --primed [S]: start from the first sentence prepared during a hold (#5), released S seconds
            // (default 0.4) after the preparing began.
            var primed: PrimedSentence?
            if let j = args.firstIndex(of: "--primed") {
                let hold = args.indices.contains(j + 1) ? Double(args[j + 1]) ?? 0.4 : 0.4
                // --idle-before S: leave the voice idle S seconds first; then ⌃ goes down 0.3 s before the
                // speculation starts, and wakes the narrator as the app does (--no-wake: it doesn't). --evict
                // drops the narrator's mapped pages first.
                if let idle = value(after: "--idle-before").flatMap(Double.init) {
                    try? await Task.sleep(for: .seconds(idle))
                    if args.contains("--evict"), let reader { reader.workingSet.evict() } // as memory pressure would
                    if !args.contains("--no-wake") { reader?.wake() }
                    try? await Task.sleep(for: .seconds(0.3))
                }
                primed = PrimedSentence.prepare(doc, from: para.start, kokoro: voice, narrator: reader, speed: speed)
                try? await Task.sleep(for: .seconds(hold))
                print(String(format: "[simulate] released after a %.2fs hold", hold))
            }
            let s = ReadingSession(document: doc, start: para.start, speed: speed, kokoro: voice, narrator: reader, player: player,
                                   overlay: overlay, startedAt: Date(), primed: primed)
            s.onFinish = { print("[session] finished"); done() }
            var reading = s
            measuring = true
            lastTick = Date()
            measuredFrom = lastTick
            // --speed-change-at T: switch to 1.75× after T seconds (#15).
            if let j = args.firstIndex(of: "--speed-change-at"), args.indices.contains(j + 1), let at = Double(args[j + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { print("[simulate] speed → 1.75×"); reading.speed = 1.75 }
            }
            if let at = switchAt, let loaded = narrator {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                    reading.narrator = reading.narrator == nil ? loaded : nil
                    print("[simulate] voice → \(reading.narrator == nil ? "kokoro" : "narrator")")
                }
            }
            s.start()
            // --jump-at T: after T seconds, hold to jump back to the start, released 0.4 s later, as
            // the app does (the session yields the narrator to the hold's speculation).
            if let at = value(after: "--jump-at").flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                    s.setAiming(true)
                    s.yieldNarrator()
                    let primed = PrimedSentence.prepare(doc, from: para.start, kokoro: voice, narrator: s.narrator, speed: speed)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        print("[simulate] jumped")
                        s.stop()
                        reading = ReadingSession(document: doc, start: para.start, speed: speed, kokoro: voice, narrator: s.narrator,
                                                 player: player, overlay: overlay, startedAt: Date(), primed: primed)
                        reading.onFinish = { print("[session] finished"); done() }
                        reading.start()
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { reading.stop(); done() }
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
    //   --blocks                      mark a sentence that ends its paragraph with " ¶" (#56)
    //   --word-boxes                  also print each word's box (#20)
    //   --from-text "…"               point at the first visible text containing this, and start at the sentence holding it
    //   --slow                        pause 1.6 s per sentence (pages that re-render), then measure, like a reading would
    //   --wait S                      keep looking for up to S seconds (a host that just launched; Chromium building its tree)
    func value(after flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    let pid = value(after: "--pid").flatMap { pid_t($0) }
    let fromStart = args.contains("--from-start")
    let limit = value(after: "--limit").flatMap { Int($0) } ?? (fromStart ? 500 : 12)
    let wait = value(after: "--wait").flatMap { TimeInterval($0) } ?? 0
    MainActor.assumeIsolated {
        let t = Date()
        func open() -> ReadableDocument? { pid.map { DocumentFinder.document(inApp: $0) } ?? DocumentFinder.frontDocument() }
        func findStart(in doc: ReadableDocument) -> AnyObject? {
            guard let needle = value(after: "--from-text") else { return fromStart ? doc.documentStart() : doc.firstVisible() }
            func search(from start: AnyObject?) -> AnyObject? {
                var pos = start
                while let p = pos, let s = doc.sentence(from: p) { if s.text.contains(needle) { return p }; pos = s.next }
                return nil
            }
            // Point at the first visible text holding the needle, as the user would; a walk from the top
            // can end before reaching it (WebKit's walk ends at some line breaks). Text below the fold falls back to the walk.
            func pointed() -> AnyObject? {
                guard let visible = doc.visibleRect(),
                      let leaf = AX.firstInOrder(in: doc.element, maxNodes: 50_000, { e in
                          AX.role(e) == kAXStaticTextRole && ((AX.attr(e, kAXValueAttribute) as? String)?.contains(needle) ?? false)
                              && AX.frame(e).map { $0.width > 2 && $0.height > 2 && visible.intersects($0) } == true
                      }),
                      let f = AX.frame(leaf) else { return nil }
                return doc.paragraph(at: CGPoint(x: f.minX + 2, y: f.minY + min(f.height / 2, 8)))?.start
            }
            return search(from: pointed()) ?? search(from: doc.documentStart())
        }
        // Polled in one process so the tree is switched on once, as in the app: a new process would set the flag again and restart Chromium's build.
        // Not before the app shows a window (a user only points at one): Chromium ignores the flag set earlier, and AX.enableTree won't set it twice.
        // A main window counts too: a window on another Space isn't in AXWindows (TextEdit opened with `open -g`).
        func showsWindow() -> Bool {
            pid.map { let app = AXUIElementCreateApplication($0)
                return (AX.attr(app, kAXWindowsAttribute) as? [AXUIElement])?.isEmpty == false || AX.attr(app, kAXMainWindowAttribute) != nil } ?? true
        }
        func readable(_ doc: ReadableDocument) -> Bool { findStart(in: doc).flatMap { doc.sentence(from: $0) } != nil }
        var found = showsWindow() ? open() : nil
        while !(found.map(readable) ?? false), Date().timeIntervalSince(t) < wait {
            Thread.sleep(forTimeInterval: 0.1)
            found = showsWindow() ? open() : nil
        }
        guard let doc = found else { print("no document in \(pid.map { "pid \($0)" } ?? "front window")"); exit(1) }
        print("doc: \(type(of: doc)) found in \(Int(Date().timeIntervalSince(t) * 1000)) ms, visible: \(doc.visibleRect().map { "\($0)" } ?? "nil")")
        let slow = args.contains("--slow")
        func findStart() -> AnyObject? { findStart(in: doc) }
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
            print("  \(n). \(b)  \(fromStart ? Substring(s.text) : s.text.prefix(90))\(args.contains("--blocks") && s.endsBlock ? " ¶" : "")")
            if args.contains("--word-boxes") {
                // Each display word with its box (#20); "?" where it has none.
                _ = doc.lines(of: s)
                let boxes = doc.words(of: s)
                let shown = zip(s.words, boxes.isEmpty ? s.words.map { _ in nil } : boxes).map { w, b in
                    b.map { "\(w)(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height)))" } ?? "\(w)?"
                }
                print("     words \(boxes.compactMap { $0 }.count)/\(s.words.count): " + shown.joined(separator: " "))
            }
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
