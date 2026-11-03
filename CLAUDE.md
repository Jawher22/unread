# Unread

macOS menu-bar app that reads on-screen text aloud with an on-device natural voice. Point at a paragraph, hold ⌃, listen. Free, open source, personal tool first.

**Read [`docs/design.md`](docs/design.md) before making product or architecture decisions.** It holds the research, the interaction design and its reasoning, technical findings, measurements and the prioritized next steps.

## Non-negotiables

- **Effortless is the product.** The user never selects text. Every feature should reduce effort, not add a step.
- **Hotkey is ⌃ Control.** The author runs Hex (voice dictation) on ⌥ Option, so never use Option.
- **Local-first.** On-device TTS by default. Cloud voices could be an optional bring-your-own-key extra, never the default.
- **Fast feel, the Hex playbook:** models stay warm, work starts on key-down, synthesis runs ahead of playback. Measure latency; don't guess.
- **Languages:** English first, French second, others later.

## Build, run, test

```bash
swift build -c release                # Swift 6.2 toolchain; macOS 15+, Apple Silicon
./.build/release/Unread               # menu-bar app; needs Accessibility permission
./.build/release/Unread --bench       # silent: model load + synthesis timings
./.build/release/Unread --extract     # print sentences + bounds Unread would read from the front window
./.build/release/Unread --stats       # p50/p95 latency from ~/Library/Logs/Unread/latency.jsonl
```

```bash
scripts/bundle.sh [--install]         # signed Unread.app in build/ (and ~/Applications); logs: ~/Library/Logs/Unread/unread.log
```

- The bundle is signed with the first "Apple Development" identity so the Accessibility grant survives rebuilds. Dev modes work from the bundle too: `build/Unread.app/Contents/MacOS/Unread --extract`.

- The first clean build compiles FluidAudio (2–15 min depending on cache). After that, rebuilds take seconds.
- Never copy `.build` between folders: Swift's precompiled headers bake in absolute paths and the build fails.
- The first launch of a new binary spends ~13 s preparing the CoreML models. After that, load is ~0.8 s.
- Models (~360 MB) are cached in `~/.cache/fluidaudio`.
- `scripts/extract-fixture.sh fixtures/pages/<page>.html` checks extraction in both engines (WebKit and Electron windows that never take focus) against `<page>.expected.txt`. Run it before and after any change to `Document.swift`. See `fixtures/README.md`.
- `--extract` and `--bench` are the safe ways to verify changes without hijacking the user's keyboard or playing audio. Ask before launching the full app or playing sound on the user's machine.

## Code map

`Sources/Unread/`: `Hotkey` (⌃ hold/tap/double-tap, chord cancel) · `AX` (Accessibility helpers) · `Document` (find text under the pointer, walk sentences) · `Session` (synthesis pipeline, playback queue, highlight following) · `Audio` (Kokoro EN v3 + FR legacy, language detection, AVAudioEngine) · `Overlay` (click-through highlight panels) · `Latency` (per-reading timing log + `--stats`) · `App` (menu bar, interaction state machine) · `main` (entry point + dev modes).

## Hard-won constraints (details in docs/design.md)

- **Chromium/Electron AX is a subset of WebKit's.** These fail in Chromium:
  - `AXTextMarkerForPosition`
  - `AXStartTextMarkerForBounds`
  - `AXNextSentenceEndTextMarkerForTextMarker`

  These work in both engines:
  - element hit-testing + `AXTextMarkerRangeForUIElement`
  - paragraph ranges and word/char stepping
  - `AXStringForTextMarkerRange` and `AXBoundsForTextMarkerRange`

  `WebDocument` deliberately uses only this common subset. Keep it that way.
- Chromium reports each **wrapped line** as a paragraph and joins blocks with **no separator**. That's why sentences are cut from a ~600-character window and block breaks are detected via a shared ancestor.
- Chromium sometimes returns viewport-sized bounds. Treat those as "no bounds".
- **Markers must be anchored to a text leaf (`AXStaticText`).** A marker taken from a container's range (the web area, a hit-tested message block) keeps that anchor through every navigation call, and Chromium then answers every bounds query with the container's box. Hit-test results are resolved down to the leaf under the point (`WebDocument.textLeaf`).
- **Chromium measures a range precisely only if both ends are inside a leaf.** Sentence bounds are therefore the union of per-word boxes, dropping words that come back taller or wider than a word can be and re-measuring those from a few characters in.
- **Block breaks come from roles, not hop counts:** static text, links, list markers and `…StyleGroup` subroles (code, strong, emphasis) are inline; anything else is a block. Both engines expose the same structure.
- Enable Chromium's tree with `AXManualAccessibility` only. Never set `AXEnhancedUserInterface`: it breaks window animations.
- Kokoro v3 (fast ANE path) supports English, Japanese and Mandarin only. French uses the legacy pipeline with a single voice, `ff_siwis`.
