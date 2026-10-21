#!/usr/bin/env bash
# Dictation demo: records the notch strip of the RUNNING boringNotch while the
# operator does a fixed script of takes, then reports GIF, strip-width timing
# and the TakeReport lines from the unified log.
#
# usage: scripts/dictation-demo.sh before|after [seconds=25]
#   before  run against the currently installed /Applications/boringNotch.app
#           (before any new build is installed)
#   after   run after the Release install
#
# Operator script, in order (press Enter at each prompt, the script marks the time):
#   1. one real take with fillers and a "no wait" correction, into TextEdit
#   2. one silent hold (failure case)
#   3. one quick tap
# Output: out/dictation-<label>.mov, out/dictation-<label>.gif, out/widths-<label>.txt
# and a summary on stdout. out/ is gitignored.

set -u

usage() {
  echo "usage: $0 before|after [seconds=25]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
LABEL="$1"
case "$LABEL" in
  before|after) ;;
  *) usage ;;
esac
SECONDS_REC="${2:-25}"
case "$SECONDS_REC" in
  ''|*[!0-9]*) usage ;;
esac

for tool in osascript screencapture ffmpeg pgrep ps; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool" >&2; exit 1; }
done

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/scripts/out"
mkdir -p "$OUT"

MOV="$OUT/dictation-$LABEL.mov"
GIF="$OUT/dictation-$LABEL.gif"
WIDTHS="$OUT/widths-$LABEL.txt"
MARKS="$OUT/marks-$LABEL.txt"

# Main display width, then the notch region centred at the top of the screen.
W="$(osascript -e 'tell application "Finder" to get bounds of window of desktop' </dev/null | awk -F', ' '{print $3}')"
case "$W" in
  ''|*[!0-9]*) echo "could not read display width" >&2; exit 1 ;;
esac
X=$((W / 2 - 320))

APP_PID="$(pgrep -x boringNotch </dev/null | head -1)"
if [ -z "$APP_PID" ]; then
  echo "boringNotch is not running" >&2
  exit 1
fi
RSS_BEFORE="$(ps -o rss= -p "$APP_PID" </dev/null | tr -d ' ')"

echo "display width: $W  region: $X,0,640,80  seconds: $SECONDS_REC  label: $LABEL"
echo "boringNotch pid $APP_PID, rss before: ${RSS_BEFORE} KB"

# Start recording in the background; the marks file holds seconds since start.
START_EPOCH="$(date +%s)"
screencapture -v -R "$X,0,640,80" -V "$SECONDS_REC" "$MOV" </dev/null &
REC_PID=$!
: > "$MARKS"

mark() {
  now="$(date +%s)"
  echo "$1 $((now - START_EPOCH))" >> "$MARKS"
}

echo "step 1: real take with fillers and a 'no wait' correction into TextEdit. Press Enter when done."
mark take_start
read -r _ </dev/tty
mark take_end

echo "step 2: silent hold (failure case). Press Enter when released."
mark fail_start
read -r _ </dev/tty
mark fail_end

echo "step 3: one quick tap. Press Enter when done."
mark tap_start
read -r _ </dev/tty
mark tap_end

wait "$REC_PID" 2>/dev/null
if [ ! -s "$MOV" ]; then
  echo "recording produced no file: $MOV (grant Screen Recording to the terminal)" >&2
  exit 1
fi

# GIF at 30 fps, 640 px wide.
ffmpeg -y -loglevel error -i "$MOV" -vf "fps=30,scale=640:-1" -loop 0 "$GIF" </dev/null

# Per-frame strip width. cropdetect logs one crop=W:H:X:Y line per frame to stderr.
ffmpeg -i "$MOV" -vf "negate,cropdetect=limit=24:round=2:reset=1" -f null - </dev/null 2>&1 \
  | grep -o 'crop=[0-9]*' | cut -d= -f2 > "$WIDTHS"

FRAMES="$(wc -l < "$WIDTHS" | tr -d ' ')"
if [ "$FRAMES" -lt 2 ]; then
  echo "too few frames measured ($FRAMES)" >&2
  exit 1
fi

# Analysis: first and last width change (appear/collapse length in ms at 30 fps),
# largest single-frame jump, and max width inside the failure segment.
FAIL_START="$(awk '$1=="fail_start"{print $2}' "$MARKS")"
FAIL_END="$(awk '$1=="fail_end"{print $2}' "$MARKS")"
awk -v fps=30 -v fs="${FAIL_START:-0}" -v fe="${FAIL_END:-0}" '
  { w[NR-1] = $1 + 0 }
  END {
    first = -1; last = -1; maxjump = 0; maxfail = 0
    for (i = 1; i < NR; i++) {
      d = w[i] - w[i-1]; if (d < 0) d = -d
      if (d > 0) { if (first < 0) first = i; last = i }
      if (d > maxjump) maxjump = d
    }
    for (i = 0; i < NR; i++) {
      t = i / fps
      if (t >= fs && t <= fe && w[i] > maxfail) maxfail = w[i]
    }
    if (first < 0) { printf "no width change measured\n" }
    else { printf "strip change: first frame %d, last frame %d, span %.0f ms\n", first, last, (last - first) * 1000 / fps }
    printf "largest single-frame width jump: %d px\n", maxjump
    printf "max width in failure segment (%.2fs-%.2fs): %d px\n", fs, fe, maxfail
    printf "frames measured: %d\n", NR
  }' "$WIDTHS"

echo "--- TakeReport (last 5 min) ---"
/usr/bin/log show --last 5m --style compact \
  --predicate 'subsystem == "theboringteam.boringnotch" AND category == "Dictation"' </dev/null \
  | grep 'take outcome' || echo "(no take outcome lines)"

RSS_AFTER="$(ps -o rss= -p "$APP_PID" </dev/null | tr -d ' ')"
echo "rss before: ${RSS_BEFORE} KB  after: ${RSS_AFTER:-gone} KB"
echo "gif: $GIF"
echo "widths: $WIDTHS"
