// Typesets a PDF fixture from a line-by-line source, the way TeX places a paper: every
// line where the source puts it, so line-end hyphens, column and page breaks, running
// headers, page numbers, footnotes, a figure's labels and citation links land exactly
// where the expected reading says (#85, #86).
//   swift scripts/make-pdf-fixture.swift fixtures/pdf/paper.layout fixtures/pages/paper.pdf
//
// Source commands, one per line (# starts a comment):
//   page [landscape]         a new US Letter page, upright unless landscape
//   columns <x,x…> <width>   the columns' left edges and width (default 54,315 243: two columns)
//   font <points>            the body's size (default 10); headings are bold at it, lines 1.2 times it
//   header [<size>pt] <text> running header, centered at the top, in italic (8 pt unless a size is given)
//   footer <y> <text>        centered at height y (points from the bottom)
//   title <text>             bold, centered, full width
//   center <text>            centered, full width
//   gap <points>             vertical space in the full-width flow
//   column                   the next column (left, then right), starting under the full-width flow
//   heading <text>           a bold line in the column
//   para [flush]             a new paragraph; its first line is indented unless flush
//   | <text>                 one typeset line of the paragraph
//   figure <height> [a;b;…]  a framed drawing with one labelled box per label (none: a picture with no text)
//   row <a;b;…>              a table row: its cells spread over the column, at the body size
//   labels <size> <a;b;…>    a figure's axis: one short label per line, right-aligned, at that size
//   footnote <text>          at the bottom of the column, under a short rule
//   dest <name>              a link destination at the current line
// Inside a line, {text} is a link to the destination "refs" and ^1 is a superscript.
import AppKit
import CoreText

let args = CommandLine.arguments
let source = try String(contentsOfFile: args[1], encoding: .utf8)
let upright = CGRect(x: 0, y: 0, width: 612, height: 792)
var media = upright
let context = CGContext(URL(fileURLWithPath: args[2]) as CFURL, mediaBox: &media, nil)!

func font(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }
var body = font("TimesNewRomanPSMT", 10), bold = font("TimesNewRomanPS-BoldMT", 10)
let italic = font("TimesNewRomanPS-ItalicMT", 8), small = font("TimesNewRomanPSMT", 8)
var columns: [CGFloat] = [54, 315]
var columnWidth: CGFloat = 243, leading: CGFloat = 12, top: CGFloat = 738

enum Piece { case plain(String), link(String), sup(String) }
func pieces(_ line: String) -> [Piece] {
    var out: [Piece] = [], plain = "", i = line.startIndex
    while i < line.endIndex {
        let c = line[i]
        if c == "{", let close = line[i...].firstIndex(of: "}") {
            if !plain.isEmpty { out.append(.plain(plain)); plain = "" }
            out.append(.link(String(line[line.index(after: i)..<close])))
            i = line.index(after: close)
        } else if c == "^" {
            if !plain.isEmpty { out.append(.plain(plain)); plain = "" }
            let digits = line[line.index(after: i)...].prefix { $0.isNumber }
            out.append(.sup(String(digits)))
            i = line.index(i, offsetBy: digits.count + 1)
        } else { plain.append(c); i = line.index(after: i) }
    }
    if !plain.isEmpty { out.append(.plain(plain)) }
    return out
}
func ctLine(_ text: String, _ f: CTFont) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): f]))
}
func width(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }
/// Draws one line at (x, y) (or only measures it), returning its width.
@discardableResult
func draw(_ text: String, x: CGFloat, y: CGFloat, font f: CTFont = body, measure: Bool = false) -> CGFloat {
    var at = x
    for p in pieces(text) {
        let (s, pf, rise): (String, CTFont, CGFloat)
        switch p {
        case .plain(let t), .link(let t): (s, pf, rise) = (t, f, 0)
        case .sup(let t): (s, pf, rise) = (t, font("TimesNewRomanPSMT", CTFontGetSize(f) * 0.7), CTFontGetSize(f) * 0.4)
        }
        let l = ctLine(s, pf)
        let w = width(l)
        if !measure {
            context.textPosition = CGPoint(x: at, y: y + rise)
            CTLineDraw(l, context)
            if case .link = p { context.setDestination("refs" as CFString, for: CGRect(x: at, y: y - 2, width: w, height: CTFontGetSize(f) + 2)) }
        }
        at += w
    }
    return at - x
}
func centered(_ text: String, y: CGFloat, font f: CTFont = body) {
    draw(text, x: (media.width - draw(text, x: 0, y: 0, font: f, measure: true)) / 2, y: y, font: f)
}

