#!/bin/zsh
# Builds Meetings.app (release) and installs it to ~/Applications (it shows up in Hangar by itself).
set -e
cd "$(dirname "$0")"
swift build -c release
APP=Meetings.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/Meetings $APP/Contents/MacOS/Meetings
cp Icon/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Meetings</string>
  <key>CFBundleDisplayName</key><string>Meetingy</string>
  <key>CFBundleIdentifier</key><string>com.lockedin.meetings</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Meetings</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>com.lockedin.meetings</string><key>CFBundleURLSchemes</key><array><string>meetings</string></array></dict></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict></plist>
PLIST
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/')
if [ -n "$IDENTITY" ]; then codesign --force --deep -s "$IDENTITY" $APP; else codesign --force -s - $APP >/dev/null 2>&1 || true; fi
mkdir -p ~/Applications
pkill -x Meetings 2>/dev/null || true
rm -rf ~/Applications/$APP && cp -R $APP ~/Applications/
rm -rf $APP
echo "Installed ~/Applications/$APP"
