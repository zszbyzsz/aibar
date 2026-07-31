#!/bin/bash
set -euo pipefail

BUNDLE_ID="${BUNDLE_ID:-com.aibar.app}"
PLIST_PATH="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
INSTALLED_APP="$HOME/Applications/aibar.app"

launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
rm -f "$PLIST_PATH"
rm -rf "$INSTALLED_APP"
echo "aibar stopped and removed from login items."
