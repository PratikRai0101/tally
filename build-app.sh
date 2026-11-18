#!/bin/zsh
# Builds Tally.app and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=~/Applications/Tally.app
pkill -x Tally 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Tally "$APP/Contents/MacOS/Tally"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.tally.menubar</string>
  <key>CFBundleName</key><string>Tally</string>
  <key>CFBundleExecutable</key><string>Tally</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
open "$APP"
echo "Installed $APP"
