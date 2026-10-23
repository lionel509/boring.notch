#!/bin/bash
# Captures the closed notch while you hold fn (or any state you want to show).
# Usage: scripts/notch-shots.sh <label> [seconds=4] [interval=0.1]
# Override the captured rect with NOTCH_RECT="x,y,w,h" (points).
# Output: scripts/out/notch-<label>-<timestamp>/ with frames, full.png and a GIF if ffmpeg is installed.
set -euo pipefail

label="${1:?usage: notch-shots.sh <label> [seconds=4] [interval=0.1]}"
seconds="${2:-4}"
interval="${3:-0.1}"

width=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSScreen.mainScreen.frame.size.width')
if [ -n "${NOTCH_RECT:-}" ]; then
  rect="$NOTCH_RECT"
else
  rect=$(awk -v w="$width" 'BEGIN { printf "%d,0,400,60", w/2 - 200 }')
fi

root="$(cd "$(dirname "$0")" && pwd)/out"
dir="$root/notch-$label-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$dir"

echo "Hold fn in 3"; sleep 1
echo "Hold fn in 2"; sleep 1
echo "Hold fn in 1"; sleep 1
echo "NOW (keep holding until the script says it is done)"

frames=$(awk -v s="$seconds" -v i="$interval" 'BEGIN { printf "%d", s / i }')
for ((n = 0; n < frames; n++)); do
  screencapture -x -R"$rect" "$dir/$(printf %03d "$n").png"
  sleep "$interval"
done

screencapture -x "$dir/full.png"
echo "Capture done. You can release fn now."

if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -y -loglevel error -framerate 10 -i "$dir/%03d.png" "$dir.gif"
  echo "GIF: $dir.gif"
else
  echo "ffmpeg not on PATH, no GIF built"
fi

echo "$dir"
