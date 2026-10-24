#!/bin/bash
# Speaker-ID demo and cost gate for dictation (#17 U5). Lionel speaks; this script cues, measures and gates.
# Usage: scripts/speaker-demo.sh [scene ...]        (default: music talker labelled)
#   music         Spotify (Music.app if Spotify is not running) at full volume; mode onlyMe. The player is
#                 polled every 0.5 s from Pop to Tink+2 s; the scene fails if it ever reads paused.
#   talker        talker video at a clearly lower level than his voice (+10 dB case); mode onlyMe
#   talker-0db    same talker at his level; known limit, run once; mode onlyMe
#   lecture       talker as the lecturer, he whispers a side remark; mode everyoneButMe
#   labelled      talker as the lecturer, he whispers; mode everyoneLabelled
#   enrol         Settings -> Learn voice, run to completion
#   enrol-cancel  Settings -> Learn voice, cancelled during "Learning your voice..."
# Env: TAKE_SECONDS=15 (Pop to Tink), BUNDLE_ID=theboringteam.boringnotch
# Per take or enrolment: helper pgrep before and 30 s after; helper footprint before, peak during, +5 s, +30 s;
# app RSS before and +30 s; app and helper CPU seconds (ps cputime deltas, never %cpu) over Pop to Tink+2 s.
# A take reads its TakeReport line from /usr/bin/log (category Dictation). Enrolment reads its per-prompt
# "take outcome=enrol-*" lines from the same category, read after the +30 s sample.
# src= (the mic channel the take or prompt read): -1 unset, -2 downmix, N the channel index.
# Gates, each fails loudly (stderr, exit 1): helper alive 30 s after; idle growth over 10 MB (helper footprint or
# app RSS, +30 s vs before); CPU over 8% of one core; music paused at any poll (music scene only);
# NEEDS A: src=0 on the music take and on every enrolment prompt.
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
  echo "usage: $0 [music|talker|talker-0db|lecture|labelled|enrol|enrol-cancel ...]   (default: music talker labelled)" >&2
  exit 2
}

# Per-scene settings: sets KIND (take|enrol), PLAYER (1 = poll the music player), MODE and TEXT.
scene_config() {
  KIND=take; PLAYER=0; MODE=""
  case "$1" in
    music)
      PLAYER=1; MODE=onlyMe
      TEXT="Spotify (or Music) plays at full volume on this Mac. Hold fn and dictate: 'Remind me to send the invoice to Sam before Friday.'" ;;
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
    enrol)
      KIND=enrol
      TEXT="Settings -> Learn voice. Let it run to completion. Tink when it says done." ;;
    enrol-cancel)
      KIND=enrol
      TEXT="Settings -> Learn voice. Cancel during 'Learning your voice...', then Tink." ;;
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

# The running music player, Spotify first. Only a running app is named, so osascript never launches one.
music_player() {
  if pgrep -x Spotify >/dev/null 2>&1; then echo Spotify
  elif pgrep -x Music >/dev/null 2>&1; then echo Music
  fi
}

# Footprint in MB of pid $1 (as footprint reports it); empty if the pid is gone.
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

# One value from a log line: logfield "<line>" <key> prints the value after key=.
logfield() {
  echo "$1" | awk -v k="$2" '{ for (i = 1; i <= NF; i++) { n = index($i, "="); if (n && substr($i, 1, n - 1) == k) { print substr($i, n + 1); exit } } }'
}

# Dictation log lines since $1 (local time, "YYYY-MM-DD HH:MM:SS") that carry a TakeReport outcome.
dictation_lines() {
  /usr/bin/log show --start "$1" --style compact \
    --predicate 'subsystem == "theboringteam.boringnotch" AND category == "Dictation"' 2>/dev/null \
    | grep 'take outcome' || true
}

# The last take line since $1 that is a take, not an enrolment prompt.
take_line() { dictation_lines "$1" | grep -v 'outcome=enrol-' | tail -1 || true; }

