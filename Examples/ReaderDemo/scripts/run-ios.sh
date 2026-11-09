#!/bin/sh
# Builds ReaderDemo for the iOS Simulator with xcodebuild, wraps the executable and the resource bundles in a
# .app, installs it on the simulator and launches it.
# Usage: scripts/run-ios.sh            (env UDID=<simulator udid> to pick a device; default: a booted iPhone)
set -eu
cd "$(dirname "$0")/.."
DD="${DERIVED_DATA:-.build/ios-derived}"
if [ -z "${UDID:-}" ]; then
  UDID=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["state"] == "Booted": print(d["udid"]); sys.exit(0)
sys.exit(1)') || { echo "No booted simulator. Boot one or pass UDID=..." >&2; exit 1; }
fi
xcodebuild -scheme ReaderDemo -destination "id=$UDID" -derivedDataPath "$DD" \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet
PRODUCTS="$DD/Build/Products/Debug-iphonesimulator"
APP=.build/ios/ReaderDemo.app
rm -rf "$APP"; mkdir -p "$APP"
cp "$PRODUCTS/ReaderDemo" "$APP/ReaderDemo"
for bundle in "$PRODUCTS"/*.bundle; do cp -R "$bundle" "$APP/"; done
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>net.kymmt.epub.ReaderDemo</string>
  <key>CFBundleExecutable</key><string>ReaderDemo</string>
  <key>CFBundleName</key><string>ReaderDemo</string>
  <key>CFBundleDisplayName</key><string>EPUB Demo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>MinimumOSVersion</key><string>26.0</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
  <key>DTPlatformName</key><string>iphonesimulator</string>
  <key>UILaunchScreen</key><dict/>
  <key>UISupportedInterfaceOrientations</key><array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <key>UIApplicationSceneManifest</key><dict>
    <key>UIApplicationSupportsMultipleScenes</key><false/>
  </dict>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch --terminate-running-process "$UDID" net.kymmt.epub.ReaderDemo
