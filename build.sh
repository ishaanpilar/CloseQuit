#!/bin/bash
# Builds CloseQuit.app into ~/Applications.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/CloseQuit.app"

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
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# ApplicationServices + CoreServices only. Linking AppKit costs ~5 MB of
# footprint for a process that draws nothing.
swiftc -O -o "$APP/Contents/MacOS/CloseQuit" \
    -framework ApplicationServices -framework CoreServices \
    "$SRC/Sources/main.swift"

codesign --force --sign - "$APP"

echo "Built $APP"
