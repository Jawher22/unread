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

The highlight is drawn *on top of the app you're already in* (Safari, Chrome, Arc, Dia, Electron apps, TextEdit, Notes…). There is no separate reader window. If you scroll away it stops following you; scroll back and it picks up again.

English and French are detected per sentence and switched automatically.

## Why it's fast

Same playbook as [Hex](https://github.com/kitlangton/Hex), in reverse:

- **Small model on the Neural Engine.** [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s CoreML port: ~25–35× real time on Apple Silicon.
- **Always warm.** Models load once at launch (under 1 s after the first download) and stay resident.
- **Work starts on key-down.** The audio device opens and the target paragraph is resolved while you're still holding the key.
- **Pipelined.** Three sentences are synthesized ahead of the one playing, so playback is gapless.

Measured on an M-series MacBook: 80–250 ms to synthesize a sentence, ~25 ms to find the document, ~70 ms to extract 12 sentences with their on-screen positions.

## Requirements

- Apple Silicon Mac, macOS 15 or later
- Accessibility permission (to read on-screen text and watch the hotkey)
- ~360 MB of models, downloaded on first launch to `~/.cache/fluidaudio`

## Build and run

```bash
scripts/bundle.sh --install   # builds, signs and installs ~/Applications/Unread.app
open ~/Applications/Unread.app
```

The first build compiles FluidAudio (~15 min). On first launch, grant Accessibility when prompted (System Settings → Privacy & Security → Accessibility); Unread picks the grant up without a relaunch. It turns on **Launch at Login** the first time it runs; toggle it from the menu. Logs go to `~/Library/Logs/Unread/unread.log`.

The script signs with your first "Apple Development" identity (or `$UNREAD_SIGN_IDENTITY`). A stable identity means the Accessibility grant survives rebuilds; without one it falls back to ad-hoc signing and you'll re-grant after every build.

For quick iteration you can also run the bare binary from a terminal that has Accessibility permission: `swift build -c release && ./.build/release/Unread`.

Developer tools:

```bash
./.build/release/Unread --bench     # silent: model load + synthesis timings
./.build/release/Unread --extract   # print the sentences Unread would read from the front window
```

## How it works

```
Sources/Unread/
  Hotkey.swift    ⌃ hold / tap / double-tap; cancels on chords, ⌃-click, ⌃-scroll
  AX.swift        Accessibility API helpers
  Document.swift  Finds readable text under the pointer and walks it sentence by sentence
  Session.swift   Synthesis pipeline, playback queue, highlight following
  Audio.swift     Kokoro voices (EN v3 + FR), language detection, gapless AVAudioEngine playback
  Overlay.swift   Click-through highlight layer above every app
  App.swift       Menu bar, interaction state machine
```

Text comes from the macOS Accessibility tree, not screenshots. Web content is read through text markers. WebKit and Chromium support different subsets of that API, so Unread sticks to the common ground: hit-test the element under the pointer, read a text window from there, split sentences with `NLTokenizer`, and step word by word to find each sentence's on-screen range.

## Known limitations

- Reads everything in the page, including navigation, timestamps and buttons. Article-only extraction is next.
- In Chromium-based apps the highlight is sometimes block-level instead of sentence-level.
- Native text views don't auto-scroll yet.
- PDFs, EPUBs and apps that don't expose text (Kindle, canvas apps) aren't supported yet.
- Signed for local use only; not notarized yet.

## Roadmap

- Main-content extraction (skip navigation and other page chrome)
- Floating mini-player pill, media keys and Now Playing
- Faster first audio (synthesize the opening clause first)
- More voices (Pocket TTS, voice cloning), better French
- PDF and EPUB, OCR fallback
- Notarized release, Homebrew cask

## Credits

- [FluidAudio](https://github.com/FluidInference/FluidAudio): CoreML speech models for Apple devices
- [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M): the voice
- [Hex](https://github.com/kitlangton/Hex): the inspiration for the feel
