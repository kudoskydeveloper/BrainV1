#!/bin/zsh
# Builds Courier.app (release) with its MCP server inside and installs it to ~/Applications. A regular Dock app.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=Courier.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/Courier $APP/Contents/MacOS/Courier
cp .build/release/courier-mcp $APP/Contents/MacOS/courier-mcp
cp Icon/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Courier</string>
  <key>CFBundleDisplayName</key><string>Courier</string>
  <key>CFBundleIdentifier</key><string>com.lockedin.courier</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Courier</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>com.lockedin.courier</string>
    <key>CFBundleURLSchemes</key><array><string>courier</string></array>
  </dict></array>
  <key>NSContactsUsageDescription</key><string>Courier našepkáva adresy príjemcov z tvojich kontaktov.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict></plist>
PLIST
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/')
if [ -n "$IDENTITY" ]; then
  codesign --force -s "$IDENTITY" $APP/Contents/MacOS/courier-mcp
  codesign --force -s "$IDENTITY" $APP
else codesign --force --deep -s - $APP >/dev/null 2>&1 || true; fi
mkdir -p ~/Applications
pkill -x Courier 2>/dev/null || true
rm -rf ~/Applications/$APP && cp -R $APP ~/Applications/
rm -rf $APP
echo "Installed ~/Applications/$APP"
