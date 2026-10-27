#!/usr/bin/env bash
# Packs an app bundle into a styled DMG: night background, Hunch on the left, an Applications link on the right.
# The window layout is written straight into the image's .DS_Store by dmgbuild (no Finder scripting, so it also runs
# headless in CI).   Scripts/make-dmg.sh <Hunch.app> <out.dmg>
set -euo pipefail
cd "$(dirname "$0")/.."

APP=${1:?usage: Scripts/make-dmg.sh <Hunch.app> <out.dmg>}
OUT=${2:?usage: Scripts/make-dmg.sh <Hunch.app> <out.dmg>}
DMGBUILD_VERSION=1.6.7

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swift Scripts/make-dmg-background.swift "$WORK"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" >/dev/null 2>&1

cat >"$WORK/settings.py" <<'PY'
import os
app = defines["app"]
name = os.path.basename(app)
format = "ULFO"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [name]
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")
background = defines["background"]
# 400 pt of picture plus the title bar. A path bar, when the user turned it on in Finder, covers only blank space.
window_rect = ((200, 120), (660, 428))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
# Centres match Scripts/make-dmg-background.swift.
icon_locations = {name: (180, 176), "Applications": (480, 176)}
PY

rm -f "$OUT"
uvx --from "dmgbuild==$DMGBUILD_VERSION" dmgbuild -s "$WORK/settings.py" \
  -D app="$APP" -D background="$WORK/background.tiff" "$(basename "$APP" .app)" "$OUT" >/dev/null
echo "dmg: $OUT ($(du -h "$OUT" | cut -f1))"
