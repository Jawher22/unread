// Fixture host (native): shows one plain-text or RTF file in an editable NSTextView
// inside an NSScrollView, like a TextEdit document, or a PDF in a PDFView, like Preview,
// without taking focus, so `Unread --extract --pid` can read it as a native text view
// or as PDFKit pages.
//   swiftc -O fixtures/hosts/native/main.swift -o build/fixture-host-native
//   build/fixture-host-native [--hidden] fixtures/pages/notes.txt   (or .rtf, or .pdf)
// --hidden: as in the WebKit host. Fully transparent and click-through, on screen, on every Space.
import AppKit
import PDFKit

let path = CommandLine.arguments.last!
let hidden = CommandLine.arguments.contains("--hidden")
let url = URL(fileURLWithPath: path).standardizedFileURL
let isPDF = url.pathExtension.lowercased() == "pdf"
let app = NSApplication.shared
// Hidden, the host must never take the keyboard (#66). Its window is on every Space, so macOS
// can still make an .accessory app active (switching Spaces, closing the frontmost window),
// and the author's typing or dictation would land in the text view.
app.setActivationPolicy(hidden ? .prohibited : .accessory) // no Dock icon

// Text: short enough that it overflows and the view has to scroll while reading.
// PDF: the WebKit host's size, so a page is scaled alike in both and the second page is below the fold.
let window = NSWindow(contentRect: isPDF ? NSRect(x: 60, y: 60, width: 900, height: 1000) : NSRect(x: 80, y: 80, width: 640, height: 420),
                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.title = "Unread fixture (native): \(url.lastPathComponent)"
if hidden {
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
}
if isPDF {
    guard let document = PDFDocument(url: url) else {
        FileHandle.standardError.write("can't read \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    let view = PDFView(frame: window.contentView!.bounds)
    view.autoresizingMask = [.width, .height]
    view.autoScales = true // fit the width, as Preview does
    view.displayMode = .singlePageContinuous
    view.document = document
    window.contentView = view
    window.orderBack(nil)
} else {
    let scroll = NSTextView.scrollableTextView()
    scroll.frame = window.contentView!.bounds
    scroll.autoresizingMask = [.width, .height]
    let text = scroll.documentView as! NSTextView
    text.isRichText = url.pathExtension == "rtf"
    text.font = .systemFont(ofSize: 15)
    text.textContainerInset = NSSize(width: 12, height: 12)
    do {
        let content = url.pathExtension == "rtf"
            ? try NSAttributedString(url: url, options: [:], documentAttributes: nil)
            : NSAttributedString(string: try String(contentsOf: url, encoding: .utf8), attributes: [.font: NSFont.systemFont(ofSize: 15)])
        text.textStorage!.setAttributedString(content)
    } catch {
        FileHandle.standardError.write("can't read \(path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    text.setSelectedRange(NSRange(location: 0, length: 0))
    window.contentView = scroll
    window.orderBack(nil)
    text.layoutManager!.ensureLayout(for: text.textContainer!)
}
print("loaded")
fflush(stdout)
app.run()
