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
./.build/release/Unread --words ["sentence"]  # silent: when each word starts, as the voice times it
./.build/release/Unread --settings-snapshot out.png [seconds]  # render the Settings window off-screen (no screen recording needed)
./.build/release/Unread --highlight-frames out.png|out.gif [from] [to] [--style mark=tail,motion=flow] [--zoom x,y,w,h]  # the demo frame by frame, to review motion
```

```bash
scripts/bundle.sh [--install]         # signed Unread.app in build/ (--install: copy to ~/Applications and restart it); logs: ~/Library/Logs/Unread/unread.log
```

- The bundle is signed with the first "Apple Development" identity so the Accessibility grant survives rebuilds. Dev modes work from the bundle too: `build/Unread.app/Contents/MacOS/Unread --extract`.

- The first clean build compiles FluidAudio (2–15 min depending on cache). After that, rebuilds take seconds.
- Never copy `.build` between folders: Swift's precompiled headers bake in absolute paths and the build fails.
- The first launch of a new binary spends ~13 s preparing the CoreML models. After that, load is ~0.8 s.
- Models (~360 MB) are cached in `~/.cache/fluidaudio`.
- `scripts/extract-fixture.sh fixtures/pages/<page>.html` checks extraction in both engines (WebKit and Electron windows that never take focus) against `<page>.expected.txt`. Run it before and after any change to `Document.swift`. See `fixtures/README.md`.
- `--extract` and `--bench` are the safe ways to verify changes without hijacking the user's keyboard or playing audio. Ask before launching the full app or playing sound on the user's machine.

## Code map

`Sources/Unread/`: `Hotkey` (⌃ hold/tap/double-tap, chord cancel) · `AX` (Accessibility helpers, `AXWorker` queue) · `Document` (find text under the pointer, walk sentences) · `Session` (synthesis pipeline, playback queue, highlight following) · `Audio` (Kokoro EN v3 + FR legacy, language detection, AVAudioEngine) · `Highlight` (highlight style settings, word-mark logic, the layer renderer shared by the overlay and the Settings demo) · `Overlay` (click-through panels, one per screen) · `Settings` (Settings window with a live highlight demo) · `Words` (word timing from Kokoro durations, word boxes) · `Latency` (per-reading timing log + `--stats`) · `App` (menu bar, interaction state machine) · `main` (entry point + dev modes).

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
- **Chromium's hit test is unreliable** (in T3 Code it can return a 1 px button that doesn't contain the point). Use a hit only if it contains the point and holds text; otherwise descend from the web area by frame. Never anchor a marker to a container.
- **Chromium can switch its tree off again** (auto-disable), leaving the focused "window" as an `AXApplication` stub. `AXManualAccessibility` always reads back false, so `AX.enableTree` judges by tree health: on first contact it sets the flag only if no `AXWebArea` exists yet (setting it restarts the build), and later re-enables a stub tree at most every 10 s.
- **Highlights are per line** (`ReadableDocument.lines(of:)`), drawn as one shape; a single union box covers the neighbouring sentences.
- **Block breaks come from roles, not hop counts:** static text, links, list markers and `…StyleGroup` subroles (code, strong, emphasis) are inline; anything else is a block. Both engines expose the same structure.
- **Reading scope (#10):** reading stays in the nearest `AXDocumentArticle`, else `AXLandmarkMain`, and skips chrome inside it: nav/banner/footer/complementary landmarks, controls (buttons…), code blocks (WebKit `AXPreformattedStyleGroup`; Chromium a group whose only child is `AXCodeStyleGroup`), figure captions, visually hidden text, timestamps, short link rows. A chrome container the user started in is read. Judge a sentence by the leaf one character *inside* its end (the end marker sits on a boundary), climbing past Chromium's per-line `AXStaticText` boxes.
- **Chromium clips element frames to the nearest scrolling container** (T3 Code's chat, not just the viewport): text out of view comes back full width but 0–1 px tall. Never treat "flat" as hidden; visually hidden text is ~1 px *wide*. Text-marker bounds are not clipped. `fixtures/pages/scroller.html` guards this.
- **Pages rebuild their elements under you** (T3 Code re-renders messages while an agent works). Stale markers read as `""`. `WebDocument.relocate` finds the sentence's text in the new tree and rebuilds fresh leaf-anchored markers; `sentence(after:scope:)` uses it to keep walking. `fixtures/pages/rerender.html` (run with `--slow`) guards this.
- **All Accessibility work runs on `AXWorker` (#12), never the main thread.** Documents are confined to that serial queue: create and call them inside `AXWorker.shared.run { }`; the main actor only touches results (sentences, rects). Dev modes in `main.swift` may call documents directly because they're single-threaded. `--simulate` prints a main-thread stall meter.
- **The player gets one sentence at a time (#15):** a buffer on `AVAudioPlayerNode` can't be taken back. The next sentence is scheduled when the current one's speech is *consumed* (its 120 ms closing pause gives the slack for gapless playback); synthesized audio waits in the session, numbered, so a speed or voice change can redo it. `--simulate … --speed-change-at T` exercises this.
- **WebKit exposes embedded objects as U+FFFC ("￼")** (icon buttons, images) and its character step **stalls at them**, one object at a time. Treat "￼" as blank when tokenizing and measuring, step past objects with `step(past:)` (falls back to the next text leaf in document order), and never let `walk` jump to the window's end. `fixtures/pages/icons.html` guards this (modelled on raphaelsalaja.com, where Safari skipped the first three paragraphs).
- **Chromium browsers may give no text positions** (Aside; likely Chrome/Arc/Dia unless VoiceOver is on). `AXManualAccessibility` is Electron-only (browsers answer −25205, unsupported); their tree is built without inline text boxes, so every text-range bounds query returns a zero-size box while element frames are right. `WebDocument.probeTextGeometry` detects this once per page and highlights whole text blocks instead (`elementFrames`). Only `AXEnhancedUserInterface` would turn on inline text boxes, and it's banned below; see the open decision in docs/design.md.
- Enable Chromium's tree with `AXManualAccessibility` only. Never set `AXEnhancedUserInterface`: it breaks window animations.
- **Word highlight (#20) needs two alignments.** The voice's words aren't the page's: acronyms are spelled out ("API" → 3 words), French merges phrases ("tout le monde" → 1), numbers expand ("$45.99" → 5). Kokoro token id 0 is BOS/EOS and 16 is the space in both vocabularies. Match `normalizedText` to spoken words by length, then display words to `normalizedText` by spelling (`WordTiming`). Check with `--words`.
- **The mark follows `AVAudioPlayerNode`'s timeline, not a timer.** That timeline keeps running when the node runs dry, reports nil while paused, and restarts at 0 on `stop`; `Player.claim` accounts for all three. Subtract the output's presentation latency (Bluetooth). The mark is a pure function of that position (`WordMark.frame`), drawn every display frame; don't hand its motion to Core Animation's implicit animations.
- Kokoro v3 (fast ANE path) supports English, Japanese and Mandarin only. French uses the legacy pipeline with a single voice, `ff_siwis`.
