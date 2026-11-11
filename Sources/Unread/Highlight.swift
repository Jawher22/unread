import AppKit
import Combine
import QuartzCore

// MARK: - Style (user settings)

/// How the read-along highlight looks and moves. Chosen in Settings, with a
/// live demo drawn by the same renderer as the real overlay.
struct HighlightStyle: Codable, Equatable {
    enum Mark: String, Codable, CaseIterable { case fill, underline, outline, tail, none }
    enum Motion: String, Codable, CaseIterable {
        case hop, glide, stretch, flow, sweep

        /// Styles saved before the motions were reworked.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Motion(rawValue: raw) ?? (raw == "continuous" ? .flow : .glide)
        }
    }
    enum Strength: String, Codable, CaseIterable { case subtle, medium, strong }
    enum Sentence: String, Codable, CaseIterable { case box, soft, off }
    enum Tint: String, Codable, CaseIterable { case yellow, blue, green, pink }
    enum Lead: Int, Codable, CaseIterable { case none = 0, short = 50, medium = 100, long = 150 }

    var mark = Mark.fill
    var motion = Motion.glide
    var strength = Strength.medium
    var sentence = Sentence.box
    var tint = Tint.yellow
    /// Move the mark this much before the word is heard. Word starts are off by ~50 ms (median; p95
    /// 129), and a mark that lags the voice is noticed from 45 ms, one that leads only from 125 ms
    /// (ITU BT.1359): 100 ms keeps almost every word from showing late. Whether it shows too many
    /// early is open (docs/design.md §9).
    var lead = Lead.medium

    static let standard = HighlightStyle()

    var wordAlpha: CGFloat { switch strength { case .subtle: 0.25; case .medium: 0.38; case .strong: 0.55 } }
    var sentenceAlpha: CGFloat { switch sentence { case .box: 0.22; case .soft: 0.12; case .off: 0 } }
    /// How many words the mark covers: the current one, plus a fading trail.
    var markedWords: Int { switch mark { case .tail: 3; case .none: 0; default: 1 } }

    func color(_ alpha: CGFloat) -> NSColor {
        let base: NSColor = switch tint {
        case .yellow: .systemYellow
        case .blue: .systemBlue
        case .green: .systemGreen
        case .pink: .systemPink
        }
        // Yellow is far lighter than the others: at the same alpha, blue and
        // pink would look twice as heavy. Even them out.
        let weight: CGFloat = switch tint { case .yellow: 1; case .green: 0.8; case .blue, .pink: 0.7 }
        return base.withAlphaComponent(min(1, alpha * weight))
    }

    // Labels for Settings.
    static func label(_ m: Mark) -> String { switch m { case .fill: "Fill"; case .underline: "Underline"; case .outline: "Outline"; case .tail: "Trail"; case .none: "None" } }
    static func label(_ m: Motion) -> String { switch m { case .hop: "Hop"; case .glide: "Glide"; case .stretch: "Stretch"; case .flow: "Flow"; case .sweep: "Sweep" } }
    static func label(_ s: Strength) -> String { switch s { case .subtle: "Subtle"; case .medium: "Medium"; case .strong: "Strong" } }
    static func label(_ s: Sentence) -> String { switch s { case .box: "Box"; case .soft: "Soft"; case .off: "Off" } }
    static func label(_ t: Tint) -> String { switch t { case .yellow: "Yellow"; case .blue: "Blue"; case .green: "Green"; case .pink: "Pink" } }
    static func label(_ l: Lead) -> String { l == .none ? "None" : "\(l.rawValue) ms" }
}

/// The saved style. Changes apply to the overlay from the next frame.
@MainActor
final class HighlightSettings: ObservableObject {
    static let shared = HighlightSettings()
    private static let key = "highlightStyle"

