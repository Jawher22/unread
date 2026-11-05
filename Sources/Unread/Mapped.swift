import Darwin
import Foundation
import Synchronization

/// The model files this process has mapped into memory: weights, embedding tables and the CPU
/// programs Core ML compiled. They're file-backed, so when the Mac needs memory or the file
/// cache churns (a build, a browser), macOS drops them, and the next synthesis reads them back
/// a page at a time.
enum MappedFiles {
    struct Region {
        let path: String
        let address: UInt64
        let size: UInt64
    }

    /// Mapped from the narrator's model set, Kokoro's, or Core ML's cache of compiled programs.
    static func isModel(_ path: String) -> Bool {
        path.hasPrefix(Narrator.modelDirectory.path) || path.contains("/.cache/fluidaudio/") || path.contains("/com.apple.e5rt.e5bundlecache/")
    }

    static func regions() -> [Region] {
        var out: [Region] = []
        var address: UInt64 = 0
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        while true {
            var info = proc_regionwithpathinfo()
            guard proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, address, &info, size) == size else { break }
            let r = info.prp_prinfo
            let path = withUnsafeBytes(of: info.prp_vip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if isModel(path) {
                out.append(Region(path: path, address: r.pri_address, size: r.pri_size))
            }
            address = r.pri_address + r.pri_size
        }
        return out
    }

    /// Bytes of `regions` in memory now, and in all.
    static func resident(_ regions: [Region]) -> (bytes: Int, of: Int) {
        let page = Int(vm_page_size)
        return regions.reduce((0, 0)) { sum, r in
            let pages = residentPages(r)
            return (sum.0 + pages.filter { $0 }.count * page, sum.1 + pages.count * page)
        }
    }

    /// Which of the region's pages are in memory now.
    static func residentPages(_ r: Region) -> [Bool] {
        var vec = [CChar](repeating: 0, count: Int(r.size) / Int(vm_page_size))
        guard let p = UnsafeMutableRawPointer(bitPattern: UInt(r.address)), mincore(p, Int(r.size), &vec) == 0 else { return [] }
        return vec.map { $0 & 1 != 0 }
    }
}

/// The pages of the narrator's mapped files that synthesis has used (`note` after each sentence),
/// to read back when ⌃ goes down. Reading all of them back costs more than it saves: the text
/// embedding table is 311 MB, and a reading touches ~1% of it (`--narrate --idle`).
final class WorkingSet: Sendable {
    let regions: [MappedFiles.Region]
    private let used: Mutex<[[Bool]]>

    init(_ regions: [MappedFiles.Region]) {
        self.regions = regions
        used = Mutex(regions.map { [Bool](repeating: false, count: Int($0.size) / Int(vm_page_size)) })
    }

    func note() {
        let now = regions.map(MappedFiles.residentPages)
        used.withLock { used in
            for (i, pages) in now.enumerated() where pages.count == used[i].count {
                for (j, resident) in pages.enumerated() where resident { used[i][j] = true }
            }
        }
    }

    var bytes: Int { used.withLock { $0.reduce(0) { $0 + $1.filter { $0 }.count } } * Int(vm_page_size) }

    /// Drops the regions' pages, as memory pressure does (`--evict` in the dev modes).
    func evict() {
        for r in regions {
            if let p = UnsafeMutableRawPointer(bitPattern: UInt(r.address)) { msync(p, Int(r.size), MS_INVALIDATE) }
        }
    }

    /// Asks the kernel to read the used pages back in, in the background; those still in memory cost nothing.
    func prefetch() {
        let page = Int(vm_page_size)
        let used = self.used.withLock { $0 }
        for (r, pages) in zip(regions, used) {
            var j = 0
            while j < pages.count {
                guard pages[j] else { j += 1; continue }
                let from = j
                while j < pages.count, pages[j] { j += 1 }
                if let p = UnsafeMutableRawPointer(bitPattern: UInt(r.address) + UInt(from * page)) { madvise(p, (j - from) * page, MADV_WILLNEED) }
            }
        }
    }
}
