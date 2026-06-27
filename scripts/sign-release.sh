#!/bin/bash
# Sign and notarize a local release build (requires Apple Developer Program).
#
# Usage:
#   export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   export APPLE_ID="you@example.com"
#   export APPLE_TEAM_ID="XXXXXXXXXX"
#   export APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"  # app-specific password
#   bash scripts/sign-release.sh
#
# Prerequisites:
#   - Full Xcode installed
#   - Developer ID Application certificate in Keychain
#   - App-specific password for notarytool (https://appleid.apple.com)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/Release"
APP="$OUT/RazerMenuBarApp.app"
DMG="$OUT/RazerMenuBarApp-macOS.dmg"

: "${DEVELOPER_ID:?Set DEVELOPER_ID to your Developer ID Application identity}"

if [ ! -d "$APP" ]; then
  echo "Building release artifacts first…"
  bash "$ROOT/scripts/ci-release-build.sh"
fi

echo "Signing app…"
codesign --deep --force --options runtime --timestamp \
  --sign "$DEVELOPER_ID" \
  "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

echo "Packaging DMG…"
bash "$ROOT/scripts/package-dmg.sh"

echo "Signing DMG…"
codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"

if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
  echo "Submitting to Apple notarization…"
  xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait

  echo "Stapling notarization ticket…"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  echo "Done. Upload $DMG to GitHub Releases — users can open without Gatekeeper warnings."
else
  echo "Skipping notarization (set APPLE_ID, APPLE_APP_PASSWORD, APPLE_TEAM_ID to notarize)."
  echo "Signed DMG at $DMG (Gatekeeper may still warn without notarization)."
fi