    @Published var style: HighlightStyle {
        didSet {
            guard style != oldValue, let data = try? JSONEncoder().encode(style) else { return }
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        style = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(HighlightStyle.self, from: $0) } ?? .standard
        // The lead was none by default until it became 100 ms, so a saved none is the old default, not a
        // choice. Moved once: a none chosen since stays.
        if !defaults.bool(forKey: Self.leadMoved) {
            if style.lead == .none, defaults.data(forKey: Self.key) != nil {
                style.lead = HighlightStyle.standard.lead
                defaults.set(try? JSONEncoder().encode(style), forKey: Self.key) // didSet doesn't run in init
            }
            defaults.set(true, forKey: Self.leadMoved)
        }
    }
    private static let leadMoved = "highlightLeadMoved"
}

// MARK: - Easing and timing

/// Easing curves, 0…1 → 0…1.
enum Ease {
    static func clamp(_ x: Double) -> Double { x.isNaN ? 1 : min(1, max(0, x)) }

    /// A CSS-style cubic Bézier timing curve.
    static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        let x = clamp(x)
        guard x > 0, x < 1 else { return x }
        func at(_ a: Double, _ b: Double, _ s: Double) -> Double { let u = 1 - s; return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s }
        func slope(_ a: Double, _ b: Double, _ s: Double) -> Double { let u = 1 - s; return 3 * u * u * a + 6 * u * s * (b - a) + 3 * s * s * (1 - b) }
        var s = x
        for _ in 0..<10 {
            let dx = at(x1, x2, s) - x
            if abs(dx) < 1e-6 { break }
            let d = slope(x1, x2, s)
            guard abs(d) > 1e-6 else { break }
            s = clamp(s - dx / d)
        }
        return at(y1, y2, s)
    }

    /// Word glides: leaves briskly, lands softly.
    static func glide(_ x: Double) -> Double { bezier(0.3, 0, 0.15, 1, x) }
    static func out(_ x: Double) -> Double { let x = clamp(x); return 1 - pow(1 - x, 3) }
    static func inOut(_ x: Double) -> Double { let x = clamp(x); return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
}

/// The voice's position for one display frame. The player reports it in
/// steps (once per audio render cycle, ~10 ms) and as of now; this projects
/// it to when the frame will be seen and smooths the steps away, so motion
/// tied to it doesn't judder.
struct AudioClock {
    private var anchor: (time: CFTimeInterval, sample: Double)?

    mutating func position(_ raw: Int?, at frameTime: CFTimeInterval, now: CFTimeInterval = CACurrentMediaTime()) -> Int? {
        guard let raw else { anchor = nil; return nil } // paused or stopped
        let measured = Double(raw) + (frameTime - now) * 24_000
        guard let a = anchor else { anchor = (frameTime, measured); return Int(measured) }
        let predicted = a.sample + max(0, frameTime - a.time) * 24_000
        let error = measured - predicted
        // A jump (the player restarted): follow it. Otherwise ease toward the
        // reports, never backwards.
        let sample = abs(error) > 2_400 ? measured : max(a.sample, predicted + error * 0.1)
        anchor = (max(frameTime, a.time), sample)
        return Int(sample)
    }
}

// MARK: - Which word, where

/// One drawn word mark: the word's box (between two words while moving),
/// where a trail's fading tail starts, and how visible it is.
struct MarkShape: Equatable {
    var rect: CGRect
    var tail: CGFloat?
    var opacity: CGFloat = 1

    func mixed(with b: MarkShape, _ p: Double) -> MarkShape {
        let p = CGFloat(p)
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * p }
        return MarkShape(rect: CGRect(x: mix(rect.minX, b.rect.minX), y: mix(rect.minY, b.rect.minY),
                                      width: mix(rect.width, b.rect.width), height: mix(rect.height, b.rect.height)),
                         tail: tail.flatMap { t in b.tail.map { mix(t, $0) } }, opacity: mix(opacity, b.opacity))
    }

    func shifted(_ dx: CGFloat) -> MarkShape {
        var s = self
        s.rect = rect.offsetBy(dx: dx, dy: 0)
        s.tail = tail.map { $0 + dx }
        return s
    }
}

/// The word mark at one moment.
struct WordMarkFrame: Equatable {
    var head: MarkShape
    /// The mark leaving the end of a line while `head` arrives on the next.
    var ghost: MarkShape?
}

