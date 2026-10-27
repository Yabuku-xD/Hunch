#!/usr/bin/env bash
# Builds a release locally: version bump -> make-app -> verify-app -> perf-gate -> ad-hoc hardened-runtime signature
# -> zip + dmg -> SHA256SUMS.txt, then prints the `gh release create` command. It never runs gh, tags or pushes.
#   Scripts/release.sh 1.0.0            # BUILD_NUMBER defaults to the commit count
#   HUNCH_SKIP_PERF=1 Scripts/release.sh 1.0.1   # skip the perf gate (do not publish such a build)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: Scripts/release.sh <version>  (e.g. 1.0.0)}
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must be X.Y.Z" >&2; exit 1; }
NAME=Hunch
APP=build/$NAME.app
DIST=dist
export VERSION
export BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}

say() { printf '==> %s\n' "$*"; }

grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "error: CHANGELOG.md has no '## [$VERSION]' section" >&2; exit 1; }

say "make-app $VERSION ($BUILD_NUMBER)"
HUNCH_SKIP_LAUNCH_CHECK=1 HUNCH_SKIP_PERF=1 Scripts/make-app.sh

say "verify-app"
Scripts/verify-app.sh "$APP"

if [[ ${HUNCH_SKIP_PERF:-0} != 1 ]]; then
  say "perf-gate"
  Scripts/perf-gate.sh
fi

# Ad-hoc signature with the hardened runtime. Ad-hoc signatures carry no Team ID, so library validation would refuse
# the bundled llama.framework; the only entitlement is the one that allows it.
say "codesign (ad-hoc, hardened runtime)"
codesign --force --sign - --options runtime --timestamp=none "$APP/Contents/Frameworks/llama.framework"
# Re-signing rewrites the framework binary, so refresh its sha256 stamp before the app signature seals Resources.
STAMP=$APP/Contents/Resources/native-libs.txt
{
  head -1 "$STAMP"
  ( cd "$APP/Contents" && shasum -a 256 "Frameworks/llama.framework/Versions/A/llama" )
} > "$STAMP.new" && mv "$STAMP.new" "$STAMP"
codesign --force --sign - --options runtime --timestamp=none --entitlements Scripts/release.entitlements \
  "$APP/Contents/Helpers/$NAME Helper.app"
codesign --force --sign - --options runtime --timestamp=none --entitlements Scripts/release.entitlements "$APP"
codesign --verify --deep --strict "$APP"
Scripts/verify-app.sh "$APP"

say "packaging"
rm -rf "$DIST"
mkdir -p "$DIST"
ZIP=$DIST/$NAME-$VERSION-arm64.zip
DMG=$DIST/$NAME-$VERSION-arm64.dmg
ditto -c -k --keepParent "$APP" "$ZIP"
hdiutil create -volname "$NAME" -srcfolder "$APP" -ov -format ULFO "$DMG" >/dev/null
( cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS.txt )
cat "$DIST/SHA256SUMS.txt"
ls -lh "$DIST"

cat <<CMD

Release artifacts are in $DIST/. To publish (after review; this script does not run it):

  git tag -a v$VERSION -m "v$VERSION" && git push origin v$VERSION
  gh release create v$VERSION --title "$NAME $VERSION" --notes-file <(awk '/^## \\[$VERSION\\]/{f=1;next} /^## \\[/{f=0} f' CHANGELOG.md) \\
    "$ZIP" "$DMG" "$DIST/SHA256SUMS.txt"
CMD
