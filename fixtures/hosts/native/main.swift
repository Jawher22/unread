// Fixture host (native): shows one plain-text or RTF file in an editable NSTextView
// inside an NSScrollView, like a TextEdit document, without taking focus, so
// `Unread --extract --pid` can read it as a native text view.
//   swiftc -O fixtures/hosts/native/main.swift -o build/fixture-host-native
//   build/fixture-host-native [--hidden] fixtures/pages/notes.txt   (or .rtf)
// --hidden: as in the WebKit host. Fully transparent and click-through, on screen, on every Space.
import AppKit

let path = CommandLine.arguments.last!
let hidden = CommandLine.arguments.contains("--hidden")
let url = URL(fileURLWithPath: path).standardizedFileURL
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, never becomes frontmost

// Short enough that the text overflows and the view has to scroll while reading.
let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 420),
                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.title = "Unread fixture (native): \(url.lastPathComponent)"
if hidden {
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
}
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
print("loaded")
fflush(stdout)
app.run()
