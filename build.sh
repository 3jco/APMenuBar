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

# Finder tags an app bundle with com.apple.FinderInfo as soon as it has an
# icon, and codesign refuses any bundle carrying one. Stripping once loses the
# race, so strip and sign together, retrying if that specific complaint returns.
sign_bundle() {
  local attempt
  for attempt in 1 2 3; do
    xattr -cr "$APP" 2>/dev/null || true
    if codesign --force --sign "$IDENTITY" "$APP" 2>/tmp/apmb-codesign.err; then
      return 0
    fi
    if ! grep -q "detritus" /tmp/apmb-codesign.err; then
      cat /tmp/apmb-codesign.err >&2
      return 1
    fi
    echo "  codesign lost the xattr race (attempt $attempt), retrying"
  done
  cat /tmp/apmb-codesign.err >&2
  return 1
}

if ! sign_bundle; then
  echo "codesign FAILED" >&2
  exit 1
fi

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
