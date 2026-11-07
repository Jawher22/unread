#!/bin/bash
# Judges the narrator's reading quality against fixed passages (#75). See scripts/voices/eval.py.
#
#   scripts/eval.sh passages                 assemble fixtures/eval/passages/ from fixtures/eval.txt
#   scripts/eval.sh render NAME [flags…]     read them with the narrator into fixtures/eval/runs/NAME/
#                                            (flags go to `Unread --eval`: --paragraph, --temperature T, --top-k K, --repetition R, --voice id,
#                                            --seed-salt S, --speed X, --stretch Y, --squeeze P, --reference-stretch R)
#   scripts/eval.sh elevenlabs [models]      the ElevenLabs references (ELEVENLABS_API_KEY; fixtures/eval/elevenlabs.json names model and voice)
#   scripts/eval.sh score NAME…              Whisper word errors, pitch spread, pauses ("elevenlabs" is the references)
#   scripts/eval.sh ab A B                   blind A/B page for two runs
#   scripts/eval.sh rate NAME                a run next to the ElevenLabs references, scored 1–5
#
# Everything under fixtures/eval/ is local (gitignored). Needs uv, a release build and the narrator model.
set -euo pipefail
cd "$(dirname "$0")/.."

venv=build/voices/.venv
if [ ! -x "$venv/bin/python" ]; then
    uv venv --quiet --python 3.12 "$venv"
    uv pip install --quiet --python "$venv/bin/python" -r scripts/voices/requirements.txt
fi
py=("$venv/bin/python" -I scripts/voices/eval.py)

step=${1:?usage: scripts/eval.sh passages|render|elevenlabs|score|ab|rate …}
shift
case "$step" in
    render)
        name=${1:?render: name the run}
        shift
        exec .build/release/Unread --eval fixtures/eval/passages --out "fixtures/eval/runs/$name" "$@"
        ;;
    score) exec taskpolicy -c utility nice -n 10 "${py[@]}" score "$@" ;;
    *) exec "${py[@]}" "$step" "$@" ;;
esac
