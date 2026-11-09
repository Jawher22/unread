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
set -euo pipefail
cd "$(dirname "$0")/.."
PAGE="${1:-fixtures/pages/article.html}"
OUT=build/window-check
mkdir -p "$OUT"
[[ -x build/fixture-host-webkit && build/fixture-host-webkit -nt fixtures/hosts/webkit/main.swift ]] ||
    swiftc -O fixtures/hosts/webkit/main.swift -o build/fixture-host-webkit
[[ -x build/window-watch && build/window-watch -nt scripts/window-check.swift ]] ||
    swiftc -O scripts/window-check.swift -o build/window-watch
[[ -x .build/release/Unread ]] || scripts/build.sh

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