/// Where the word mark is at any moment: a pure function of the voice's
/// position, so it is exact on every frame, freezes when paused, and the
/// Settings demo can draw any instant.
///
/// - Hop: jumps as each word starts.
/// - Glide: slides to the next word, half way there as it's heard.
/// - Stretch: the front edge reaches for the next word, the back edge
///   follows, like an inchworm.
/// - Flow: always easing toward the next word, resting on each one just as
///   it's heard.
/// - Sweep: each word fills in from the left while it's spoken, karaoke-like;
///   the previous one fades.
///
/// Except Sweep, a move to a new line cross-fades with a small
/// carriage-return drift instead of sweeping back across the text.
enum WordMark {
    private enum Transition { case snap, glide(Double), stretch(Double), fade(Double), flow, sweep(Double) }

    /// `starts` and `boxes` are per display word (either may be nil).
    /// `entry`: where the previous sentence's mark ended, to come from.
    /// Any coordinate space with x growing to the right. Nil: no mark.
    static func frame(_ style: HighlightStyle, starts: [Int?], boxes: [WordBox?], at offset: Int, entry: CGRect? = nil) -> WordMarkFrame? {
        guard style.markedWords > 0 else { return nil }
        let t = Double(offset) / 24_000 + Double(style.lead.rawValue) / 1000
        // Knots: words with both a time and a box, in time order. A word set on two lines is a knot
        // per line, the second reached when the voice is through the first line's share of its
        // letters, by the time until the next word.
        var times: [Double] = [], rects: [CGRect] = []
        let count = min(starts.count, boxes.count)
        for i in 0..<count {
            guard let s = starts[i], let b = boxes[i] else { continue }
            let time = Double(s) / 24_000
            var next = time + 0.45
            for j in i + 1..<count { if let n = starts[j], n > s { next = Double(n) / 24_000; break } }
            let letters = b.parts.reduce(0) { $0 + $1.letters }
            var said = 0
            for part in b.parts {
                defer { said += part.letters }
                let at = time + (next - time) * Double(said) / Double(max(1, letters))
                guard !part.rect.isEmpty else { continue }
                if let last = times.last, at <= last { continue }
                times.append(at)
                rects.append(part.rect)
            }
        }
        guard let first = times.first else { return nil }
        let hasEntry = entry != nil
        if let entry { times.insert(first - 10, at: 0); rects.insert(entry, at: 0) }
        let n = times.count

        // Each knot's line: it continues the line if it sits beside the previous word, to its right.
        var lineStart = [Int](repeating: 0, count: n)
        for k in 1..<max(1, n) {
            let a = rects[k - 1], b = rects[k]
            lineStart[k] = sameLine(a, b) && b.minX >= a.minX - 2 ? lineStart[k - 1] : k
        }
        /// How long the word at `k` is heard for, roughly: until the next one.
        func spoken(_ k: Int) -> Double { k + 1 < n ? times[k + 1] - times[k] : 0.45 }
        func transition(_ k: Int) -> Transition {
            let sameLine = lineStart[k] == lineStart[k - 1]
            switch style.motion {
            case .hop: return .snap
            case .sweep: return .sweep(min(0.55, 0.85 * spoken(k)))
            case .glide: return sameLine ? .glide(0.24) : .fade(0.2)
            case .stretch: return sameLine ? .stretch(0.32) : .fade(0.2)
            case .flow: return !sameLine ? .fade(0.2) : (hasEntry && k == 1 ? .glide(0.24) : .flow)
            }
        }
        /// Where the word's start falls within a move: glides are part way
        /// there as it's heard; flow arrives exactly on time.
        let onset = style.motion == .flow ? 1.0 : 0.4
        func window(_ k: Int) -> (start: Double, end: Double) {
            switch transition(k) {
            case .snap: return (times[k], times[k])
            case .flow: return (times[k - 1], times[k])
            case .sweep(let d): return (times[k], times[k] + d)
            case .glide(let d), .stretch(let d), .fade(let d):
                // Never overlap the neighbouring moves, however fast the voice.
                let after = k + 1 < n ? times[k + 1] - times[k] : .infinity
                let d = min(d, 0.9 * (times[k] - times[k - 1]), 0.9 * after)
                return (times[k] - onset * d, times[k] + (1 - onset) * d)
            }
        }
        let trail = style.markedWords - 1
        func shape(_ k: Int) -> MarkShape {
            MarkShape(rect: rects[k], tail: trail > 0 ? rects[max(lineStart[k], k - trail)].minX : nil)
        }
        /// The word filled in from its left edge up to `p`.
        func revealed(_ s: MarkShape, _ p: Double) -> MarkShape {
            var s = s
            s.rect.size.width = max(min(s.rect.width, s.rect.height * 0.4), s.rect.width * CGFloat(p))
            return s
        }

        // The latest move that has begun; before any, the first knot.
        var k = n - 1
        while k >= 1, window(k).start > t { k -= 1 }
        guard k > 0 else {
            var head = shape(0)
            guard !hasEntry else { return WordMarkFrame(head: head) }
            if style.motion == .sweep {
                let p = (t - times[0]) / min(0.55, 0.85 * spoken(0))
                guard p >= 0 else { return nil }
                return WordMarkFrame(head: revealed(head, Ease.out(p)))
            }
            // The first word fades in as it's heard.
            let appear = 0.14
            head.opacity = Ease.out((t - (times[0] - onset * appear)) / appear)
            guard head.opacity > 0 else { return nil }
            return WordMarkFrame(head: head)
        }
        let (start, end) = window(k)
        let u = end > start ? Ease.clamp((t - start) / (end - start)) : 1
        let from = shape(k - 1), to = shape(k)
        switch transition(k) {
        case .snap:
            return WordMarkFrame(head: to)
        case .glide:
            return WordMarkFrame(head: from.mixed(with: to, Ease.glide(u)))
        case .flow:
            return WordMarkFrame(head: from.mixed(with: to, u * u * (3 - 2 * u)))
        case .stretch:
            // Front edge first, back edge after it.
            let front = Ease.glide(u / 0.62), back = Ease.glide((u - 0.32) / 0.68)
            var head = from.mixed(with: to, (front + back) / 2)
            let minX = from.rect.minX + (to.rect.minX - from.rect.minX) * CGFloat(back)
            let maxX = from.rect.maxX + (to.rect.maxX - from.rect.maxX) * CGFloat(front)
            head.rect.origin.x = minX
            head.rect.size.width = max(1, maxX - minX)
            head.tail = from.tail.flatMap { a in to.tail.map { a + ($0 - a) * CGFloat(back) } }
            return WordMarkFrame(head: head)
        case .sweep:
            var ghost: MarkShape?
            if trail == 0 { // a trail already holds the words behind; a single mark lets go of the last one
                ghost = from
                ghost?.opacity = 1 - Ease.out(u / 0.7)
                if ghost!.opacity <= 0 { ghost = nil }
            }
            return WordMarkFrame(head: revealed(to, 1 - (1 - u) * (1 - u)), ghost: ghost)
        case .fade:
            guard u < 1 else { return WordMarkFrame(head: to) }
            let q = Ease.inOut(u), drift: CGFloat = 6
            var head = to.shifted(-drift * CGFloat(1 - q)), ghost = from.shifted(drift * CGFloat(q))
            head.opacity = q
            ghost.opacity = 1 - q
            return WordMarkFrame(head: head, ghost: ghost)
        }
    }

