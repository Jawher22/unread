// Fixture host (WebKit): shows one HTML file in a WKWebView window without
// taking focus, so `Unread --extract --pid` can read it like Safari content.
//   swiftc -O fixtures/hosts/webkit/main.swift -o build/fixture-host-webkit
//   build/fixture-host-webkit fixtures/pages/inline.html   (or an https:// URL)
import AppKit
import WebKit

let arg = CommandLine.arguments[1]
let isRemote = arg.hasPrefix("http://") || arg.hasPrefix("https://") // live pages, for investigating
let url = isRemote ? URL(string: arg)! : URL(fileURLWithPath: arg).standardizedFileURL
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, never becomes frontmost

let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 900, height: 1000),
                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.title = "Unread fixture (WebKit): \(url.lastPathComponent)"
let web = WKWebView(frame: window.contentView!.bounds)
web.autoresizingMask = [.width, .height]
window.contentView = web
if isRemote { web.load(URLRequest(url: url)) } else { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
window.orderBack(nil)
app.run()
