#!/bin/bash
# Build and launch the throwaway roaming spike (separate bundle from APMenuBar).
set -euo pipefail
cd "$(dirname "$0")"
APP="build/RoamSpike.app"
IDENTITY="${IDENTITY:-Apple Development: Erik Niklas Gustafsson (C54753U489)}"

pkill -x RoamSpike 2>/dev/null || true
swift build -c release --product RoamSpike >/dev/null
BIN="$(swift build -c release --show-bin-path)/RoamSpike"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/RoamSpike"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>RoamSpike</string>
    <key>CFBundleIdentifier</key><string>com.3jco.roamspike</string>
    <key>CFBundleExecutable</key><string>RoamSpike</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>RoamSpike asks the UniFi controller for access point names.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>RoamSpike needs your location to read Wi-Fi BSSIDs, which macOS treats as location data.</string>
</dict>
PLIST
echo "</plist>" >> "$APP/Contents/Info.plist"

codesign --force --sign "$IDENTITY" "$APP" 2>&1 | sed 's/^/  /'
# Deliberately NOT resetting TCC here: it would also wipe the Location grant,
# which is the whole point of this spike. If the controller lookup reports
# "offline", enable RoamSpike under Privacy & Security > Local Network.
open "$APP"
echo "launched $APP"
