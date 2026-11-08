#!/bin/sh
# Builds spike-ios-app for the iOS Simulator with SwiftPM, wraps it in a .app bundle, installs and launches it.
# Usage: scripts/run-ios.sh [spike ids...]   (env UDID=<simulator udid> to pick a device)
set -eu
cd "$(dirname "$0")/.."
IDS="${*:-1 2 3 4 7}"
if [ -z "${UDID:-}" ]; then
  UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
for rt,devs in d.items():
    if "iOS-27" in rt:
        for dev in devs:
            if dev["name"]=="iPhone 17 Pro": print(dev["udid"]); sys.exit(0)
sys.exit(1)')
fi
# SwiftPM cannot cross-build an iOS executable here, so compile SpikeKit + the app main as one module with swiftc.
APP=.build/ios/SpikeApp.app
rm -rf "$APP"; mkdir -p "$APP"
xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios27.0-simulator -swift-version 6 \
  -enable-upcoming-feature ApproachableConcurrency -module-name SpikeApp -DSPIKE_SINGLE_MODULE \
  Sources/SpikeKit/*.swift Sources/spike-ios-app/main.swift -o "$APP/SpikeApp"
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>net.kymmt.epub.spikes</string>
  <key>CFBundleExecutable</key><string>SpikeApp</string>
  <key>CFBundleName</key><string>SpikeApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>MinimumOSVersion</key><string>27.0</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
  <key>DTPlatformName</key><string>iphonesimulator</string>
  <key>UILaunchScreen</key><dict/>
  <key>UIApplicationSceneManifest</key><dict>
    <key>UIApplicationSupportsMultipleScenes</key><false/>
    <key>UISceneConfigurations</key><dict>
      <key>UIWindowSceneSessionRoleApplication</key><array><dict>
        <key>UISceneConfigurationName</key><string>Default</string>
        <key>UISceneDelegateClassName</key><string>SpikeApp.SceneDelegate</string>
      </dict></array>
    </dict>
  </dict>
</dict></plist>
PLIST
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP"
mkdir -p output/ios
SIMCTL_CHILD_SPIKE_OUT="$PWD/output/ios" SIMCTL_CHILD_SPIKE_IDS="$IDS" \
  xcrun simctl launch --console --terminate-running-process "$UDID" net.kymmt.epub.spikes
