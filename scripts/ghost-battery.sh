#!/bin/zsh
# Samples battery power for N seconds and prints mean watts and ghost-text model calls per minute.
# Usage: scripts/ghost-battery.sh <seconds>
# Run unplugged: once idle (baseline), once while typing in Safari with ghost text on.
set -u
secs=${1:?usage: ghost-battery.sh <seconds>}
domain=theboringteam.boringnotch

calls_before=$(defaults read $domain ghostTextCalls 2>/dev/null || echo 0)
samples=()
end=$(( $(date +%s) + secs ))
while (( $(date +%s) < end )); do
  out=$(ioreg -rn AppleSmartBattery 2>/dev/null)
  amps=$(print -r -- "$out" | awk -F' = ' '/"InstantAmperage"/{print $2; exit}')
  volts=$(print -r -- "$out" | awk -F' = ' '/"Voltage"/{print $2; exit}')
  samples+=("${amps:-0} ${volts:-0}")
  sleep 2
done
calls_after=$(defaults read $domain ghostTextCalls 2>/dev/null || echo 0)

printf '%s\n' "${samples[@]}" | awk -v secs="$secs" -v calls="$(( calls_after - calls_before ))" '
NF == 2 {
  a = $1 + 0
  # Unsigned 64-bit readings above 2^63 are negative values (discharging).
  if (a > 9.2e18) a -= 1.8446744073709552e19
  v = $2 + 0
  s += (a < 0 ? -a : a) * v / 1e6
  n++
}
END {
  m = n ? s / n : 0
  printf "mean_w=%.2f samples=%d calls=%d calls_per_min=%.1f\n", m, n, calls, calls * 60 / secs
}'
