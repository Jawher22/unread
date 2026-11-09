#!/bin/bash
# Checks that the reading highlight belongs to the window being read, in a hidden WebKit fixture host:
# a muted `--simulate` reads the page while the host moves its own window, resizes it, opens a second window
# over it and raises itself, and `scripts/window-check.swift` watches the window server meanwhile.
#
#   scripts/window-check.sh [fixtures/pages/article.html]
#
# Prints the stacking order after each step (the panel must sit right above the host's window and below the
# window opened over it), the panel's lag behind the moving window, and the session's highlight log. Logs are
# kept in build/window-check/. Nothing is drawn: the host and its second window are transparent and
# click-through, and `--simulate` keeps its highlight invisible.
#
#   scripts/window-check.sh --tabs [fixtures/pages/article.html]
#
# Checks that the highlight belongs to its tab: the Electron host shows the page and a second one as two tabs in one
# window, and a muted `--simulate` reads the page while the host switches to the other tab and back, as a browser's tab
# strip does. Run twice: as a Chromium browser before the pulse (block highlights) and after it (word boxes). The
# highlight must hide when its tab goes to the background, stay hidden there, nothing may scroll, and it must come back
# when the tab is shown again. Exit status 1 if not.
set -euo pipefail
cd "$(dirname "$0")/.."
TABS=0; [[ "${1:-}" == --tabs ]] && { TABS=1; shift; }
PAGE="${1:-fixtures/pages/article.html}"
OUT=build/window-check
mkdir -p "$OUT"
[[ -x .build/release/Unread ]] || scripts/build.sh

if (( TABS )); then
    ELECTRON=fixtures/hosts/electron/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron
    stamp() { python3 -c 'import time; print(f"{time.time() % 1000:.2f}")'; } # the overlay log's clock
    tabs() { # Browser | Pulsed
        local log="$OUT/tabs-$1.log" host="$OUT/tabs-$1-host.log" fifo="$OUT/tabs-$1.fifo" pulse=()
        [[ $1 == Pulsed ]] && pulse=(--pulse-electron)
        rm -f "$fifo" "$log"; mkfifo "$fifo"
        # Shells inside Electron apps export ELECTRON_RUN_AS_NODE, which would run Electron as plain Node.
        env -u ELECTRON_RUN_AS_NODE "$ELECTRON" fixtures/hosts/electron --hidden --browser --profile "$OUT/tabs-$1-profile" \
            --tabs fixtures/pages/inline.html "$PAGE" <"$fifo" >"$host" 2>&1 & local h=$!
        exec 3>"$fifo"
        for _ in $(seq 1 200); do grep -q '^loaded$' "$host" && break; sleep 0.05; done
        local sim
        for _ in $(seq 1 10); do
            # >>: this script writes its own lines into the log, in order with the session's.
            : >"$log"; UNREAD_DEBUG_OVERLAY=1 .build/release/Unread --simulate 0,0 60 --pid $h ${pulse[@]+"${pulse[@]}"} >>"$log" 2>&1 & sim=$!
            sleep 1
            grep -q '^nothing at point' "$log" || break
        done
        for _ in $(seq 1 1200); do kill -0 $sim 2>/dev/null || break; grep -q 'show reading' "$log" && break; sleep 0.1; done
        if [[ $1 == Pulsed ]]; then for _ in $(seq 1 100); do grep -q 'text positions now' "$log" && break; sleep 0.1; done; fi
        sleep 1.5
        echo "[check] $(stamp) tab 2" >>"$log"; echo "tab 2" >&3
        sleep 3
        echo "[check] $(stamp) tab 1" >>"$log"; echo "tab 1" >&3
        sleep 2.5
        echo "[check] $(stamp) end" >>"$log"
        exec 3>&-; kill $h $sim 2>/dev/null || true; wait $h $sim 2>/dev/null || true; rm -f "$fifo"
        awk -v engine="$1" '
            /^\[check\] .* tab 2$/ { phase = 2; switched = $2; next }
            /^\[check\] .* tab 1$/ { phase = 1; back = $2; next }
            /^\[check\] .* end$/ { phase = 0 }
            phase && /into view/ { scrolled = scrolled " " $0 }
            phase == 2 { t = $2; sub(/\]$/, "", t) }
            phase == 2 && /^\[overlay .*\] hide$/ && !hid { hid = t }
            phase == 2 && /show reading/ && hid { late = late " " t }
            phase == 1 && /show reading/ && !shown { t = $2; sub(/\]$/, "", t); shown = t }
            END {
                bad = 0
                if (!switched || !back) { print "FAIL  tabs (" engine "): the reading never got to the switch"; exit 1 }
                if (!hid) { print "FAIL  tabs (" engine "): the highlight stayed on screen over the other tab"; bad = 1 }
                else if (late) { print "FAIL  tabs (" engine "): drawn over the other tab after hiding, at" late; bad = 1 }
                if (!shown) { print "FAIL  tabs (" engine "): the highlight never came back with its tab"; bad = 1 }
                if (scrolled) { print "FAIL  tabs (" engine "): scrolled:" scrolled; bad = 1 }
                if (!bad) printf "PASS  tabs (%s): hidden %.0f ms after the switch, back %.0f ms after its tab returned\n", engine, (hid - switched) * 1000, (shown - back) * 1000
                exit bad }' "$log"
    }
    FAILED=0
    tabs Browser || FAILED=1
    tabs Pulsed || FAILED=1
    (( FAILED )) && echo "logs: $OUT/tabs-*.log"
    exit $FAILED
