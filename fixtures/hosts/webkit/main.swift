// Fixture host (WebKit): shows one HTML file in a WKWebView window without
// taking focus, so `Unread --extract --pid` can read it like Safari content.
//   swiftc -O fixtures/hosts/webkit/main.swift -o build/fixture-host-webkit
//   build/fixture-host-webkit [--hidden] fixtures/pages/inline.html   (or an https:// URL)
// --hidden (extract-fixture.sh): fully transparent and click-through, so a test run
// never covers the user's work. It stays on screen, so Accessibility sees the same geometry,
// and on every Space: Accessibility lists only the current Space's windows.
//
//   build/fixture-host-webkit --hidden --save out.html <https:// URL | saved .html>
// --save (save-corpus.sh): renders the page, then writes its DOM as one offline file and quits.
// See Snapshot below and fixtures/README.md.
import AppKit
import WebKit

let args = CommandLine.arguments
let arg = args.last!
let hidden = args.contains("--hidden")
let saveTo = args.firstIndex(of: "--save").map { URL(fileURLWithPath: args[$0 + 1]) }
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
let config = WKWebViewConfiguration()
// A page saved by hand from a signed-in browser is already rendered; its own scripts would rebuild it, or log out.
if saveTo != nil, !isRemote { config.defaultWebpagePreferences.allowsContentJavaScript = false }
let web = WKWebView(frame: window.contentView!.bounds, configuration: config)
web.autoresizingMask = [.width, .height]
// Some sites turn away a WKWebView's default user agent (it has no "Safari/…" token).
if saveTo != nil { web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15" }
window.contentView = web
/// extract-fixture.sh waits for "loaded": until then the window holds an empty document.
final class LoadSignal: NSObject, WKNavigationDelegate {
    var saved = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("loaded")
        fflush(stdout)
        if let saveTo, !saved {
            saved = true
            Task { @MainActor in await Snapshot.save(webView, to: saveTo) }
        }
    }
}
let signal = LoadSignal()
web.navigationDelegate = signal
if isRemote { web.load(URLRequest(url: url)) } else { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
window.orderBack(nil)

/// The rendered DOM as one self-contained file that lays out the same offline, in both engines:
/// scripts and event handlers removed, every stylesheet inlined (read from the CSSOM, so rules
/// that CSS-in-JS inserted are kept), fonts inlined as data URLs, images replaced by an empty
/// image of the size they were drawn at, links made absolute.
enum Snapshot {
    static let prepare = """
    const pause = ms => new Promise(r => setTimeout(r, ms));
    await pause(1500);
    // Scroll through once, so lazy images and scroll-triggered reveals settle as a reader would see them.
    for (let y = 0; y < document.documentElement.scrollHeight; y += innerHeight * 0.8) { scrollTo(0, y); await pause(100); }
    scrollTo(0, 0);
    await pause(1000);
    const blank = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
    for (const img of document.querySelectorAll('img')) {
        const r = img.getBoundingClientRect();
        if (r.width && r.height) { img.style.width = r.width + 'px'; img.style.height = r.height + 'px'; }
        img.removeAttribute('srcset'); img.removeAttribute('sizes'); img.removeAttribute('loading');
        img.src = blank;
    }
    document.querySelectorAll('picture source, video source, audio source').forEach(e => e.remove());
    document.querySelectorAll('video, audio').forEach(e => { e.removeAttribute('src'); e.removeAttribute('autoplay'); e.removeAttribute('poster'); });
    document.querySelectorAll('iframe, frame').forEach(e => { e.removeAttribute('srcdoc'); e.src = 'about:blank'; });
    document.querySelectorAll('a[href]').forEach(a => a.setAttribute('href', a.href));
    const sheets = [];
    for (const el of document.querySelectorAll('link[rel~="stylesheet"], style')) {
        if (!el.sheet || el.disabled) { el.remove(); continue; }
        let css = null;
        try { css = [...el.sheet.cssRules].map(r => r.cssText).join('\\n'); } catch {} // cross-origin: fetched by the host
        sheets.push({ css, href: el.href || null, base: el.sheet.href || document.baseURI });
        const style = document.createElement('style');
        style.dataset.unreadSheet = sheets.length - 1;
        if (el.media) style.media = el.media;
        el.replaceWith(style);
    }
    for (const sheet of document.adoptedStyleSheets || []) {
        sheets.push({ css: [...sheet.cssRules].map(r => r.cssText).join('\\n'), href: null, base: document.baseURI });
        const style = document.createElement('style');
        style.dataset.unreadSheet = sheets.length - 1;
        document.head.append(style);
    }
    document.querySelectorAll('script, noscript, base, link, meta[http-equiv]').forEach(e => e.remove());
    for (const el of document.querySelectorAll('*'))
        for (const a of [...el.attributes]) if (a.name.startsWith('on')) el.removeAttribute(a.name);
    const d = document.doctype;
    const doctype = d ? `<!DOCTYPE ${d.name}${d.publicId ? ` PUBLIC "${d.publicId}"` : ''}${d.systemId ? ` "${d.systemId}"` : ''}>` : '';
    return { html: doctype + '\\n' + document.documentElement.outerHTML, sheets, url: location.href };
    """

    @MainActor static func save(_ web: WKWebView, to file: URL) async {
        do {
            guard let page = try await web.callAsyncJavaScript(prepare, contentWorld: .defaultClient) as? [String: Any],
                  var html = page["html"] as? String, let sheets = page["sheets"] as? [[String: Any]]
            else { fail("the page gave no DOM") }
            for (i, sheet) in sheets.enumerated() {
                let base = (sheet["base"] as? String).flatMap(URL.init(string:)) ?? url
                var css = sheet["css"] as? String
                if css == nil, let href = (sheet["href"] as? String).flatMap(URL.init(string:)) { css = await text(href) }
                let inlined = await inline(css ?? "", base: base, depth: 0)
                    .replacingOccurrences(of: "</style", with: "<\\/style")
                // The placeholder is empty, so its closing tag is the first one after it.
                if let open = html.range(of: "<style data-unread-sheet=\"\(i)\""),
                   let close = html.range(of: "</style>", range: open.upperBound..<html.endIndex) {
                    html.insert(contentsOf: inlined, at: close.lowerBound)
                }
            }
            // Charset first: the file is UTF-8 whatever the page said.
            if let head = html.range(of: "<head[^>]*>", options: .regularExpression) {
                html.insert(contentsOf: "<meta charset=\"utf-8\">", at: head.upperBound)
            }
            try html.write(to: file, atomically: true, encoding: .utf8)
            print("saved \(file.path) from \(page["url"] as? String ?? url.absoluteString) (\(html.utf8.count / 1024) KB, \(sheets.count) stylesheets)")
            exit(0)
        } catch { fail("\(error)") }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("save failed: \(message)\n".utf8))
        exit(1)
    }

    static func data(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return data
    }
    static func text(_ url: URL) async -> String? { await data(url).flatMap { String(data: $0, encoding: .utf8) } }

    static let urlPattern = try! NSRegularExpression(pattern: #"url\(\s*(['"]?)([^'")]*)\1\s*\)"#)
    static let importPattern = try! NSRegularExpression(pattern: #"@import\s+(?:url\(\s*['"]?([^'")]*)['"]?\s*\)|['"]([^'"]*)['"])\s*([^;]*);"#)
    static let fontFacePattern = try! NSRegularExpression(pattern: #"@font-face\s*\{[^}]*\}"#)

    /// Imports spliced in, URLs made absolute, fonts embedded. Other resources (background images)
    /// stay remote: they don't change the layout.
    static func inline(_ css: String, base: URL, depth: Int) async -> String {
        var css = css
        for m in importPattern.matches(in: css, range: NSRange(css.startIndex..., in: css)).reversed() {
            let ref = [1, 2].compactMap { Range(m.range(at: $0), in: css).map { String(css[$0]) } }.first ?? ""
            let media = Range(m.range(at: 3), in: css).map { css[$0].trimmingCharacters(in: .whitespaces) } ?? ""
            var imported = ""
            if depth < 4, let u = URL(string: ref, relativeTo: base)?.absoluteURL, let text = await text(u) {
                imported = await inline(text, base: u, depth: depth + 1)
                if !media.isEmpty { imported = "@media \(media) {\n\(imported)\n}" }
            }
            css.replaceSubrange(Range(m.range, in: css)!, with: imported)
        }
        let fontFaces = fontFacePattern.matches(in: css, range: NSRange(css.startIndex..., in: css)).map(\.range)
        for m in urlPattern.matches(in: css, range: NSRange(css.startIndex..., in: css)).reversed() {
            let ref = String(css[Range(m.range(at: 2), in: css)!])
            guard !ref.hasPrefix("data:"), !ref.hasPrefix("#"), let u = URL(string: ref, relativeTo: base)?.absoluteURL else { continue }
            var replacement = "url(\"\(u.absoluteString)\")"
            if fontFaces.contains(where: { NSLocationInRange(m.range.location, $0) }), let font = await data(u) {
                replacement = "url(\"data:\(fontType(u));base64,\(font.base64EncodedString())\")"
            }
            css.replaceSubrange(Range(m.range, in: css)!, with: replacement)
        }
        return css
    }

    static func fontType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "otf": "font/otf"
        default: "font/ttf"
        }
    }
}

app.run()
