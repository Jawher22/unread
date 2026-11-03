// Fixture host (WebKit): shows one HTML file in a WKWebView window without
// taking focus, so `Unread --extract --pid` can read it like Safari content.
//   swiftc -O fixtures/hosts/webkit/main.swift -o build/fixture-host-webkit
//   build/fixture-host-webkit fixtures/pages/inline.html
import AppKit
import WebKit

let url = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, never becomes frontmost

let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 900, height: 1000),
                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.title = "Unread fixture (WebKit): \(url.lastPathComponent)"
let web = WKWebView(frame: window.contentView!.bounds)
web.autoresizingMask = [.width, .height]
window.contentView = web
web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
window.orderBack(nil)
app.run()
