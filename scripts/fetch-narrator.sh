#!/bin/bash
# Download the narrator's model set: Qwen3-TTS 1.7B Base compiled for the
# Neural Engine (tinytrashlabs/Qwen3-TTS-1.7B-Base-ANE, Apache-2.0, 2.88 GB),
# at a pinned revision, into the folder Unread loads it from.
#
#   scripts/fetch-narrator.sh               # download what's missing or wrong
#   scripts/fetch-narrator.sh --from DIR    # copy files from a local copy of the set when they match
#
# Every file is checked against scripts/narrator-model.sha256 (size and
# sha256). Interrupted downloads resume. Running it again only fetches files
# that are missing or don't match. `.complete` is written last; Unread won't
# load the set without it.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="tinytrashlabs/Qwen3-TTS-1.7B-Base-ANE"
REVISION="552e9512c4618570df2b1b9c4a34373c018e0674"
MANIFEST="scripts/narrator-model.sha256"
DEST="${UNREAD_NARRATOR_MODEL:-$HOME/Library/Application Support/Unread/models/Qwen3-TTS-1.7B-Base-ANE}"
FROM=""
if [[ "${1:-}" == "--from" ]]; then FROM="${2:?--from needs a folder}"; fi

matches() { [[ -f "$1" && "$(stat -f %z "$1")" == "$2" && "$(shasum -a 256 "$1" | cut -d' ' -f1)" == "$3" ]]; }

mkdir -p "$DEST"
rm -f "$DEST/.complete"
kept=0 copied=0 fetched=0
while read -r sha size rel; do
    target="$DEST/$rel"
    if matches "$target" "$size" "$sha"; then kept=$((kept + 1)); continue; fi
    mkdir -p "$(dirname "$target")"
    if [[ -n "$FROM" ]] && matches "$FROM/$rel" "$size" "$sha"; then
        rm -f "$target"
        cp -c "$FROM/$rel" "$target" 2>/dev/null || cp "$FROM/$rel" "$target"
        copied=$((copied + 1))
        continue
    fi
    part="$target.part"
    have=$([[ -f "$part" ]] && stat -f %z "$part" || echo 0)
    if (( have > size )); then rm -f "$part"; have=0; fi
    if (( have < size )); then
        echo "fetching $rel ($((size / 1048576)) MB)"
        progress=(--silent --show-error)
        if (( size > 10485760 )); then progress=(--progress-bar); fi
        curl --fail --location --retry 5 --retry-delay 2 "${progress[@]}" --continue-at - --output "$part" \
            "https://huggingface.co/$REPO/resolve/$REVISION/$rel"
    fi
    if ! matches "$part" "$size" "$sha"; then
        rm -f "$part"
        echo "error: $rel doesn't match the manifest; run the script again" >&2
        exit 1
    fi
    mv "$part" "$target"
    fetched=$((fetched + 1))
done < "$MANIFEST"
echo "$REVISION" > "$DEST/.complete"
echo "Narrator model ready in $DEST ($kept already there, $copied copied, $fetched downloaded)"
