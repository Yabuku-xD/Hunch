#!/usr/bin/env bash
# Proves build/Hunch.app is self-contained: no /opt/homebrew in any load command or rpath, a valid
# signature, and a 3 s launch (DYLD_PRINT_LIBRARIES=1, cwd=/) that maps no /opt/homebrew image.
# Kills only the PID it started.
set -uo pipefail
cd "$(dirname "$0")/.."
APP=${1:-build/Hunch.app}
APP=$(cd "$APP" && pwd)
LOG=$(mktemp -d "${TMPDIR:-/tmp}/bs-verify.XXXXXX")
fail=0

# Every Mach-O in the bundle (the executable and the framework binaries).
machos=$(find "$APP/Contents/MacOS" "$APP/Contents/Frameworks" -type f -perm -u+x 2>/dev/null; \
  find "$APP/Contents/Frameworks" -type f -path '*/Versions/*' ! -path '*/Resources/*' 2>/dev/null)
refs=$(for f in $(echo "$machos" | sort -u); do otool -L "$f" 2>/dev/null; otool -l "$f" 2>/dev/null | grep -A2 LC_RPATH; done | grep -c /opt/homebrew)
echo "HOMEBREW_LINKS=$refs (otool load commands + rpaths in the bundle)"; (( refs == 0 )) || fail=1

if codesign --verify --deep --strict "$APP"; then echo "CODESIGN_OK"; else echo "CODESIGN_FAILED"; fail=1; fi
echo "LSUIElement=$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist" 2>/dev/null || echo missing)"

# S2: license notices ship in the bundle.
if [[ -s $APP/Contents/Resources/THIRD_PARTY_NOTICES.md && -s $APP/Contents/Resources/LICENSE ]]; then echo "NOTICES_OK"; else echo "NOTICES_MISSING"; fail=1; fi
# No strings of the dev-only BS_ overrides in the release binary (they are DEBUG-only).
bs=$(strings "$APP/Contents/MacOS/"* 2>/dev/null | grep -cE '^HUNCH_(HOVER_ROW|PRESS|INDEX_STATE|MODEL_STATE|HOTKEY_STATE|APPEARANCE|SCREEN|FIRST_RUN)' || true)
echo "HUNCH_OVERRIDE_STRINGS=$bs"
# S1: every bundled native library matches its recorded sha256.
STAMP=$APP/Contents/Resources/native-libs.txt
if [[ -s $STAMP ]] && ( cd "$APP/Contents" && grep -E '^[0-9a-f]{64} ' "$STAMP" | shasum -a 256 -c --quiet ); then
  echo "NATIVE_LIBS_OK ($(head -2 "$STAMP" | tr '\n' ' '))"
else
  echo "NATIVE_LIBS_MISMATCH"; fail=1
fi

( cd / && exec env DYLD_PRINT_LIBRARIES=1 "$APP/Contents/MacOS/Hunch" >"$LOG/dyld.log" 2>&1 ) &
pid=$!
sleep 3
vmmap -w "$pid" 2>/dev/null | grep -Eo '/[^ ]+\.(dylib|so)' | sort -u >"$LOG/mapped.txt"
if kill -0 "$pid" 2>/dev/null; then alive=yes; else alive=no; fail=1; fi
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
loaded=$(grep -c 'dyld\[' "$LOG/dyld.log")
brew=$(cat "$LOG/dyld.log" "$LOG/mapped.txt" | grep -c /opt/homebrew)
echo "launch: alive after 3 s = $alive, images loaded = $loaded, /opt/homebrew images = $brew (log $LOG)"
grep -Eo 'Contents/(Frameworks|MacOS)/[^ ]+' "$LOG/dyld.log" | sort -u | sed 's/^/  /'
(( brew == 0 && loaded > 0 )) || fail=1
(( fail == 0 )) && echo "verify: OK" || echo "verify: FAILED"
exit "$fail"
