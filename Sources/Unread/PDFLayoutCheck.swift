import CoreGraphics

/// `--pdf-check` (scripts/test.sh): `PDFLayout` read from tables of pages, against what a listener should hear.
extension PDFLayout {
    struct Check {
        let name: String
        let pages: [[PDFBlock]]
        /// Pointed at this block (page, index) instead of read from the start.
        var pointed: (Int, Int)? = nil
        let said: [String]
    }

    /// A block as PDFium gives it: lines joined by "\r\n"; a line ending in "~" is a line-end hyphen (U+0002),
    /// with no line end after it. 14 points a line, from `y`.
    static func block(_ lines: [String], x: CGFloat = 72, y: CGFloat, width: CGFloat = 468, font: CGFloat? = nil, heading: Bool = false) -> PDFBlock {
        var raw = ""
        for line in lines { raw += line.hasSuffix("~") ? line.dropLast() + "\u{02}" : line + "\r\n" }
        return PDFBlock(raw: raw, bounds: CGRect(x: x, y: y, width: width, height: CGFloat(lines.count) * 14), headingRole: heading, fontSize: font)
    }

    static let checks: [Check] = [
        Check(name: "one column: a paragraph's first lines at a page's foot, carried on the next page", pages: [
            [block(["Background"], y: 72, width: 80),
             block(["The committee met on a cold morning to review the budget of the town.",
                    "Every member had brought a stack of notes from the previous year, and",
                    "the meeting ran late."], y: 100),
             block(["They argued at length about the cost of repairing the old bridge, which",
                    "had been closed to heavy traffic since the spring floods, and they"], y: 700),
             block(["iv"], x: 300, y: 760, width: 12)],
            [block(["agreed to pay for it over three years.", "The work starts in May."], y: 72),
             block(["Civil engineering"], y: 120, width: 110),
             block(["The bridge will reopen in the autumn, once the new deck is laid and the",
                    "railings are painted, and the council will hold a small ceremony to",
                    "mark the day."], y: 150),
             block(["Proceedings of the Town Council, 2026"], x: 200, y: 740, width: 200),
             block(["v"], x: 300, y: 760, width: 12)],
        ], said: [
            "Background",
            "The committee met on a cold morning to review the budget of the town.",
            "Every member had brought a stack of notes from the previous year, and the meeting ran late.",
            "They argued at length about the cost of repairing the old bridge, which had been closed to heavy traffic since the spring floods, and they agreed to pay for it over three years.",
            "The work starts in May.",
            "Civil engineering",
            "The bridge will reopen in the autumn, once the new deck is laid and the railings are painted, and the council will hold a small ceremony to mark the day.",
        ]),
        Check(name: "footers: below a paragraph the next page carries on", pages: [
            [block(["A paper is read in the order a person would read it."], y: 72),
             block(["Sentences are cut where a period ends them, not where a line ends.", "When a page ends in the middle of a sentence,",
                    "the walk carries the sen-"], y: 600),
             block(["Proceedings of the Workshop on Reading Aloud, pages 17–18"], x: 180, y: 740, width: 250),
             block(["17"], x: 300, y: 760, width: 12)],
            [block(["Listening to Documents"], x: 250, y: 40, width: 110),
             block(["tence across the break and leaves the page number out.", "Then it reads on."], y: 72)],
            [block(["Listening to Documents"], x: 250, y: 40, width: 110),
             block(["The end."], y: 72)],
        ], said: [
            "A paper is read in the order a person would read it.",
            "Sentences are cut where a period ends them, not where a line ends.",
            "When a page ends in the middle of a sentence, the walk carries the sentence across the break and leaves the page number out.",
            "Then it reads on.",
            "The end.",
        ]),
        Check(name: "page feet: a heading, a short last paragraph and an indented first line are text; a footer isn't", pages: [
            [block(["The survey asked every household how often it used the library, and almost",
                    "half of them answered that they came at least once a month, more than in",
                    "any year before."], y: 72),
             block(["The answers were sorted by street and by the age of the person who wrote",
                    "them, and the clerks read every comment that came with them, one by one,",
                    "over the winter."], y: 200),
             block(["Methods"], y: 700, width: 60),
             block(["1"], x: 300, y: 760, width: 10)],
            [block(["Each answer was entered twice, by two clerks working apart, and the two",
                    "copies were compared at the end of each week to find the mistakes in",
                    "either one."], y: 72),
             block(["The rest was simple."], y: 680, width: 120),
             block(["The last part of the survey asked what the"], x: 82, y: 700, width: 300),
             block(["Proceedings of the Town Council, 2026"], x: 200, y: 740, width: 200),
             block(["2"], x: 300, y: 760, width: 10)],
            [block(["library should buy next, and most asked for more maps."], y: 72)],
        ], said: [
            "The survey asked every household how often it used the library, and almost half of them answered that they came at least once a month, more than in any year before.",
            "The answers were sorted by street and by the age of the person who wrote them, and the clerks read every comment that came with them, one by one, over the winter.",
            "Methods",
            "Each answer was entered twice, by two clerks working apart, and the two copies were compared at the end of each week to find the mistakes in either one.",
            "The rest was simple.",
            "The last part of the survey asked what the library should buy next, and most asked for more maps.",
        ]),
        Check(name: "page feet in exact fonts: a footer on the paragraphs' margin is smaller than them; a heading isn't", pages: [
            [block(["The model was trained on eight machines for twelve hours, and each step took",
                    "about four tenths of a second, which is less than any model before it took",
                    "on the same machines."], y: 72, font: 10),
             block(["We used the same schedule for every run, raising the rate for the first four",
                    "thousand steps and lowering it after that, in proportion to the step's root."], y: 120, font: 10),
             block(["5.4 Regularization"], y: 690, width: 100, font: 10),
             block(["We employ three types of regularization during training:"], y: 705, width: 300, font: 10),
             block(["31st Conference on Neural Information Processing Systems (NIPS 2017), Long Beach, CA, USA."], y: 740, font: 9),
             block(["5"], x: 300, y: 760, width: 10, font: 10)],
            [block(["Residual dropout is applied to the output of each layer, before it is added."], y: 72, font: 10)],
        ], said: [
            "The model was trained on eight machines for twelve hours, and each step took about four tenths of a second, which is less than any model before it took on the same machines.",
            "We used the same schedule for every run, raising the rate for the first four thousand steps and lowering it after that, in proportion to the step's root.",
            "5.4 Regularization",
            "We employ three types of regularization during training:",
            "Residual dropout is applied to the output of each layer, before it is added.",
        ]),
        Check(name: "running headers: one in the group under it, and a carried-over end that repeats", pages: [
            [block(["The bridge was closed for a month while the deck was replaced, and the",
                    "road over it was closed to heavy"], y: 72),
             block(["3"], x: 300, y: 760, width: 10)],
            [block(["A Report on the Town Archive", "traffic since the spring floods. The clerks believe that"], y: 40),
             block(["4"], x: 300, y: 760, width: 10)],
            [block(["A Report on the Town Archive"], x: 230, y: 40, width: 150),
             block(["the archive should keep both, and the road over the river was closed to heavy"], y: 72),
             block(["5"], x: 300, y: 760, width: 10)],
            [block(["traffic since the spring floods."], y: 72)],
        ], said: [
            "The bridge was closed for a month while the deck was replaced, and the road over it was closed to heavy traffic since the spring floods.",
            "The clerks believe that the archive should keep both, and the road over the river was closed to heavy traffic since the spring floods.",
        ]),
        Check(name: "slides: a title and bullets without periods", pages: [
            [block(["Quarterly review", "• Revenue grew in every region", "   across the whole year", "• Hiring slowed", "• Short bullet here"], y: 60, width: 600),
             block(["1"], x: 380, y: 560, width: 10)],
            [block(["What comes next", "• Open the second office", "• Hire twelve people"], y: 60, width: 600)],
        ], said: [
            "Quarterly review",
            "Revenue grew in every region across the whole year",
            "Hiring slowed",
            "Short bullet here",
            "What comes next",
            "Open the second office",
            "Hire twelve people",
        ]),
        Check(name: "legal: a paragraph that starts with a section sign", pages: [
            [block(["The council adopts the following rules for its public meetings.",
                    "They apply from the first of January."], y: 72),
             block(["§ 3. Every resident may attend the public meeting and speak for three",
                    "minutes on any topic on the agenda."], y: 110),
             block(["§ 4. The minutes are published within a week."], y: 150),
             block(["Meetings are held in the town hall."], y: 180)],
        ], said: [
            "The council adopts the following rules for its public meetings.",
            "They apply from the first of January.",
            "§ 3. Every resident may attend the public meeting and speak for three minutes on any topic on the agenda.",
            "§ 4. The minutes are published within a week.",
            "Meetings are held in the town hall.",
        ]),
        Check(name: "legal: a run of sections with a section sign down to the page's foot, then a real footnote", pages: [
            (1...8).map { section($0, y: CGFloat(72 + 90 * ($0 - 1))) } + [block(["1"], x: 300, y: 790, width: 10)],
            [section(9, y: 72),
             block(["* Members who joined before the spring keep the plot they hold, whatever its size."], y: 162),
             block(["4GB of photographs of the garden are kept by the secretary, one for every plot."], y: 182),
             block(["1The gate house is open on Saturdays from nine until noon."], y: 730),
             block(["2"], x: 300, y: 790, width: 10)],
        ], said: (1...9).flatMap { sectionSaid($0) } + [
            "* Members who joined before the spring keep the plot they hold, whatever its size.",
            "4GB of photographs of the garden are kept by the secretary, one for every plot.",
        ]),
        Check(name: "running headers that alternate the book's title and the chapter's", pages: [
            [block(["Chapter Two: The River Crossing"], x: 230, y: 60, width: 150),
             block(["The ferry had stopped running in the spring, when the water rose over the",
                    "landing, so the family walked to the ford and waited there for the"], y: 100),
             block(["1"], x: 300, y: 760, width: 10)],
            [block(["The Long Road Home", "light to change. Mara counted the stones in the shallows while her brother"], y: 40),
             block(["2"], x: 300, y: 760, width: 10)],
            [block(["Chapter Two: The River Crossing", "tied the bundles tighter. They had left the farm four days before, and the"], y: 40),
             block(["3"], x: 300, y: 760, width: 10)],
            [block(["The Long Road Home", "cart had lost a wheel on the second morning."], y: 40),
             block(["4"], x: 300, y: 760, width: 10)],
        ], said: [
            "Chapter Two: The River Crossing",
            "The ferry had stopped running in the spring, when the water rose over the landing, so the family walked to the ford and waited there for the light to change.",
            "Mara counted the stones in the shallows while her brother tied the bundles tighter.",
            "They had left the farm four days before, and the cart had lost a wheel on the second morning.",
        ]),
        Check(name: "footnotes: a real one below the text, and paragraphs that open like one", pages: [
            [block(["The archive grew again this year, as it has every year since it opened.1",
                    "It now fills the whole basement, and the boxes that came last are",
                    "kept in the hall."], y: 72, font: 10),
             block(["4GB of storage was purchased for the archive, which now holds every",
                    "record the town has kept."], y: 110, font: 10),
             block(["2FA protects the archive's accounts, and every clerk has a key."], y: 150, font: 10),
             block(["1Password keeps the keys, and the clerk changes them each spring."], y: 680, font: 10),
             block(["1The archive is in the old town hall, under the council chamber."], y: 730, font: 8)],
        ], said: [
            "The archive grew again this year, as it has every year since it opened.",
            "It now fills the whole basement, and the boxes that came last are kept in the hall.",
            "4GB of storage was purchased for the archive, which now holds every record the town has kept.",
            "2FA protects the archive's accounts, and every clerk has a key.",
            "1Password keeps the keys, and the clerk changes them each spring.",
        ]),
        Check(name: "footnotes in fonts that can't be trusted: below the text, in the page's lower half", pages: [
            [block(["The archive grew again this year, as it has every year since it opened.1"], y: 72),
             block(["4GB of storage was purchased for the archive, which now holds every",
                    "record the town has kept."], y: 110),
             block(["2FA protects the archive's accounts, and every clerk has a key."], y: 150),
             block(["1The archive is in the old town hall, under the council chamber."], y: 730)],
        ], said: [
            "The archive grew again this year, as it has every year since it opened.",
            "4GB of storage was purchased for the archive, which now holds every record the town has kept.",
            "2FA protects the archive's accounts, and every clerk has a key.",
        ]),
        Check(name: "figures: a heading above a picture, and a figure's labels", pages: [
            [block(["Spending rose in every department but one."], y: 72),
             block(["Results"], y: 100, width: 50),
             block(["Figure 1: Spending by department over the last five years."], y: 300),
             block(["Roads took the largest share of the money."], y: 330),
             block(["Page Tree"], x: 140, y: 400, width: 200),
             block(["Voice"], x: 160, y: 430, width: 40),
             block(["Figure 2: From the page to the voice."], y: 470),
             block(["Each step is described below."], y: 500)],
        ], said: [
            "Spending rose in every department but one.",
            "Results",
            "♪ figure",
            "Figure 1: Spending by department over the last five years.",
            "Roads took the largest share of the money.",
            "♪ figure",
            "Figure 2: From the page to the voice.",
            "Each step is described below.",
        ]),
        Check(name: "continuations: a chain of nine blocks", pages: [opening, chain], said: [
            "The chain is on the second page.",
            "Part 1 goes on and on part 2 goes on and on part 3 goes on and on part 4 goes on and on part 5 goes on and on part 6 goes on and on part 7 goes on and on part 8 goes on and on",
            "part 9 goes on and on to the end.",
            "Then a new paragraph starts.",
        ]),
        Check(name: "continuations: pointed at the ninth block of a chain", pages: [opening, chain], pointed: (1, 8), said: [
            "part 9 goes on and on to the end.",
            "Then a new paragraph starts.",
        ]),
        Check(name: "hyphens: joined unless both halves are words, in English and German", pages: [
            [block(["It needs no task~", "specific setup, and it reads the para~", "graph under the pointer, as Col~",
                    "lobert and Weston did."], y: 72),
             block(["Die Verwal~", "tung der Stadt hat be~", "schlossen, das alte Rathaus im nächsten Jahr zu reno~",
                    "vieren und die Brücke zu erneuern."], y: 130)],
        ], said: [
            "It needs no task-specific setup, and it reads the paragraph under the pointer, as Collobert and Weston did.",
            "Die Verwaltung der Stadt hat beschlossen, das alte Rathaus im nächsten Jahr zu renovieren und die Brücke zu erneuern.",
        ]),
        Check(name: "footnote markers: after a word or a quote, not in a section number", pages: [
            [block(["The method is set out in Appendix A.1", "for the details of each step."], y: 72),
             block(["The first figure was drawn by hand.2", "The rest were drawn by the tool."], y: 110),
             block(["We refer readers to guides such as “The Annotated Transformer.”3", "Each one is short."], y: 150),
             block(["Earlier readers encoded the pairs first, as in Parikh et al.", "(2016). The tool reads them as one."], y: 190)],
        ], said: [
            "The method is set out in Appendix A.1 for the details of each step.",
            "The first figure was drawn by hand.",
            "The rest were drawn by the tool.",
            "We refer readers to guides such as “The Annotated Transformer.”",
            "Each one is short.",
            "Earlier readers encoded the pairs first, as in Parikh et al. (2016).",
            "The tool reads them as one.",
        ]),
    ]

