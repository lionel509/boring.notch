#!/bin/zsh
# Checks scripts/local-release.sh with stubbed xcodebuild, security, codesign, pgrep, pkill, osascript, open, ditto and ps.
# Nothing real is touched: no keychain, no DerivedData, no /Applications, no app launch, no keystrokes.
# Usage: scripts/test_local_release.sh
set -u
here=${0:A:h}
script=$here/local-release.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stubs=$tmp/stubs
mkdir -p "$stubs" "$tmp/apps"
export CALLS=$tmp/calls.log
export LAUNCHED=$tmp/launched
export BN_DERIVED_DATA=$tmp/dd
export BN_INSTALL_DIR=$tmp/apps
export STUB_CODESIGN_OUT='Authority=boringNotch Local Signing
flags=0x0(none)
designated => identifier "theboringteam.boringnotch" and certificate leaf = H"0123abcd"'
fail=0

check() { # name, exit status of the test; on failure the last run's output is shown
  if (( $2 == 0 )); then print -r -- "PASS $1"; else print -r -- "FAIL $1"; print -r -- "$out" | tail -12 | sed 's/^/    | /'; fail=1; fi
}

# Stubs: each one appends its argv to $CALLS and acts on the env vars the cases set.
cat > "$stubs/xcodebuild" <<'EOF'
#!/bin/zsh
print -r -- "xcodebuild $*" >> "$CALLS"
mkdir -p "$BN_DERIVED_DATA/Build/Products/Release/boringNotch.app/Contents/XPCServices/BoringNotchXPCHelper.xpc"
EOF
cat > "$stubs/security" <<'EOF'
#!/bin/zsh
print -r -- "security $*" >> "$CALLS"
if [[ "$1" == find-identity ]]; then
  [[ -n "${STUB_NO_IDENTITY:-}" ]] || print -r -- '  1) 0123ABCD "boringNotch Local Signing"'
  print -r -- '     1 valid identities found'
fi
exit 0
EOF
cat > "$stubs/codesign" <<'EOF'
#!/bin/zsh
print -r -- "codesign $*" >> "$CALLS"
print -r -- "$STUB_CODESIGN_OUT"
EOF
cat > "$stubs/pgrep" <<'EOF'
#!/bin/zsh
print -r -- "pgrep $*" >> "$CALLS"
name=$argv[-1]
if [[ " ${STUB_RUNNING:-} " == *" $name "* ]] || { [[ $name == boringNotch && -e "$LAUNCHED" ]]; }; then
  print -r -- 4242
  exit 0
fi
exit 1
EOF
cat > "$stubs/pkill" <<'EOF'
#!/bin/zsh
print -r -- "pkill $*" >> "$CALLS"
EOF
cat > "$stubs/osascript" <<'EOF'
#!/bin/zsh
print -r -- "osascript $*" >> "$CALLS"
EOF
cat > "$stubs/open" <<'EOF'
#!/bin/zsh
print -r -- "open $*" >> "$CALLS"
touch "$LAUNCHED"
EOF
cat > "$stubs/ditto" <<'EOF'
#!/bin/zsh
print -r -- "ditto $*" >> "$CALLS"
mkdir -p "$2"
EOF
cat > "$stubs/ps" <<'EOF'
#!/bin/zsh
print -r -- "ps $*" >> "$CALLS"
print -r -- 1
EOF
chmod +x "$stubs"/*

run() { # runs the script with the stubs first on PATH; prints combined output
  PATH="$stubs:$PATH" zsh "$script" "$@" 2>&1
}
reset() { rm -f "$CALLS" "$LAUNCHED"; rm -rf "$BN_DERIVED_DATA" "$BN_INSTALL_DIR"; mkdir -p "$BN_INSTALL_DIR"; unset STUB_RUNNING STUB_NO_IDENTITY; export STUB_CODESIGN_OUT; }
calls_has() { grep -q -- "$1" "$CALLS" 2>/dev/null; }

# 1. Another xcodebuild running: refuse before anything else runs.
reset
export STUB_RUNNING=xcodebuild
out=$(run); code=$?
if (( code == 3 )) && ! grep -q '^xcodebuild ' "$CALLS" 2>/dev/null; then ok=0; else ok=1; fi
check "refuses while another build runs (exit $code)" $ok

# 2. Normal run: exit 0 and the xcodebuild argv carries the identity, Manual signing, hardened runtime off, no -target.
reset
out=$(run); code=$?
argv=$(grep '^xcodebuild ' "$CALLS" 2>/dev/null)
ok=0
(( code == 0 )) || ok=1
[[ "$argv" == *"-scheme boringNotch"* ]] || ok=1
[[ "$argv" == *"-configuration Release"* ]] || ok=1
[[ "$argv" == *"CODE_SIGN_IDENTITY=boringNotch Local Signing"* ]] || ok=1
[[ "$argv" == *"CODE_SIGN_STYLE=Manual"* ]] || ok=1
[[ "$argv" == *"ENABLE_HARDENED_RUNTIME=NO"* ]] || ok=1
[[ "$argv" != *"-target"* ]] || ok=1
check "normal run builds with the local identity (exit $code)" $ok

# 3. Ad-hoc signature is refused.
reset
export STUB_CODESIGN_OUT='Authority=boringNotch Local Signing
Signature=adhoc
flags=0x2(adhoc)
certificate leaf = H"0123abcd"'
out=$(run); code=$?
(( code == 6 )) && ok=0 || ok=1
check "ad-hoc signature is refused (exit $code)" $ok

# 4. Hardened runtime is refused, even with the right authority.
reset
export STUB_CODESIGN_OUT='Authority=boringNotch Local Signing
flags=0x10000(runtime)
certificate leaf = H"0123abcd"'
out=$(run); code=$?
(( code == 6 )) && ok=0 || ok=1
check "hardened runtime is refused (exit $code)" $ok
export STUB_CODESIGN_OUT='Authority=boringNotch Local Signing
flags=0x0(none)
designated => identifier "theboringteam.boringnotch" and certificate leaf = H"0123abcd"'

# 5. No identity and the one-time creation does not produce one: exit 4, and the cert was imported and trusted.
reset
export STUB_NO_IDENTITY=1
out=$(run); code=$?
ok=0
(( code == 4 )) || ok=1
calls_has '^security import ' || ok=1
calls_has '^security add-trusted-cert ' || ok=1
check "missing identity is created, then refused if still missing (exit $code)" $ok

# 6. --install: quit, replace, ditto, open, in that order, and the installed copy is the new one.
reset
out=$(run --install); code=$?
ok=0
(( code == 0 )) || ok=1
[[ -d "$BN_INSTALL_DIR/boringNotch.app" ]] || ok=1
q=$(grep -n '^osascript ' "$CALLS" | head -1 | cut -d: -f1)
d=$(grep -n '^ditto ' "$CALLS" | head -1 | cut -d: -f1)
o=$(grep -n '^open ' "$CALLS" | head -1 | cut -d: -f1)
[[ -n "$q" && -n "$d" && -n "$o" ]] || ok=1
(( ${q:-0} < ${d:-0} && ${d:-0} < ${o:-0} )) || ok=1
check "--install quits, copies, then opens (exit $code)" $ok

exit $fail
