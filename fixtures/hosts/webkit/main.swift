// Fixture host (WebKit): shows one HTML file in a WKWebView window without
// taking focus, so `Unread --extract --pid` can read it like Safari content.
//   swiftc -O fixtures/hosts/webkit/main.swift -o build/fixture-host-webkit
//   build/fixture-host-webkit [--hidden] fixtures/pages/inline.html   (or an https:// URL)
// --hidden (extract-fixture.sh): fully transparent and click-through, so a test run
// never covers the user's work. It stays on screen, so Accessibility sees the same geometry,
// and on every Space: Accessibility lists only the current Space's windows.
import AppKit
import WebKit

let arg = CommandLine.arguments.last!
let hidden = CommandLine.arguments.contains("--hidden")
let isRemote = arg.hasPrefix("http://") || arg.hasPrefix("https://") // live pages, for investigating
let url = isRemote ? URL(string: arg)! : URL(fileURLWithPath: arg).standardizedFileURL
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, never becomes frontmost

let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 900, height: 1000),
                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.title = "Unread fixture (WebKit): \(url.lastPathComponent)"
if hidden {
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
}
let web = WKWebView(frame: window.contentView!.bounds)
web.autoresizingMask = [.width, .height]
window.contentView = web
/// extract-fixture.sh waits for "loaded": until then the window holds an empty document.
final class LoadSignal: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("loaded")
        fflush(stdout)
    }
}
let signal = LoadSignal()
web.navigationDelegate = signal
if isRemote { web.load(URLRequest(url: url)) } else { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
window.orderBack(nil)
app.run()