fi
[[ -x build/fixture-host-webkit && build/fixture-host-webkit -nt fixtures/hosts/webkit/main.swift ]] ||
    swiftc -O fixtures/hosts/webkit/main.swift -o build/fixture-host-webkit
[[ -x build/window-watch && build/window-watch -nt scripts/window-check.swift ]] ||
    swiftc -O scripts/window-check.swift -o build/window-watch

FIFO="$OUT/levers"; rm -f "$FIFO"; mkfifo "$FIFO"
build/fixture-host-webkit --hidden --levers "$PAGE" <"$FIFO" >"$OUT/host.log" 2>&1 & HOST=$!
exec 3>"$FIFO"
cleanup() { exec 3>&-; kill $HOST ${SIM:-} ${CHECK:-} 2>/dev/null || true; rm -f "$FIFO"; }
trap cleanup EXIT
for _ in $(seq 1 200); do grep -q '^loaded$' "$OUT/host.log" && break; sleep 0.05; done
WINDOW=$(sed -n 's/^\[host\] window //p' "$OUT/host.log" | head -1)

# A host that just loaded may have no tree to read yet: try again for a few seconds.
for _ in $(seq 1 10); do
    UNREAD_DEBUG_OVERLAY=1 .build/release/Unread --simulate 0,0 90 --pid $HOST >"$OUT/session.log" 2>&1 & SIM=$!
    sleep 1
    grep -q '^nothing at point' "$OUT/session.log" || break
done
# Wait for the highlight to be drawn (the narrator's first load from a new binary path compiles for ~50 s).
for _ in $(seq 1 1200); do kill -0 $SIM 2>/dev/null || break; grep -q 'show reading' "$OUT/session.log" && break; sleep 0.1; done
grep -q 'show reading' "$OUT/session.log" || { echo "no highlight drawn; see $OUT/session.log" >&2; exit 1; }
sleep 1
build/window-watch $HOST "$WINDOW" $SIM 10 >"$OUT/check.log" & CHECK=$!
lever() { sleep "$2"; echo "$1" >&3; }
lever move 1; lever resize 2.5; lever cover 2; lever raise 2
wait $CHECK
cat "$OUT/host.log" | grep -v '\] moved ' | grep '^\[host'
cat "$OUT/check.log"
echo "--- session (highlight lines) ---"
grep -E 'attached|ordered above|window being read|resized|before the window moved|show reading|hide|reordered' "$OUT/session.log" | grep -v '\] window at' | tail -40