    static func sameLine(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.midY - b.midY) < min(a.height, b.height) / 2 }
}

// MARK: - Drawing

/// Calls back once per display frame with when that frame will be shown.
@MainActor
final class DisplayTicker: NSObject {
    private var link: CADisplayLink?
    private weak var view: NSView?
    private let tick: (CFTimeInterval) -> Void

    init(view: NSView, tick: @escaping (CFTimeInterval) -> Void) {
        self.view = view
        self.tick = tick
    }

    var isRunning: Bool { link != nil }

    func start() {
        guard link == nil, let view else { return }
        let l = view.displayLink(target: self, selector: #selector(step))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ l: CADisplayLink) {
        guard view != nil else { stop(); return }
        tick(l.targetTimestamp)
    }
}

/// The highlight's layers inside one host layer: the sentence (or the
/// aiming preview) and the word mark. Used by every overlay panel and by
/// the demo in Settings, so the demo is exactly what reading looks like.
///
/// Nothing animates on its own: callers say what to show and when, and
/// `render(at:)` draws that moment. Rects are in the host layer's
/// coordinates; times are any one clock.
@MainActor
final class HighlightLayers {
    /// `loading`: the aimed paragraph from the hold's release until the voice starts, breathing.
    enum Kind { case preview, loading, reading }

