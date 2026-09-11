#!/bin/bash
# Builds CloseQuit.app (the daemon) and CloseQuit Settings.app into ~/Applications.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/CloseQuit.app"
SETTINGS="$HOME/Applications/CloseQuit Settings.app"

# ---------- daemon ----------

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>CloseQuit</string>
    <key>CFBundleDisplayName</key>     <string>CloseQuit</string>
    <key>CFBundleExecutable</key>      <string>CloseQuit</string>
    <key>CFBundleIdentifier</key>      <string>com.ishaanpilar.CloseQuit</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.1</string>
    <key>CFBundleVersion</key>         <string>2</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# ApplicationServices + CoreServices only. Linking AppKit costs ~5 MB of
# footprint for a process that draws nothing.
swiftc -O -o "$APP/Contents/MacOS/CloseQuit" \
    -framework ApplicationServices -framework CoreServices \
    "$SRC/Sources/Config.swift" "$SRC/Sources/main.swift"

codesign --force --sign - "$APP"
echo "Built $APP"

# ---------- settings ----------
#
# A separate app on purpose. It links SwiftUI and AppKit, which the daemon must
# never do — but it only exists while its window is open, so it costs nothing the
# rest of the time. The two never talk; they share config.json.

rm -rf "$SETTINGS"
mkdir -p "$SETTINGS/Contents/MacOS"

cat > "$SETTINGS/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>CloseQuit Settings</string>
    <key>CFBundleDisplayName</key>     <string>CloseQuit Settings</string>
    <key>CFBundleExecutable</key>      <string>CloseQuitSettings</string>
    <key>CFBundleIdentifier</key>      <string>com.ishaanpilar.CloseQuitSettings</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.1</string>
    <key>CFBundleVersion</key>         <string>2</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

swiftc -O -parse-as-library -o "$SETTINGS/Contents/MacOS/CloseQuitSettings" \
    "$SRC/Sources/Config.swift" "$SRC/Sources/SettingsApp.swift"

codesign --force --sign - "$SETTINGS"
echo "Built $SETTINGS"
