#!/bin/bash
# Build, then check every extraction fixture in both engines, all at once.
#
#   scripts/test.sh                 # every fixtures/pages/*.html with an expected file, then the corpus score (~40 s)
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
if (( $# )); then PAGES=("${@/#/fixtures/pages/}"); PAGES=("${PAGES[@]/%/.html}")
else PAGES=(); for e in fixtures/pages/*.expected.txt; do
    (( QUICK )) && grep -q '^# flags: .*--slow' "$e" && continue
    PAGES+=("${e%.expected.txt}.html"); done; fi

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
PIDS=()
for p in "${PAGES[@]}"; do
    scripts/extract-fixture.sh "$p" >"$OUT/$(basename "$p")" 2>&1 & PIDS+=($!)
done

FAILED=0
for i in "${!PAGES[@]}"; do
    name=$(basename "${PAGES[$i]}" .html)
    if wait "${PIDS[$i]}"; then echo "PASS  $name"
    else echo "FAIL  $name"; sed 's/^/      /' "$OUT/$name.html"; FAILED=1; fi
done
# After the gated pages, not alongside them: under that load Chromium reads Wikipedia differently.
if (( ! QUICK && ! $# )); then echo; scripts/score-corpus.sh || true; fi
echo "${#PAGES[@]} pages in $(( $(date +%s) - START )) s"
exit $FAILED
