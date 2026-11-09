#!/bin/zsh
# Builds the iPhone app (CourierMobile) for the iOS Simulator, installs it and launches it.
#   ./build-ios.sh            build, install, launch on the booted simulator (boots an iPhone if none is)
#   ./build-ios.sh --mac-data also copies the Mac's mail cache into the simulator, to see real mail (no passwords are copied)
set -e
cd "$(dirname "$0")"
BUNDLE_ID=com.lockedin.courier
DERIVED=.build/ios
APP=$DERIVED/Courier.app

xcodebuild -scheme CourierMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath $DERIVED \
  -configuration Debug -quiet build
BIN=$DERIVED/Build/Products/Debug-iphonesimulator/CourierMobile

rm -rf $APP && mkdir -p $APP
cp $BIN $APP/Courier
# App icon from the Mac icon (one 1024 px PNG is enough for the simulator home screen).
if [ -f Icon/AppIcon.icns ]; then
  sips -s format png -z 180 180 Icon/AppIcon.icns --out $APP/AppIcon60x60@3x.png >/dev/null 2>&1 || true
  sips -s format png -z 120 120 Icon/AppIcon.icns --out $APP/AppIcon60x60@2x.png >/dev/null 2>&1 || true
fi
cat > $APP/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Courier</string>
  <key>CFBundleDisplayName</key><string>Courier</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Courier</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
  <key>MinimumOSVersion</key><string>26.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><true/></dict>
  <key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
  <key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><dict>
    <key>CFBundleIconFiles</key><array><string>AppIcon60x60</string></array>
  </dict></dict>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
    <key>CFBundleURLSchemes</key><array><string>courier</string></array>
  </dict></array>
</dict></plist>
PLIST
# Ad-hoc signing is all the simulator needs (custom entitlements make launchd refuse to spawn it).
codesign --force -s - $APP

# Booted iPhone, or boot the newest one.
DEVICE=$(xcrun simctl list devices booted | grep -m1 -oE '\(([0-9A-F-]{36})\)' | tr -d '()' || true)
if [ -z "$DEVICE" ]; then
  DEVICE=$(xcrun simctl list devices available | awk '/^-- iOS (2[6-9]|[3-9][0-9])/{ok=1;next} /^--/{ok=0} ok && /iPhone/' | head -1 | grep -oE '[0-9A-F-]{36}')
  xcrun simctl boot $DEVICE
fi
open -b com.apple.iphonesimulator 2>/dev/null || true
xcrun simctl terminate $DEVICE $BUNDLE_ID 2>/dev/null || true
xcrun simctl install $DEVICE $APP

if [[ "$1" == "--mac-data" ]]; then
  SRC="$HOME/Library/Application Support/Courier"
  DST="$(xcrun simctl get_app_container $DEVICE $BUNDLE_ID data)/Library/Application Support/Courier"
  mkdir -p "$DST"
  rm -f "$DST"/courier.sqlite(N) "$DST"/courier.sqlite-*(N)
  sqlite3 "$SRC/courier.sqlite" ".backup '$DST/courier.sqlite'"
  [ -d "$SRC/Messages" ] && rsync -a --delete "$SRC/Messages/" "$DST/Messages/"
  echo "Copied the Mac mail cache into the simulator (read-only preview: passwords stay on the Mac)."
fi

xcrun simctl launch $DEVICE $BUNDLE_ID
echo "Courier running on simulator $DEVICE"
