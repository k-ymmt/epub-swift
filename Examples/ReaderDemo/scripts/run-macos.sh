#!/bin/sh
# Builds ReaderDemo with SwiftPM, wraps it in a .app bundle (so it behaves like a regular app) and opens it.
# `swift run` also works but then the process has no bundle identifier.
set -eu
cd "$(dirname "$0")/.."
swift build
BIN=$(swift build --show-bin-path)
APP=.build/macos/ReaderDemo.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ReaderDemo" "$APP/Contents/MacOS/ReaderDemo"
for bundle in "$BIN"/*.bundle; do cp -R "$bundle" "$APP/Contents/Resources/"; done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>net.kymmt.epub.ReaderDemo</string>
  <key>CFBundleExecutable</key><string>ReaderDemo</string>
  <key>CFBundleName</key><string>ReaderDemo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
open "$APP"
