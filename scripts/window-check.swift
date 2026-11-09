// Watches, from the window server, whether Unread's reading panel stays with the window being read
// (scripts/window-check.sh). Every millisecond it reads the bounds of the host's window and of the panel;
// every 20 ms the stacking order of the host's windows and the panel. Read-only: it moves nothing.
//   swift scripts/window-check.swift <host pid> <host window> <unread pid> <seconds>
// Prints each order change, then the panel's lag behind each move of the host's window (WINDOW_CHECK_VERBOSE=1:
// and every place each was seen at).
import CoreGraphics
import Foundation

let a = CommandLine.arguments
guard a.count == 5, let host = pid_t(a[1]), let hostWindow = CGWindowID(a[2]), let unread = pid_t(a[3]), let seconds = Double(a[4]) else {
    print("usage: window-check.swift <host pid> <host window> <unread pid> <seconds>"); exit(2)
}
func now() -> Double { Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000) }
func number(_ w: [String: Any]) -> CGWindowID { CGWindowID(w[kCGWindowNumber as String] as? Int ?? 0) }
func bounds(_ w: [String: Any]) -> CGRect? { (w[kCGWindowBounds as String]).flatMap { CGRect(dictionaryRepresentation: $0 as! CFDictionary) } }

var panel: CGWindowID?
var lastOrder = ""
var hostMoves: [(t: Double, origin: CGPoint)] = []
var panelMoves: [(t: Double, origin: CGPoint)] = []
let end = Date().addingTimeInterval(seconds)
var tick = 0
while Date() < end {
    if tick % 20 == 0 {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        // Front to back: the host's windows and Unread's layer-0 panels (the reading's).
        var names: [String] = []
        for w in list {
            let owner = pid_t(w[kCGWindowOwnerPID as String] as? Int ?? 0), layer = w[kCGWindowLayer as String] as? Int ?? -1
            if owner == host { names.append(number(w) == hostWindow ? "host" : "host's other window") }
            if owner == unread, layer == 0 {
                names.append("panel")
                panel = number(w)
            }
        }
        let order = names.joined(separator: " > ")
        if order != lastOrder { print(String(format: "[check %.3f] front to back: %@", now(), order.isEmpty ? "(none)" : order)); lastOrder = order }
    }
    let ids = [hostWindow] + (panel.map { [$0] } ?? [])
    var pointers = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) } // the array holds window numbers, not objects
    let array = CFArrayCreate(nil, &pointers, ids.count, nil)!
    if let info = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] {
        let t = now()
        for w in info {
            guard let b = bounds(w) else { continue }
            if number(w) == hostWindow { if hostMoves.last?.origin != b.origin { hostMoves.append((t, b.origin)) } }
            else if panelMoves.last?.origin != b.origin { panelMoves.append((t, b.origin)) }
        }
    }
    tick += 1
    usleep(1000)
}

// For each place the host's window reached after the first: how long until the panel was there, or somewhere
// the window went after it (the panel may skip a step of the glide). Reported per glide: moves less than
// 0.2 s apart.
let index = Dictionary(hostMoves.enumerated().map { ("\($0.element.origin)", $0.offset) }, uniquingKeysWith: { a, _ in a })
var glide: [Double] = [], missed = 0, from = 1
func report(_ until: Int) {
    defer { glide = []; missed = 0; from = until + 1 }
    guard until >= from else { return }
    glide.sort()
    func pct(_ q: Double) -> Double { glide.isEmpty ? .nan : glide[min(glide.count - 1, Int(Double(glide.count) * q))] }
    let a = hostMoves[from - 1].origin, b = hostMoves[until].origin
    print(String(format: "[check %.3f] the host's window went from %d,%d to %d,%d in %d steps over %.0f ms; the panel followed to %d of them, %d never: lag first %.1f ms, p50 %.1f ms, p95 %.1f ms, max %.1f ms, last %.1f ms",
                 hostMoves[from].t, Int(a.x), Int(a.y), Int(b.x), Int(b.y), until - from + 1, (hostMoves[until].t - hostMoves[from].t) * 1000,
                 glide.count, missed, firstLag, pct(0.5), pct(0.95), glide.last ?? .nan, lastLag))
}
var firstLag = Double.nan, lastLag = Double.nan
for (i, m) in hostMoves.enumerated().dropFirst() {
    if i > from, m.t - hostMoves[i - 1].t > 0.2 { report(i - 1) }
    let lag = panelMoves.first(where: { $0.t >= m.t - 0.0005 && (index["\($0.origin)"] ?? -1) >= i }).map { ($0.t - m.t) * 1000 }
    if let lag { glide.append(lag) } else { missed += 1 }
    if i == from { firstLag = lag ?? .nan }
    lastLag = lag ?? .nan
}
report(hostMoves.count - 1)
if ProcessInfo.processInfo.environment["WINDOW_CHECK_VERBOSE"] != nil {
    for m in hostMoves { print(String(format: "[check %.4f] host at %d,%d", m.t, Int(m.origin.x), Int(m.origin.y))) }
    for m in panelMoves { print(String(format: "[check %.4f] panel at %d,%d", m.t, Int(m.origin.x), Int(m.origin.y))) }
}
if let last = hostMoves.last, let p = panelMoves.last {
    print("[check] at the end: host window at \(Int(last.origin.x)),\(Int(last.origin.y)), panel at \(Int(p.origin.x)),\(Int(p.origin.y))")
}
