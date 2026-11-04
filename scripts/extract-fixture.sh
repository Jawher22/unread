#!/bin/bash
# Show what Unread would read from a local HTML page, in both engines.
#
#   scripts/extract-fixture.sh fixtures/pages/inline.html [--limit N]
#   scripts/extract-fixture.sh fixtures/corpus/<page>.html [--raw DIR]
#
# Opens the page in two throwaway windows, invisible and click-through: a WKWebView
# host (what Safari exposes) and an Electron host (what Chrome, Dia and
# Electron apps expose). Runs `Unread --extract --pid … --from-start` against
# both at once, then closes them. Needs the terminal to have Accessibility
# permission. Uses the existing release build; scripts/test.sh rebuilds first.
#
# If <page>.expected.txt exists (one sentence per line), each engine's text is
# compared against it, and every sentence must have bounds. Exit status 1 on
# any failure. A corpus page (fixtures/corpus/) is scored instead (scripts/score.py:
# precision, recall, bounds, then each missed and junk sentence), and never fails.
# --raw DIR also saves each engine's output as DIR/<page>.<Engine>.txt (score-corpus.sh).
# The expected file may begin with header lines:
#   # start: <text>   start reading at the first sentence containing <text>, as if the user pointed there
#   # flags: <flags>  extra --extract flags the page needs (rerender.html: --slow)
set -euo pipefail
cd "$(dirname "$0")/.."
PAGE="$1"; shift
EXTRA=(); RAW=
while (( $# )); do if [[ "$1" == --raw ]]; then RAW="$2"; shift 2; else EXTRA+=("$1"); shift; fi; done
CORPUS=0; [[ "$PAGE" == *fixtures/corpus/* ]] && CORPUS=1
(( CORPUS )) && EXTRA+=(--limit 5000) # whole articles; a flag given above comes first and wins
ELECTRON=fixtures/hosts/electron/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron

[[ -x build/fixture-host-webkit && build/fixture-host-webkit -nt fixtures/hosts/webkit/main.swift ]] || {
    mkdir -p build && swiftc -O fixtures/hosts/webkit/main.swift -o build/fixture-host-webkit; }
[[ -x "$ELECTRON" ]] || {
    echo "Electron host not installed: (cd fixtures/hosts/electron && npm install)" >&2; exit 1; }
[[ -x .build/release/Unread ]] || scripts/build.sh

EXPECTED="${PAGE%.html}.expected.txt"
if [[ -f "$EXPECTED" ]]; then
    START=$(sed -n 's/^# start: //p' "$EXPECTED")
    [[ -n "$START" ]] && EXTRA+=(--from-text "$START")
    read -ra FLAGS <<<"$(sed -n 's/^# flags: //p' "$EXPECTED")"
    EXTRA+=(${FLAGS[@]+"${FLAGS[@]}"})
fi

OUT=$(mktemp -d)
build/fixture-host-webkit --hidden "$PAGE" >"$OUT/webkit.log" 2>&1 & WK=$!
# Shells inside Electron apps (VS Code, T3 Code…) export ELECTRON_RUN_AS_NODE, which would run Electron as plain Node.
# The binary is launched directly (not through node_modules/.bin) so $! is the window's process.
env -u ELECTRON_RUN_AS_NODE "$ELECTRON" fixtures/hosts/electron --hidden --profile "$OUT/profile" "$PAGE" >"$OUT/electron.log" 2>&1 & EL=$!
trap '{ kill $WK $EL; wait $WK $EL; } 2>/dev/null; rm -rf "$OUT"' EXIT

check() { # output file
    [[ -f "$EXPECTED" ]] || return 0
    (( CORPUS )) && { python3 scripts/score.py page "$EXPECTED" "$2=$1"; return 0; }
    local got; got=$(sed -nE 's/^  [0-9]+\. (\([^)]*\)|no bounds)  //p' "$1")
    local want; want=$(grep -vE '^# (start|flags): ' "$EXPECTED")
    if [[ "$got" == "$want" ]]; then echo "   text: PASS"; else
        echo "   text: FAIL"; { diff <(echo "$want") <(echo "$got") || true; } | sed "s/^/     /"; return 1; fi
    local missing; missing=$(grep -c "^  [0-9]*\. no bounds" "$1" || true)
    if [[ "$missing" == 0 ]]; then echo "   bounds: PASS"; else echo "   bounds: FAIL ($missing without)"; return 1; fi
}

extract() { # name, pid, host log
    # --wait: Chromium builds its tree only after the first query switches it on.
    if ! .build/release/Unread --extract --pid "$2" --from-start --wait 20 ${EXTRA[@]+"${EXTRA[@]}"} >"$OUT/$1" 2>&1 \
        || grep -q "^0 sentences" "$OUT/$1"; then
        [[ -n "$RAW" ]] && cp "$OUT/$1" "$RAW/$(basename "$PAGE" .html).$1.txt"
        echo "== $1: nothing readable"; cat "$OUT/$1"; echo "   host log:"; sed 's/^/     /' "$3"; return 1; fi
    [[ -n "$RAW" ]] && cp "$OUT/$1" "$RAW/$(basename "$PAGE" .html).$1.txt"
    echo "== $1"; tail -n +2 "$OUT/$1"; check "$OUT/$1" "$1"
}

loaded() { # host log: wait up to 10 s for the host to say its page is up
    for _ in $(seq 1 200); do grep -q '^loaded$' "$1" && return; sleep 0.05; done
}
{ loaded "$OUT/webkit.log"; extract WebKit "$WK" "$OUT/webkit.log"; } >"$OUT/WebKit.report" & A=$!
{ loaded "$OUT/electron.log"; extract Chromium "$EL" "$OUT/electron.log"; } >"$OUT/Chromium.report" & B=$!
FAILED=0
wait $A || FAILED=1
wait $B || FAILED=1
cat "$OUT/WebKit.report" "$OUT/Chromium.report"
exit $FAILED
