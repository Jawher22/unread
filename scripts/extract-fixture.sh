#!/bin/bash
# Show what Unread would read from a local fixture page.
#
#   scripts/extract-fixture.sh fixtures/pages/inline.html [--limit N]
#   scripts/extract-fixture.sh fixtures/corpus/<page>.html [--raw DIR]
#   scripts/extract-fixture.sh fixtures/pages/notes.txt          (or .rtf)
#   scripts/extract-fixture.sh fixtures/pages/paper.pdf
#
# Opens the page in throwaway windows, invisible and click-through: an HTML page in a
# WKWebView host (what Safari exposes) and an Electron host (what Chrome, Dia and
# Electron apps expose), a .txt or .rtf file in an NSTextView host (what TextEdit and
# other Cocoa apps expose). A .pdf shows in both web hosts: WKWebView draws it with PDFKit
# (Safari's and Preview's tree), Electron with PDFium (Chrome's). Runs `Unread --extract --pid … --from-start` against
# each at once, then closes them. Needs the terminal to have Accessibility
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
#   # pending: <engines>  engines not expected to pass yet: their result is shown, marked PENDING, and never fails
set -euo pipefail
cd "$(dirname "$0")/.."
PAGE="$1"; shift
EXTRA=(); RAW=
while (( $# )); do if [[ "$1" == --raw ]]; then RAW="$2"; shift 2; else EXTRA+=("$1"); shift; fi; done
CORPUS=0; [[ "$PAGE" == *fixtures/corpus/* ]] && CORPUS=1
(( CORPUS )) && EXTRA+=(--limit 5000) # whole articles; a flag given above comes first and wins
ELECTRON=fixtures/hosts/electron/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron

case "$PAGE" in
    *.txt | *.rtf) ENGINES=(Native) ;;
    *) ENGINES=(WebKit Chromium) ;;
esac
host() { # name: build the Swift host if it's missing or older than its source
    [[ -x build/fixture-host-$1 && build/fixture-host-$1 -nt fixtures/hosts/$1/main.swift ]] || {
        mkdir -p build && swiftc -O fixtures/hosts/$1/main.swift -o build/fixture-host-$1; }
}
if [[ ${ENGINES[0]} == Native ]]; then host native; else
    host webkit
    [[ -x "$ELECTRON" ]] || {
        echo "Electron host not installed: (cd fixtures/hosts/electron && npm install)" >&2; exit 1; }
fi
[[ -x .build/release/Unread ]] || scripts/build.sh

EXPECTED="${PAGE%.*}.expected.txt"
PENDING=" "
if [[ -f "$EXPECTED" ]]; then
    START=$(sed -n 's/^# start: //p' "$EXPECTED")
    [[ -n "$START" ]] && EXTRA+=(--from-text "$START")
    read -ra FLAGS <<<"$(sed -n 's/^# flags: //p' "$EXPECTED")"
    PENDING=" $(sed -n 's/^# pending: //p' "$EXPECTED") "
    EXTRA+=(${FLAGS[@]+"${FLAGS[@]}"})
fi

OUT=$(mktemp -d)
HOSTS=()
# || true: a host killed here exits 143, and under set -e that would become the script's status.
trap '{ kill ${HOSTS[@]+"${HOSTS[@]}"}; wait ${HOSTS[@]+"${HOSTS[@]}"}; } 2>/dev/null || true; rm -rf "$OUT"' EXIT
launch() { # engine: start its host on the page, logging to $OUT/<engine>.log
    # exec, so $! is the host's own process (the one to read), not a subshell.
    case $1 in
        WebKit) exec build/fixture-host-webkit --hidden "$PAGE" ;;
        # Shells inside Electron apps (VS Code, T3 Code…) export ELECTRON_RUN_AS_NODE, which would run Electron as plain Node.
        # The binary is launched directly (not through node_modules/.bin) so $! is the window's process.
        Chromium) exec env -u ELECTRON_RUN_AS_NODE "$ELECTRON" fixtures/hosts/electron --hidden --profile "$OUT/profile" "$PAGE" ;;
        Native) exec build/fixture-host-native --hidden "$PAGE" ;;
    esac >"$OUT/$1.log" 2>&1 &
    HOSTS+=($!)
}
for e in "${ENGINES[@]}"; do launch "$e"; done

pending() { [[ "$PENDING" == *" $1 "* ]]; }
check() { # output file, engine
    [[ -f "$EXPECTED" ]] || return 0
    compare "$@" && return 0
    pending "$2" && { echo "   PENDING: not expected to pass yet"; return 0; }
    return 1
}
compare() { # output file, engine
    (( CORPUS )) && { python3 scripts/score.py page "$EXPECTED" "$2=$1"; return 0; }
    local got; got=$(sed -nE 's/^  [0-9]+\. (\([^)]*\)|no bounds)  //p' "$1")
    local want; want=$(grep -vE '^# (start|flags|pending): ' "$EXPECTED")
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
        echo "== $1: nothing readable"; cat "$OUT/$1"; echo "   host log:"; sed 's/^/     /' "$3"
        pending "$1" && { echo "   PENDING: not expected to pass yet"; return 0; }; return 1; fi
    [[ -n "$RAW" ]] && cp "$OUT/$1" "$RAW/$(basename "$PAGE" .html).$1.txt"
    echo "== $1"; tail -n +2 "$OUT/$1"; check "$OUT/$1" "$1"
}

loaded() { # host log: wait up to 10 s for the host to say its page is up
    for _ in $(seq 1 200); do grep -q '^loaded$' "$1" && return; sleep 0.05; done
}
RUNS=()
for i in "${!ENGINES[@]}"; do
    e=${ENGINES[$i]}
    { loaded "$OUT/$e.log"; extract "$e" "${HOSTS[$i]}" "$OUT/$e.log"; } >"$OUT/$e.report" & RUNS+=($!)
done
FAILED=0
for r in "${RUNS[@]}"; do wait "$r" || FAILED=1; done
for e in "${ENGINES[@]}"; do cat "$OUT/$e.report"; done
exit $FAILED
