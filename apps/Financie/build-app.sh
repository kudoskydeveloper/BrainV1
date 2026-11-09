#!/bin/zsh
# Builds Financie.app (release) with its MCP server inside and installs it to ~/Applications (Hangar finds it by itself).
set -e
cd "$(dirname "$0")"
swift build -c release
APP=Financie.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/Financie $APP/Contents/MacOS/Financie
cp .build/release/financie-mcp $APP/Contents/MacOS/financie-mcp
cp Icon/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Financie</string>
  <key>CFBundleDisplayName</key><string>Financie</string>
  <key>CFBundleIdentifier</key><string>com.lockedin.financie</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Financie</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>com.lockedin.financie</string>
    <key>CFBundleURLSchemes</key><array><string>financie</string></array>
  </dict></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
</dict></plist>
PLIST
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/')
if [ -n "$IDENTITY" ]; then
  codesign --force -s "$IDENTITY" $APP/Contents/MacOS/financie-mcp
  codesign --force -s "$IDENTITY" $APP
else codesign --force --deep -s - $APP >/dev/null 2>&1 || true; fi
mkdir -p ~/Applications
pkill -x Financie 2>/dev/null || true
rm -rf ~/Applications/$APP && cp -R $APP ~/Applications/
rm -rf $APP
echo "Installed ~/Applications/$APP"
