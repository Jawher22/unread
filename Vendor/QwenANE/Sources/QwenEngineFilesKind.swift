import Foundation

/// The one part of GVoiceKit's `QwenEngineFiles` that `QwenVoicePrep` uses: which model size a
/// voice is prepared for. The rest of that type reads and writes .gvoice packs, which Unread doesn't use.
public enum QwenEngineFiles {
    public struct Kind: Hashable, Sendable {
        public let engineID: String
        public let speakerDimension: Int
        public static let qwen06 = Kind(engineID: "qwen3-0.6b", speakerDimension: 1024)
        public static let qwen17 = Kind(engineID: "qwen3-1.7b", speakerDimension: 2048)
    }
}
