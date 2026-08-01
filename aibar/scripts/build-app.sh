#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="aibar"
BUNDLE_ID="${BUNDLE_ID:-com.aibar.app}"
APP_VERSION="${APP_VERSION:-0.1.10}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
BUILD_DIR="$ROOT/.build/release"
APP_DIR="$ROOT/dist/$APP_NAME.app"

echo "Building release binary..."
cd "$ROOT"
swift build -c release
# Keep the replacement helper out of SwiftPM's executable products so normal
# development remains the simple `swift run`. It is only needed inside the
# assembled .app, where this direct compile produces the bundled executable.
swiftc -parse-as-library -O -framework AppKit -framework Security \
  "$ROOT/Sources/aibarUpdateInstaller/main.swift" \
  -o "$BUILD_DIR/aibarUpdateInstaller"

echo "Assembling $APP_NAME.app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Assets/aibar.icns" "$APP_DIR/Contents/Resources/aibar.icns"
cp "$BUILD_DIR/aibarUpdateInstaller" "$APP_DIR/Contents/Resources/aibarUpdateInstaller"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>aibar</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>aibar.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_VERSION</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

SIGN_OPTIONS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "Ad-hoc signing for local development (privacy grants will not survive rebuilds)..."
else
  echo "Signing with $SIGNING_IDENTITY..."
  SIGN_OPTIONS+=(--options runtime --timestamp)
fi

# Sign nested code explicitly before sealing the outer bundle. Signing with
# --deep can silently repair or replace nested identities, which makes release
# identity drift harder to detect.
codesign "${SIGN_OPTIONS[@]}" "$APP_DIR/Contents/Resources/aibarUpdateInstaller"
codesign "${SIGN_OPTIONS[@]}" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "Done: $APP_DIR"
