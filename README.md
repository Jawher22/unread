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

## Requirements

- Apple Silicon Mac, macOS 15 or later
- To build: Swift 6.2 or later (Xcode 26)
- Accessibility permission (to read on-screen text and watch the hotkey)
- About 3 GB of disk for the voice, downloaded once

## Build and run

```bash
scripts/fetch-narrator.sh     # the voice model, once
scripts/bundle.sh --install   # builds, signs and installs ~/Applications/Unread.app
open ~/Applications/Unread.app
```

The first build takes about 15 minutes. The first launch takes about a minute to get the voice ready: while the menu says "Loading voice…", ⌃ only beeps. Later launches take a few seconds. On first launch, grant Accessibility when prompted (System Settings → Privacy & Security → Accessibility); Unread picks the grant up without a relaunch. It turns on **Launch at Login** the first time it runs; toggle it from the menu. Logs go to `~/Library/Logs/Unread/unread.log`.

The script signs with your first "Apple Development" identity (or `$UNREAD_SIGN_IDENTITY`). A stable identity means the Accessibility grant survives rebuilds; without one it falls back to ad-hoc signing and you'll re-grant after every build.

## Known limitations

- English and French only. The word-by-word highlight is less precise in French.
- In Chrome, Arc and Dia a page's first couple of seconds are highlighted a block at a time, until the browser starts giving word positions.
- Code blocks and tables aren't read: a soft double tap marks them and the reading goes on.
- Apps that don't expose their text (Kindle, canvas apps) aren't supported.
- No download yet: you build it yourself, and it's signed for local use only (not notarized).

## Roadmap

- Floating mini-player pill, media keys and Now Playing
- "Design a voice" and "use my own voice"
- Notarized release, Homebrew cask
