#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/Release"
APP="$OUT/RazerMenuBarApp.app"
STAGING="$OUT/dmg-staging"
DMG="$OUT/RazerMenuBarApp-macOS.dmg"
VOLUME_NAME="Razer Viper Control"

if [ ! -d "$APP" ]; then
  echo "error: app bundle not found at $APP (run scripts/ci-release-build.sh first)" >&2
  exit 1
fi

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG"

rm -rf "$STAGING"
echo "Created $DMG"
