#!/bin/zsh
# Builds Brain.app (release) and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=Brain.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/Brain $APP/Contents/MacOS/Brain
cp Icon/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Brain</string>
  <key>CFBundleDisplayName</key><string>Brain</string>
  <key>CFBundleIdentifier</key><string>com.lockedin.brain</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Brain</string>
  <key>NSPrincipalClass</key><string>Brain.BrainApplication</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Brain</string><key>CFBundleURLSchemes</key><array><string>brain</string></array></dict></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict></plist>
PLIST
# Sign with the Apple Development certificate so macOS keeps privacy permissions (Full Disk Access,
# notifications, login item) across rebuilds; ad-hoc signing ties them to one build. Falls back to ad-hoc.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/')
if [ -n "$IDENTITY" ]; then codesign --force --deep -s "$IDENTITY" $APP; else codesign --force -s - $APP >/dev/null 2>&1 || true; fi
mkdir -p ~/Applications
pkill -x Brain 2>/dev/null || true
rm -rf ~/Applications/$APP && cp -R $APP ~/Applications/
rm -rf $APP   # keep only the installed copy, so macOS never starts this one too (same bundle id)
echo "Installed ~/Applications/$APP"
