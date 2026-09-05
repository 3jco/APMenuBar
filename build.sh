#!/bin/bash
# Build APMenuBar.app. No Xcode UI needed.
#   ./build.sh          -> build + sign into build/APMenuBar.app
#   ./build.sh run      -> build, then relaunch it
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP="build/APMenuBar.app"
IDENTITY="${IDENTITY:-Apple Development: Erik Niklas Gustafsson (C54753U489)}"

# Never leave two instances showing two names in the menu bar.
pkill -x APMenuBar 2>/dev/null || true

swift build -c "$CONFIG" >/dev/null
BIN="$(swift build -c "$CONFIG" --show-bin-path)/APMenuBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/APMenuBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Optional app icon: drop a 1024x1024 PNG at Resources/AppIcon.png and run
# ./make-icon.sh to generate this.
if [ -f Resources/AppIcon.icns ]; then
  mkdir -p "$APP/Contents/Resources"
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Extended attributes (quarantine, provenance, Finder info) travel with copied
# files and make codesign refuse the bundle outright.
xattr -cr "$APP"

# Do NOT pipe codesign: the pipeline's exit status hides its failure and the
# build then reports success while shipping an unsigned app.
if ! codesign --force --sign "$IDENTITY" "$APP"; then
  echo "codesign FAILED" >&2
  exit 1
fi
# Finder re-applies com.apple.FinderInfo as soon as the bundle has an icon, so
# strip once more and treat only the real signature check as fatal. --strict
# additionally rejects that cosmetic xattr, which does not affect launching.
xattr -cr "$APP" 2>/dev/null || true
if ! codesign --verify "$APP"; then
  echo "signature verification FAILED" >&2
  exit 1
fi
if codesign --verify --strict "$APP" 2>/dev/null; then
  echo "  signature OK (strict)"
else
  echo "  signature OK (strict check skipped: Finder icon xattr)"
fi

# macOS binds Local Network approval to the binary's cdhash, so every rebuild
# invalidates it — and then denies silently, surfacing as "Internet connection
# appears to be offline". Clear the stale entry so the grant is re-established.
tccutil reset All com.3jco.apmenubar >/dev/null 2>&1 || true
echo "built $APP"

case "${1:-}" in
  run)
    open "$APP"
    echo "launched from build/ - look at the right-hand side of your menu bar"
    ;;
  install)
    rm -rf /Applications/APMenuBar.app
    cp -R "$APP" /Applications/APMenuBar.app
    # The copy has a new path, so re-clear the stale Local Network grant.
    tccutil reset All com.3jco.apmenubar >/dev/null 2>&1 || true
    open /Applications/APMenuBar.app
    echo "installed to /Applications and launched"
    ;;
esac
