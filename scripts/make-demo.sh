#!/bin/zsh
# Renders Tally's panel offscreen with your real usage (project names hidden),
# then builds promo/tally-demo.mp4 and promo/tally-demo.gif.
# Needs ffmpeg, plus Python 3 with Pillow and numpy.
set -e
cd "$(dirname "$0")/.."
swift build -c release
SNAP=$(mktemp -d)
TALLY_DEMO_DIR=$SNAP .build/release/Tally --snapshot /dev/null
python3 scripts/make-demo.py "$SNAP" promo
