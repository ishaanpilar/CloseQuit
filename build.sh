#!/bin/bash
# Builds CloseQuit.app (the daemon) and CloseQuit Settings.app into ~/Applications.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/CloseQuit.app"
SETTINGS="$HOME/Applications/CloseQuit Settings.app"

# Signing identity. This matters more than it looks: an ad-hoc signature ties the
# Accessibility grant to the exact binary hash, so *every code change revokes it*
# and the daemon silently goes idle. Signing with a stable self-signed certificate
# keeps the grant across rebuilds. See README, "Rebuilding and Accessibility".
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null \
        | grep -q "CloseQuit Local"; then
    IDENTITY="CloseQuit Local"
fi

# Which target to build. The settings app and the daemon are independent binaries, and
# during a dry-run observation window you want to iterate on the UI *without* replacing
# the bundle a running daemon is paged in from.
#   ./build.sh            both
#   ./build.sh settings   settings app only
#   ./build.sh daemon     daemon only
TARGET="${1:-both}"
case "$TARGET" in
    both|daemon|settings) ;;
    *) echo "usage: $0 [both|daemon|settings]" >&2; exit 2 ;;
esac

sign() {
    if [ -n "$IDENTITY" ]; then
        codesign --force --sign "$IDENTITY" "$1"
    else
        codesign --force --sign - "$1"
    fi
}

# ---------- daemon ----------

if [ "$TARGET" = "both" ] || [ "$TARGET" = "daemon" ]; then

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
    -framework ApplicationServices -framework CoreServices -framework Security \
    "$SRC/Sources/Config.swift" "$SRC/Sources/main.swift"

sign "$APP"
echo "Built $APP"

fi

# ---------- settings ----------
#
# A separate app on purpose. It links SwiftUI and AppKit, which the daemon must
# never do — but it only exists while its window is open, so it costs nothing the
# rest of the time. The two never talk; they share config.json.

if [ "$TARGET" = "both" ] || [ "$TARGET" = "settings" ]; then

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

sign "$SETTINGS"
echo "Built $SETTINGS"

fi

if [ -z "$IDENTITY" ] && [ "$TARGET" != "settings" ]; then
    cat <<'WARN'

  Signed ad-hoc. macOS ties the Accessibility grant to the exact binary hash, so
  this build has lost the permission the previous one had.

  To re-grant: System Settings > Privacy & Security > Accessibility. Remove the
  old CloseQuit entry with "-" and add it again -- ticking the existing checkbox
  is usually not enough once the hash has changed. Then RELAUNCH the daemon: a
  running process cannot see a grant made after it started.

  To stop this happening on every rebuild, create a self-signed code-signing
  certificate named "CloseQuit Local" (Keychain Access > Certificate Assistant >
  Create a Certificate, type "Code Signing", self-signed). build.sh picks it up
  automatically, and the grant then survives rebuilds.
WARN
fi
