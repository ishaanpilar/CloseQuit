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
    <!-- KeepAlive is load-bearing, not just resilience: a process cannot observe an
         Accessibility grant made after it launched, so the daemon exits when it is
         untrusted and relies on launchd to restart it with a fresh check. -->
    <key>KeepAlive</key>          <true/>
    <key>ThrottleInterval</key>   <integer>15</integer>
    <!-- The daemon writes closequit.log itself. This catches only crash output,
         which would otherwise interleave into the same file. -->
    <key>StandardErrorPath</key>  <string>$HOME/Library/Logs/closequit.crash.log</string>
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
