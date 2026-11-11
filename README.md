# Unread

**Your unread pile, read to you.** A tiny macOS menu-bar app that reads anything on your screen aloud in a natural voice, fully on-device.

No selecting, no copy-paste, no "open in reader". Point at a paragraph, hold a key, listen.

> Status: v0 prototype. It works, it's rough. Expect sharp edges.

## How it feels

| Gesture | What happens |
| --- | --- |
| **Hold ⌃ Control** and point | The paragraph under the pointer lights up |
| **Release** | Unread reads from that paragraph to the end, highlighting each sentence in place |
| **Tap ⌃** | Playing: pause / resume. Nothing playing: nothing, so a stray tap never starts talking |
| **Double-tap ⌃** | Nothing playing: read from the top of what's visible. Playing: stop |
| **Hold ⌃ and point elsewhere** while reading | Jump there |

A soft chime plays when reading ends, whether it reached the end or you stopped it.

The highlight is drawn *on top of the app you're already in* (Safari, Chrome, Arc, Dia, Electron apps, TextEdit, Notes, PDFs in Preview and in the browser, Apple Books…). There is no separate reader window. If you scroll away it stops following you; scroll back and it picks up again.

English and French are detected per sentence and switched automatically.

## Why it's fast

Same playbook as [Hex](https://github.com/kitlangton/Hex), in reverse:

- **A narrator on the Neural Engine.** Qwen3-TTS 1.7B through Core ML ([TinyTrashLabs' model set](https://huggingface.co/tinytrashlabs/Qwen3-TTS-1.7B-Base-ANE)), cloning one of 34 designed voices (English and French), streaming as it speaks: ~0.7× real time, the GPU untouched.
- **Always warm.** The model loads once at launch (a few seconds) and stays resident; ⌃ going down wakes it after a while idle.
- **Work starts on key-down.** The audio device opens, the target paragraph is resolved and its first sentence is synthesized while you're still holding the key.
- **Pipelined.** Sentences are synthesized ahead of the one playing, so playback is gapless.

Measured on an M-series MacBook: ~0.3–0.6 s from release to first audio after a hold, ~25 ms to find the document, ~70 ms to extract 12 sentences with their on-screen positions.

## Requirements

- Apple Silicon Mac, macOS 15 or later
- To build: Swift 6.2 or later (Xcode 26)
- Accessibility permission (to read on-screen text and watch the hotkey)
- The narrator's model (2.88 GB), fetched once with `scripts/fetch-narrator.sh`, and the word aligner's (~100 MB), downloaded on first launch to `~/.cache/fluidaudio`

## Build and run

```bash
scripts/fetch-narrator.sh     # the voice model, once
scripts/bundle.sh --install   # builds, signs and installs ~/Applications/Unread.app
open ~/Applications/Unread.app
```

The first build compiles FluidAudio (~15 min). The first launch compiles the voice model for the Neural Engine, which takes about a minute: while the menu says "Loading voice…", ⌃ only beeps. Later launches take a few seconds. On first launch, grant Accessibility when prompted (System Settings → Privacy & Security → Accessibility); Unread picks the grant up without a relaunch. It turns on **Launch at Login** the first time it runs; toggle it from the menu. Logs go to `~/Library/Logs/Unread/unread.log`.

The script signs with your first "Apple Development" identity (or `$UNREAD_SIGN_IDENTITY`). A stable identity means the Accessibility grant survives rebuilds; without one it falls back to ad-hoc signing and you'll re-grant after every build.

For quick iteration you can also run the bare binary from a terminal that has Accessibility permission: `scripts/build.sh && ./.build/release/Unread`.

Developer tools:

```bash
./.build/release/Unread --narrate   # silent: the voice's load, first audio and speed
./.build/release/Unread --extract   # print the sentences Unread would read from the front window
./.build/release/Unread --stats     # latency percentiles from your real use
```

## How it works

```
Sources/Unread/
  Hotkey.swift    ⌃ hold / tap / double-tap; cancels on chords, ⌃-click, ⌃-scroll
  AX.swift        Accessibility API helpers
  Document.swift  Finds readable text under the pointer and walks it sentence by sentence
  Session.swift   Synthesis pipeline, playback queue, highlight following
  Narrator.swift  The voice: Qwen3-TTS on the Neural Engine, streaming sentence by sentence
  Align.swift     Word timing by forced alignment of the voice's audio
  Audio.swift     Language detection, gapless AVAudioEngine playback
  Overlay.swift   Click-through highlight layer above every app
  Latency.swift   Per-reading timing log (~/Library/Logs/Unread/latency.jsonl) and --stats
  App.swift       Menu bar, interaction state machine
```

Text comes from the macOS Accessibility tree, not screenshots. Web content is read through text markers. WebKit and Chromium support different subsets of that API, so Unread sticks to the common ground: hit-test the element under the pointer, read a text window from there, split sentences with `NLTokenizer`, and step word by word to find each sentence's on-screen range.

## Known limitations

- English and French only. The word-by-word mark is timed from the audio in English and estimated in French.
- In Chrome, Arc and Dia a page's first couple of seconds are highlighted a block at a time, until the browser starts giving word positions.
- Code blocks and tables aren't read: a soft double tap marks them and the reading goes on.
- Apps that don't expose their text (Kindle, canvas apps) aren't supported.
- No download yet: you build it yourself, and it's signed for local use only (not notarized).

## Roadmap

- Floating mini-player pill, media keys and Now Playing
- "Design a voice" and "use my own voice"
- Notarized release, Homebrew cask

## Credits

- Qwen3-TTS: the voice, through [Gloam Voice Studio](https://github.com/TinyTrashLabs/gloam-voice-studio)'s Core ML runtime (vendored, see `Vendor/QwenANE`)
- [FluidAudio](https://github.com/FluidInference/FluidAudio): CoreML speech models for Apple devices (the word aligner)
- [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M): the first voice
- [Hex](https://github.com/kitlangton/Hex): the inspiration for the feel
