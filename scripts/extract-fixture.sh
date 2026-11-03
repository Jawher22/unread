#!/bin/bash
# Show what Unread would read from a local HTML page, in both engines.
#
#   scripts/extract-fixture.sh fixtures/pages/inline.html [--limit N]
#
# Opens the page in two throwaway windows that never take focus: a WKWebView
# host (what Safari exposes) and an Electron host (what Chrome, Dia and
# Electron apps expose). Runs `Unread --extract --pid … --from-start` against
# each, then closes them. Needs the terminal to have Accessibility permission.
#
# If <page>.expected.txt exists (one sentence per line), each engine's text is
# compared against it, and every sentence must have bounds. Exit status 1 on
# any failure.
set -euo pipefail
cd "$(dirname "$0")/.."
PAGE="$1"; shift
EXTRA=("$@")

[[ -x build/fixture-host-webkit && build/fixture-host-webkit -nt fixtures/hosts/webkit/main.swift ]] || {
    mkdir -p build && swiftc -O fixtures/hosts/webkit/main.swift -o build/fixture-host-webkit; }
[[ -x fixtures/hosts/electron/node_modules/.bin/electron ]] || {
    echo "Electron host not installed: (cd fixtures/hosts/electron && npm install)" >&2; exit 1; }
[[ -x .build/release/Unread ]] || swift build -c release

build/fixture-host-webkit "$PAGE" & WK=$!
# Shells inside Electron apps (VS Code, T3 Code…) export ELECTRON_RUN_AS_NODE, which would run Electron as plain Node.
env -u ELECTRON_RUN_AS_NODE fixtures/hosts/electron/node_modules/.bin/electron fixtures/hosts/electron "$PAGE" >/dev/null 2>&1 & EL=$!
trap 'kill $WK $EL 2>/dev/null; pkill -f "MacOS/Electron fixtures/hosts/electron" 2>/dev/null || true' EXIT

EXPECTED="${PAGE%.html}.expected.txt"
FAILED=0
# An expected file may begin with "# start: <text>": start reading at the
# first sentence containing <text>, as if the user pointed there.
START=()
if [[ -f "$EXPECTED" ]] && head -1 "$EXPECTED" | grep -q '^# start: '; then
    START=(--from-text "$(head -1 "$EXPECTED" | sed 's/^# start: //')")
fi
check() { # name, output
    [[ -f "$EXPECTED" ]] || return 0
    local got; got=$(echo "$2" | sed -nE 's/^  [0-9]+\. (\([^)]*\)|no bounds)  //p')
    local want; want=$(grep -v '^# start: ' "$EXPECTED")
    if [[ "$got" == "$want" ]]; then echo "   text: PASS"; else
        echo "   text: FAIL"; { diff <(echo "$want") <(echo "$got") || true; } | sed "s/^/     /"; FAILED=1; fi
    local missing; missing=$(echo "$2" | grep -c "^  [0-9]*\. no bounds" || true)
    if [[ "$missing" == 0 ]]; then echo "   bounds: PASS"; else echo "   bounds: FAIL ($missing without)"; FAILED=1; fi
}

extract() { # name, pid
    for _ in $(seq 1 12); do # the first query switches Chromium's tree on; it takes a few seconds, and re-asking too often restarts it
        if out=$(.build/release/Unread --extract --pid "$2" --from-start ${START[@]+"${START[@]}"} ${EXTRA[@]+"${EXTRA[@]}"} 2>&1) && ! grep -q "^0 sentences" <<<"$out"; then
            echo "== $1"; echo "$out" | tail -n +2; check "$1" "$out"; return; fi
        sleep 2
    done
    echo "== $1: nothing readable"; echo "$out"; FAILED=1
}
sleep 1.5
EL_PID=$(pgrep -f "MacOS/Electron fixtures/hosts/electron" | head -1)
extract "WebKit" "$WK"
extract "Chromium" "$EL_PID"
exit $FAILED
