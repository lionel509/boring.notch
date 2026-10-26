#!/bin/zsh
# Samples battery power for N seconds and prints mean watts and ghost-text model calls per minute.
# Usage: scripts/ghost-battery.sh <seconds>
# Run unplugged: once idle (baseline), once while typing in Safari with ghost text on.
# Test hooks: GHOST_PREFS (prefs file path) and GHOST_IOREG_FILE (canned ioreg output).
set -u
secs=${1:?usage: ghost-battery.sh <seconds>}
[[ $secs == <1-> ]] || { print -u2 "seconds must be a whole number above 0"; exit 2 }
# The app is sandboxed, so it writes ghostTextCalls to its container, not the shared domain.
prefs=${GHOST_PREFS:-$HOME/Library/Containers/theboringteam.boringnotch/Data/Library/Preferences/theboringteam.boringnotch}
read_calls() { defaults read "$prefs" ghostTextCalls 2>/dev/null || echo 0; }

calls_before=$(read_calls)
samples=()
end=$(( $(date +%s) + secs ))
while (( $(date +%s) < end )); do
  if [[ -n ${GHOST_IOREG_FILE:-} ]]; then out=$(cat "$GHOST_IOREG_FILE"); else out=$(ioreg -rn AppleSmartBattery 2>/dev/null); fi
  amps=$(print -r -- "$out" | awk -F' = ' '/^[ |]*"InstantAmperage" = /{print $2; exit}')
  volts=$(print -r -- "$out" | awk -F' = ' '/^[ |]*"Voltage" = /{print $2; exit}')
  if [[ -z $amps || -z $volts ]]; then
    print -u2 "no battery: ioreg AppleSmartBattery has no InstantAmperage/Voltage"
    exit 1
  fi
  # Discharge is an unsigned 64-bit value above 2^63. Convert it as an exact integer,
  # because awk doubles lose the milliamp digits at that size.
  if [[ $amps == <-> ]] && { (( ${#amps} == 20 )) || { (( ${#amps} == 19 )) && [[ $amps > 9223372036854775807 ]] } }; then
    amps=$(print -r -- "$amps - 18446744073709551616" | bc)
  fi
  samples+=("$amps $volts")
  sleep 2
done
calls_after=$(read_calls)

printf '%s\n' "${samples[@]}" | awk -v secs="$secs" -v calls="$(( calls_after - calls_before ))" '
NF == 2 {
  a = $1 + 0
  v = $2 + 0
  s += (a < 0 ? -a : a) * v / 1e6
  n++
}
END {
  m = n ? s / n : 0
  printf "mean_w=%.2f samples=%d calls=%d calls_per_min=%.1f\n", m, n, calls, calls * 60 / secs
}'