# Samples the helper's footprint once a second into $1 as "<pid> <MB>" until killed.
sample_during() {
  local pid
  while :; do
    pid="$(helper_pid)"
    if [[ -n "$pid" ]]; then echo "$pid $(footprint_mb "$pid")" >>"$1"; fi
    sleep 1
  done
}

# Polls the player state of app $2 every 0.5 s into $1 until killed.
sample_player() {
  local st
  while :; do
    st="$(/usr/bin/osascript -e "tell application \"$2\" to player state" 2>/dev/null || echo error)"
    echo "$st" >>"$1"
    sleep 0.5
  done
}

# True if $1 > $2 (both numeric).
greater() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'; }

# One row, tab-separated, for the summary table.
emit_row() { local IFS=$'\t'; printf '%s\n' "$*" >>"$rows"; }

work="$(mktemp -d)"
sampler=""
poller=""
stop_bg() {
  local p
  for p in "$sampler" "$poller"; do
    if [[ -n "$p" ]]; then kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; fi
  done
  sampler=""; poller=""
}
cleanup() { stop_bg; rm -rf "$work"; }
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
echo "app pid $app_pid; helper before the first scene: ${helper_start:-none}"

rows="$work/rows"; : >"$rows"
fails_file="$work/fails"; : >"$fails_file"

