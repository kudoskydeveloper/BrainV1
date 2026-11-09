#!/bin/zsh
# Builds Hangar.app (release) and installs it to ~/Applications. A regular Dock app (keep it in the Dock).
set -e
cd "$(dirname "$0")"
swift build -c release
APP=Hangar.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/Hangar $APP/Contents/MacOS/Hangar
cp Icon/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Hangar</string>
  <key>CFBundleDisplayName</key><string>Hangar</string>
  <key>CFBundleIdentifier</key><string>com.lockedin.hangar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Hangar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict></plist>
PLIST
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/')
if [ -n "$IDENTITY" ]; then codesign --force --deep -s "$IDENTITY" $APP; else codesign --force -s - $APP >/dev/null 2>&1 || true; fi
mkdir -p ~/Applications
pkill -x Hangar 2>/dev/null || true
rm -rf ~/Applications/$APP && cp -R $APP ~/Applications/
rm -rf $APP
echo "Installed ~/Applications/$APP"
