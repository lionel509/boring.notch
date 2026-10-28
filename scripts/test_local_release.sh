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
GOOD_CODESIGN='Authority=boringNotch Local Signing
flags=0x0(none)
designated => identifier "theboringteam.boringnotch" and certificate leaf = H"0123abcd"'
export STUB_CODESIGN_OUT="$GOOD_CODESIGN"
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
name=${STUB_IDENT_NAME:-boringNotch Local Signing}
if [[ "$1" == find-identity ]]; then
  if [[ " $* " == *" -v "* ]]; then
    # -v lists only trusted identities; STUB_UNTRUSTED hides the one there is, STUB_DUP adds a second with the same name.
    if [[ -z "${STUB_NO_IDENTITY:-}" && -z "${STUB_UNTRUSTED:-}" ]]; then
      print -r -- "  1) 0123ABCD \"$name\""
      [[ -n "${STUB_DUP:-}" ]] && print -r -- "  2) 0123EEEE \"$name\""
    fi
    print -r -- '     1 valid identities found'
  elif [[ -n "${STUB_MIXED:-}" ]]; then
    # Round-3 finding 1: one trusted and one untrusted copy of the name. The plain listing has a Matching section
    # and a Valid section that repeats the trusted identity.
    print -r -- "Policy: X.509 Basic"
    print -r -- "  Matching identities"
    print -r -- "  1) 0123ABCD \"$name\""
    print -r -- "  2) 0123EEEE \"$name\" (CSSMERR_TP_NOT_TRUSTED)"
    print -r -- "     2 identities found"
    print -r -- ""
    print -r -- "  Valid identities only"
    print -r -- "  1) 0123ABCD \"$name\""
    print -r -- "     1 valid identities found"
  elif [[ -n "${STUB_BOTH_SECTIONS:-}" ]]; then
    # One trusted identity, listed in both sections as the real plain listing does: it is one identity.
    print -r -- "Policy: X.509 Basic"
    print -r -- "  Matching identities"
    print -r -- "  1) 0123ABCD \"$name\""
    print -r -- "     1 identities found"
    print -r -- ""
    print -r -- "  Valid identities only"
    print -r -- "  1) 0123ABCD \"$name\""
    print -r -- "     1 valid identities found"
  elif [[ -z "${STUB_NO_IDENTITY:-}" ]]; then
    # Without -v the untrusted one is listed, marked as not trusted.
    mark=""
    [[ -n "${STUB_UNTRUSTED:-}" ]] && mark=" (CSSMERR_TP_NOT_TRUSTED)"
    print -r -- "  1) 0123ABCD \"$name\"$mark"
  fi
fi
if [[ "$1" == add-trusted-cert && -n "${STUB_TRUST_FAIL:-}" ]]; then exit 1; fi
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
reset() { rm -f "$CALLS" "$LAUNCHED"; rm -rf "$BN_DERIVED_DATA" "$BN_INSTALL_DIR"; mkdir -p "$BN_INSTALL_DIR"; unset STUB_RUNNING STUB_NO_IDENTITY STUB_UNTRUSTED STUB_DUP STUB_MIXED STUB_BOTH_SECTIONS STUB_TRUST_FAIL STUB_IDENT_NAME BN_SIGN_IDENTITY; export STUB_CODESIGN_OUT="$GOOD_CODESIGN"; }
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

# 7. Round-1 fix 2: an untrusted same-name identity exists. Exit 4 without importing a second copy.
reset
export STUB_UNTRUSTED=1
out=$(run); code=$?
ok=0
(( code == 4 )) || ok=1
calls_has '^security import ' && ok=1
check "untrusted same-name identity is not imported again (exit $code)" $ok

# 8. Round-1 fix 2: add-trusted-cert fails (declined prompt). Exit 4 with a message, not security's own status.
reset
export STUB_NO_IDENTITY=1 STUB_TRUST_FAIL=1
out=$(run); code=$?
ok=0
(( code == 4 )) || ok=1
[[ "$out" == *"trust"* ]] || ok=1
check "a declined trust prompt exits 4 with a message (exit $code)" $ok

# 9. Round-1 fix 3: two trusted identities with the same name. Exit 4 before xcodebuild.
reset
export STUB_DUP=1
out=$(run); code=$?
ok=0
(( code == 4 )) || ok=1
calls_has '^xcodebuild ' && ok=1
check "two same-name trusted identities are refused before the build (exit $code)" $ok

# 10. Round-1 fix 6: a stray argument after --install is a usage error, nothing installs.
reset
out=$(run --install extra); code=$?
ok=0
(( code == 2 )) || ok=1
calls_has '^ditto ' && ok=1
calls_has '^xcodebuild ' && ok=1
check "a stray argument exits 2 and installs nothing (exit $code)" $ok

# 11. Round-1 fix 4: the identity is matched literally, so 'boringNotch.Local' does not match 'boringNotchXLocal'.
reset
export STUB_IDENT_NAME='boringNotchXLocal' BN_SIGN_IDENTITY='boringNotch.Local'
out=$(run); code=$?
ok=0
calls_has '^xcodebuild ' && ok=1
check "identity is matched literally, not as a regex (exit $code)" $ok

# 12. Round-1 fix 5: a name containing 'runtime' is not hardened runtime. Only the flags= line decides.
reset
export STUB_IDENT_NAME='boringNotch runtime dev' BN_SIGN_IDENTITY='boringNotch runtime dev'
export STUB_CODESIGN_OUT='Authority=boringNotch runtime dev
flags=0x0(none)
designated => identifier "theboringteam.boringnotch" and certificate leaf = H"0123abcd"'
out=$(run); code=$?
(( code == 0 )) && ok=0 || ok=1
check "a 'runtime' name in Authority is not a hardened runtime (exit $code)" $ok

# 13. Round-3 finding 1: one trusted and one untrusted identity with the same name. Exit 4 before import and build.
reset
export STUB_MIXED=1
out=$(run); code=$?
ok=0
(( code == 4 )) || ok=1
calls_has '^xcodebuild ' && ok=1
calls_has '^security import ' && ok=1
check "trusted plus untrusted same-name identities are refused (exit $code)" $ok

# 14. Guard for 13: one trusted identity listed in both plain-listing sections is still one identity and builds.
reset
export STUB_BOTH_SECTIONS=1
out=$(run); code=$?
ok=0
(( code == 0 )) || ok=1
calls_has '^xcodebuild ' || ok=1
check "one trusted identity listed in both sections still builds (exit $code)" $ok

# 15. Round-3 finding 2: the Authority must match the identity exactly. 'Local Signing 2' is not 'Local Signing'.
reset
export STUB_CODESIGN_OUT='Authority=boringNotch Local Signing 2
flags=0x0(none)
designated => identifier "theboringteam.boringnotch" and certificate leaf = H"0123abcd"'
out=$(run); code=$?
(( code == 6 )) && ok=0 || ok=1
check "an Authority that only contains the identity name is refused (exit $code)" $ok

# 16. Round-3 finding 3: the runtime flag is caught when it is one of several comma-joined flags.
reset
export STUB_CODESIGN_OUT='Authority=boringNotch Local Signing
flags=0x12000(library-validation,runtime)
designated => identifier "theboringteam.boringnotch" and certificate leaf = H"0123abcd"'
out=$(run); code=$?
(( code == 6 )) && ok=0 || ok=1
check "hardened runtime among comma-joined flags is refused (exit $code)" $ok

exit $fail
