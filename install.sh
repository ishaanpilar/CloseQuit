#!/bin/bash
# Builds CloseQuit and sets it to run at login.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/CloseQuit.app"
PLIST="$HOME/Library/LaunchAgents/com.ishaanpilar.CloseQuit.plist"

bash "$SRC/build.sh"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>              <string>com.ishaanpilar.CloseQuit</string>
    <key>ProgramArguments</key>
    <array><string>$APP/Contents/MacOS/CloseQuit</string></array>
    <key>RunAtLoad</key>          <true/>
    <key>KeepAlive</key>          <true/>
    <key>StandardErrorPath</key>  <string>$HOME/Library/Logs/closequit.log</string>
</dict>
</plist>
PL

launchctl bootout "gui/$UID/com.ishaanpilar.CloseQuit" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"

echo
echo "Installed and running."
echo "Grant Accessibility to CloseQuit:"
echo "  System Settings > Privacy & Security > Accessibility > + > $APP"
echo
echo "Settings: open \"$HOME/Applications/CloseQuit Settings.app\""
echo "Logs:     ~/Library/Logs/closequit.log"
echo "Config:   ~/.config/closequit/config.json"
echo
echo "Config changes apply within a second — no need to restart the daemon."
