#!/bin/bash
# Save the real-page corpus listed in fixtures/corpus.txt into fixtures/corpus/.
# That folder is gitignored: snapshots and expected files hold third-party text.
#
#   scripts/save-corpus.sh                     every listed page that has no snapshot yet
#   scripts/save-corpus.sh NAME…               these pages, saved again from the live site (refresh)
#   scripts/save-corpus.sh --file NAME PAGE.html "start text"
#                                              a page saved by hand (e.g. from a signed-in browser),
#                                              snapshotted with its own scripts off; not in the manifest
#
# A snapshot is the page's rendered DOM in one offline file (fixtures/hosts/webkit/main.swift --save).
# A page without an expected file gets a draft: what WebKit reads today from the start text.
# The draft is not the spec until it's corrected by hand (fixtures/README.md). An existing
# expected file is never touched; after a refresh, check it still matches the page.
set -euo pipefail
cd "$(dirname "$0")/.."
MANIFEST=fixtures/corpus.txt
mkdir -p fixtures/corpus
[[ -x build/fixture-host-webkit && build/fixture-host-webkit -nt fixtures/hosts/webkit/main.swift ]] || {
    mkdir -p build && swiftc -O fixtures/hosts/webkit/main.swift -o build/fixture-host-webkit; }

save() { # name, url or file, start text
    local html=fixtures/corpus/$1.html expected=fixtures/corpus/$1.expected.txt
    build/fixture-host-webkit --hidden --save "$html" "$2" | grep -v '^loaded$' || { echo "$1: not saved" >&2; return 1; }
    [[ -f "$expected" ]] && return
    local raw; raw=$(mktemp -d)
    [[ -n "$3" ]] && echo "# start: $3" >"$expected" || : >"$expected"
    scripts/extract-fixture.sh "$html" --raw "$raw" >/dev/null || true
    sed -nE 's/^  [0-9]+\. (\([^)]*\)|no bounds)  //p' "$raw/$1.WebKit.txt" >>"$expected" 2>/dev/null || true
    rm -rf "$raw"
    echo "$1: drafted $expected ($(grep -vc '^# ' "$expected") sentences from WebKit). Correct it by hand against the page."
}

if [[ "${1:-}" == --file ]]; then save "$2" "$(cd "$(dirname "$3")" && pwd)/$(basename "$3")" "${4:-}"; exit; fi

FAILED=0
while read -r name url start; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    if (( $# )); then [[ " $* " == *" $name "* ]] || continue
    else [[ -f fixtures/corpus/$name.html ]] && continue; fi
    save "$name" "$url" "$start" </dev/null || FAILED=1
done <"$MANIFEST"
exit $FAILED
