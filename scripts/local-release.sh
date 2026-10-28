#!/bin/zsh
# Builds a Release boringNotch signed with one stable local identity, so the Accessibility and
# Microphone grants survive rebuilds (#46). Ad-hoc signing changes the code hash on every build.
# Usage: scripts/local-release.sh [--install]
# Env: BN_SIGN_IDENTITY, BN_DERIVED_DATA, BN_INSTALL_DIR (test hooks; defaults below).
# Exit: 0 ok, 1 build failed, 2 bad usage, 3 another build running, 4 no identity, 5 no scheme,
#       6 signature wrong, 7 new process not running.
set -eu
root=${0:A:h:h}
IDENTITY=${BN_SIGN_IDENTITY:-"boringNotch Local Signing"}
DD=${BN_DERIVED_DATA:-$HOME/worktrees/boring.notch/local-dd}
INSTALL_DIR=${BN_INSTALL_DIR:-/Applications}
KEYCHAIN=$HOME/Library/Keychains/login.keychain-db
install=0
# One optional argument only: a stray second one used to be ignored (round-1 fix 6).
(( $# <= 1 )) || { print -u2 "usage: scripts/local-release.sh [--install]"; exit 2; }
case "${1:-}" in
  --install) install=1 ;;
  "") ;;
  *) print -u2 "usage: scripts/local-release.sh [--install]"; exit 2 ;;
esac

# a. One heavy build at a time.
if pgrep -x xcodebuild >/dev/null || pgrep -x swift-build >/dev/null; then
  print -u2 "another build is running; one at a time"
  exit 3
fi

# b. The identity: created once, in the login keychain, and trusted for code signing.
trusted_count() { security find-identity -v -p codesigning | grep -cF -- "\"$IDENTITY\"" || true; }  # -F: literal name
has_identity() { (( $(trusted_count) >= 1 )); }
# Two trusted identities with one name make codesign's choice ambiguous, so refuse before the build (round-1 fix 3).
n=$(trusted_count)
if (( n > 1 )); then
  print -u2 "ambiguous identity: $n trusted identities are named '$IDENTITY'; delete the extras in Keychain Access"
  exit 4
fi
if ! has_identity; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  cat > "$tmp/cfg" <<CFG
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $IDENTITY
[codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
  print -r -- "creating the signing identity '$IDENTITY' (macOS may ask for your password once)"
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$IDENTITY" \
    -config "$tmp/cfg" -extensions codesign -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout pass:bn-local
  security import "$tmp/id.p12" -k "$KEYCHAIN" -P bn-local -T /usr/bin/codesign
  security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$tmp/cert.pem"
  if ! has_identity; then
    print -u2 "the signing identity '$IDENTITY' is still missing after the import"
    exit 4
  fi
fi

# c. The scheme is gitignored, so a fresh worktree has none.
scheme=$root/boringNotch.xcodeproj/xcshareddata/xcschemes/boringNotch.xcscheme
if [[ ! -f $scheme ]]; then
  print -u2 "missing $scheme: copy it from ~/worktrees/boring.notch/29-ghost-text/ (it is gitignored)"
  exit 5
fi

# d. Build. The identity is passed on the command line, which beats the project's [sdk=macosx*] "-" override.
# Hardened runtime stays off: with a cert that has no Team ID, library validation refuses the embedded frameworks.
cd "$root"
mkdir -p "$DD"
if ! xcodebuild -scheme boringNotch -configuration Release -derivedDataPath "$DD" -jobs 6 ARCHS=arm64 \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= "CODE_SIGN_IDENTITY=$IDENTITY" ENABLE_HARDENED_RUNTIME=NO \
    build > "$DD/build.log" 2>&1; then
  tail -30 "$DD/build.log" >&2
  print -u2 "build failed; full log at $DD/build.log"
  exit 1
fi

# e. Verify: the app and its XPC helper must both carry the identity, unsigned-runtime and ad-hoc-free.
check_sig() {
  local target=$1 info req  # not `path`: in zsh that name is tied to $PATH
  info=$(codesign -dvv "$target" 2>&1) || info=""
  req=$(codesign -d -r- "$target" 2>&1) || req=""
  # Only the flags= line says whether the runtime is on: a name or path containing "runtime" is not (round-1 fix 5).
  local flags=$(print -r -- "$info" | grep -m1 'flags=' || true)
  if [[ $info != *"Authority=$IDENTITY"* || $info == *"Signature=adhoc"* || $flags == *"(runtime)"* \
        || $req != *"certificate leaf"* ]]; then
    print -u2 "wrong signature on $target"
    print -u2 "$info"
    print -u2 "$req"
    exit 6
  fi
  print -r -- "${req:-}" | grep designated || true
}
APP=$DD/Build/Products/Release/boringNotch.app
HELPER=$APP/Contents/XPCServices/BoringNotchXPCHelper.xpc
[[ -d $HELPER ]] || { print -u2 "helper not found at $HELPER"; exit 6; }
check_sig "$APP"
check_sig "$HELPER"
codesign --verify --strict --deep "$APP" || { print -u2 "codesign --verify failed"; exit 6; }
print -r -- "signed build: $APP"

# f. --install: quit the running app (SIGKILL if it survives, since it relaunches itself on SIGTERM),
# replace the installed copy, open it, and confirm the process that runs is the new one.
if (( install )); then
  osascript -e 'tell application "boringNotch" to quit' >/dev/null 2>&1 || true
  i=0
  while pgrep -x boringNotch >/dev/null && (( i < 20 )); do sleep 0.5; i=$((i + 1)); done
  if pgrep -x boringNotch >/dev/null; then
    pkill -9 -x boringNotch || true
    i=0
    while pgrep -x boringNotch >/dev/null && (( i < 20 )); do sleep 0.5; i=$((i + 1)); done
  fi
  if [[ -d $INSTALL_DIR/boringNotch.app ]]; then
    rm -rf "$DD/previous-boringNotch.app"
    mv "$INSTALL_DIR/boringNotch.app" "$DD/previous-boringNotch.app"
  fi
  t0=$(date +%s)
  ditto "$APP" "$INSTALL_DIR/boringNotch.app"
  open "$INSTALL_DIR/boringNotch.app"

  # etime is [[dd-]hh:]mm:ss on macOS ps (etimes is Linux-only).
  secs_of() {
    local v=$1 days=0 h=0 m=0 s parts
    if [[ $v == *-* ]]; then days=${v%%-*}; v=${v#*-}; fi
    parts=("${(@s/:/)v}")
    case ${#parts} in
      1) s=$parts[1] ;;
      2) m=$parts[1]; s=$parts[2] ;;
      *) h=$parts[1]; m=$parts[2]; s=$parts[3] ;;
    esac
    print -r -- $(( ((10#$days * 24 + 10#$h) * 60 + 10#$m) * 60 + 10#$s ))
  }
  pid=""
  i=0
  while [[ -z $pid ]] && (( i < 20 )); do
    pid=$(pgrep -x boringNotch | head -1 || true)
    [[ -n $pid ]] || sleep 0.5
    i=$((i + 1))
  done
  if [[ -z $pid ]]; then print -u2 "boringNotch did not start after install"; exit 7; fi
  et=$(secs_of "$(ps -o etime= -p "$pid" | tr -d ' ')")
  now=$(date +%s)
  if (( et > now - t0 + 1 )); then
    print -u2 "the running boringNotch (pid $pid) is older than this install"
    exit 7
  fi
  check_sig "$INSTALL_DIR/boringNotch.app" >/dev/null
  print -r -- "installed and running: $INSTALL_DIR/boringNotch.app"
fi
