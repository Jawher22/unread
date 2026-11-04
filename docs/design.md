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

**Text layer (#11, 2026-11-05),** from the real-page corpus. Most junk the structural rules missed has no role at all, so it's judged by its text, Readability-style, over the AX subtree Unread already walks (never by fetching the page):
- *The unit is the block, not the sentence.* A sentence is judged by the block its last leaf is in: a paragraph, heading, list item or cell. WebKit drops plain `<div>`s, so on Cloudflare the byline links, the tag row and the paragraphs are all children of the `<article>`, and on simonwillison.net every block of the page, sidebar included, is a child of the web area. Where a block holds blocks *and* inline content, the unit is the run of inline siblings between two blocks. Each unit is measured once: words, link density (citation markers aren't links), sentence ends (".", "?", "!", ":", ";" before a space), whether it ends like a sentence, and its frame's x-range (Chromium clips frames to scroll containers vertically, never horizontally).
- *Main text* starts at the first paragraph at or after the start: a block that reads as a sentence, isn't a heading, list item or cell, and isn't in the article's `<header>`, a `<figure>` or a form (Chromium shows a `<form>` as a plain group; the text field beside the text gives it away). Its x-range is the article's column.
- *Before it* (the title is the start), only headings, list items and sentences are read: bylines, "12 MINUTE READ", "Published / Team / Topics", "Listen to article 7:53", Wikipedia's tagline and its notice box (sentences, but more than half links) are skipped. The article's `<header>` is skipped whole except its headings ("This post is also available in…" is a sentence).
- *After it,* a block that isn't a sentence, or sits outside the column, ends the reading when no paragraph follows in scope (or a list that reads as prose: footnotes, with seven words or more per sentence and few links; a reference list is fragments like "Coast Press." and linked titles). That's the first tag row, "Discuss online", "Announcement contributors", "Keep reading", "More recent articles", the sidebar column of a page with no landmarks, "See also". If no text at all follows, the block is the article's last line and is read (a chat's last message, "All tests pass"). The lookahead passes over chrome, headings and tables whole and stops at the next paragraph, so mid-article it costs a few calls; only hits are memoized (a chat grows).
- *Furniture:* a heading speaks its own leaves' text, without a symbol-only link ("#"), so WebKit's hidden "Copy link" tooltip (rendered, `aria-hidden`, in the range string but in no leaf) and Wikipedia's "edit" beside the heading go; a sentence of only a heading row's links is skipped. A short line ending in a separator and links ("How web bloat impacts users with slow connections | Patreon") drops the separator and links. The spoken text, the highlight and the scope verdict all use what's left.
- *Link rows* (#52) are short, at least 60% links, and don't end like a sentence; a list item that is one link ("• The Claude Agent SDK;", "• AT-SPI") is content.
- *Hidden link hints:* "(opens in a new window)" is clipped with `clip-path`, and its text frame is full size in both engines, so geometry can't tell. It's removed by its idiom, like citation markers ("[who?]" now too).
- *Figures:* both engines give a `<figure>` the role description "figure" (localized by the browser; English and French say "figure"). Chromium drops a decorative `alt=""` image, so Anthropic's captions came without an image beside them; a caption in a figure that isn't a sentence is skipped.

**Resulting algorithm (`WebDocument`), common subset only:**

1. Hit-test the element under the point → descend to the text leaf under it → the start of its text range → the paragraph start.
2. From the cursor, read a ~600-character window extended paragraph by paragraph. The window always starts exactly at the cursor, so no character is lost; stepping with `NextTextMarker` past a boundary used to drop the first letter.
3. Record block breaks: places where consecutive "paragraphs" sit in different blocks. The block is found by climbing past inline elements (static text, links, list markers, style groups).
4. `NLTokenizer` finds the first sentence, starting from the first visible character. A block break always ends it.
5. Step word by word (`AXNextWordEnd…`), never past the sentence's last visible character, then by characters for trailing punctuation. That range is the sentence.
6. Bounds: the union of the sentence's word boxes (implausible ones re-measured or dropped), cached per sentence; the 10 Hz refresh re-measures one word and shifts the cached box.
7. Scope: reading stays in the nearest article, else main area, around the start, and ends (with the chime) when a sentence falls outside it. Page chrome inside is skipped (landmarks, controls, code blocks, captions, hidden text, timestamps, short link rows), except a chrome container the user started in. Per-element answers are memoized per document (~30 ms per sentence on T3 Code). Then the text layer (#11, above): metadata before the article's first paragraph is skipped, the first non-sentence block after its last paragraph ends the reading, and headings and title lines lose their furniture.
8. First visible paragraph when nothing is pointed at: `AXStartTextMarkerForBounds`, or else scan the viewport downward from 12% of its height (to skip toolbars).

**Word highlight (#20, 2026-11-04):**
- *When:* `synthesizeDetailed` returns each phoneme token's duration (`predictedDurations`, 600 samples per frame) with its id. In both the English v3 and French legacy vocabularies, id 0 is BOS/EOS and id 16 the space, so runs between them are the spoken words. The voice's words don't map 1:1 to the page's: acronyms are spelled out ("API" → three words), French runs phrases together ("tout le monde" → one), and numbers and symbols are expanded ("$45.99" → five words, in `normalizedText`). So it takes two alignments: `normalizedText` words → spoken words by length (Gale–Church style, calibrated per sentence), then display words → `normalizedText` words by spelling (edit distance). A word that doesn't match exactly starts where the previous word's speech ends. `--words` prints both for any sentence.
- *Where:* `lines(of:)` already measures every word to build the line boxes; those boxes are kept per sentence and matched to the display words by their letters (`WordBoxes.assign`). Native text views measure each whitespace-separated word once per sentence. The session moves the cached word boxes by as much as the lines move (scrolling) and re-measures only when the text reflows. Chromium browsers without text positions have no word boxes, so they keep the whole-block highlight with no word mark.
- *Clock:* the player's own sample timeline (`AVAudioPlayerNode.playerTime`), minus the output's presentation latency, against where each sentence was scheduled. That timeline keeps running when the node runs out of audio (so a sentence scheduled late starts at "now", not at the end of the last one), reports nil while paused (the mark stays put) and restarts at 0 after `stop`. `AudioClock` projects it to each display frame's time and smooths out its ~10 ms render-cycle steps.
- *Motion (polish pass, 2026-11-04):* the whole highlight is drawn frame by frame from a display link (`DisplayTicker`, 120 Hz on ProMotion); nothing uses Core Animation's implicit animations, which had made glides land ~90 ms late, the trail pop, line changes jump and the sentence box lag behind scrolling. The word mark is a pure function of the voice's position (`WordMark.frame`). Motions, reworked after trying them (a 90–120 ms glide was indistinguishable from a hop; a spline that never rested on a word felt like a sliding cursor, not like the playground): *hop* jumps; *glide* slides over 240 ms, 40% there as the word is heard; *stretch* moves the front edge to the next word first and the back edge after (inchworm); *flow* is the playground's continuous motion, smoothstep from each word to the next over the time between them, so it rests on a word as it's heard; *sweep* fills each word in from the left while it's spoken (karaoke) as the previous one fades. Line changes cross-fade with a 6 pt carriage-return drift instead of sweeping back across the text (sweep needs none); the next sentence's first word comes from where the last one ended. A new sentence wipes in line by line while the old one retracts toward it; the same sentence measured again (scrolling) moves in place, instantly. Blue, green and pink are drawn lighter than yellow so every color has the same weight. `--highlight-frames` renders any style as a frame strip or GIF to review motion.

**Native text views (`NativeDocument`):**
- `AXValue`, `AXRangeForPosition`, `AXBoundsForRange`, `AXVisibleCharacterRange`, with sentences from `NLTokenizer`.
- **Auto-scroll (#13, 2026-11-04): set `AXVisibleCharacterRange`.** NSTextView treats it as "scroll this range to visible": the view scrolls, and the selection, the caret and focus stay as they were. Measured with `scripts/native-scroll-probe.swift` against the native fixture host and a TextEdit document opened in the background (a range two thirds of the way down a 2,865-character text, scrolled from the top, selection set to 10+5 first):

  | Mechanism | Scrolls the range into view | Selection and caret | Focus, front app |
  | --- | --- | --- | --- |
  | **Set `AXVisibleCharacterRange` on the text area** | **yes** (3 ms) | **untouched** | **untouched** |
  | Set the vertical `AXScrollBar`'s `AXValue` (0–1) | yes, but the fraction has to be computed from frames, and it clamps at the end | untouched | untouched |
  | `AXScrollToVisible` on the text area | no: unsupported (−25205) | – | – |
  | `AXScrollToShowDescendant` on the scroll area | no: unsupported (−25205) | – | – |
  | `AXScrollDownByPage` on the scroll area (listed in its actions) | no: unsupported (−25205), and only by pages | – | – |
  | Set the selection to the range | yes | moved to the range (the caret hijack) | untouched |
  | Set the selection to the range, then restore it | no: restoring scrolls back to the old selection | restored | untouched |

  AppKit places the range near the middle of the view when it scrolls down (0.45 of the view's height in the host, 0.46 in TextEdit) and nearer the top (0.20–0.29) when it scrolls up, so what was just read stays on screen, and an already visible range doesn't move. A range taller than the view lands with its start below the view (1.1–1.4 of its height), so for a sentence taller than 80% of the view only its first line is asked for. "Follow, but don't fight" is the session's, shared with the web path: it scrolls only while the user is following and the sentence isn't fully on screen.
- **Text edited while reading:** positions are `NativeRange`s, a character range tagged with the version of the text it came from. Each call that reads or measures first compares `AXNumberOfCharacters` with the snapshot (one cheap call); if it changed, `AXValue` is re-read, the edit is found as the common prefix and suffix of the two texts, and older ranges are shifted past it. An edit that keeps the length the same (replacing a word with one as long) isn't noticed. In the native host, typing a paragraph at the top in the middle of a reading moved every following highlight down by exactly the new text's height.
- An app's windows on another Space aren't in `AXWindows` (a TextEdit document opened with `open -g`), but `AXMainWindow` still returns them, and they read and scroll the same.

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

**Real-page corpus (#8, 2026-11-04),** `scripts/score-corpus.sh` on six saved pages (Anthropic, OpenAI, Cloudflare, Simon Willison, Dan Luu, Wikipedia), 706 expected sentences, reading from the title. First run, then after the walk fixes for #49, #50 and #51:

| Engine | Precision | Recall | Bounds | After: precision | Recall | Bounds |
| --- | --- | --- | --- | --- | --- | --- |
| WebKit | 77.9% | 54.4% | 99.8% | 77.2% | 93.8% | 99.9% |
| Chromium | 70.5% | 93.9% | 86.9% | 79.1% | 97.5% | 91.1% |

- WebKit's low first recall was its walk ending at a `<br>` after a sentence end (#49): a "next" marker went backwards.
- Junk that gets read (precision) is mostly outside the structural rules: figure captions not in a `<figure>`, metadata labels ("Published", "Team"), permalink "#" and "[edit]" links, tag rows, newsletter boxes and "more articles" lists after the article's last paragraph, data tables, Wikipedia's reference list.
- Chromium used to cut sentences at inline `<b id>`/`<abbr id>`/citations and in link-dense prose, drop the space at some wraps ("static typingwhen"), and lose the start of the sentence after a table (#51).
- Full list per page and sentence: PR #46.

**After the text layer (#11, #52, 2026-11-05):**

| Engine | Precision | Recall | Bounds |
| --- | --- | --- | --- |
| WebKit | 91.8% | 99.3% | 100.0% |
| Chromium | 92.4% | 100.0% | 93.6% |

- Four pages are now exact in both engines (Anthropic, Cloudflare, Willison, Wikipedia: every expected sentence, nothing else). What's left is data tables read cell by cell (Dan Luu, OpenAI; #26), and WebKit reading OpenAI's "• Claim:" items with the bullet Chromium leaves out.
- Walk times (whole page, a fresh host per run, mean of two): every page is as fast or faster, mostly because reading now ends at the article's end. Wikipedia, Chromium: 5.8 s → 1.6 s; WebKit: 2.0 s → 1.3 s. Per sentence, Chromium is faster everywhere (the inline test in `block(containing:)` is memoized now); WebKit is within 1 ms except Wikipedia (16 → 20 ms: more lookahead per heading). The first sentence costs the same (8–16 ms); the second pays the one-time search for the first paragraph (+30 to +110 ms), while the first is playing. Long-lived hidden WebKit hosts get throttled (80 ms per sentence instead of 15), so time against fresh ones.

**Long first sentences (#14, 2026-11-04),** `--bench --split`. Synthesis takes ~40 ms + 1.45 ms per character (57 ms for 14 characters, 248 ms for 149, 474 ms for 293). Splitting the first sentence at a clause break cuts what first audio waits for from 248–296 ms to 104–195 ms in English and from 185–238 ms to 97–123 ms in French. The rest takes 140–220 ms to synthesize, while the opening plays for 2.9–6.7 s. Kokoro pads every chunk with ~0.3 s of quiet before the voice and ~0.5 s after. Joined as is, that is a 715–890 ms hole where a whole sentence pauses 210–520 ms. A clause synthesized alone ends with a falling, sentence-final pitch. Synthesized with the next 3 words, which are then cut off at the voice's own pause, it ends as inside the whole sentence, and the join pauses 100–460 ms.

**Expected time to first audio:** ~150–300 ms after release, dominated by synthesizing the first sentence. Not yet measured with real hotkey use; the app logs it as `[unread] first audio … ms after release`.

## 8. Next steps (prioritized, revised 2026-11-03)

Goal: perfect it for the author's own read-along use first. Public release comes later.

Tracked as [GitHub issues](https://github.com/Jawher22/unread/issues), one milestone per phase below. Open policy questions are the issues labelled `question`.

**Phase 0: make daily use possible (do first)**
1. **`.app` bundle + launch at login.** Sign it with a stable local identity so the Accessibility grant survives rebuilds (ad-hoc signatures change every build). No notarization yet.
2. **Interaction changes:** idle tap does nothing, idle double-tap reads from the first visible paragraph, soft chime at the end.
3. **Synthesize while the key is held.** The aim target is already known during the hold, so synthesize its first sentence speculatively and throw it away if the pointer moves. Log key-up → first audio (p50/p95) to a local file.
4. **Use it for at least 3 days** on real reading and keep a friction log. Re-rank everything below from that log.

**Phase 1: read-along quality** (done so far: #7, #9, #10 structural layer, #11 text layer, per-line highlight, fixture hosts, #8 corpus and scorer, #13 native auto-scroll)
5. **Chromium bounds.** Fix the missing bounds (9/12 in T3 Code) and the block-level ones: per-line ranges, a union of word ranges (`walk()` already visits every word), or `AXBoundsForRange` on the static text.
6. **Inline code must not split sentences.** Revisit `sameBlock` for code, links and emphasis.
7. **Fixture corpus + scorer.** Saved real pages (Anthropic and OpenAI engineering posts, other technical blogs, a T3 Code LLM response, Wikipedia, a TextEdit doc). For each, list the expected sentences and score `--extract` against them, so heuristics stop silently regressing.
8. **Reading scope ("skip junk, know the end").** Layered:
   - *Structural:* scope reading to the nearest article / main landmark around the start point. Skip navigation, sidebars, footers, banners, buttons and link-dense lines. Every role used must be confirmed in both WebKit and Chromium before relying on it.
   - *Heuristic (done, #11):* text and link density (Readability-style) over the AX subtree, for poorly marked-up pages.
   - *Model (optional, later):* Apple's on-device Foundation Models to classify a block as content or chrome. It runs during look-ahead, so it stays off the first-audio path. Needs Apple Intelligence and macOS 26+, so it can only be an enhancement.
   - The skipping matters more than the ending: junk *inside* the article (captions, "Share", related-article cards, handles, timestamps) is what hurts read-along.
9. **Move AX work off the main thread.** The 30 Hz aim loop, the 10 Hz highlight refresh and `walk()` (two AX calls per word) stall the hotkey and overlay on slow Chromium pages.
10. **Auto-scroll in native text views.**
11. **Faster first audio for long first sentences** (synthesize the opening clause separately) if step 3 isn't enough. Done (#14): see §7.
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
