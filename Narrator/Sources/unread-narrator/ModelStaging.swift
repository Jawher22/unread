import Foundation

/// The model's files as the loader wants them. mlx-audio-swift's loader
/// writes tokenizer.json into the folder it loads, and deletes the whole
/// folder if `speech_tokenizer` isn't a real directory. So it never gets the
/// Hugging Face cache itself: it gets a staged folder of real directories and
/// symlinks to the cached files.
enum ModelStaging {
    /// `spec` is a model folder, or a Hugging Face repo id found in the
    /// Hugging Face cache. Returns the staged folder to load.
    static func stage(_ spec: String) throws -> URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let source: URL, name: String
        if fm.fileExists(atPath: spec, isDirectory: &isDir), isDir.boolValue {
            source = URL(fileURLWithPath: spec).resolvingSymlinksInPath()
            name = source.path.split(separator: "/").joined(separator: "-")
        } else {
            source = try snapshot(repo: spec)
            name = source.lastPathComponent
        }
        let staged = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Unread/narrator/model")
            .appendingPathComponent(name)
        try mirror(source, into: staged)
        return staged
    }

    static func snapshot(repo: String) throws -> URL {
        let env = ProcessInfo.processInfo.environment
        let hub = env["HF_HUB_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? env["HF_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("hub") }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
        let repoDir = hub.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
        guard let revision = try? String(contentsOf: repoDir.appendingPathComponent("refs/main"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !revision.isEmpty else {
            throw StagingError(description: "\(repo) is not in \(hub.path); download it first (hf download \(repo))")
        }
        return repoDir.appendingPathComponent("snapshots").appendingPathComponent(revision)
    }

    /// Recreates `source`'s directories under `target` and symlinks each file
    /// to its resolved path. Links the source no longer has are removed (the
    /// loader would load a stale shard); real files (tokenizer.json from an
    /// earlier load) are kept, so staging again is a no-op.
    static func mirror(_ source: URL, into target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let names = try fm.contentsOfDirectory(atPath: source.path).filter { !$0.hasPrefix(".") }
        for stale in try fm.contentsOfDirectory(atPath: target.path) where !names.contains(stale) {
            let path = target.appendingPathComponent(stale).path
            if (try? fm.destinationOfSymbolicLink(atPath: path)) != nil { try fm.removeItem(atPath: path) }
        }
        for name in names {
            let from = source.appendingPathComponent(name).resolvingSymlinksInPath()
            let to = target.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: from.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                try mirror(from, into: to)
            } else if (try? fm.destinationOfSymbolicLink(atPath: to.path)) != from.path {
                try? fm.removeItem(at: to)
                try fm.createSymbolicLink(at: to, withDestinationURL: from)
            }
        }
    }

    struct StagingError: Error, CustomStringConvertible {
        let description: String
    }
}
