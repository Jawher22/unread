# QwenANE (vendored)

Qwen3-TTS on the Neural Engine through Core ML: the runtime from [Gloam Voice Studio](https://github.com/TinyTrashLabs/gloam-voice-studio), MIT (`LICENSE`, © 2026 TinyTrashLabs). Unread's `Narrator` uses it to run the 1.7B Base model set `tinytrashlabs/Qwen3-TTS-1.7B-Base-ANE` (Apache-2.0, fetched by `scripts/fetch-narrator.sh`, not stored here).

Upstream commit: `f46258b1889dd0c94d227c265831853f54fd9f7d` (2026-10-31).

It's vendored rather than a package dependency because upstream's `Package.swift` also declares its MLX, ONNX and app dependencies, which SwiftPM would resolve and fetch for Unread too.

## What was taken

- `Sources/QwenANE/*.swift`, except `QwenVoicePrep+Pack.swift`, `+Folder.swift` and `+Production.swift` (.gvoice packs, reference sections, the cleanup pipeline).
- From `Sources/GVoiceKit`: `ReferenceTail.swift` whole, and from `RefLoudness.swift` only the WAV parser (`SampleFormat`, `dataChunk(in:)`, upstream lines 113–176).

## Local changes

Each is marked `Unread:` in the source.

- `QwenEngineFilesKind.swift` is new: the `QwenEngineFiles.Kind` type from GVoiceKit's `QwenEngineFiles.swift`, without the pack code around it.
- `QwenVoicePrep.swift`: no `import GVoiceKit` / `GVoiceProductionKit` (one module now). A reference must be mono 24 kHz PCM16 or float32; other formats are refused instead of converted.
- `CoreMLVocoder.swift`: the upsampler (`upMall`) runs on the CPU. On the Neural Engine each call waits behind the talker's: 85–130 ms a chunk instead of 27 ms on this M4 Pro, which delays first audio by ~100 ms and makes short chunks expensive. The GPU stays unused either way.
- `CoreMLVocoder.swift`, `QwenStreamTrim.swift`, `QwenANEEngine.swift`: when streaming, the chunk schedule holds its first size until the stream has heard speech (`ANEVocoder.speechStarted`, `QwenStreamTrimmer.hasStarted`), so the chunk with the voice's onset is a short one. The model starts most lines with 0.1–0.6 s of quiet.
- `QwenANEEngine.swift`: `onDecode`, called for every decoded chunk before trimming, so `--narrate` can time the first chunk.
