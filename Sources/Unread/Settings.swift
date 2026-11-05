import AppKit
import NaturalLanguage
import SwiftUI

// MARK: - Settings window

enum SettingsTab: String, CaseIterable {
    case voices, highlight
    static let key = "settingsTab"
    var title: String { self == .voices ? "Voice" : "Highlight" }
}

struct SettingsView: View {
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.voices

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings", selection: $tab) {
                ForEach(SettingsTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 14)
            switch tab {
            case .voices: VoiceSettingsView()
            case .highlight: HighlightSettingsView()
            }
        }
        .frame(width: 760)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Which voice reads (#59), and the narrator's voices (#60), one choice per language. Play buttons
/// play a recording the narrator made in that voice, so they work before it has loaded.
private struct VoiceSettingsView: View {
    @ObservedObject private var reading = ReadingVoice.shared
    @ObservedObject private var voices = NarratorVoices.shared
    @ObservedObject private var preview = VoicePreview.shared

    var body: some View {
        Form {
            Section {
                Picker("Read with", selection: Binding(get: { reading.choice }, set: { reading.choose($0) })) {
                    Text("Narrator").tag(VoiceChoice.narrator)
                    Text("Kokoro").tag(VoiceChoice.kokoro)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(readWithNote).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(NarratorVoices.languages, id: \.self) { language in
                Section {
                    ForEach(NarratorVoices.presets(language)) { row($0, chosen: voices.preset(for: language) == $0) }
                } header: {
                    Text(language == .french ? "French" : "English")
                } footer: {
                    Text(language == .french
                         ? "French sentences are read in the French voice. These voices are synthetic, designed from a description; none is a real person's."
                         : "A new voice starts at the next sentence.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 640)
        .onDisappear { preview.stop() }
    }

    private var readWithNote: String {
        switch (reading.choice, reading.narratorStatus) {
        case (.kokoro, _): "Kokoro starts sooner and uses less memory, in a plainer voice."
        case (.narrator, .loading): "The narrator is loading. Kokoro reads until it's ready."
        case (.narrator, .unavailable): "The narrator couldn't load (see the log), so Kokoro reads."
        case (.narrator, _): "The narrator reads in the voices below. Kokoro reads in the seconds it takes to load."
        }
    }

    private func row(_ preset: VoicePreset, chosen: Bool) -> some View {
        let playing = preview.playing == preset.id
        return HStack(spacing: 10) {
            Button { preview.toggle(preset) } label: {
                Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(playing ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            .disabled(preset.preview == nil)
            .accessibilityLabel(playing ? "Stop \(preset.name)" : "Play \(preset.name)")
            Text(preset.name)
                .frame(width: 180, alignment: .leading)
            Text(preset.summary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .fontWeight(.semibold)
                .opacity(chosen ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { voices.choose(preset) }
        .help(preset.description)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Choose") { voices.choose(preset) }
    }
}

private struct HighlightSettingsView: View {
    @ObservedObject private var settings = HighlightSettings.shared
    @State private var darkPage = false
    @State private var previewSpeed = 1.3

    var body: some View {
        Form {
            Section {
                HighlightDemo(style: settings.style, dark: darkPage, speed: previewSpeed)
                    .frame(height: 116)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack {
                    Text("Page").foregroundStyle(.secondary)
                    Picker("Page", selection: $darkPage) {
                        Text("Light").tag(false)
                        Text("Dark").tag(true)
                    }
                    .fixedSize()
                    Spacer()
                    Text("Speed").foregroundStyle(.secondary)
                    Picker("Speed", selection: $previewSpeed) {
                        ForEach([1.0, 1.3, 2.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                    }
                    .fixedSize()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Read-along highlight")
            } footer: {
                Text("A preview of reading, with real word timings. The page and speed here only change the preview.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                row("Word mark", $settings.style.mark, HighlightStyle.label)
                row("Motion", $settings.style.motion, HighlightStyle.label)
                row("Word strength", $settings.style.strength, HighlightStyle.label)
                    .disabled(settings.style.mark == .none)
                row("Sentence", $settings.style.sentence, HighlightStyle.label)
                row("Color", $settings.style.tint, HighlightStyle.label)
                row("Lead", $settings.style.lead, HighlightStyle.label)
            } footer: {
                Text("Glide slides to each word. Stretch reaches for the next word and pulls itself along. Flow is always easing toward the next word. Sweep fills each word in as it's spoken. Lead moves the mark ahead of the voice, if it feels late to you.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Restore Defaults") { settings.style = .standard }
                    .disabled(settings.style == .standard)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row<T: Hashable & CaseIterable>(_ title: String, _ value: Binding<T>, _ label: @escaping (T) -> String) -> some View
    where T.AllCases: RandomAccessCollection {
        Picker(title, selection: value) {
            ForEach(T.allCases, id: \.self) { Text(label($0)).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(tab: SettingsTab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.key) }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            hosting.sizingOptions = .preferredContentSize // the window takes each pane's height
            let w = NSWindow(contentViewController: hosting)
            w.title = "Unread Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            // Closing drops the window, so the demo stops animating.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.window = nil }
            }
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Demo

private struct HighlightDemo: NSViewRepresentable {
    let style: HighlightStyle
    let dark: Bool
    let speed: Double

    func makeNSView(context: Context) -> HighlightDemoView { HighlightDemoView() }

    /// Whatever width the form offers; the paragraph wraps to it.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HighlightDemoView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 560, height: proposal.height ?? 148)
    }

    func updateNSView(_ view: HighlightDemoView, context: Context) {
        view.style = style
        view.dark = dark
        view.speed = speed
    }
}

/// Plays a short paragraph with real word timings, drawn by the same
/// `HighlightLayers` as the overlay, so what you pick is what you'll see.
@MainActor
final class HighlightDemoView: NSView {
    /// Recorded with `Unread --words` (af_heart, 1×): when each word starts, and the sentence's length, in seconds.
    private static let sentences: [(text: String, starts: [Double], end: Double)] = [
        ("Reading should feel effortless, like someone beside you reading the page aloud.",
         [0.38, 0.78, 0.95, 1.23, 2.1, 2.3, 2.55, 2.98, 3.17, 3.48, 3.6, 3.95], 4.8),
        ("You point at a paragraph, hold the Control key, and listen while the highlight follows along.",
         [0.35, 0.5, 0.75, 0.82, 0.9, 1.77, 2.02, 2.12, 2.55, 3.12, 3.25, 3.58, 3.75, 3.88, 4.3, 4.6], 5.42),
        ("Every word is marked the moment it is spoken, so your eyes never lose their place.",
         [0.35, 0.68, 0.95, 1.1, 1.35, 1.48, 1.75, 1.85, 1.98, 2.88, 3.05, 3.25, 3.7, 4.03, 4.28, 4.45], 5.25),
    ]

    /// For off-screen snapshots: draw this moment instead of playing.
    static var fixedTime: Double?

    var style = HighlightStyle.standard { didSet { if style != oldValue { redraw() } } }
    var dark = false { didSet { if dark != oldValue { applyPage() } } }
    var speed = 1.3 { didSet { if speed != oldValue { restart() } } }

    private let textView = NSTextView()
    private let overlayView = NSView()
    private var layers: HighlightLayers!
    private var ticker: DisplayTicker?
    /// The demo's clock: seconds since it was created. The highlight only
    /// ever sees this clock; a restart moves `origin`, not the clock.
    private let createdAt = CACurrentMediaTime()
    private var origin = 0.0
    private var lastTime = 0.0
    /// Character ranges of each sentence's words.
    private var wordRanges: [[NSRange]] = []
    private var boxCache: [Int: [CGRect?]] = [:]
    private var shownSentence: Int?
    /// Redraw the sentence in place (new style, new layout).
    private var restyled = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 580, height: 148))
        wantsLayer = true
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        let text = NSMutableString()
        for s in Self.sentences {
            var ranges: [NSRange] = []
            for word in s.text.split(separator: " ") {
                if text.length > 0 { text.append(" ") }
                ranges.append(NSRange(location: text.length, length: (String(word) as NSString).length))
                text.append(String(word))
            }
            wordRanges.append(ranges)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        textView.textStorage?.setAttributedString(NSAttributedString(string: text as String, attributes: [
            .font: NSFont.systemFont(ofSize: 15), .paragraphStyle: paragraph,
        ]))
        addSubview(textView)
        overlayView.wantsLayer = true
        addSubview(overlayView)
        layers = HighlightLayers(in: overlayView.layer!)
        ticker = DisplayTicker(view: self) { [weak self] t in
            guard let self, self.window != nil else { self?.ticker?.stop(); return }
            self.render(at: t - self.createdAt)
        }
        applyPage()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func layout() {
        super.layout()
        textView.frame = bounds.insetBy(dx: 22, dy: 18)
        overlayView.frame = bounds
        boxCache = [:]
        redraw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, Self.fixedTime == nil { ticker?.start() } else { ticker?.stop() }
        redraw()
    }

    private func applyPage() {
        layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(red: 0.984, green: 0.98, blue: 0.969, alpha: 1)).cgColor
        textView.textColor = dark ? NSColor(white: 0.91, alpha: 1) : NSColor(white: 0.11, alpha: 1)
        // System colors (the highlight's yellow…) resolve differently on a dark page.
        overlayView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        redraw()
    }

    private func restart() {
        origin = lastTime
        layers.hide(at: lastTime)
        shownSentence = nil
    }

    private func redraw() {
        restyled = true
        render(at: Self.fixedTime ?? lastTime)
    }

    /// The word boxes of a sentence, in the overlay layer's coordinates.
    private func boxes(_ sentence: Int) -> [CGRect?] {
        if let cached = boxCache[sentence] { return cached }
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return [] }
        lm.ensureLayout(for: tc)
        let origin = textView.textContainerOrigin
        let boxes: [CGRect?] = wordRanges[sentence].map { range in
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var r = lm.boundingRect(forGlyphRange: glyphs, in: tc).offsetBy(dx: origin.x, dy: origin.y)
            // The line fragment includes the paragraph's line spacing; keep the glyphs' height.
            r.size.height -= 5
            return textView.convert(r, to: overlayView)
        }
        boxCache[sentence] = boxes
        return boxes
    }

    /// Draw the demo at `t` seconds on its clock: the sentences back to back
    /// with Unread's 120 ms pause, a rest, and again. Every event is placed at
    /// the time it happens in the script, so any instant draws the same.
    func render(at t: Double) {
        lastTime = t
        let lengths = Self.sentences.map { $0.end / speed + 0.12 }
        let period = lengths.reduce(0, +) + 1.2
        let loop = Int(max(0, t - origin) / period)
        var start = origin + Double(loop) * period
        var index = 0
        while index < lengths.count, t >= start + lengths[index] { start += lengths[index]; index += 1 }
        let id = loop * 100 + index
        overlayView.effectiveAppearance.performAsCurrentDrawingAppearance {
            if index == lengths.count {
                if shownSentence != nil { layers.hide(at: start); shownSentence = nil }
            } else {
                let words = boxes(index)
                if shownSentence != id || restyled {
                    let lines = WebDocument.groupIntoLines(words.compactMap { $0 })
                    layers.showSentence(lines, kind: .reading, style: style, id: id, at: start)
                    shownSentence = id
                }
                let starts = Self.sentences[index].starts.map { Int?(Int($0 / speed * 24_000)) }
                let entry = index > 0 ? boxes(index - 1).compactMap { $0 }.last : nil
                let mark = WordMark.frame(style, starts: starts, boxes: words, at: Int((t - start) * 24_000), entry: entry)
                layers.showWord(mark, style: style, at: start)
            }
            restyled = false
            layers.render(at: t)
        }
    }
}
