#!/bin/zsh
# Builds Courier for a real iPhone connected by cable, signs it with your (free) Apple Development profile and installs it.
#   ./build-iphone.sh             build, sign, install, launch
#   ./build-iphone.sh --mac-data  also copies the Mac's accounts, mail cache and passwords to the iPhone (one-time hand-off)
# Needs: the iPhone plugged in and trusted, Xcode signed in to your Apple ID, and a development profile for
# com.lockedin.courier in ~/Library/Developer/Xcode/UserData/Provisioning Profiles (Xcode makes it on the first device build;
# a free profile lasts 7 days, then run this again).
set -e
cd "$(dirname "$0")"
BUNDLE_ID=com.lockedin.courier
DERIVED=.build/ios-device
WRAP=$DERIVED/wrap
APP=$WRAP/Courier.app

DEVICE=${COURIER_DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /physical/ && /(connected|available)/' | grep -m1 -oE '[0-9A-F]{8}-[0-9A-F]{16}')}
[ -z "$DEVICE" ] && { echo "No iPhone connected (plug it in, unlock it, tap Trust)."; exit 1; }

# Newest unexpired profile for this bundle id.
PROFILE=""
for p in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision(Nom); do
  plist=$(security cms -D -i "$p" 2>/dev/null) || continue
  appid=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:application-identifier" /dev/stdin <<< "$plist" 2>/dev/null)
  [[ "$appid" == *.$BUNDLE_ID ]] || continue
  exp=$(/usr/libexec/PlistBuddy -c "Print :ExpirationDate" /dev/stdin <<< "$plist")
  [[ $(date -j -f "%a %b %d %T %Z %Y" "$exp" +%s 2>/dev/null || echo 0) -gt $(date +%s) ]] && { PROFILE=$p; break; }
done
[ -z "$PROFILE" ] && { echo "No valid provisioning profile for $BUNDLE_ID: build any app with this bundle id to the iPhone from Xcode once."; exit 1; }

xcodebuild -scheme CourierMobile -destination 'generic/platform=iOS' -derivedDataPath $DERIVED -configuration Release -quiet build

rm -rf $WRAP && mkdir -p $APP
cp $DERIVED/Build/Products/Release-iphoneos/CourierMobile $APP/Courier
cp "$PROFILE" $APP/embedded.mobileprovision
security cms -D -i "$PROFILE" > $WRAP/profile.plist
/usr/libexec/PlistBuddy -x -c "Print :Entitlements" $WRAP/profile.plist > $WRAP/entitlements.plist
TEAM=$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" $WRAP/profile.plist)
# iOS fills transparent pixels with black, so the iPhone icon is the full-bleed variant (iOS rounds the corners itself).
swift Icon/make-icon-ios.swift $WRAP/icon.png
sips -s format jpeg $WRAP/icon.png --out $WRAP/icon.jpg >/dev/null   # drop the alpha channel
# Compiled asset catalog (Assets.car), like Xcode makes: iOS 26 shows loose legacy icon files in a dark frame.
XCA=$WRAP/Assets.xcassets/AppIcon.appiconset
mkdir -p $XCA
sips -s format png -z 1024 1024 $WRAP/icon.jpg --out $XCA/icon-1024.png >/dev/null
cat > $XCA/Contents.json <<'JSON'
{ "images": [ { "filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" } ],
  "info": { "author": "xcode", "version": 1 } }
JSON
echo '{ "info": { "author": "xcode", "version": 1 } }' > $WRAP/Assets.xcassets/Contents.json
xcrun actool $WRAP/Assets.xcassets --compile $APP --platform iphoneos --minimum-deployment-target 26.0 \
  --app-icon AppIcon --target-device iphone --target-device ipad \
  --output-partial-info-plist $WRAP/icon-info.plist --output-format human-readable-text >/dev/null
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
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>MinimumOSVersion</key><string>26.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><true/></dict>
  <key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
    <key>CFBundleURLSchemes</key><array><string>courier</string></array>
  </dict></array>
</dict></plist>
PLIST
# Icon keys (CFBundleIcons, CFBundleIcons~ipad) as actool wrote them for the catalog.
/usr/libexec/PlistBuddy -c "Merge $WRAP/icon-info.plist" $APP/Info.plist >/dev/null
IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | grep -m1 -oE '[0-9A-F]{40}')
codesign --force --sign $IDENTITY --entitlements $WRAP/entitlements.plist $APP
# Installing replaces the app (and stops it if it was running), so the data copy below never races an open database.
xcrun devicectl device install app --device $DEVICE $APP >/dev/null

if [[ "$1" == "--mac-data" ]]; then
  SRC="$HOME/Library/Application Support/Courier"
  STAGE=$WRAP/mac-data
  SECRETS=$STAGE/mac-secrets.json
  trap 'rm -rf "$STAGE"' EXIT
  mkdir -p $STAGE
  sqlite3 "$SRC/courier.sqlite" ".backup '$STAGE/courier.sqlite'"
  # Passwords from the Mac Keychain (macOS asks once per account: Always Allow). Never printed; the file is deleted on exit
  # here and by the iPhone app right after it has read it.
  umask 077
  sqlite3 "$SRC/courier.sqlite" "SELECT id FROM accounts" | while read -r id; do
    pw=$(security find-generic-password -s $BUNDLE_ID -a "$id" -w 2>/dev/null) || { echo "No Keychain password for account $id" >&2; continue; }
    printf '%s\0%s\0' "$id" "$pw"
  done | python3 -I -c 'import sys, json; p = sys.stdin.buffer.read().split(b"\0")[:-1]; json.dump({p[i].decode(): p[i+1].decode() for i in range(0, len(p), 2)}, sys.stdout)' > $SECRETS
  echo "Passwords read for $(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' $SECRETS) accounts."
  copy() { xcrun devicectl device copy to --device $DEVICE --domain-type appDataContainer --domain-identifier $BUNDLE_ID \
             --source "$1" --destination "Library/Application Support/Courier/$2" >/dev/null }
  # Empty -wal/-shm so leftovers from the iPhone's own (unused) database can't be replayed into the Mac copy.
  : > $STAGE/empty
  copy $STAGE/empty courier.sqlite-wal
  copy $STAGE/empty courier.sqlite-shm
  copy $STAGE/courier.sqlite courier.sqlite
  [ -d "$SRC/Messages" ] && copy "$SRC/Messages" Messages
  copy $SECRETS mac-secrets.json
  rm -rf $STAGE
  echo "Copied accounts, mail cache and passwords to the iPhone."
fi

xcrun devicectl device process launch --device $DEVICE $BUNDLE_ID >/dev/null && echo "Courier running on the iPhone ($TEAM)."
