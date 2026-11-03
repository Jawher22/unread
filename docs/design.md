# Unread: design notes

Living document: why Unread exists, what we learned, what we decided and what's next. Update it when a decision changes.

## 1. Origin

- The author installed Readwise's reading app and found its text-to-speech eye-opening: a natural voice made reading genuinely pleasant.
- There was no equivalent for macOS that works across articles, books and everything else. Unread is the answer: free, open source, personal tool first.
- The quality bar is **Hex** ([kitlangton/Hex](https://github.com/kitlangton/Hex), Swift; [anomalyco/hex](https://github.com/anomalyco/hex), a Rust rewrite). Hex is "hold a key, talk, it pastes." Unread is the same idea in reverse: hold a key, point, it reads.

## 2. Landscape (researched 2026-11)

| Product | Gap |
| --- | --- |
| ElevenReader | Great voices, but no real desktop app |
| Speechify | Mac support, cloud-only, ~$29/month premium |
| Apple Spoken Content | Free and built in, but robotic and selection-driven |
| NaturalReader, Speechie, Speak My Text | Document- or selection-centric, no in-place experience |
| [ReadRead](https://github.com/aaajiao/readread) | Closest open-source project: a menu-bar app on Kokoro with a bundled Python server. Unread differs in being native Swift, using point-and-hold, and highlighting inside the source app |

## 3. What makes Hex feel fast (and why it isn't Rust)

From reading anomalyco/hex's source and its `docs/research/performance-2026-09-04.md`:

- **Inference dominates.** Hex uses `transcribe.cpp` (C++/ggml, a Metal encoder) running Parakeet. Rust only coordinates.
  - Metal encode: ~58 ms of ~65 ms for a 3 s clip.
  - A fresh model load is ~300 ms, so they never pay it at use time.
- **Speed comes from technique:**
  - a small model
  - models kept warm
  - work started before it's needed (`keep_warm`, preloaded sounds)
  - measuring tail latency, not just medians
- **Rust is for cross-platform** (Windows, Linux) and a GPU-drawn UI.
- The Swift original feels just as fast. For Unread, Swift + FluidAudio is the natural fit: direct calls into macOS APIs (AX, AVAudioEngine, NSPanel) and Neural Engine models.

## 4. Voice engine

Chosen: **Kokoro-82M via [FluidAudio](https://github.com/FluidInference/FluidAudio)** (CoreML, Neural Engine).

| Option | Notes |
| --- | --- |
| **Kokoro v3** (current, English) | ~30× real time, SSML/lexicon support, `predictedDurations` exposed (word timing possible). v3 is English/Japanese/Mandarin only |
| **Kokoro legacy, French** (current) | Works, but only one voice: `ff_siwis` |
| Pocket TTS (Kyutai, in FluidAudio) | Streams in 80 ms frames, voice cloning, 6 languages including French. Candidate for better French and for "read in my own voice" |
| Phonon 31m (in FluidAudio) | 103 English voices, Apache-2.0, built-in text normalizer |
| Qwen3-TTS, Chatterbox, OmniVoice ([speech-swift](https://github.com/soniqo/speech-swift), MLX) | Heavier (0.8–1.7B parameters), more expressive. Possible "premium voice" tier |
| Cloud (ElevenLabs, OpenAI, Cartesia) | Quality reference. Only ever an optional bring-your-own-key extra |

## 5. Interaction design

**Principle: the pointer is the cursor for listening.** No selection. The app infers *what* and *where* from what's on screen.

| Gesture | Behaviour |
| --- | --- |
| Hold ⌃ (≥0.22 s) + point | Paragraph under the pointer gets a preview outline (after 0.12 s, so taps don't flash) |
| Release | Read from that paragraph to the end |
| Tap ⌃ while idle | Read from the first visible paragraph ("continue from where I am") |
| Tap ⌃ while reading | Pause / resume |
| Double-tap ⌃ | Stop |
| Hold + point while reading | Jump there. Seeking is pointing |

Details that make it feel right:

- **Chords cancel.** ⌃C, ⌃-click (right-click), ⌃-scroll (zoom) or ⌃ added to an existing chord never trigger reading.
- **The highlight lives in the source app.** A click-through overlay draws a soft yellow box on the current sentence and glides between sentences. There is no reader window.
- **Follow, but don't fight.** It auto-scrolls while you're following along. If you scroll away it stops dragging you back, and resumes once the sentence is visible again.
- **Tied to the document, not the window.** Switching apps doesn't stop playback.
- **Language is automatic.** English or French is chosen per sentence and is sticky: short or ambiguous sentences keep the current language.
- **Prewarm on key-down.** The audio engine starts while the key is held, and the release triggers immediate synthesis.

Planned UX (not built yet):
- floating mini-player pill (title, waveform, speed; scroll on it to change speed)
- media keys, AirPods controls and Now Playing
- a "↩ back to voice" chip when you've scrolled away

## 6. Technical findings: reading text from any app

Text comes from the macOS Accessibility (AX) tree, not screenshots.

**WebKit (Safari, WebKit views)** supports the full text-marker API: position → marker, sentence/paragraph navigation, bounds.

**Chromium/Electron (Chrome, Dia, Arc, T3 Code, Claude, VS Code…)** is a subset, verified on this machine:

- **Works:**
  - `AXTextMarkerRangeForUIElement`
  - `AXParagraphTextMarkerRangeForTextMarker`
  - `AXNext{Word,Line,Paragraph}End…`
  - `AXNextTextMarkerForTextMarker`
  - `AXStringForTextMarkerRange`
  - `AXBoundsForTextMarkerRange`
  - `AXUIElementForTextMarker`
- **Returns no value:**
  - `AXTextMarkerForPosition`
  - `AXStartTextMarkerForBounds`
  - `AXNextSentenceEndTextMarkerForTextMarker`
- **Quirks:**
  - Each wrapped *line* is reported as a "paragraph".
  - Text across separate blocks is concatenated with no separator ("TitleBody…").
  - Bounds are sometimes viewport-sized (bogus) or block-level rather than sentence-level.
  - The tree must be enabled per process with `AXManualAccessibility` (avoid `AXEnhancedUserInterface`).

**Resulting algorithm (`WebDocument`), common subset only:**

1. Hit-test the element under the point → the start of its text range → the paragraph start.
2. From the cursor, read a ~600-character window extended paragraph by paragraph. The window always starts exactly at the cursor, so no character is lost; stepping with `NextTextMarker` past a boundary used to drop the first letter.
3. Record block breaks: places where consecutive "paragraphs" don't share a close ancestor. Inline spans (bold, links, `code`) share the paragraph one or two levels up.
4. `NLTokenizer` finds the first sentence. A block break always ends it.
5. Step word by word (`AXNextWordEnd…`) until the range covers the sentence. That range is used for highlighting.
6. First visible paragraph when nothing is pointed at: `AXStartTextMarkerForBounds`, or else scan the viewport downward from 12% of its height (to skip toolbars).

**Native text views (`NativeDocument`):**
- `AXValue`, `AXRangeForPosition`, `AXBoundsForRange`, `AXVisibleCharacterRange`, with sentences from `NLTokenizer`.
- No auto-scroll yet: the only scroll mechanism is moving the caret, which would hijack the user's selection.

## 7. Measurements (M-series MacBook, macOS 27)

| What | Result |
| --- | --- |
| Kokoro load, already compiled | 0.81 s English, 0.85 s French |
| First launch of a new binary | ~13 s (CoreML compile, one time) |
| First run, model download | 359 MB; ~3.5 min English, ~5 min French on the author's network |
| Synthesis | 76 ms for 2.2 s of audio · 110 ms for 3.4 s · 240 ms for 8.3 s · French 151 ms for 5.3 s (29–35× real time) |
| Find the document in the front window | ~25 ms |
| Extract 12 sentences with bounds | ~70–110 ms |

**Expected time to first audio:** ~150–300 ms after release, dominated by synthesizing the first sentence. Not yet measured with real hotkey use; the app logs it as `[unread] first audio … ms after release`.

## 8. Next steps (prioritized)

1. **Real-use feedback** on the author's articles: latency, voice, highlight tracking.
2. **Main-content extraction.** It currently reads everything (X timeline handles, timestamps, "Post" buttons). Options:
   - a Readability-style heuristic over the AX tree (roles such as `AXArticle` / `AXLandmarkMain`, text density)
   - fetching the URL and running Readability, then mapping back to on-screen text
3. **Faster first audio.** Synthesize the opening clause of a long first sentence separately.
4. **Mini-player pill, media keys, Now Playing**, and handling audio-route changes (pause when headphones are removed).
5. **Sentence-level highlight in Chromium.** Try `AXBoundsForRange` on the `AXStaticText`, or per-line ranges.
6. **Proper `.app` bundle:** signed, its own Accessibility permission, launch at login, settings for hotkey/voice/speed.
7. **Voices:** A/B Kokoro voices vs Pocket TTS vs Phonon. Better French (Pocket TTS). Later, voice cloning.
8. **More sources:** PDF (Preview's AX tree; strip headers, page numbers, hyphenation), EPUB, OCR fallback via ScreenCaptureKit + Vision (opt-in, needs Screen Recording permission).
9. **Word-level highlight** from Kokoro's `predictedDurations`.
10. **Export / listen later:** MP3 or M4B, or a private podcast feed.
11. **Text normalization:** numbers, abbreviations, code blocks, URLs (Phonon's normalizer, Kokoro SSML/lexicon).

## 9. Open decisions

- License (MIT like Hex is the likely default).
- GitHub repo: create `unread` under the author's account, public or private.

## 10. Naming

Picked **Unread**: "your unread pile, read to you." You *un*-read it by listening. It fits the author's naming style: funny, sticky everyday words with a double meaning (their previous product is **Crumbs**).

Rejected along the way:
- animals: Hoot, Purr, Coo, Wren, Mynah, Parrot
- foreign words: Kiku, Mimi, Lismo
- already used: Bulbul (an OSS macOS dictation app), Rawi and Hakawati (Arabic audiobook apps), Lilt (a translation company)
- earlier favourites: Readme (unsearchable; ReadMe the company), Toast

Known clash: an old iOS RSS reader was also called Unread (not on GitHub).
