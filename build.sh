#!/bin/bash
# Build FloatNote.app (no Xcode project needed, only swiftc)
set -euo pipefail
cd "$(dirname "$0")"

# The .app is built next to this script. Keep the folder out of iCloud/Dropbox-synced
# locations: their extended attributes make code signing fail.
APP="$(pwd)/FloatNote.app"
BUNDLE_ID="${BUNDLE_ID:-io.github.xoevip-web.FloatNote}"   # override if you want a different identifier
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O main.swift -o "$APP/Contents/MacOS/FloatNote"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FloatNote</string>
  <key>CFBundleDisplayName</key><string>FloatNote</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>FloatNote</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "OK: $APP"
