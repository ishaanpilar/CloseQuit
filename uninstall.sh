#!/bin/bash
set -euo pipefail
launchctl bootout "gui/$UID/com.ishaanpilar.CloseQuit" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.ishaanpilar.CloseQuit.plist"
rm -rf "$HOME/Applications/CloseQuit.app"
echo "Removed. You can delete the leftover Accessibility entry in System Settings."
