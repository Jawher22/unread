#!/bin/bash
# Build, then check every extraction fixture in both engines, all at once, the narrator's time stretch (--stretch-check), what it's given for technical text (--speakable-check) and how Chromium's PDF viewer is read (--pdf-check).
#
#   scripts/test.sh                 # every fixture page (.html, .pdf, .txt, .rtf) with an expected file, then the corpus score (~40 s)
#   scripts/test.sh --quick         # skip pages that declare --slow (rerender.html) and the corpus, for the inner loop (~5 s)
#   scripts/test.sh chat scroller   # just these pages
#
# Prints a PASS/FAIL line per page and the full report of each failure, then the
# real-page corpus table (scripts/score-corpus.sh; scored, never fails, absent on a fresh clone).
# Exit status 1 if any page fails. See fixtures/README.md.
set -euo pipefail
cd "$(dirname "$0")/.."
START=$(date +%s)

if ! log=$(scripts/build.sh 2>&1); then echo "$log"; exit 1; fi

QUICK=0; [[ "${1:-}" == --quick ]] && { QUICK=1; shift; }
page() { # name → its page file, whatever the extension
    local f; for f in fixtures/pages/"$1".{html,pdf,txt,rtf}; do [[ -f $f ]] && { echo "$f"; return; }; done
    echo "fixtures/pages/$1.html"
}
PAGES=()
if (( $# )); then for n in "$@"; do PAGES+=("$(page "$n")"); done
else for e in fixtures/pages/*.expected.txt; do
    (( QUICK )) && grep -q '^# flags: .*--slow' "$e" && continue
    PAGES+=("$(page "$(basename "$e" .expected.txt)")"); done; fi

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
PIDS=()
for p in "${PAGES[@]}"; do
    scripts/extract-fixture.sh "$p" >"$OUT/$(basename "$p")" 2>&1 & PIDS+=($!)
done

FAILED=0
if ./.build/release/Unread --stretch-check >"$OUT/stretch" 2>&1; then echo "PASS  stretch"
else echo "FAIL  stretch"; sed 's/^/      /' "$OUT/stretch"; FAILED=1; fi
if ./.build/release/Unread --speakable-check >"$OUT/speakable" 2>&1; then echo "PASS  speakable"
else echo "FAIL  speakable"; sed 's/^/      /' "$OUT/speakable"; FAILED=1; fi
if ./.build/release/Unread --pdf-check >"$OUT/pdf" 2>&1; then echo "PASS  pdf-check"
else echo "FAIL  pdf-check"; sed 's/^/      /' "$OUT/pdf"; FAILED=1; fi
for i in "${!PAGES[@]}"; do
    name=$(basename "${PAGES[$i]}")
    if wait "${PIDS[$i]}"; then echo "PASS  ${name%.*}"
    else echo "FAIL  ${name%.*}"; sed 's/^/      /' "$OUT/$name"; FAILED=1; fi
done
# After the gated pages, not alongside them: under that load Chromium reads Wikipedia differently.
if (( ! QUICK && ! $# )); then echo; scripts/score-corpus.sh || true; fi
echo "${#PAGES[@]} pages in $(( $(date +%s) - START )) s"
exit $FAILED
