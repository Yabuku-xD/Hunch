#!/usr/bin/env bash
# Builds build/Hunch.app: the release binary plus llama.framework (ggml-org's pinned b11669 xcframework,
# thinned to arm64), Info.plist, icon and notices, ad-hoc signed inside-out.
# The embedding model is NOT bundled; ModelStore resolves or downloads it at runtime (Sources/HunchCore/Model).
# Env: VERSION (default 1.0.0), BUILD_NUMBER (default: commit count, else 1).
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=Hunch
BUNDLE_ID=${BUNDLE_ID:-app.hunch.Hunch}  # neutral default; publishers pass their own reverse-DNS id
VERSION=${VERSION:-1.1.0}
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
MIN_MACOS=26.0
APP=build/$NAME.app
SCRATCH=.build/app            # own scratch path: no lock/cache contention with dev builds and tests
TMP_ROOT=${TMPDIR:-/tmp}

say() { printf '==> %s\n' "$*"; }

if [[ ${HUNCH_LLAMA:-} == homebrew ]]; then
  echo "error: make-app.sh bundles the pinned xcframework only; unset HUNCH_LLAMA" >&2
  exit 1
fi

say "swift build -c release"
swift build -c release --product "$NAME" --scratch-path "$SCRATCH"
swift build -c release --product hunch-embedder --scratch-path "$SCRATCH"
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)"

say "assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
EXE="$APP/Contents/MacOS/$NAME"
FW="$APP/Contents/Frameworks"
HELPER="$APP/Contents/MacOS/hunch-embedder"
cp "$BIN_DIR/$NAME" "$EXE"
cp "$BIN_DIR/hunch-embedder" "$HELPER"

# llama.framework (llama + ggml + Metal backend + mtmd in one binary). SwiftPM copies it next to the products.
ditto "$BIN_DIR/llama.framework" "$FW/llama.framework"
LLAMA_BIN=$FW/llama.framework/Versions/A/llama
chmod u+w "$LLAMA_BIN"
if lipo -archs "$LLAMA_BIN" | grep -q x86_64; then lipo -thin arm64 "$LLAMA_BIN" -output "$LLAMA_BIN"; fi
rm -rf "$FW/llama.framework/Headers" "$FW/llama.framework/Modules" \
  "$FW/llama.framework/Versions/A/Headers" "$FW/llama.framework/Versions/A/Modules"

# The executables find the framework through their bundle rpath only.
for bin in "$EXE" "$HELPER"; do
  chmod u+w "$bin"
  while read -r rp; do
    install_name_tool -delete_rpath "$rp" "$bin" 2>/dev/null
  done < <(otool -l "$bin" | awk '/cmd LC_RPATH/{getline; getline; print $2}')
  install_name_tool -add_rpath @executable_path/../Frameworks "$bin" 2>/dev/null
done

say "Info.plist + icon"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSArchitecturePriority</key><array><string>arm64</string></array>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Yabuku-xD. MIT License.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>$NAME transcribes speech in your audio and video files on this Mac so you can search what was said.</string>
    <key>NSDesktopFolderUsageDescription</key><string>$NAME searches the names and contents of files in this folder, on this Mac only.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>$NAME searches the names and contents of files in this folder, on this Mac only.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>$NAME searches the names and contents of files in this folder, on this Mac only.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>$NAME searches the names and contents of files in this folder, on this Mac only.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp LICENSE "$APP/Contents/Resources/LICENSE"

ICONSET=$(mktemp -d "$TMP_ROOT/AppIcon.XXXXXX")/AppIcon.iconset
mkdir -p "$ICONSET"
if swift Scripts/make-icon.swift "$ICONSET/icon_512x512@2x.png"; then
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    [[ $d -eq 1024 ]] || sips -z $d $d "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
else
  echo "warning: icon generation failed; shipping without an icon" >&2
  /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$APP/Contents/Info.plist"
fi

say "verifying no Homebrew references"
links=$( { otool -L "$EXE"; otool -l "$EXE" | grep -A2 LC_RPATH; otool -L "$HELPER"; otool -l "$HELPER" | grep -A2 LC_RPATH; otool -L "$LLAMA_BIN"; otool -l "$LLAMA_BIN" | grep -A2 LC_RPATH; } \
  | grep -c /opt/homebrew || true)
echo "HOMEBREW_LINKS=$links"
(( links == 0 ))
echo "Frameworks: $(ls "$FW" | tr '\n' ' ')($(lipo -archs "$LLAMA_BIN"))"
echo "LSUIElement=$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist")"

# S1: version + sha256 stamp of the bundled native code (taken after signing the framework, since codesign rewrites it).
say "signing"
# Ad-hoc, WITHOUT --options runtime: the hardened runtime enforces library validation, and ad-hoc signatures carry
# no Team ID. Scripts/release.sh re-signs with the hardened runtime plus the one entitlement that allows it.
SIGN_OPTS=(--force --timestamp=none -s -)
codesign "${SIGN_OPTS[@]}" "$FW/llama.framework"
codesign "${SIGN_OPTS[@]}" "$HELPER"
{
  echo "llama.cpp b11669 (ggml-org xcframework, arm64)"
  ( cd "$APP/Contents" && shasum -a 256 "Frameworks/llama.framework/Versions/A/llama" )
} > "$APP/Contents/Resources/native-libs.txt"
codesign "${SIGN_OPTS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "CODESIGN_OK"
say "built $APP ($(du -sh "$APP" | cut -f1))"

[[ ${HUNCH_SKIP_LAUNCH_CHECK:-0} == 1 ]] || ./Scripts/verify-app.sh "$APP" || exit 1
# §D UI gate in the verify chain: release `--measure` (panel_show / first_results / commit p50+p95, idle CPU).
# Its PERF_GATE line is the verdict; a miss is printed, not fatal, so the remaining checks still report.
if [[ ${HUNCH_SKIP_PERF:-0} != 1 ]]; then
  say "UI perf gate (--measure)"
  ./Scripts/perf-gate.sh --measure-only || echo "PERF_GATE_UI=FAIL"
fi
