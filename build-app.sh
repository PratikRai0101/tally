#!/bin/zsh
# Builds Tally.app.
#   ./build-app.sh            build for this Mac, install to ~/Applications, and launch
#   ./build-app.sh --package  build a universal (Apple Silicon + Intel) app into dist/Tally.zip
set -e
cd "$(dirname "$0")"
VERSION=1.3

make_bundle() { # $1 = binary, $2 = destination .app
  local APP="$2"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$1" "$APP/Contents/MacOS/Tally"
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.tally.menubar</string>
  <key>CFBundleName</key><string>Tally</string>
  <key>CFBundleDisplayName</key><string>Tally</string>
  <key>CFBundleExecutable</key><string>Tally</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
  codesign --force --sign - "$APP"
}

if [[ "$1" == "--package" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Tally"
  rm -rf dist && mkdir -p dist
  make_bundle "$BIN" dist/Tally.app
  (cd dist && ditto -c -k --keepParent Tally.app Tally.zip)
  echo "Packaged dist/Tally.zip ($(lipo -archs dist/Tally.app/Contents/MacOS/Tally))"
  exit 0
fi

swift build -c release
pkill -x Tally 2>/dev/null || true
make_bundle .build/release/Tally ~/Applications/Tally.app
open ~/Applications/Tally.app
echo "Installed ~/Applications/Tally.app"
