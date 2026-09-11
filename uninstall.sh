#!/bin/bash
set -euo pipefail
launchctl bootout "gui/$UID/com.ishaanpilar.CloseQuit" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.ishaanpilar.CloseQuit.plist"
rm -rf "$HOME/Applications/CloseQuit.app"
rm -rf "$HOME/Applications/CloseQuit Settings.app"
echo "Removed the daemon and the settings app."
echo "Your config is left at ~/.config/closequit/config.json — delete it by hand if you want it gone."
echo "You can also delete the leftover Accessibility entry in System Settings."
