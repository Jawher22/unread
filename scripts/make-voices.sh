#!/bin/bash
# Makes the narrator's voice presets (#60) from scripts/voices/voices.json:
# Resources/Voices/<id>.{wav,json} and <id>-preview.m4a. See scripts/voices/make_voices.py.
#
#   scripts/make-voices.sh            every step; each skips what's already made
#   scripts/make-voices.sh <step>…    some steps: design asr install previews finish report
#   scripts/make-voices.sh audition ~/Desktop/voices   copy the previews there with readable names
#
# Needs: uv (the venv is made in build/voices/.venv from the pinned requirements), a release
# build (scripts/build.sh) and the narrator model (scripts/fetch-narrator.sh). VoiceDesign and
# Whisper download into ~/.cache/huggingface at their pinned revisions (~3 GB, ~1.6 GB).
#
# VoiceDesign and Whisper run on the GPU (VoiceDesign takes ~7 GB), so those steps run at
# utility priority and load one model at a time. The previews run on the Neural Engine with
# the app's own narrator, so a preview sounds the way reading will.
set -euo pipefail
cd "$(dirname "$0")/.."

venv=build/voices/.venv
if [ ! -x "$venv/bin/python" ]; then
    uv venv --quiet --python 3.12 "$venv"
    uv pip install --quiet --python "$venv/bin/python" -r scripts/voices/requirements.txt
fi
py=("$venv/bin/python" -I scripts/voices/make_voices.py)
low=(taskpolicy -c utility nice -n 10)

steps=("$@")
[ ${#steps[@]} -eq 0 ] && steps=(design asr install previews asr finish report)
[ "${steps[0]}" = audition ] && exec "${py[@]}" "${steps[@]}"
for step in "${steps[@]}"; do
    case "$step" in
        design|asr) "${low[@]}" "${py[@]}" "$step" ;;
        previews) "${py[@]}" previews .build/release/Unread ;;
        *) "${py[@]}" "$step" ;;
    esac
done
