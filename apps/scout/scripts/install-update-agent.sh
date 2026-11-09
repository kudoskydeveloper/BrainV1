#!/bin/zsh
# Runs `scout update` every day at 6:30 with launchd (SK registry changes daily, CZ when ČSÚ publishes a new file).
# A missed run (Mac asleep or off) happens at the next wake. Log: ~/.scout/update.log. Remove: launchctl bootout gui/$(id -u)/com.lockedin.scout-update
set -e
NODE=$(command -v node)
DIR=$(cd "$(dirname "$0")/.." && pwd)
PLIST=~/Library/LaunchAgents/com.lockedin.scout-update.plist
mkdir -p ~/.scout
cat > $PLIST <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.lockedin.scout-update</string>
  <key>ProgramArguments</key><array><string>$NODE</string><string>$DIR/src/cli.js</string><string>update</string></array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>6</integer><key>Minute</key><integer>30</integer></dict>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HOME/.scout/update.log</string>
  <key>StandardErrorPath</key><string>$HOME/.scout/update.log</string>
</dict></plist>
PLIST
launchctl bootout gui/$(id -u)/com.lockedin.scout-update 2>/dev/null || true
launchctl bootstrap gui/$(id -u) $PLIST
echo "Installed $PLIST"