    /// Six lines of a bylaw, "§ n." and two sentences.
    private static func section(_ n: Int, y: CGFloat) -> PDFBlock {
        block(["§ \(n). The members shall keep the paths of the garden clear, and every plot",
               "holder shall cut the hedge along the side of the plot before the end of",
               "the month in which the board asks for it. A holder who cannot do the work",
               "may ask a neighbour to do it, or may pay the association to have it done",
               "by the gardener, at the rate the board sets each spring for the work of",
               "one hour, and the board shall write the payment in the accounts."], y: y)
    }
    private static func sectionSaid(_ n: Int) -> [String] {
        ["§ \(n). The members shall keep the paths of the garden clear, and every plot holder shall cut the hedge along the side of the plot before the end of the month in which the board asks for it.",
         "A holder who cannot do the work may ask a neighbour to do it, or may pay the association to have it done by the gardener, at the rate the board sets each spring for the work of one hour, and the board shall write the payment in the accounts."]
    }

    private static let opening = [block(["The chain is on the second page."], y: 72)]
    private static let chain: [PDFBlock] = {
        var blocks: [PDFBlock] = []
        for i in 1...9 {
            let first = i == 1 ? "Part 1 goes on" : "part \(i) goes on"
            let second = i == 9 ? "and on to the end." : "and on"
            blocks.append(block([first, second], y: CGFloat(60 + 40 * i)))
        }
        return blocks + [block(["Then a new paragraph starts."], y: 480)]
    }()

