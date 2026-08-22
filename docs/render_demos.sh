#!/usr/bin/env bash
# Render all BashTab demo tapes and convert them to GIF.
#
# Usage:  docs/render_demos.sh [tape ...]     (default: all docs/demo*.tape)
#
# Requires: vhs, ttyd, ffmpeg.
# Tapes Output .mp4 because vhs's built-in GIF encoder produces 0-byte
# files in some containers; ffmpeg does the mp4 -> gif conversion here
# (two-pass palette, 15 fps).
#
# Container note: if chromium fails with a namespace/sandbox error, create
# a wrapper that adds --no-sandbox and put it first on PATH:
#   mkdir -p /tmp/vhs-bin
#   printf '#!/bin/sh\nexec /usr/bin/chromium --no-sandbox --disable-gpu --disable-dev-shm-usage "$@"\n' > /tmp/vhs-bin/chromium
#   chmod +x /tmp/vhs-bin/chromium
#   PATH=/tmp/vhs-bin:$PATH docs/render_demos.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if (($#)); then
    tapes=("$@")
else
    tapes=(docs/demo.tape docs/demo-query.tape docs/demo-pipeline.tape docs/demo-external.tape docs/demo-help.tape)
fi

for tape in "${tapes[@]}"; do
    mp4=${tape%.tape}.mp4
    gif=${tape%.tape}.gif
    echo "== vhs $tape"
    vhs "$tape"
    echo "== ffmpeg $mp4 -> $gif"
    ffmpeg -y -v error -i "$mp4" \
        -vf "fps=15,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer" \
        "$gif"
done