    private enum Timing {
        static let wipe = 0.42, leave = 0.26, hide = 0.22, morph = 0.24, fadeIn = 0.16, wordIn = 0.14, wordOut = 0.2
        static let breath = 1.1
    }

    private let sentenceLayer = CAShapeLayer()
    private let leavingLayer = CAShapeLayer()
    private let wordGroup = CALayer()
    private let head = CAGradientLayer()
    private let ghost = CAGradientLayer()

    private enum Entrance { case wipe, fade, morph(from: [CGRect]) }
    private struct Sentence { var rects: [CGRect]; var kind: Kind; var id: Int?; var since: CFTimeInterval; var entrance: Entrance }
    private struct Leaving { var rects: [CGRect]; var kind: Kind; var opacity: Double; var since: CFTimeInterval; var retract: Bool }
    private var current: Sentence?
    private var leaving: Leaving?
    private var style = HighlightStyle.standard
    private var word: WordMarkFrame?
    private var wordFade = Fade()
    /// When the aimed paragraph started loading: its breath starts from the preview's look.
    private var loadingSince: CFTimeInterval = 0

    init(in host: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [leavingLayer, sentenceLayer] {
            l.fillRule = .nonZero // overlapping line boxes fill once, no darker seams
            l.opacity = 0
            host.addSublayer(l)
        }
        wordGroup.opacity = 0
        host.addSublayer(wordGroup)
        for l in [ghost, head] {
            l.startPoint = CGPoint(x: 0, y: 0.5)
            l.endPoint = CGPoint(x: 1, y: 0.5)
            l.opacity = 0
            wordGroup.addSublayer(l)
        }
        CATransaction.commit()
    }

    /// A sentence's line boxes (or the aimed paragraph), drawn as one shape.
    /// The same `id` again updates it in place (scrolling, restyling). A new
    /// sentence wipes in line by line, in reading order, while the old one
    /// retracts toward it; the aiming preview morphs from paragraph to paragraph.
    func showSentence(_ rects: [CGRect], kind: Kind, style: HighlightStyle, id: Int?, at now: CFTimeInterval) {
        self.style = style
        let boxes = rects.map { $0.insetBy(dx: -4, dy: -2) }
        guard !boxes.isEmpty, kind == .preview || style.sentenceAlpha > 0 else { hideSentence(at: now); return }
        if var c = current, c.kind == kind, let id, c.id == id {
            c.rects = boxes
            current = c
            return
        }
        // Shown again where it was just hidden (a hold's release hides the preview, then shows it loading): it stays, no blink.
        if current == nil, let l = leaving, !l.retract, l.kind != .reading, kind != .reading, l.rects == boxes {
            leaving = nil
            if kind == .loading, l.kind != .loading { loadingSince = now }
            current = Sentence(rects: boxes, kind: kind, id: id, since: now - Timing.fadeIn, entrance: .fade)
            return
        }
        if let c = current, c.kind != .reading, kind != .reading {
            if kind == .loading, c.kind != .loading { loadingSince = now }
            guard c.rects != boxes else { current?.kind = kind; return }
            current = Sentence(rects: boxes, kind: kind, id: id, since: now, entrance: .morph(from: displayed(c, at: now).rects))
            return
        }
        if let c = current {
            let shown = displayed(c, at: now)
            leaving = Leaving(rects: shown.rects, kind: c.kind, opacity: shown.opacity, since: now, retract: true)
        }
        current = Sentence(rects: boxes, kind: kind, id: id, since: now, entrance: kind == .reading ? .wipe : .fade)
    }

