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
| [Sotto](https://github.com/Shreysid/Sotto) | Native menu-bar app on the same stack (Kokoro via FluidAudio/CoreML). Selection + shortcut, no in-place highlight |
| [aloud-tts](https://pypi.org/project/aloud-tts) | MIT, Kokoro on MLX, select text + ⌃⌥S. Selection-driven |

**What this means (2026-11-03):** the voice stack is a commodity; anyone can wire FluidAudio up in a weekend. Unread's edge is *no selection + highlight in the source app + follow-scroll*, and all three depend on extraction quality. Extraction is the product.

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
| Pocket TTS (Kyutai, in FluidAudio) | Streams (~80 ms to first audio; Kokoro doesn't stream), voice cloning, 6 languages. French exists only as the heavier 24-layer pack. Candidate for better French and for "read in my own voice" |
| Phonon 31m (in FluidAudio) | 103 English voices, Apache-2.0, built-in text normalizer |
| Qwen3-TTS, Chatterbox, OmniVoice ([speech-swift](https://github.com/soniqo/speech-swift), MLX) | Heavier (0.8–1.7B parameters), more expressive. Possible "premium voice" tier |
| Cloud (ElevenLabs, OpenAI, Cartesia) | Quality reference. Only ever an optional bring-your-own-key extra |

## 5. Interaction design

**Principle: the pointer is the cursor for listening.** No selection. The app infers *what* and *where* from what's on screen.

| Gesture | Behaviour |
| --- | --- |
| Hold ⌃ (≥0.22 s) + point | Paragraph under the pointer gets a preview outline (after 0.12 s, so taps don't flash) |
| Release | Read from that paragraph to the end |
| Tap ⌃ while idle | Nothing (an aborted chord or stray tap must never start speaking) |
| Double-tap ⌃ while idle | Read from the first visible paragraph ("continue from where I am") |
| Tap ⌃ while reading | Pause / resume |
| Double-tap ⌃ while reading | Stop, with the chime |
| Reaching the end of the content | Soft chime, then stop |
| Hold + point while reading | Jump there. Seeking is pointing |

Details that make it feel right:

- **Chords cancel.** ⌃C, ⌃-click (right-click), ⌃-scroll (zoom) or ⌃ added to an existing chord never trigger reading.
- **The highlight lives in the source app.** A click-through overlay draws a soft yellow box on the current sentence and glides between sentences, with a stronger mark on the word being spoken (#20). There is no reader window. How it looks is a setting (mark: fill, underline, outline, trail or none; motion: hop, glide, stretch, flow or sweep; strength; sentence box; color; lead), chosen in Settings over a live demo drawn by the same renderer as the overlay.
- **Follow, but don't fight.** It auto-scrolls while you're following along. If you scroll away it stops dragging you back, and resumes once the sentence is visible again.
- **Tied to the document, not the window.** Switching apps doesn't stop playback.
- **Language is automatic.** English or French is chosen per sentence and is sticky: short or ambiguous sentences keep the current language.
- **Prewarm on key-down.** The audio engine starts while the key is held, and the release triggers immediate synthesis.

**Primary use is read-along** (decided 2026-11-03): eyes on the screen, following the highlight. Highlight accuracy and time to first audio are what get noticed. Listen-away is secondary and gets only the minimum: pause when headphones are removed, media keys / AirPods play-pause.

Planned UX (not built yet):
- media keys, AirPods play/pause, pause on audio-route change (the listen-away minimum)
- a "↩ back to voice" chip when you've scrolled away
- deferred: floating mini-player pill and Now Playing (they serve listen-away, which is secondary)
- dropped: export / listen later (MP3, M4B, podcast feed): not wanted

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

**More findings (2026-11-03, from the fixture hosts):**
- Markers inherit their *anchor*. One derived from a container's range (web area, message block) stays anchored to it, and Chromium returns that container's box for any range. Starting from a text leaf fixes it: all later markers stay leaf-anchored.
- Even leaf-anchored, Chromium returns an enclosing block's box when a range starts or ends on a leaf boundary (a new paragraph, after a final ".", the space before a wrap). Word-sized ranges are almost always inside a leaf.
- Both engines expose inline markup identically: `AXStaticText`, `AXLink`, `AXListMarker`, and `AXGroup` with `AXCodeStyleGroup` / `AXStrongStyleGroup` / `AXEmphasisStyleGroup` subroles. Paragraphs are plain `AXGroup`s, articles are `AXGroup/AXDocumentArticle`, lists `AXList/AXContentList`.
- `NLTokenizer` returns a lone leading `"\n"` as its own sentence; walking to cover it swallowed the next word (first word of every WebKit paragraph was lost).

**Reading scope (#10, 2026-11-03):** both engines expose page structure with the same roles/subroles: `AXLandmarkBanner` / `Navigation` / `Main` / `Complementary` / `ContentInfo` / `Region`, `AXDocumentArticle`, `AXSectionHeader`, `AXTimeGroup`. A `<pre>` is `AXPreformattedStyleGroup` in WebKit but a plain group around an `AXCodeStyleGroup` in Chromium. A figure is a small group holding an `AXImage` and the caption group. Visually hidden text: Chromium gives the text a ~1 px frame, WebKit gives its container 1 px (or, if the container isn't exposed, wraps the text one word per line into a ~40 px column). Chromium clips element frames to the nearest scrolling container (in T3 Code, the chat's own scroller), so text out of view is full width but 0–1 px tall; only narrow (~1 px wide) frames mean hidden. T3 Code's chat has no articles; messages sit in `AXLandmarkMain`, tool rows are `AXButton`s, speaker labels are headings (the assistant's is hidden), timestamps are bare text.

**Resulting algorithm (`WebDocument`), common subset only:**

1. Hit-test the element under the point → descend to the text leaf under it → the start of its text range → the paragraph start.
2. From the cursor, read a ~600-character window extended paragraph by paragraph. The window always starts exactly at the cursor, so no character is lost; stepping with `NextTextMarker` past a boundary used to drop the first letter.
3. Record block breaks: places where consecutive "paragraphs" sit in different blocks. The block is found by climbing past inline elements (static text, links, list markers, style groups).
4. `NLTokenizer` finds the first sentence, starting from the first visible character. A block break always ends it.
5. Step word by word (`AXNextWordEnd…`), never past the sentence's last visible character, then by characters for trailing punctuation. That range is the sentence.
6. Bounds: the union of the sentence's word boxes (implausible ones re-measured or dropped), cached per sentence; the 10 Hz refresh re-measures one word and shifts the cached box.
7. Scope: reading stays in the nearest article, else main area, around the start, and ends (with the chime) when a sentence falls outside it. Page chrome inside is skipped (landmarks, controls, code blocks, captions, hidden text, timestamps, short link rows), except a chrome container the user started in. Per-element answers are memoized per document (~30 ms per sentence on T3 Code).
8. First visible paragraph when nothing is pointed at: `AXStartTextMarkerForBounds`, or else scan the viewport downward from 12% of its height (to skip toolbars).

**Word highlight (#20, 2026-11-04):**
- *When:* `synthesizeDetailed` returns each phoneme token's duration (`predictedDurations`, 600 samples per frame) with its id. In both the English v3 and French legacy vocabularies, id 0 is BOS/EOS and id 16 the space, so runs between them are the spoken words. The voice's words don't map 1:1 to the page's: acronyms are spelled out ("API" → three words), French runs phrases together ("tout le monde" → one), and numbers and symbols are expanded ("$45.99" → five words, in `normalizedText`). So it takes two alignments: `normalizedText` words → spoken words by length (Gale–Church style, calibrated per sentence), then display words → `normalizedText` words by spelling (edit distance). A word that doesn't match exactly starts where the previous word's speech ends. `--words` prints both for any sentence.
- *Where:* `lines(of:)` already measures every word to build the line boxes; those boxes are kept per sentence and matched to the display words by their letters (`WordBoxes.assign`). Native text views measure each whitespace-separated word once per sentence. The session moves the cached word boxes by as much as the lines move (scrolling) and re-measures only when the text reflows. Chromium browsers without text positions have no word boxes, so they keep the whole-block highlight with no word mark.
- *Clock:* the player's own sample timeline (`AVAudioPlayerNode.playerTime`), minus the output's presentation latency, against where each sentence was scheduled. That timeline keeps running when the node runs out of audio (so a sentence scheduled late starts at "now", not at the end of the last one), reports nil while paused (the mark stays put) and restarts at 0 after `stop`. `AudioClock` projects it to each display frame's time and smooths out its ~10 ms render-cycle steps.
- *Motion (polish pass, 2026-11-04):* the whole highlight is drawn frame by frame from a display link (`DisplayTicker`, 120 Hz on ProMotion); nothing uses Core Animation's implicit animations, which had made glides land ~90 ms late, the trail pop, line changes jump and the sentence box lag behind scrolling. The word mark is a pure function of the voice's position (`WordMark.frame`). Motions, reworked after trying them (a 90–120 ms glide was indistinguishable from a hop; a spline that never rested on a word felt like a sliding cursor, not like the playground): *hop* jumps; *glide* slides over 240 ms, 40% there as the word is heard; *stretch* moves the front edge to the next word first and the back edge after (inchworm); *flow* is the playground's continuous motion, smoothstep from each word to the next over the time between them, so it rests on a word as it's heard; *sweep* fills each word in from the left while it's spoken (karaoke) as the previous one fades. Line changes cross-fade with a 6 pt carriage-return drift instead of sweeping back across the text (sweep needs none); the next sentence's first word comes from where the last one ended. A new sentence wipes in line by line while the old one retracts toward it; the same sentence measured again (scrolling) moves in place, instantly. Blue, green and pink are drawn lighter than yellow so every color has the same weight. `--highlight-frames` renders any style as a frame strip or GIF to review motion.

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

**`--extract` on a T3 Code window (2026-11-03):** 12 sentences in 101 ms, but **9 of 12 had no bounds**, so read-along would show no highlight most of the time in Electron. Inline `code` spans were also split into separate sentences (`sameBlock` treats the span as a new block).

**Main-thread stalls (#12, 2026-11-03),** measured by `--simulate` (a 10 ms main-thread timer during 20 s of muted reading on T3 Code): before moving AX work off the main thread, worst stall ~120 ms with 1–3 stalls over 50 ms; after, worst 33–39 ms and none over 50 ms.

**Word highlight (#20, 2026-11-04):** on the fixture pages every spoken word gets a box in both engines (98% of display words; the rest are list bullets). In `--simulate` the mark moves 0–20 ms after each word's due time (one 50 Hz tick). Synthesis time is unchanged (`--bench`: 31–35× real time).

**Expected time to first audio:** ~150–300 ms after release, dominated by synthesizing the first sentence. Not yet measured with real hotkey use; the app logs it as `[unread] first audio … ms after release`.

## 8. Next steps (prioritized, revised 2026-11-03)

Goal: perfect it for the author's own read-along use first. Public release comes later.

Tracked as [GitHub issues](https://github.com/Jawher22/unread/issues), one milestone per phase below. Open policy questions are the issues labelled `question`.

**Phase 0: make daily use possible (do first)**
1. **`.app` bundle + launch at login.** Sign it with a stable local identity so the Accessibility grant survives rebuilds (ad-hoc signatures change every build). No notarization yet.
2. **Interaction changes:** idle tap does nothing, idle double-tap reads from the first visible paragraph, soft chime at the end.
3. **Synthesize while the key is held.** The aim target is already known during the hold, so synthesize its first sentence speculatively and throw it away if the pointer moves. Log key-up → first audio (p50/p95) to a local file.
4. **Use it for at least 3 days** on real reading and keep a friction log. Re-rank everything below from that log.

**Phase 1: read-along quality** (done so far: #7, #9, #10 structural layer, per-line highlight, fixture hosts)
5. **Chromium bounds.** Fix the missing bounds (9/12 in T3 Code) and the block-level ones: per-line ranges, a union of word ranges (`walk()` already visits every word), or `AXBoundsForRange` on the static text.
6. **Inline code must not split sentences.** Revisit `sameBlock` for code, links and emphasis.
7. **Fixture corpus + scorer.** Saved real pages (Anthropic and OpenAI engineering posts, other technical blogs, a T3 Code LLM response, Wikipedia, a TextEdit doc). For each, list the expected sentences and score `--extract` against them, so heuristics stop silently regressing.
8. **Reading scope ("skip junk, know the end").** Layered:
   - *Structural:* scope reading to the nearest article / main landmark around the start point. Skip navigation, sidebars, footers, banners, buttons and link-dense lines. Every role used must be confirmed in both WebKit and Chromium before relying on it.
   - *Heuristic:* text and link density (Readability-style) over the AX subtree, for poorly marked-up pages.
   - *Model (optional, later):* Apple's on-device Foundation Models to classify a block as content or chrome. It runs during look-ahead, so it stays off the first-audio path. Needs Apple Intelligence and macOS 26+, so it can only be an enhancement.
   - The skipping matters more than the ending: junk *inside* the article (captions, "Share", related-article cards, handles, timestamps) is what hurts read-along.
9. **Move AX work off the main thread.** The 30 Hz aim loop, the 10 Hz highlight refresh and `walk()` (two AX calls per word) stall the hotkey and overlay on slow Chromium pages.
10. **Auto-scroll in native text views.**
11. **Faster first audio for long first sentences** (synthesize the opening clause separately) if step 3 isn't enough.
12. **Apply speed and voice changes immediately:** drop and re-synthesize the look-ahead queue.
13. **Highlight quality: follow the voice word by word** (#20, moved up from Phase 3 on 2026-11-04). Mark the spoken word inside the sentence highlight. Time it with Kokoro's `predictedDurations` (both engines already return them from `synthesizeDetailed`), map onto the word boxes `walk()` and `lines(of:)` already measure, and drive it from the player's sample clock. Chromium browsers without text positions keep the paragraph fallback.

**Phase 2: sources the author reads**
14. **PDF and EPUB. Probe before building:** run `--extract` on an EPUB in Apple Books (WebKit, may already work), a PDF in Chrome's viewer (PDFium exposes an AX tree) and a PDF in Preview (PDFKit). Then fix what's missing: page headers, page numbers, hyphenation. OCR via ScreenCaptureKit + Vision is the last resort.
15. **LLM responses still streaming** (T3 Code, Claude): at the end of the text, wait briefly for it to grow before finishing.
16. **Text normalization:** numbers, abbreviations, URLs, identifiers in inline code; a policy for code blocks (default: skip `<pre>` blocks, read inline code) and tables.

**Phase 3: polish**
17. Listen-away minimum: media keys, AirPods, pause on route change.
18. Voices: A/B Kokoro voices vs Pocket TTS vs Phonon. Better French via Pocket TTS 24-layer later; `ff_siwis` is good enough for now.

**Later: public release**
- Signing and notarization, first-run onboarding, model download progress, Homebrew cask, MIT license.

**Dropped:** export / listen later.

## 9. Open decisions

- Code blocks in technical posts: **skipped silently** for now (#24 default, implemented in #10). Revisit if it's confusing in use.
- X / timelines: with article scope, each post is its own article, so reading **stops after the post** (with the chime). Continuing to the next post is still open (#25).
- Tables: read row by row, or skip?
- Languages beyond French: none planned. Arabic would need a different engine, since Kokoro has none.
- **Sentence highlight in Chromium browsers (Aside, Chrome, Arc, Dia):** they give no text positions to Unread (no inline text boxes; `AXManualAccessibility` is Electron-only), so highlights fall back to the whole paragraph. Setting `AXEnhancedUserInterface` on the browser (what VoiceOver does) would give exact sentence boxes, at the cost of the window-animation side effects that made us ban it, plus some browser overhead. Opt-in per app? **Tested on Aside 1.0.1022 (2026-11-04): it refuses the flag** (setting it returns −25208, not implemented; it reads back 0), and text positions stay zero-size, so neither a brief flip nor an opt-in can work there. **What works: Chromium's own "Text metrics" mode** (formerly "Inline text boxes") on `chrome://accessibility`. Ticking it gave real text and word boxes in Aside at once (0×0 → 172×21). It lasts until the browser quits. To make it stick, launch the browser with `--force-renderer-accessibility=complete` (untested, and costs the browser some memory), or have Unread tell the user to tick it when a page gives no text positions.
- License (MIT like Hex is the likely default).
- When to make the repo public. It's currently private at https://github.com/Jawher22/unread (created 2026-11-03). Not before the author has used it daily for real reading.

## 10. Naming

Picked **Unread**: "your unread pile, read to you." You *un*-read it by listening. It fits the author's naming style: funny, sticky everyday words with a double meaning (their previous product is **Crumbs**).

Rejected along the way:
- animals: Hoot, Purr, Coo, Wren, Mynah, Parrot
- foreign words: Kiku, Mimi, Lismo
- already used: Bulbul (an OSS macOS dictation app), Rawi and Hakawati (Arabic audiobook apps), Lilt (a translation company)
- earlier favourites: Readme (unsearchable; ReadMe the company), Toast

Known clash: an old iOS RSS reader was also called Unread (not on GitHub).
