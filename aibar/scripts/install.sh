#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="aibar"
BUNDLE_ID="${BUNDLE_ID:-com.aibar.app}"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
PLIST_PATH="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

"$ROOT/scripts/build-app.sh"

echo "Installing to $INSTALLED_APP..."
mkdir -p "$INSTALL_DIR"
launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
rm -rf "$INSTALLED_APP"
cp -R "$ROOT/dist/$APP_NAME.app" "$INSTALLED_APP"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALLED_APP/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>/tmp/aibar.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/aibar.log</string>
</dict>
</plist>
PLIST

echo "Loading LaunchAgent..."
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"

echo "Installed. aibar will now start automatically at login."
echo "It's running now — look at the notch. Logs: /tmp/aibar.log"
