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

Each host prints `loaded` once its page is up. The script then runs `Unread --extract --pid … --from-start --wait 20` against both at once; `--wait` polls in one process until the page has a sentence (Chromium builds its tree a second or two after the first query switches it on). If `<page>.expected.txt` exists (one sentence per line), it checks the text and that every sentence has bounds, and exits 1 on failure. An expected file may start with header lines: `# start: <text>` starts reading at the first sentence containing `<text>`, as if the user pointed there, with the reading scope (#10) applied; `# flags: <flags>` passes extra `--extract` flags the page needs.

Pages: `inline.html` (inline formatting, sentence and block boundaries), `article.html` (an engineering-blog layout: header, nav, article with share row, figure, code, quote, list, related aside; more-posts cards, sidebar, footer), `chat.html` (an agent-chat layout like T3 Code: thread nav, speaker headings, timestamps, tool-call buttons), `scroller.html` (a conversation scrolling inside its own container, so most text is clipped out of view and must still be read). `icons.html` has icon-only buttons between a date and the first paragraph (WebKit's "￼"). `rerender.html` rebuilds its message every 1.5 s like a chat app; its expected file asks for `--slow` so the walk crosses several rebuilds. All text is original; the structure is modelled on real sites.

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
