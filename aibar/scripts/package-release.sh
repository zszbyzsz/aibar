#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-${APP_VERSION:-}}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
APP_PATH="$ROOT/dist/aibar.app"

if [[ -z "$VERSION" || ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Usage: SIGNING_IDENTITY='Developer ID Application: ...' $0 <version>" >&2
  exit 64
fi

if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then
  echo "A stable Developer ID Application identity is required for a release." >&2
  exit 65
fi

if [[ "$SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
  echo "SIGNING_IDENTITY must name a Developer ID Application certificate." >&2
  exit 65
fi

APP_VERSION="$VERSION" SIGNING_IDENTITY="$SIGNING_IDENTITY" "$ROOT/scripts/build-app.sh"

requirement="$(codesign -d -r- "$APP_PATH" 2>&1)"
if [[ "$requirement" == *cdhash* ]]; then
  echo "Release rejected: the designated requirement is tied to a per-build CDHash." >&2
  exit 66
fi

if [[ "$requirement" != *"identifier \"com.aibar.app\""* ]]; then
  echo "Release rejected: unexpected designated requirement: $requirement" >&2
  exit 66
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

archive="$ROOT/dist/aibar-$VERSION.zip"
if [[ -e "$archive" ]]; then
  echo "Release archive already exists: $archive" >&2
  exit 73
fi

/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$archive"

echo "Stable designated requirement:"
echo "$requirement"
echo "SHA-256:"
shasum -a 256 "$archive"
echo "Release package: $archive"
