#!/usr/bin/env bash
# Installs build/Hunch.app into /Applications, quitting a running copy first.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=build/Hunch.app
DEST=/Applications/Hunch.app
BUNDLE_ID=${BUNDLE_ID:-app.hunch.Hunch}  # neutral default; publishers pass their own reverse-DNS id

[[ -d $SRC ]] || { echo "error: $SRC missing; run Scripts/make-app.sh first" >&2; exit 1; }
codesign --verify --deep --strict "$SRC"

# Ask politely, then make sure only the installed copy's process is gone.
if pgrep -x Hunch >/dev/null; then
  echo "==> quitting running Hunch"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..50}; do pgrep -x Hunch >/dev/null || break; sleep 0.1; done
  pkill -x Hunch 2>/dev/null || true
fi

echo "==> installing $DEST"
rm -rf "$DEST.new"
ditto "$SRC" "$DEST.new"
rm -rf "$DEST"
mv "$DEST.new" "$DEST"
echo "==> installed; launch with: open $DEST"
