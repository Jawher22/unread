#!/bin/bash
# Release build. Use this rather than a bare `swift build -c release`.
#
# FluidAudio enables its package traits (TTS, NemoTextProcessing, Diarizer) as
# -D flags, and SwiftPM 6.2 emits them in Set order, which Swift randomizes per
# process. A new order is a new command line, so FluidAudio recompiles (~60 s)
# with no source change. Deterministic hashing keeps the order stable; any build
# without it can flip the order and cost the next one a full recompile.
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFT_DETERMINISTIC_HASHING=1 exec swift build -c release "$@"
