# Extraction fixtures

Local HTML pages for checking what Unread reads, in both engines, without touching the real browser or the keyboard.

```bash
(cd fixtures/hosts/electron && npm install)      # once
scripts/test.sh                                  # build, then every page in parallel (~20 s; --quick ~5 s)
scripts/extract-fixture.sh fixtures/pages/inline.html   # one page, full output
```

`extract-fixture.sh` opens the page in two throwaway windows, launched with `--hidden`: fully transparent and click-through, so a run never covers your work, but still on screen, so Accessibility reports the same geometry (checked: identical word boxes either way). Launch a host without `--hidden` to watch it:

- **WebKit**: `hosts/webkit/main.swift`, a `WKWebView` (what Safari exposes)
- **Chromium**: `hosts/electron/`, an Electron window (what Chrome, Dia and Electron apps expose)

Each host prints `loaded` once its page is up. The script then runs `Unread --extract --pid … --from-start --wait 20` against both at once; `--wait` polls in one process until the page has a sentence (Chromium builds its tree a second or two after the first query switches it on). If `<page>.expected.txt` exists (one sentence per line), it checks the text and that every sentence has bounds, and exits 1 on failure. An expected file may start with header lines: `# start: <text>` starts reading at the first sentence containing `<text>`, as if the user pointed there (`--from-text` points at the first visible text leaf holding it, and falls back to walking from the top), with the reading scope (#10) applied; `# flags: <flags>` passes extra `--extract` flags the page needs.

Pages: `inline.html` (inline formatting, sentence and block boundaries), `article.html` (an engineering-blog layout: header, nav, article with share row, figure, code, quote, list, related aside; more-posts cards, sidebar, footer), `chat.html` (an agent-chat layout like T3 Code: thread nav, speaker headings, timestamps, tool-call buttons), `scroller.html` (a conversation scrolling inside its own container, so most text is clipped out of view and must still be read). `icons.html` has icon-only buttons between a date and the first paragraph (WebKit's "￼"). `rerender.html` rebuilds its message every 1.5 s like a chat app; its expected file asks for `--slow` so the walk crosses several rebuilds. All text is original; the structure is modelled on real sites.

## Real-page corpus (scored, local only)

The synthetic pages above are gated: exact text, every sentence with bounds. Real pages are messier, so they're scored instead: how much of what a reader should hear Unread reads (recall), how much of what it reads should be heard (precision), and how many sentences come with a highlight (bounds).

```bash
scripts/save-corpus.sh             # once per machine: snapshot every page in fixtures/corpus.txt, draft its expected file
scripts/score-corpus.sh            # table per page and engine, then corpus totals (~10 s)
scripts/score-corpus.sh --diff     # also every missed (-) and junk (+) sentence
scripts/score-corpus.sh --record   # make these scores the baseline; later runs show the change and mark drops "← worse"
scripts/extract-fixture.sh fixtures/corpus/<page>.html   # one page, full output, then its score and differences
```

`scripts/test.sh` scores the corpus after the gated pages and prints its table; `--quick` skips it. Run alone, scores repeat exactly, except Chromium on Wikipedia, which reads 192 to 195 sentences (same recall); run alongside other hosts it read 167. Only the manifest, `fixtures/corpus.txt` (name, URL, start text), is committed. The snapshots, their expected files and the baseline hold third-party text, so `fixtures/corpus/` is gitignored and a fresh clone has no corpus: `score-corpus.sh` says so and `test.sh` still passes.

**Snapshots.** `save-corpus.sh` opens each URL in the WebKit host with `--save`, which waits for the page to settle, scrolls through it once (lazy images, scroll-triggered reveals), then writes the rendered DOM as one file: scripts, event handlers and `<link>`s removed; every stylesheet inlined from the CSSOM (so CSS-in-JS rules count), cross-origin ones fetched, `@import`s spliced in; fonts embedded as data URLs; each image swapped for an empty one of the size it was drawn at; links made absolute. Layout is what visually-hidden detection and bounds depend on, so it has to survive. Checked on the six pages (2026-11-04): element by element they render within 1 to 6 px of the live pages at the hosts' 900 × 1000 size, four of them identically, and `--extract` on the live URL and on the snapshot reads the same sentences with the same bounds rate in 11 of 12 page × engine runs (the twelfth differs by one sentence: OpenAI's audio player said "Loading…" live). Background images stay remote and simply fail offline; they don't move anything. `save-corpus.sh NAME…` saves those pages again (refresh); an existing expected file is never overwritten, so after a refresh check it still matches the page.

**Expected files** are the spec, not a copy of today's output. A new page gets a draft from what WebKit reads today, starting at the manifest's start text (written as `# start:`, like the gated pages). Then correct it by hand against the page: what a reader following along should hear, in order. Rules used so far:

- Start where a reader would point: the article title. Read the byline/date line only if it's a sentence, not a row of metadata.
- Skip site chrome and article furniture: nav, table-of-contents rails, share and "copy link" rows, author/date/tag rows, figure captions, code blocks (#24 default), "related"/"more posts" cards, newsletter boxes, comments, footers.
- Read headings, paragraphs, list items and block quotes, in order. Read inline code and links as text.
- Data tables are skipped: a grid of numbers read cell by cell isn't listenable (tables are an open decision in docs/design.md §9; change the spec if that decision changes).
- Wikipedia: citation markers (`[12]`) and "[edit]" are not part of the sentence; the article ends before "See also" and the reference lists.
- Sentences are split the way Unread splits them (`NLTokenizer`), plus at a `<br>`, where the page shows a new line. Keep a draft's split unless it's a real defect (e.g. a sentence cut at a link or a wrapped line).
- List items start with the marker Unread reads from the page (`• `, `■ `), as in the gated pages.
- `scripts/score.py` compares after collapsing whitespace and dropping invisible characters (zero-width spaces, soft hyphens), so the spec doesn't need to reproduce those.

The current specs were drafted from each page's DOM (the content blocks a reader would hear, split with `NLTokenizer`) rather than from Unread's output, then every difference from what Unread reads was checked by hand: list markers and line breaks were fixed in the spec, everything else was left as a defect for the score to count.

**A page saved by hand** (one that needs a login, like an X thread, or saved from the author's signed-in browser): in a Chromium browser (Chrome, Arc, Dia, Aside), File › Save Page As… › "Webpage, Complete", which writes the page as it's shown (Safari's "Page Source" saves the HTML before scripts ran, which for a timeline is empty), then

```bash
scripts/save-corpus.sh --file x-thread ~/Downloads/thread.html "first words of the post"
```

It's snapshotted the same way with the page's own scripts switched off (they'd re-render it or log out), so save it while it shows what you want read. It isn't in the manifest (it can't be fetched again); its snapshot and expected file sit in `fixtures/corpus/` and are scored like the others.

Useful while investigating:

- `UNREAD_DEBUG_WALK=1` traces each chunk, sentence range and word box.
- `scripts/extract-fixture.sh <page> --word-boxes` prints each display word's box (#20); `?` marks a word without one.
- `Unread --simulate 0,0 12 --pid <pid>` reads a fixture window from the top, muted, with the real overlay; with `UNREAD_DEBUG_OVERLAY=1` it logs each word mark against its due time. `UNREAD_DEBUG_MOTION=1` logs the voice clock every display frame, raw and smoothed, to check motion smoothness.
- `Unread --axtree <pid>` dumps the web area's roles and subroles.
- The hosts also accept an `https://` URL instead of a file, to investigate a live page: `build/fixture-host-webkit https://…`, then `Unread --extract --pid <pid> --from-start` or `Unread --at x,y --pid <pid>`.

Gotchas:

- Shells inside Electron apps (VS Code, T3 Code) export `ELECTRON_RUN_AS_NODE`; the script unsets it.
- Chromium takes a second or two to build its tree after it's switched on, and setting `AXManualAccessibility` again restarts that, so `--wait` polls inside one process. It touches the app only once the app shows a window: querying an Electron host from the moment it launches left its tree unbuilt in 7 of 8 tries.
- Accessibility lists only the current Space's windows, so a Space switch while hosts start used to hide every Electron window from a run. `--hidden` hosts join all Spaces, including full-screen ones.
- Each Electron host gets its own profile (`--profile`, inside the script's temp dir). Started together on one shared profile, all twelve hosts of a stress run failed to build a tree; on separate profiles, 36 of 36 succeeded.
- `rerender.html` occasionally fails with one sentence without bounds, after a relocation (`page re-rendered` in its output). That's a real race between a rebuild and measuring a relocated sentence, not a fixture problem.
- If `npm install` leaves `node_modules/electron/dist` empty (its unzip can fail on new Node versions), unpack the cached zip by hand: `ditto -x -k ~/Library/Caches/electron/*/electron-v*-darwin-arm64.zip node_modules/electron/dist && printf 'Electron.app/Contents/MacOS/Electron' > node_modules/electron/path.txt`.
