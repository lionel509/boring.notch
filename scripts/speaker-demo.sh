#!/bin/bash
# Speaker-ID demo and cost gate for dictation (#17 U5). Lionel speaks; this script cues, measures and gates.
# Usage: scripts/speaker-demo.sh [scene ...]        (default: music talker labelled)
#   music       Apple Music at full volume; mode onlyMe
#   talker      talker video at a clearly lower level than his voice (+10 dB case); mode onlyMe
#   talker-0db  same talker at his level; known limit, run once; mode onlyMe
#   lecture     talker as the lecturer, he whispers a side remark; mode everyoneButMe
#   labelled    talker as the lecturer, he whispers; mode everyoneLabelled
# Env: TAKE_SECONDS=15 (Pop to Tink), BUNDLE_ID=theboringteam.boringnotch
# Per take: helper (BoringNotchXPCHelper) pgrep before and 30 s after; helper footprint before, peak during,
# +5 s and +30 s; app RSS before and +30 s; app and helper CPU seconds (ps cputime deltas, never %cpu)
# over Pop to Tink+2 s, as % of one core. The take line comes from /usr/bin/log (category Dictation).
# Gates, each fails loudly (stderr, exit 1): helper alive 30 s after a take; idle growth over 10 MB
# (helper footprint or app RSS, +30 s vs before); CPU over 8% of one core.
# No stdin and no TTY: cues are afplay of system sounds, so this runs under `! scripts/speaker-demo.sh`.
exec </dev/null
set -euo pipefail

BUNDLE_ID="${BUNDLE_ID:-theboringteam.boringnotch}"
TAKE_SECONDS="${TAKE_SECONDS:-15}"
APP_NAME="boringNotch"
HELPER_NAME="BoringNotchXPCHelper"
IDLE_LIMIT_MB=10
CPU_LIMIT_PCT=8

usage() {
  echo "usage: $0 [music|talker|talker-0db|lecture|labelled ...]   (default: music talker labelled)" >&2
  exit 2
}

# Per-scene settings: sets MODE and TEXT, or fails for an unknown scene.
scene_config() {
  case "$1" in
    music)
      MODE=onlyMe
      TEXT="Apple Music plays at full volume on this Mac. Hold fn and dictate: 'Remind me to send the invoice to Sam before Friday.'" ;;
    talker)
      MODE=onlyMe
      TEXT="A talker's video plays beside the Mac at a clearly lower level than your voice (about +10 dB). Hold fn and dictate: 'Move the stringing rig to the second shelf.'" ;;
    talker-0db)
      MODE=onlyMe
      TEXT="Same talker at the same loudness as your voice (0 dB). Known limit, recorded once. Hold fn and dictate: 'Move the stringing rig to the second shelf.'" ;;
    lecture)
      MODE=everyoneButMe
      TEXT="A lecturer's video plays. Hold fn, whisper 'Did you finish the problem set?', release. Expect the lecturer's words pasted and the whisper left out." ;;
    labelled)
      MODE=everyoneLabelled
      TEXT="A lecturer's video plays. Hold fn, whisper 'Did you finish the problem set?', release. Expect 'Me:' and 'Speaker 2:' lines." ;;
    *) return 1 ;;
  esac
}

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

# Sleep until epoch second $1 (returns at once if it has passed).
sleep_until() {
  local d
  d="$(awk -v t="$1" -v n="$(now)" 'BEGIN { d = t - n; if (d < 0) d = 0; printf "%.3f\n", d }')"
  sleep "$d"
}

cue() { /usr/bin/afplay "/System/Library/Sounds/$1.aiff" || true; }

helper_pid() { pgrep -x "$HELPER_NAME" | head -1 || true; }

# Footprint in MB of pid $1 (dirty + compressed, as footprint reports it); empty if the pid is gone.
footprint_mb() {
  [[ -n "$1" ]] || return 0
  /usr/bin/footprint -p "$1" 2>/dev/null | awk '
    /Footprint:/ { for (i = 1; i < NF; i++) if ($i == "Footprint:") { v = $(i + 1); u = $(i + 2) } }
    END {
      if (v == "") exit 1
      m = v
      if (u == "B") m = v / 1048576; else if (u == "KB") m = v / 1024; else if (u == "GB") m = v * 1024
      printf "%.1f\n", m
    }' || true
}

# Resident set size in MB of pid $1 (ps reports KB).
rss_mb() {
  [[ -n "$1" ]] || return 0
  ps -o rss= -p "$1" 2>/dev/null | awk 'NF { printf "%.1f\n", $1 / 1024 }' || true
}

# Cumulative CPU seconds of pid $1 from ps cputime ([D-]HH:MM:SS or MM:SS.hh); 0 if the pid is gone.
cpu_secs() {
  [[ -n "$1" ]] || { echo 0; return 0; }
  ps -o cputime= -p "$1" 2>/dev/null | awk '
    NF {
      t = $1; d = 0
      if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
      n = split(t, p, ":"); s = 0
      for (i = 1; i <= n; i++) s = s * 60 + p[i]
      printf "%.2f\n", d * 86400 + s; found = 1
    }
    END { if (!found) print 0 }' || true
}

