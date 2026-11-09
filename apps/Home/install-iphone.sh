#!/bin/zsh
# Builds Home for the iPhone plugged into this Mac (USB or the same Wi-Fi), signs it with the free Apple team and installs it.
# A free team's signature runs out after 7 days: run this again every week to keep the app opening. Data stays on the phone.
#   ./install-iphone.sh            the first connected iPhone
#   ./install-iphone.sh <udid>     a specific one (xcrun devicectl list devices)
set -e
cd "$(dirname "$0")"
DEVICE=${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /physical/ && /(connected|available)/' | grep -m1 -oE '[0-9A-F]{8}-[0-9A-F]{16}')}
if [ -z "$DEVICE" ]; then
  echo "No iPhone found. Plug it in (or keep it on the same Wi-Fi), unlock it, and trust this Mac." >&2
  exit 1
fi
DERIVED=.build/iphone
xcodebuild -project ios/Home.xcodeproj -scheme Home -configuration Release -destination "id=$DEVICE" \
  -derivedDataPath $DERIVED -allowProvisioningUpdates -quiet build
APP=$DERIVED/Build/Products/Release-iphoneos/Home.app
xcrun devicectl device install app --device $DEVICE $APP >/dev/null
xcrun devicectl device process launch --device $DEVICE com.lockedin.home >/dev/null 2>&1 || true
echo "Installed Home on $DEVICE (signature valid for 7 days, until $(date -v+7d '+%a %-d. %-m.'))."
