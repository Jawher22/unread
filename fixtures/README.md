# Extraction fixtures

Local HTML pages for checking what Unread reads, in both engines, without touching the real browser or the keyboard.

```bash
(cd fixtures/hosts/electron && npm install)      # once
scripts/extract-fixture.sh fixtures/pages/inline.html
```

`extract-fixture.sh` opens the page in two throwaway windows that never take focus:

- **WebKit**: `hosts/webkit/main.swift`, a `WKWebView` (what Safari exposes)
- **Chromium**: `hosts/electron/`, an Electron window (what Chrome, Dia and Electron apps expose)

Then it runs `Unread --extract --pid … --from-start` against each. If `<page>.expected.txt` exists (one sentence per line), it checks the text and that every sentence has bounds, and exits 1 on failure.

Useful while investigating:

- `UNREAD_DEBUG_WALK=1` traces each chunk, sentence range and word box.
- `Unread --axtree <pid>` dumps the web area's roles and subroles.

Gotchas:

- Shells inside Electron apps (VS Code, T3 Code) export `ELECTRON_RUN_AS_NODE`; the script unsets it.
- Chromium takes a few seconds to build its tree after it's switched on, and setting `AXManualAccessibility` again too often restarts that. The script retries every 2 s.
- If `npm install` leaves `node_modules/electron/dist` empty (its unzip can fail on new Node versions), unpack the cached zip by hand: `ditto -x -k ~/Library/Caches/electron/*/electron-v*-darwin-arm64.zip node_modules/electron/dist && printf 'Electron.app/Contents/MacOS/Electron' > node_modules/electron/path.txt`.
