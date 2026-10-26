#!/bin/zsh
# Checks scripts/ghost-battery.sh without a live battery or the real app prefs.
# Usage: scripts/test_ghost_battery.sh
set -u
here=${0:A:h}
script=$here/ghost-battery.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
prefs=$tmp/prefs
fail=0

check() { # name, expected substring, actual output
  if [[ "$3" == *"$2"* ]]; then print -r -- "PASS $1"; else print -r -- "FAIL $1: wanted '$2' got '$3'"; fail=1; fi
}

# 1. Counter is read from the sandboxed container prefs (the path the app writes).
defaults write "$prefs" ghostTextCalls 5
print -r -- '  |   "Voltage" = 12000' > "$tmp/ioreg1"
print -r -- '  |   "InstantAmperage" = 1000' >> "$tmp/ioreg1"
out=$( (sleep 0.5; defaults write "$prefs" ghostTextCalls 8) & GHOST_PREFS=$prefs GHOST_IOREG_FILE=$tmp/ioreg1 $script 1 2>&1; wait )
check "calls delta from prefs" "calls=3" "$out"

# 2. Unsigned 64-bit discharge (2^64 - 1000 mA) reads as 12.00 W, not 0.00 W.
print -r -- '  |   "Voltage" = 12000' > "$tmp/ioreg2"
print -r -- '  |   "InstantAmperage" = 18446744073709550616' >> "$tmp/ioreg2"
out=$(GHOST_PREFS=$prefs GHOST_IOREG_FILE=$tmp/ioreg2 $script 1 2>&1)
check "discharge decode" "mean_w=12.00" "$out"

# 3. No battery in ioreg is an error, not a 0.00 W baseline.
: > "$tmp/ioreg3"
out=$(GHOST_PREFS=$prefs GHOST_IOREG_FILE=$tmp/ioreg3 $script 1 2>&1); code=$?
if (( code != 0 )) && [[ "$out" == *"no battery"* ]]; then print -r -- "PASS no battery is an error"; else print -r -- "FAIL no battery: exit=$code out=$out"; fail=1; fi

exit $fail
