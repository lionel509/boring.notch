#!/bin/bash
# Demo recorder for the cloud dictation rewrite (#13). Records the running app, not a render.
# Usage: scripts/dictation-demo.sh before|after <app> [seconds=20]
#   before|after  label for the GIF and file name (before = raw Apple paste only, after = rewrite on)
#   <app>         the app the take is pasted into, e.g. TextEdit, "Visual Studio Code", Slack
# Env: NOTCH_RECT="x,y,w,h" for the notch strip in screen points (required).
# Prints the timings from the take's log line. Output goes to scripts/out/ (gitignored).
set -euo pipefail

mode="${1:-}"; app="${2:-}"; seconds="${3:-20}"
if [[ "$mode" != "before" && "$mode" != "after" ]] || [[ -z "$app" ]]; then
  echo "usage: $0 before|after <app> [seconds]" >&2; exit 2
fi
if [[ -z "${NOTCH_RECT:-}" ]]; then
  echo "set NOTCH_RECT=x,y,w,h for the notch strip (screen points)" >&2; exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/scripts/out"; mkdir -p "$out"
stamp="$(date +%Y%m%d-%H%M%S)"
slug="$(echo "$app" | tr -c 'A-Za-z0-9' '-' | tr 'A-Z' 'a-z')"
mov="$out/dictation-$mode-$slug-$stamp.mov"
gif="$out/dictation-$mode-$slug-$stamp.gif"

# Window of the frontmost process; the operator brings <app> to the front first.
win="$(/usr/bin/osascript -e 'tell application "System Events" to tell (first application process whose frontmost is true) to get {position, size} of front window' 2>/dev/null | tr -d ' ' || true)"
if [[ -z "$win" ]]; then
  echo "no front window found; grant Accessibility to the terminal and bring $app forward" >&2; exit 1
fi
IFS=',' read -r wx wy ww wh <<<"$win"
IFS=',' read -r nx ny nw nh <<<"$NOTCH_RECT"

# One region covering the notch strip and the app window, so both sit in one capture.
x0=$(( nx < wx ? nx : wx )); y0=$(( ny < wy ? ny : wy ))
x1=$(( nx + nw > wx + ww ? nx + nw : wx + ww )); y1=$(( ny + nh > wy + wh ? ny + nh : wy + wh ))
region="$x0,$y0,$(( x1 - x0 )),$(( y1 - y0 ))"

echo "recording $seconds s of region $region ($mode, $app); start the take now"
/usr/sbin/screencapture -v -V "$seconds" -R "$region" "$mov"

# The take line: numbers and enums only, written by the app's TakeReport (see LogPrivacyTests).
line="$(/usr/bin/log show --last 5m --style compact \
  --predicate 'subsystem == "theboringteam.boringnotch" AND category == "Dictation"' 2>/dev/null \
  | grep 'take outcome' | tail -1 || true)"
field() { echo "$line" | tr ' ' '\n' | awk -F= -v k="$1" '$1==k {print $2; exit}'; }
mech="$(field mech)"; mech="${mech:-none}"

label="$mode | $app | mech=$mech"
ffmpeg -y -loglevel error -i "$mov" \
  -vf "fps=12,scale=960:-1:flags=lanczos,drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='$label':fontcolor=white:fontsize=20:box=1:boxcolor=black@0.6:x=12:y=12,split[a][b];[a]palettegen[p];[b][p]paletteuse" \
  "$gif"

echo "gif: $gif"
echo "mech=$mech"
for key in release_to_paste_ms first_cleanup_ms max_swap_ms swaps llm_ms rewrite; do
  echo "$key=$(field "$key")"
done
[[ -n "$line" ]] || echo "no 'take outcome' line in the last 5 minutes; check the Dictation log category"
