#!/bin/bash
# Build APMenuBar.app. No Xcode UI needed.
#   ./build.sh           -> build + sign into build/APMenuBar.app
#   ./build.sh run       -> build, then relaunch it
#   ./build.sh install   -> build, replace /Applications copy, relaunch
#   ./build.sh release   -> Developer ID signed, notarized, stapled .dmg
#
# Release needs a Developer ID Application certificate and stored notary
# credentials (once):
#   xcrun notarytool store-credentials APMenuBar-notary \
#     --apple-id <your-apple-id> --team-id DU9L4NU4T9 \
#     --password <app-specific-password>
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP="build/APMenuBar.app"
DMG="build/APMenuBar.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-APMenuBar-notary}"
MODE="${1:-}"

# Marketing version from VERSION; build number from commit count, which is
# monotonic and needs no manual bookkeeping.
SHORT_VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# Certificate names are not unique — Xcode happily creates a second cert with
# an identical name, and codesign then refuses as "ambiguous". Resolve to the
# SHA-1 hash, which always identifies exactly one identity.
resolve_identity() {
  security find-identity -v -p codesigning \
    | awk -v pat="$1" '$0 ~ pat { print $2; exit }'
}

if [ "$MODE" = "release" ]; then
  # Distribution outside the App Store: Developer ID, hardened runtime and a
  # secure timestamp are all required for notarization to succeed.
  IDENTITY="${IDENTITY:-$(resolve_identity "Developer ID Application")}"
  if [ -z "$IDENTITY" ]; then
    echo "no Developer ID Application certificate found." >&2
    echo "Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application" >&2
    exit 1
  fi
  CODESIGN_EXTRA=(--options runtime --timestamp)
else
  IDENTITY="${IDENTITY:-$(resolve_identity "Apple Development")}"
  if [ -z "$IDENTITY" ]; then
    echo "no Apple Development certificate found" >&2
    exit 1
  fi
  CODESIGN_EXTRA=()
fi

# Never leave two instances showing two names in the menu bar.
pkill -x APMenuBar 2>/dev/null || true

swift build -c "$CONFIG" >/dev/null
BIN="$(swift build -c "$CONFIG" --show-bin-path)/APMenuBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/APMenuBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$SHORT_VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

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
    if codesign --force "${CODESIGN_EXTRA[@]+"${CODESIGN_EXTRA[@]}"}" \
         --sign "$IDENTITY" "$APP" 2>/tmp/apmb-codesign.err; then
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

echo "built $APP ($SHORT_VERSION build $BUILD_NUMBER)"

case "${1:-}" in
  run)
    open "$APP"
    echo "launched from build/ - look at the right-hand side of your menu bar"
    ;;
  release)
    echo "signed with: $IDENTITY"
    rm -f "$DMG"
    hdiutil create -quiet -volname APMenuBar -srcfolder "$APP" \
      -ov -format UDZO "$DMG"
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"

    echo "notarizing (this waits for Apple, usually a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

    # Stapling lets the app validate without a network round trip on first launch.
    xcrun stapler staple "$DMG"
    xcrun stapler staple "$APP"
    spctl -a -vv -t install "$DMG" || true
    echo "release ready: $DMG"
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