    /// What a reading gives, one line each: a sentence's text, or "♪ figure" for a cue.
    func walk(from start: PDFPosition?, limit: Int = 200) -> [String] {
        var out: [String] = [], pos = start
        while let p = pos, out.count < limit, let r = read(from: p).reading {
            switch r {
            case .sentence(let text, _, let next): out.append(text); pos = next
            case .cue(let what, _, let next): out.append("♪ \(what)"); pos = next
            }
        }
        return out
    }

    /// Every check passes. Prints the ones that don't.
    static func check() -> Bool {
        var ok = true
        for c in checks {
            let layout = PDFLayout(pageCount: { (c.pages.count, true) }, page: { $0 < c.pages.count ? c.pages[$0] : nil })
            let from = c.pointed.map { PDFPosition(BlockID(page: $0.0, index: $0.1), walked: false) } ?? layout.start()
            let said = layout.walk(from: from)
            guard said != c.said else { continue }
            ok = false
            print("pdf: \(c.name)")
            for i in 0..<max(said.count, c.said.count) {
                let got = i < said.count ? said[i] : "(nothing)", want = i < c.said.count ? c.said[i] : "(nothing)"
                print(got == want ? "   = \(got)" : "   said     \(got.debugDescription)\n   expected \(want.debugDescription)")
            }
        }
        print(ok ? "pdf: \(checks.count) checks pass" : "pdf: FAILED")
        return ok
    }
}
