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
# By default this rebuilds release artifacts. Pass --reuse-existing-build only when
# you intentionally want to sign the current build/Release tree (revision must match).
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
REUSE_EXISTING=0

for arg in "$@"; do
  case "$arg" in
    --reuse-existing-build) REUSE_EXISTING=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "error: unknown argument: $arg" >&2
      echo "usage: bash scripts/sign-release.sh [--reuse-existing-build]" >&2
      exit 1
      ;;
  esac
done

: "${DEVELOPER_ID:?Set DEVELOPER_ID to your Developer ID Application identity}"

verify_build_revision() {
  local meta="$OUT/BUILD_REVISION"
  local expected
  expected="$(git -C "$ROOT" rev-parse HEAD)"
  if [ ! -f "$meta" ]; then
    echo "error: missing $meta; refuse to reuse an unverifiable build" >&2
    exit 1
  fi
  local recorded
  recorded="$(awk -F= '/^git_revision=/ {print $2; exit}' "$meta")"
  if [ -z "$recorded" ] || [ "$recorded" = "unknown" ]; then
    echo "error: BUILD_REVISION has no usable git_revision" >&2
    exit 1
  fi
  if [ "$recorded" != "$expected" ]; then
    echo "error: build revision mismatch (build=$recorded HEAD=$expected)" >&2
    echo "Rebuild without --reuse-existing-build, or check out the matching commit." >&2
    exit 1
  fi
  echo "Reusing existing build at revision $recorded"
}

if [ "$REUSE_EXISTING" -eq 1 ]; then
  if [ ! -d "$APP" ]; then
    echo "error: --reuse-existing-build requires $APP" >&2
    exit 1
  fi
  verify_build_revision
else
  echo "Building release artifacts (default; pass --reuse-existing-build to skip)…"
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