# One value from the take line: logfield "<line>" <key> prints the value after key=.
logfield() {
  echo "$1" | awk -v k="$2" '{ for (i = 1; i <= NF; i++) { n = index($i, "="); if (n && substr($i, 1, n - 1) == k) { print substr($i, n + 1); exit } } }'
}

# The TakeReport line logged since $1 (local time, "YYYY-MM-DD HH:MM:SS").
take_line() {
  /usr/bin/log show --start "$1" --style compact \
    --predicate 'subsystem == "theboringteam.boringnotch" AND category == "Dictation"' 2>/dev/null \
    | grep 'take outcome' | tail -1 || true
}

# Samples the helper's footprint once a second into $1 as "<pid> <MB>" until killed.
sample_during() {
  local pid
  while :; do
    pid="$(helper_pid)"
    if [[ -n "$pid" ]]; then echo "$pid $(footprint_mb "$pid")" >>"$1"; fi
    sleep 1
  done
}

# True if $1 > $2 (both numeric).
greater() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'; }

work="$(mktemp -d)"
sampler=""
cleanup() {
  if [[ -n "$sampler" ]]; then kill "$sampler" 2>/dev/null || true; wait "$sampler" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

scenes=("$@")
[[ ${#scenes[@]} -gt 0 ]] || scenes=(music talker labelled)
talker0=0
for s in "${scenes[@]}"; do
  scene_config "$s" || usage
  [[ "$s" == "talker-0db" ]] && talker0=$((talker0 + 1))
done
if [[ $talker0 -gt 1 ]]; then echo "talker-0db is the known-limit take: run it once" >&2; exit 2; fi

app_pid="$(pgrep -x "$APP_NAME" | head -1 || true)"
if [[ -z "$app_pid" ]]; then echo "$APP_NAME is not running: start the app, then re-run" >&2; exit 2; fi
helper_start="$(helper_pid)"
echo "app pid $app_pid; helper before the first take: ${helper_start:-none}"
echo "rows: $work/rows (scratch, removed on exit)"

rows="$work/rows"
: >"$rows"
fails_file="$work/fails"
: >"$fails_file"

# One take: cue, measure, read the take line, gate. Appends one row to $rows and failures to $fails_file.
run_take() {
  local n="$1" scene="$2"
  local helper0 helper1 hpre hpeak="-" h5 h30 alive30 rss_pre rss30 line stamp
  local cpu_app0 cpu_app1 cpu_h0 cpu_h1 t0 t1 t2 target cpu_pct dapp dh cur_app
  local level spk applog reasons=""

  scene_config "$scene"
  defaults write "$BUNDLE_ID" dictationSpeakerMode -string "$MODE"
  echo ""
  echo "=== take $n: $scene (mode $MODE)"
  echo "$TEXT"
  echo "countdown:"
  for c in 3 2 1; do echo "  $c"; sleep 1; done

  helper0="$(helper_pid)"
  hpre="$(footprint_mb "$helper0")"; hpre="${hpre:--}"
  rss_pre="$(rss_mb "$app_pid")"; rss_pre="${rss_pre:--}"
  cpu_app0="$(cpu_secs "$app_pid")"
  cpu_h0="$(cpu_secs "$helper0")"
  stamp="$(date -v-3S '+%Y-%m-%d %H:%M:%S')"

  : >"$work/during"
  cue Pop
  echo "  GO: hold fn and speak"
  t0="$(now)"
  sample_during "$work/during" &
  sampler=$!
  sleep "$TAKE_SECONDS"
  cue Tink
  echo "  STOP: release fn"
  t1="$(now)"

  target="$(awk -v a="$t1" 'BEGIN { printf "%.3f\n", a + 2 }')"
  sleep_until "$target"
  helper1="$(helper_pid)"
  cpu_app1="$(cpu_secs "$app_pid")"
  cpu_h1="$(cpu_secs "$helper1")"
  t2="$(now)"
  kill "$sampler" 2>/dev/null || true; wait "$sampler" 2>/dev/null || true; sampler=""
  if [[ -s "$work/during" ]]; then
    hpeak="$(awk '{ if ($2 + 0 > m) m = $2 + 0 } END { printf "%.1f\n", m }' "$work/during")"
  fi

  target="$(awk -v a="$t1" 'BEGIN { printf "%.3f\n", a + 5 }')"
  sleep_until "$target"
  h5="$(footprint_mb "$(helper_pid)")"; h5="${h5:--}"

  target="$(awk -v a="$t1" 'BEGIN { printf "%.3f\n", a + 30 }')"
  sleep_until "$target"
  local alive_pid
  alive_pid="$(helper_pid)"
  if [[ -n "$alive_pid" ]]; then alive30="yes($alive_pid)"; h30="$(footprint_mb "$alive_pid")"; h30="${h30:--}"
  else alive30="no"; h30="-"; fi
  rss30="$(rss_mb "$app_pid")"; rss30="${rss30:--}"
  cur_app="$(pgrep -x "$APP_NAME" | head -1 || true)"

  line=""
  for _ in 1 2 3; do
    line="$(take_line "$stamp")"
    [[ -n "$line" ]] && break
    sleep 2
  done

  dapp="$(awk -v a="$cpu_app1" -v b="$cpu_app0" 'BEGIN { printf "%.2f\n", a - b }')"
  if [[ "$helper1" == "$helper0" ]]; then dh="$(awk -v a="$cpu_h1" -v b="$cpu_h0" 'BEGIN { printf "%.2f\n", a - b }')"
  else dh="$cpu_h1"; fi
  cpu_pct="$(awk -v a="$dapp" -v b="$dh" -v s="$(awk -v x="$t2" -v y="$t0" 'BEGIN { printf "%.3f\n", x - y }')" 'BEGIN { printf "%.1f\n", (a + b) / s * 100 }')"

  # Gates.
  if [[ "$alive30" != "no" ]]; then reasons="$reasons; helper alive 30 s after take (pid ${alive_pid})"; fi
  if [[ "$hpre" != "-" && "$h30" != "-" ]] && greater "$(awk -v a="$h30" -v b="$hpre" 'BEGIN { printf "%.1f\n", a - b }')" "$IDLE_LIMIT_MB"; then
    reasons="$reasons; helper idle growth over ${IDLE_LIMIT_MB} MB"
  fi
  if [[ "$rss_pre" != "-" && "$rss30" != "-" ]] && greater "$(awk -v a="$rss30" -v b="$rss_pre" 'BEGIN { printf "%.1f\n", a - b }')" "$IDLE_LIMIT_MB"; then
    reasons="$reasons; app RSS idle growth over ${IDLE_LIMIT_MB} MB"
  fi
  if greater "$cpu_pct" "$CPU_LIMIT_PCT"; then reasons="$reasons; CPU ${cpu_pct}% of one core over ${CPU_LIMIT_PCT}%"; fi
  if [[ -z "$line" ]]; then reasons="$reasons; no 'take outcome' line in the log"; fi
  if [[ "$cur_app" != "$app_pid" ]]; then reasons="$reasons; $APP_NAME restarted or exited during the take"; fi

  if [[ -n "$line" ]]; then
    applog="$(logfield "$line" mode)"; applog="${applog:--}"
    level="$(logfield "$line" level)"; level="${level:--}"
    spk="$(logfield "$line" speakers)"; spk="${spk:--}"
    app_cpu="$(logfield "$line" cpu)"; app_cpu="${app_cpu:--}"
  else
    applog="-"; level="-"; spk="-"; app_cpu="-"
  fi
  local result="PASS"
  if [[ -n "$reasons" ]]; then result="FAIL${reasons}"; printf '%s\n' "take $n ($scene):${reasons}" >>"$fails_file"; fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$n" "$scene" "$applog" "$hpre" "$hpeak" "$h5" "$h30" "$alive30" "$rss_pre" "$rss30" \
    "$cpu_pct" "$app_cpu" "$level" "$spk" "$result" "$dapp" >>"$rows"
  echo "  done: take $n $result"
}

n=0
for scene in "${scenes[@]}"; do
  n=$((n + 1))
  run_take "$n" "$scene"
done

echo ""
echo "=== summary (#17 U5): mem in MB, cpu in % of one core over Pop to Tink+2 s"
printf '%-4s %-11s %-15s %8s %8s %8s %8s %-9s %9s %9s %8s %8s %7s %4s %s\n' \
  take scene mode h_pre h_peak h_+5s h_+30s alive+30 app_pre app_+30 cpu_ps cpu_app level spk result
while IFS=$'\t' read -r n scene applog hpre hpeak h5 h30 alive30 rss_pre rss30 cpu_pct app_cpu level spk result dapp; do
  printf '%-4s %-11s %-15s %8s %8s %8s %8s %-9s %9s %9s %8s %8s %7s %4s %s\n' \
    "$n" "$scene" "$applog" "$hpre" "$hpeak" "$h5" "$h30" "$alive30" "$rss_pre" "$rss30" \
    "$cpu_pct" "$app_cpu" "$level" "$spk" "$result"
done <"$rows"
echo "gates: helper alive at +30 s; idle growth > ${IDLE_LIMIT_MB} MB (helper footprint, app RSS); CPU > ${CPU_LIMIT_PCT}%"

if [[ -s "$fails_file" ]]; then
  echo "" >&2
  echo "!!! GATE FAILED !!!" >&2
  cat "$fails_file" >&2
  exit 1
fi
echo "all gates passed"
