#!/bin/bash
# Builds CCUsageTracker as a .app bundle and installs it to ~/Applications.
# The app is menu-bar-only (LSUIElement=true — no Dock icon).
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="CC Usage Tracker"
BUNDLE_ID="com.ccusage.tracker"
VERSION="1"
BUILD_DIR=".build/release"
BINARY="$BUILD_DIR/CCUsageTracker"
INSTALL_DIR="$HOME/Applications"
APP_PATH="$INSTALL_DIR/$APP_NAME.app"

echo "==> Building release binary…"
swift build -c release

if [ ! -f "$BINARY" ]; then
    echo "ERROR: build did not produce $BINARY"
    exit 1
fi

echo "==> Creating .app bundle at $APP_PATH …"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

cp "$BINARY" "$APP_PATH/Contents/MacOS/CCUsageTracker"
chmod +x "$APP_PATH/Contents/MacOS/CCUsageTracker"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CCUsageTracker</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION.0</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><false/>
    </dict>
</dict>
</plist>
PLIST

echo "==> Installed to: $APP_PATH"
echo ""
echo "Done. To run:"
echo "  open \"$APP_PATH\""
echo ""
echo "To launch at login, add it via:"
echo "  System Settings > General > Login Items > + (select the .app)"
