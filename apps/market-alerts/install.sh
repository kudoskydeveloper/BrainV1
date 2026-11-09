#!/bin/zsh
# Installs the three launchd jobs. Times are Mac local time (Bratislava).
#   brief  : weekdays 08:30 and 15:15 (before the US open at 15:30)
#   alerts : every 15 min, does nothing while the US market is closed
#   trades : weekdays 22:30, after the US close
set -e
DIR=${0:A:h}
KEYS=~/.config/market-alerts/keys.env
[ -s $KEYS ] || { echo "Add your Alpaca paper keys to $KEYS first (see keys.env.example)."; exit 1; }
chmod 600 $KEYS
LOG=~/Library/Logs/market-alerts.log

plist() {  # label, args, schedule xml
  local p=~/Library/LaunchAgents/local.brain.market-alerts.$1.plist
  cat > $p <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.brain.market-alerts.$1</string>
  <key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>-m</string><string>market_alerts</string><string>$2</string></array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>StandardOutPath</key><string>$LOG</string><key>StandardErrorPath</key><string>$LOG</string>
  $3
</dict></plist>
EOF
  launchctl bootout gui/$UID $p 2>/dev/null || true
  launchctl bootstrap gui/$UID $p && echo "installed $1"
}

days() { for d in 1 2 3 4 5; do echo "<dict><key>Weekday</key><integer>$d</integer><key>Hour</key><integer>$1</integer><key>Minute</key><integer>$2</integer></dict>"; done; }

plist brief brief "<key>StartCalendarInterval</key><array>$(days 8 30)$(days 15 15)</array>"
plist alerts alerts "<key>StartInterval</key><integer>900</integer>"
plist trades trades "<key>StartCalendarInterval</key><array>$(days 22 30)</array>"
