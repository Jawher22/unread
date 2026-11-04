#!/bin/bash
# Score what Unread reads from every saved real page (fixtures/corpus/*.expected.txt), in both engines.
#
#   scripts/score-corpus.sh                 table of precision, recall and bounds per page, then the corpus totals
#   scripts/score-corpus.sh --diff          also each page's missed (-) and junk (+) sentences
#   scripts/score-corpus.sh --record        save these scores as the baseline later runs compare against
#   scripts/score-corpus.sh NAME…           just these pages
#
# Scored, not gated: the expected files are the spec, so a page below 100% is a known gap, not a
# failure. With a baseline (fixtures/corpus/baseline.tsv), each row shows its change and "← worse"
# marks a drop: run it before and after an extraction change. Exits 0 unless the build fails.
# No corpus (a fresh clone): says how to save one and exits 0. See fixtures/README.md.
set -euo pipefail
cd "$(dirname "$0")/.."
BASELINE=fixtures/corpus/baseline.tsv
RECORD=; DIFF=0; NAMES=()
for a in "$@"; do case "$a" in --record) RECORD=--record;; --diff) DIFF=1;; *) NAMES+=("$a");; esac; done

PAGES=()
if (( ${#NAMES[@]} )); then for n in "${NAMES[@]}"; do PAGES+=("fixtures/corpus/$n.html"); done
else for e in fixtures/corpus/*.expected.txt; do [[ -f "$e" ]] && PAGES+=("${e%.expected.txt}.html"); done; fi
if (( ! ${#PAGES[@]} )); then
    echo "corpus: no saved pages (fixtures/corpus/ is local only). Save them with scripts/save-corpus.sh."; exit 0; fi

[[ -x .build/release/Unread ]] || scripts/build.sh
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
PIDS=()
for p in "${PAGES[@]}"; do
    scripts/extract-fixture.sh "$p" --raw "$OUT" >"$OUT/$(basename "$p" .html).report" 2>&1 & PIDS+=($!)
done
for pid in "${PIDS[@]}"; do wait "$pid" || true; done

NAMES=(); for p in "${PAGES[@]}"; do NAMES+=("$(basename "$p" .html)"); done
python3 scripts/score.py table "$OUT" "${NAMES[@]}" --baseline "$BASELINE" $RECORD
if (( DIFF )); then for p in "${PAGES[@]}"; do
    name=$(basename "$p" .html); echo; echo "== $name"
    grep -E '^(== |   score: |     [-+] |   - expected)' "$OUT/$name.report" || true
done; fi