    /// The voice has started: the loading box goes, if it's still up.
    func hideLoading(at now: CFTimeInterval) {
        if current?.kind == .loading { hideSentence(at: now) }
    }

    func hideSentence(at now: CFTimeInterval) {
        guard let c = current else { return }
        let shown = displayed(c, at: now)
        leaving = Leaving(rects: shown.rects, kind: c.kind, opacity: shown.opacity, since: now, retract: false)
        current = nil
    }

    /// The word mark for this moment (nil: none right now). Fades in if it was hidden.
    func showWord(_ frame: WordMarkFrame?, style: HighlightStyle, at now: CFTimeInterval) {
        self.style = style
        word = frame
        wordFade.set(1, at: now, duration: Timing.wordIn)
    }

    func hideWord(at now: CFTimeInterval) { wordFade.set(0, at: now, duration: Timing.wordOut) }

    func hide(at now: CFTimeInterval) {
        hideSentence(at: now)
        hideWord(at: now)
    }

    /// Draw the moment `now`. Returns true while something is still in motion.
    @discardableResult
    func render(at now: CFTimeInterval) -> Bool {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var moving = false

        if let c = current {
            let shown = displayed(c, at: now)
            sentenceLayer.path = Self.path(shown.rects)
            paint(sentenceLayer, c.kind, at: now)
            sentenceLayer.opacity = Float(shown.opacity)
            moving = moving || now - c.since < duration(of: c.entrance) || (c.kind == .loading && breathes)
        } else {
            sentenceLayer.opacity = 0
        }
        if let l = leaving {
            let p = (now - l.since) / (l.retract ? Timing.leave : Timing.hide)
            if p >= 1 {
                leaving = nil
                leavingLayer.opacity = 0
            } else {
                let rects = l.retract ? Self.retracted(l.rects, Ease.inOut(p)) : l.rects
                leavingLayer.path = Self.path(rects)
                paint(leavingLayer, l.kind, at: now)
                leavingLayer.opacity = Float(l.opacity * (1 - (l.retract ? Ease.inOut(p) : Ease.out(p))))
                moving = true
            }
        }

        let fade = wordFade.value(at: now)
        moving = moving || !wordFade.done(at: now)
        wordGroup.opacity = Float(fade)
        draw(head, fade > 0 ? word?.head : nil)
        draw(ghost, fade > 0 ? word?.ghost : nil)
        return moving
    }

    // MARK: Sentence shapes

    private func duration(of e: Entrance) -> Double {
        switch e { case .wipe: Timing.wipe; case .fade: Timing.fadeIn; case .morph: Timing.morph }
    }

    private func displayed(_ c: Sentence, at now: CFTimeInterval) -> (rects: [CGRect], opacity: Double) {
        let p = (now - c.since) / duration(of: c.entrance)
        switch c.entrance {
        case .wipe: return (Self.wiped(c.rects, p), Ease.out(p * 4))
        case .fade: return (c.rects, Ease.out(p))
        case .morph(let from): return (Self.morphed(from, c.rects, Ease.out(p)), 1)
        }
    }

    /// Lines grow from their start, one after another, like reading.
    private static func wiped(_ rects: [CGRect], _ p: Double) -> [CGRect] {
        guard p < 1 else { return rects }
        let n = rects.count
        let stagger = n > 1 ? min(0.18, 0.5 / Double(n - 1)) : 0
        let span = 1 - stagger * Double(n - 1)
        return rects.enumerated().compactMap { i, r in
            let q = CGFloat(Ease.out((p - stagger * Double(i)) / span))
            return q <= 0 ? nil : CGRect(x: r.minX, y: r.minY, width: r.width * q, height: r.height)
        }
    }

    /// Lines shrink toward their end, where the next sentence picks up.
    private static func retracted(_ rects: [CGRect], _ p: Double) -> [CGRect] {
        let p = CGFloat(p)
        return rects.map { CGRect(x: $0.minX + $0.width * p, y: $0.minY, width: $0.width * (1 - p), height: $0.height) }
    }

