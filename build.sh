#!/bin/bash
# Builds BagelGuard.app and installs it to ~/Applications.
#
# Signs with the "BagelGuard Local Signing" self-signed identity from the login keychain when it is
# there, so the Accessibility grant survives rebuilds (macOS ties it to the certificate). Without it
# the build is ad-hoc signed and every rebuild needs the grant again.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/BagelGuard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -target arm64-apple-macos14 \
    -o "$APP/Contents/MacOS/BagelGuard" Sources/*.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.thomasip.bagelguard</string>
    <key>CFBundleName</key><string>BagelGuard</string>
    <key>CFBundleExecutable</key><string>BagelGuard</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSCameraUsageDescription</key><string>BagelGuard takes a mugshot of whoever tries to post a bagel. The photo is only shown on screen and never saved.</string>
</dict>
</plist>
PLIST

IDENTITY=$(security find-identity -p codesigning | awk '/BagelGuard Local Signing/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" --identifier com.thomasip.bagelguard "$APP"
codesign -dr - "$APP" 2>&1 | tail -1

mkdir -p ~/Applications
rm -rf ~/Applications/BagelGuard.app
cp -R "$APP" ~/Applications/
echo "installed ~/Applications/BagelGuard.app"