# One measured take or enrolment: cue, measure, read the log (take line or prompt lines), gate. Writes one row and any failures.
run_measured() {
  local n="$1" scene="$2"
  local helper0 helper1 alive_pid hpre hpeak="-" h5 h30 alive30 rss_pre rss30 cur_app
  local cpu_app0 cpu_app1 cpu_h0 cpu_h1 t0 t1 t2 target cpu_pct dapp dh
  local line="" enrol_all="" stamp player="" music_note="-" reasons="" result="" c
  local applog="-" mic="-" src="-" level="-" spk="-" app_cpu="-"

  scene_config "$scene"
  if [[ "$PLAYER" == 1 ]]; then
    player="$(music_player)"
    if [[ -z "$player" ]]; then
      echo "=== take $n: $scene skipped, neither Spotify nor Music is running" >&2
      printf '%s\n' "take $n ($scene): neither Spotify nor Music is running" >>"$fails_file"
      emit_row "$n" "$scene" - - - - - - - no - - - - - - - "FAIL no player running" -
      return 0
    fi
  fi
  if [[ "$KIND" == take ]]; then defaults write "$BUNDLE_ID" dictationSpeakerMode -string "$MODE"; fi

  echo ""
  echo "=== $KIND $n: $scene${MODE:+ (mode $MODE)}${player:+ (player $player)}"
  echo "$TEXT"
  echo "countdown:"
  for c in 3 2 1; do echo "  $c"; sleep 1; done

  helper0="$(helper_pid)"
  hpre="$(footprint_mb "$helper0")"; hpre="${hpre:--}"
  rss_pre="$(rss_mb "$app_pid")"; rss_pre="${rss_pre:--}"
  cpu_app0="$(cpu_secs "$app_pid")"
  cpu_h0="$(cpu_secs "$helper0")"
  stamp="$(date -v-3S '+%Y-%m-%d %H:%M:%S')"

  : >"$work/during"; : >"$work/player"
  cue Pop
  if [[ "$KIND" == take ]]; then echo "  GO: hold fn and speak"; else echo "  GO: click Learn voice"; fi
  t0="$(now)"
  sample_during "$work/during" &
  sampler=$!
  if [[ -n "$player" ]]; then sample_player "$work/player" "$player" & poller=$!; fi
  sleep "$TAKE_SECONDS"
  cue Tink
  if [[ "$KIND" == take ]]; then echo "  STOP: release fn"; else echo "  STOP: done or cancelled"; fi
  t1="$(now)"

  target="$(awk -v a="$t1" 'BEGIN { printf "%.3f\n", a + 2 }')"
  sleep_until "$target"
  helper1="$(helper_pid)"
  cpu_app1="$(cpu_secs "$app_pid")"
  cpu_h1="$(cpu_secs "$helper1")"
  t2="$(now)"
  stop_bg
  if [[ -s "$work/during" ]]; then
    hpeak="$(awk '{ if ($2 + 0 > m) m = $2 + 0 } END { printf "%.1f\n", m }' "$work/during")"
  fi

  target="$(awk -v a="$t1" 'BEGIN { printf "%.3f\n", a + 5 }')"
  sleep_until "$target"
  h5="$(footprint_mb "$(helper_pid)")"; h5="${h5:--}"

  target="$(awk -v a="$t1" 'BEGIN { printf "%.3f\n", a + 30 }')"
  sleep_until "$target"
  alive_pid="$(helper_pid)"
  if [[ -n "$alive_pid" ]]; then alive30="yes($alive_pid)"; h30="$(footprint_mb "$alive_pid")"; h30="${h30:--}"
  else alive30="no"; h30="-"; fi
  rss30="$(rss_mb "$app_pid")"; rss30="${rss30:--}"
  cur_app="$(pgrep -x "$APP_NAME" | head -1 || true)"

  if [[ "$KIND" == take ]]; then
    for _ in 1 2 3; do
      line="$(take_line "$stamp")"
      [[ -n "$line" ]] && break
      sleep 2
    done
  else
    enrol_all="$(dictation_lines "$stamp" | grep 'outcome=enrol-' || true)"
  fi

  dapp="$(awk -v a="$cpu_app1" -v b="$cpu_app0" 'BEGIN { printf "%.2f\n", a - b }')"
  if [[ "$helper1" == "$helper0" ]]; then dh="$(awk -v a="$cpu_h1" -v b="$cpu_h0" 'BEGIN { printf "%.2f\n", a - b }')"
  else dh="$cpu_h1"; fi
  cpu_pct="$(awk -v a="$dapp" -v b="$dh" -v s="$(awk -v x="$t2" -v y="$t0" 'BEGIN { printf "%.3f\n", x - y }')" 'BEGIN { printf "%.1f\n", (a + b) / s * 100 }')"

  # Gates.
  if [[ "$alive30" != "no" ]]; then reasons="$reasons; helper alive 30 s after $KIND (pid ${alive_pid})"; fi
  if [[ "$hpre" != "-" && "$h30" != "-" ]] && greater "$(awk -v a="$h30" -v b="$hpre" 'BEGIN { printf "%.1f\n", a - b }')" "$IDLE_LIMIT_MB"; then
    reasons="$reasons; helper idle growth over ${IDLE_LIMIT_MB} MB"
  fi
  if [[ "$rss_pre" != "-" && "$rss30" != "-" ]] && greater "$(awk -v a="$rss30" -v b="$rss_pre" 'BEGIN { printf "%.1f\n", a - b }')" "$IDLE_LIMIT_MB"; then
    reasons="$reasons; app RSS idle growth over ${IDLE_LIMIT_MB} MB"
  fi
  if greater "$cpu_pct" "$CPU_LIMIT_PCT"; then reasons="$reasons; CPU ${cpu_pct}% of one core over ${CPU_LIMIT_PCT}%"; fi
  if [[ "$cur_app" != "$app_pid" ]]; then reasons="$reasons; $APP_NAME restarted or exited"; fi
  if [[ "$KIND" == take && -z "$line" ]]; then reasons="$reasons; no 'take outcome' line in the log"; fi
  if [[ -n "$player" ]]; then
    local samples paused
    samples="$(grep -c . "$work/player" || true)"
    paused="$(grep -c '^paused$' "$work/player" || true)"
    music_note="${paused}/${samples} paused"
    if [[ "$paused" -gt 0 ]]; then reasons="$reasons; $player paused during the take"; fi
    if [[ "$samples" -eq 0 ]]; then reasons="$reasons; no player poll landed"; fi
  fi

  # NEEDS A: the mic channel. Music take: src=0. Enrolment: src=0 on every prompt line.
  if [[ -n "$line" ]]; then
    applog="$(logfield "$line" mode)"; applog="${applog:--}"
    level="$(logfield "$line" level)"; level="${level:--}"
    spk="$(logfield "$line" speakers)"; spk="${spk:--}"
    app_cpu="$(logfield "$line" cpu)"; app_cpu="${app_cpu:--}"
    mic="tap=$(logfield "$line" tap) vp=$(logfield "$line" vp)"
    src="$(logfield "$line" src)"; src="${src:--}"
  fi
  if [[ "$PLAYER" == 1 && "$src" != "0" ]]; then
    reasons="$reasons; NEEDS A: music take src=$src, expected 0"
  fi
  if [[ "$KIND" == enrol ]]; then
    src=""
    while IFS= read -r l; do
      [[ -n "$l" ]] || continue
      src="${src:+$src,}$(logfield "$l" src)"
    done <<<"$enrol_all"
    if [[ -z "$src" ]]; then
      src="none"
      if [[ "$scene" == enrol ]]; then reasons="$reasons; NEEDS A: no enrolment prompt logged"; fi
    elif [[ -n "$(printf '%s\n' "$src" | tr ',' '\n' | grep -v '^0$' || true)" ]]; then
      reasons="$reasons; NEEDS A: enrolment prompt src=$src, expected 0 on every prompt"
    fi
  fi

  result="PASS"
  if [[ -n "$reasons" ]]; then result="FAIL${reasons}"; printf '%s\n' "$KIND $n ($scene):${reasons}" >>"$fails_file"; fi

  emit_row "$n" "$scene" "$applog" "$mic" "$src" "$hpre" "$hpeak" "$h5" "$h30" "$alive30" "$rss_pre" "$rss30" \
    "$cpu_pct" "$app_cpu" "$level" "$spk" "$music_note" "$result" "$dapp"
  echo "  done: $scene $result"
}