    /// Box by box; the shorter list repeats its last box so counts match.
    private static func morphed(_ from: [CGRect], _ to: [CGRect], _ p: Double) -> [CGRect] {
        guard p < 1, !from.isEmpty, !to.isEmpty else { return to }
        let count = max(from.count, to.count)
        let a = from + Array(repeating: from.last!, count: count - from.count)
        let b = to + Array(repeating: to.last!, count: count - to.count)
        let p = CGFloat(p)
        return zip(a, b).map { a, b in
            CGRect(x: a.minX + (b.minX - a.minX) * p, y: a.minY + (b.minY - a.minY) * p,
                   width: a.width + (b.width - a.width) * p, height: a.height + (b.height - a.height) * p)
        }
    }

    private static func path(_ rects: [CGRect]) -> CGPath {
        let path = CGMutablePath()
        for r in rects where r.width > 0.5 && r.height > 0.5 {
            let corner = min(5, r.width / 2, r.height / 2)
            path.addRoundedRect(in: r, cornerWidth: corner, cornerHeight: corner)
        }
        return path
    }

    private var breathes: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func paint(_ layer: CAShapeLayer, _ kind: Kind, at now: CFTimeInterval) {
        switch kind {
        case .preview, .loading:
            // Loading breathes from the preview's look and back, so "it's coming" reads without a spinner.
            let b = kind == .loading && breathes ? 0.5 - 0.5 * cos(2 * .pi * (now - loadingSince) / Timing.breath) : 0
            let accent = NSColor.controlAccentColor
            layer.fillColor = accent.withAlphaComponent(0.08 + 0.14 * b).cgColor
            layer.strokeColor = accent.withAlphaComponent(0.55 + 0.3 * b).cgColor
            layer.lineWidth = 1.5
        case .reading:
            layer.fillColor = style.color(style.sentenceAlpha).cgColor
            layer.strokeColor = nil
            layer.lineWidth = 0
        }
    }

    // MARK: Word mark

    private func draw(_ layer: CAGradientLayer, _ shape: MarkShape?) {
        guard let shape, shape.opacity > 0.001, style.markedWords > 0 else { layer.opacity = 0; return }
        let r = shape.rect, alpha = style.wordAlpha
        var frame = r.insetBy(dx: -2.5, dy: -1)
        var colors: [CGFloat] = [1, 1], locations: [NSNumber]?
        var border: CGFloat = 0, fill = alpha
        switch style.mark {
        case .underline:
            frame = CGRect(x: r.minX, y: r.minY - 1.5, width: r.width, height: 2.5)
            fill = min(1, alpha * 2.2)
        case .outline:
            frame = r.insetBy(dx: -3, dy: -1.5)
            fill = alpha * 0.2
            border = 1.5
        case .tail:
            // One soft stroke: full on the word, fading out over the words just read.
            if let tail = shape.tail, tail < r.minX - 1 {
                let start = tail - 2.5
                frame = CGRect(x: start, y: frame.minY, width: frame.maxX - start, height: frame.height)
                let f = Double((r.minX - 2.5 - start) / frame.width)
                colors = [0, 0.16, 0.55, 1, 1]
                locations = [0, f * 0.45, f * 0.8, f, 1].map { NSNumber(value: $0) }
            }
        case .fill, .none:
            break
        }
        layer.opacity = Float(shape.opacity)
        layer.frame = frame
        layer.cornerRadius = min(frame.height / 2, 5)
        layer.colors = colors.map { style.color(fill * $0).cgColor }
        layer.locations = locations
        layer.borderWidth = border
        layer.borderColor = border > 0 ? style.color(min(1, alpha * 2)).cgColor : nil
    }
}

/// A value easing toward a target from the moment it was set.
private struct Fade {
    private var from = 0.0, to = 0.0, since: CFTimeInterval = 0, duration = 0.0

    func value(at now: CFTimeInterval) -> Double {
        duration <= 0 ? to : from + (to - from) * Ease.out((now - since) / duration)
    }

    func done(at now: CFTimeInterval) -> Bool { now - since >= duration }

    mutating func set(_ target: Double, at now: CFTimeInterval, duration: Double) {
        guard target != to else { return }
        from = value(at: now)
        to = target
        since = now
        self.duration = duration
    }
}