var open = false, y = top, column = -1, columnY = top, columnTop = top, indent: CGFloat = 0, footnotes = 0
func endPage() { if open { context.endPDFPage(); open = false } }
for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
    let line = String(raw)
    if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
    let (command, rest) = line.hasPrefix("| ") ? ("|", String(line.dropFirst(2)))
        : (String(line.prefix { $0 != " " }), String(line.drop { $0 != " " }.dropFirst()))
    let x = column >= 0 ? columns[column] : 54
    switch command {
    case "page":
        endPage()
        if rest == "landscape" {
            media = CGRect(x: 0, y: 0, width: upright.height, height: upright.width)
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &media, length: MemoryLayout<CGRect>.size)] as CFDictionary)
        } else {
            media = upright
            context.beginPDFPage(nil)
        }
        open = true
        top = media.height - 54
        y = top; column = -1; footnotes = 0
    case "columns":
        let parts = rest.split(separator: " ")
        columns = parts[0].split(separator: ",").map { CGFloat(Double($0)!) }
        columnWidth = CGFloat(Double(parts[1])!)
    case "font":
        let size = CGFloat(Double(rest)!)
        body = font("TimesNewRomanPSMT", size); bold = font("TimesNewRomanPS-BoldMT", size); leading = (size * 1.2).rounded()
    case "header":
        let size = rest.split(separator: " ").first.flatMap { $0.hasSuffix("pt") ? Double($0.dropLast(2)) : nil }
        let text = size == nil ? rest : String(rest.drop { $0 != " " }.dropFirst())
        centered(text, y: media.height - 36, font: size.map { font("TimesNewRomanPS-ItalicMT", CGFloat($0)) } ?? italic)
    case "footer":
        let (at, text) = (CGFloat(Double(rest.prefix { $0 != " " })!), String(rest.drop { $0 != " " }.dropFirst()))
        centered(text, y: at, font: small)
    case "title": centered(rest, y: y, font: font("TimesNewRomanPS-BoldMT", 14)); y -= 22
    case "center": centered(rest, y: y); y -= 13
    case "gap": y -= CGFloat(Double(rest)!)
    case "column":
        column += 1
        if column == 0 { columnTop = y }
        columnY = columnTop; footnotes = 0
    case "heading": columnY -= 6; draw(rest, x: x, y: columnY, font: bold); columnY -= leading + 2
    case "para": columnY -= 3; indent = rest == "flush" ? 0 : 10
    case "|":
        if draw(rest, x: x + indent, y: columnY) > columnWidth - indent { print("wider than the column: \(rest)") }
        indent = 0; columnY -= leading
        if columnY < 96 { print("past the column's foot: \(rest)") }
    case "figure":
        let height = CGFloat(Double(rest.prefix { $0 != " " })!)
        let labels = rest.drop { $0 != " " }.dropFirst().split(separator: ";").map(String.init)
        columnY -= 6
        let frame = CGRect(x: x, y: columnY - height, width: columnWidth, height: height)
        context.setLineWidth(0.6); context.stroke(frame)
        if labels.isEmpty { context.strokeLineSegments(between: [frame.origin, CGPoint(x: frame.maxX, y: frame.maxY)]) }
        let slot = columnWidth / CGFloat(max(labels.count, 1))
        for (i, label) in labels.enumerated() {
            let boxRect = CGRect(x: x + CGFloat(i) * slot + 6, y: frame.midY - 12, width: slot - 12, height: 24)
            context.stroke(boxRect)
            let w = draw(label, x: 0, y: 0, font: small, measure: true)
            draw(label, x: boxRect.midX - w / 2, y: boxRect.midY - 3, font: small)
        }
        columnY -= height + 6
    case "row":
        let cells = rest.split(separator: ";").map(String.init)
        let slot = columnWidth / CGFloat(cells.count)
        for (i, cell) in cells.enumerated() { draw(cell, x: x + CGFloat(i) * slot, y: columnY) }
        columnY -= leading
    case "labels":
        let size = CGFloat(Double(rest.prefix { $0 != " " })!)
        for label in rest.drop(while: { $0 != " " }).dropFirst().split(separator: ";") {
            let f = font("TimesNewRomanPSMT", size), w = draw(String(label), x: 0, y: 0, font: f, measure: true)
            draw(String(label), x: x + 70 - w, y: columnY, font: f); columnY -= size + 2 // right-aligned, like an axis's
        }
    case "footnote":
        let at: CGFloat = 84 - CGFloat(footnotes) * 10
        if footnotes == 0 { context.setLineWidth(0.4); context.strokeLineSegments(between: [CGPoint(x: x, y: at + 10), CGPoint(x: x + 60, y: at + 10)]) }
        draw(rest, x: x, y: at, font: small); footnotes += 1
    case "dest": context.addDestination(rest as CFString, at: CGPoint(x: x, y: columnY + leading))
    default: fatalError("unknown command: \(line)")
    }
}
endPage()
context.closePDF()
