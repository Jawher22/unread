import AVFoundation
import Foundation
import NaturalLanguage

/// A designed voice the narrator clones (#60): a ~5 s clip and its exact transcript, and a preview
/// the narrator recorded in that voice. Made by scripts/make-voices.sh into Resources/Voices.
struct VoicePreset: Sendable, Identifiable, Hashable {
    /// The file name: `london-storyteller` for london-storyteller.json.
    let id: String
    let name: String
    let language: NLLanguage
    /// A few words for the Settings list.
    let summary: String
    /// What it was designed from.
    let description: String
    let transcript: String
    let audio: URL
    let preview: URL?
    /// Characters a second at 1×, over the voiced part of each sentence of the preview.
    let pace: Double?

    static func load(_ url: URL) throws -> VoicePreset {
        struct File: Decodable {
            let name, description, transcript, audio: String
            let language, summary, preview: String?
            let pace: Double?
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        let dir = url.deletingLastPathComponent()
        return VoicePreset(id: url.deletingPathExtension().lastPathComponent, name: file.name,
                           language: file.language == "fr" ? .french : .english, summary: file.summary ?? "",
                           description: file.description, transcript: file.transcript,
                           audio: dir.appendingPathComponent(file.audio),
                           preview: file.preview.map { dir.appendingPathComponent($0) }, pace: file.pace)
    }

    /// Resources/Voices, from Unread.app or the checkout a dev build runs from.
    static let directory: URL? = {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Voices"), fm.fileExists(atPath: bundled.path) {
            return bundled
        }
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        while let current = dir, current.path != "/" {
            let candidate = current.appendingPathComponent("Resources/Voices")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            dir = current.deletingLastPathComponent()
        }
        return nil
    }()

    /// Every preset, by name.
    static let all: [VoicePreset] = {
        guard let dir = directory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { try? load($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    static func named(_ id: String) throws -> VoicePreset {
        guard let preset = all.first(where: { $0.id == id }) else { throw Narrator.Failure.voiceMissing(id) }
        return preset
    }
}

enum NarratorStatus {
    case notLoaded, loading, ready, unavailable

    /// What the menu says beside the narrator's name.
    var note: String? {
        switch self {
        case .loading: "loading…"
        case .unavailable: "unavailable, see log"
        case .notLoaded, .ready: nil
        }
    }
}

/// Which voice reads (#59), shared by the menu and Settings and kept across launches. Until one is
/// picked, the narrator if its model is installed, else Kokoro. While the narrator loads, or if it
/// can't, Kokoro reads.
@MainActor
final class ReadingVoice: ObservableObject {
    static let shared = ReadingVoice()
    @Published private(set) var choice = UserDefaults.standard.string(forKey: VoiceChoice.key).flatMap(VoiceChoice.init)
        ?? (Narrator.isInstalled() ? .narrator : .kokoro)
    @Published var narratorStatus = NarratorStatus.notLoaded
    /// Called after a new choice.
    var onChoose: ((VoiceChoice) -> Void)?

    func choose(_ choice: VoiceChoice) {
        guard choice != self.choice else { return }
        self.choice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: VoiceChoice.key)
        onChoose?(choice)
    }
}

/// The narrator voice chosen for each language, kept across launches. English sentences are read
/// in the English choice and French ones in the French choice.
@MainActor
final class NarratorVoices: ObservableObject {
    static let shared = NarratorVoices()
    static let languages: [NLLanguage] = [.english, .french]
    nonisolated static let defaults: [NLLanguage: String] = [.english: "london-storyteller", .french: "conteur-parisien"]

    @Published private var chosen: [NLLanguage: String]

    private init() {
        chosen = Dictionary(uniqueKeysWithValues: Self.languages.map { language in
            (language, UserDefaults.standard.string(forKey: Self.key(language)) ?? Self.defaults[language]!)
        })
    }

    private static func key(_ language: NLLanguage) -> String { "narratorVoice.\(language.rawValue)" }

    /// The presets that read `language`.
    nonisolated static func presets(_ language: NLLanguage) -> [VoicePreset] { VoicePreset.all.filter { $0.language == language } }

    /// The chosen preset, else the default, else the language's first; nil when it has none.
    func preset(for language: NLLanguage) -> VoicePreset? { Self.preset(for: language, chosen: chosen[language]) }

    nonisolated static func preset(for language: NLLanguage, chosen: String? = nil) -> VoicePreset? {
        let presets = presets(language)
        return presets.first { $0.id == chosen } ?? presets.first { $0.id == defaults[language] } ?? presets.first
    }

    /// Called after a new choice.
    var onChoose: ((VoicePreset) -> Void)?

    func choose(_ preset: VoicePreset) {
        guard chosen[preset.language] != preset.id else { return }
        chosen[preset.language] = preset.id
        UserDefaults.standard.set(preset.id, forKey: Self.key(preset.language))
        onChoose?(preset)
    }
}

/// Plays a preset's stored preview. No synthesis, so it works before the narrator has loaded.
@MainActor
final class VoicePreview: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoicePreview()
    @Published private(set) var playing: String?
    private var player: AVAudioPlayer?

    func toggle(_ preset: VoicePreset) {
        let wasPlaying = playing == preset.id
        stop()
        guard !wasPlaying, let url = preset.preview, let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        player.play()
        self.player = player
        playing = preset.id
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in if finished === player { stop() } }
    }
}