n=0
for scene in "${scenes[@]}"; do
  n=$((n + 1))
  run_measured "$n" "$scene"
done

echo ""
echo "=== summary (#17 U5): mem in MB, cpu in % of one core over Pop to Tink+2 s; src = mic channel (-1 unset, -2 downmix, N channel)"
printf '%-3s %-12s %-15s %-17s %-7s %7s %7s %7s %7s %-9s %8s %8s %7s %7s %7s %4s %-10s %s\n' \
  no scene mode mic src h_pre h_peak h_+5s h_+30s alive+30 app_pre app_+30 cpu_ps cpu_app level spk music result
while IFS=$'\t' read -r n scene applog mic src hpre hpeak h5 h30 alive30 rss_pre rss30 cpu_pct app_cpu level spk music result dapp; do
  printf '%-3s %-12s %-15s %-17s %-7s %7s %7s %7s %7s %-9s %8s %8s %7s %7s %7s %4s %-10s %s\n' \
    "$n" "$scene" "$applog" "$mic" "$src" "$hpre" "$hpeak" "$h5" "$h30" "$alive30" "$rss_pre" "$rss30" \
    "$cpu_pct" "$app_cpu" "$level" "$spk" "$music" "$result"
done <"$rows"
echo "gates: helper alive at +30 s; idle growth > ${IDLE_LIMIT_MB} MB (helper footprint, app RSS); CPU > ${CPU_LIMIT_PCT}%; music never paused; NEEDS A: src=0 on the music take and every enrolment prompt"

if [[ -s "$fails_file" ]]; then
  echo "" >&2
  echo "!!! GATE FAILED !!!" >&2
  cat "$fails_file" >&2
  exit 1
fi
echo "all gates passed"
