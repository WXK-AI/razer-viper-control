#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/Release"

# Optional args: $1 = path to .app to package, $2 = output DMG path.
APP="${1:-$OUT/RazerMenuBarApp.app}"
DMG="${2:-$OUT/RazerMenuBarApp-macOS.dmg}"
STAGING_NAME="dmg-staging"
DMG_RW_NAME="RazerMenuBarApp-rw.dmg"
VOLUME_NAME="Razer Viper Control"
BACKGROUND="$ROOT/design/dmg-background.png"

validate_dmg_path() {
  local path="$1"
  if [ -d "$path" ]; then
    echo "error: DMG output path exists as a directory: $path" >&2
    return 1
  fi
  case "$path" in
    *.dmg) ;;
    *)
      echo "error: DMG output path must end in .dmg: $path" >&2
      return 1
      ;;
  esac
}

# Shell-level contract checks (also invoked by verify-release-contract.sh).
if [ "${1:-}" = "--self-test" ]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dmg-contract.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/not-a-dmg"
  if validate_dmg_path "$tmp/not-a-dmg" 2>/dev/null; then
    echo "error: expected directory DMG path to be rejected" >&2
    exit 1
  fi
  if validate_dmg_path "$tmp/output.zip" 2>/dev/null; then
    echo "error: expected non-.dmg path to be rejected" >&2
    exit 1
  fi
  touch "$tmp/stale.dmg"
  validate_dmg_path "$tmp/stale.dmg"
  rm -f -- "$tmp/stale.dmg"
  if [ -e "$tmp/stale.dmg" ]; then
    echo "error: expected stale DMG file to be removed with rm -f" >&2
    exit 1
  fi
  echo "package-dmg self-test OK"
  exit 0
fi

mkdir -p "$OUT"
OUT_CANON="$(cd "$OUT" && pwd -P)"

validate_dmg_path "$DMG"

if [ ! -d "$APP" ]; then
  echo "error: app bundle not found at $APP (run scripts/ci-release-build.sh first)" >&2
  exit 1
fi

STAGING="$OUT_CANON/$STAGING_NAME"
DMG_RW="$OUT_CANON/$DMG_RW_NAME"

# Recursive deletion only for script-owned staging paths under build/Release.
case "$STAGING" in
  "$OUT_CANON"/*) ;;
  *)
    echo "error: staging path escapes release directory: $STAGING" >&2
    exit 1
    ;;
esac
case "$DMG_RW" in
  "$OUT_CANON"/*) ;;
  *)
    echo "error: RW DMG path escapes release directory: $DMG_RW" >&2
    exit 1
    ;;
esac

rm -rf "$STAGING"
rm -f -- "$DMG_RW"
rm -f -- "$DMG"

mkdir -p "$STAGING/.background"
cp -R "$APP" "$STAGING/"
ln -sf /Applications "$STAGING/Applications"
if [ -f "$BACKGROUND" ]; then
  cp "$BACKGROUND" "$STAGING/.background/background.png"
fi

# Writable image so Finder layout can be applied before compression.
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDRW \
  -fs HFS+ \
  "$DMG_RW"

MOUNT_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_RW")"
DEVICE="$(echo "$MOUNT_OUTPUT" | awk '/Apple_HFS/ {print $1; exit}')"
VOLUME="$(echo "$MOUNT_OUTPUT" | awk -F'\t' '/Apple_HFS/ {gsub(/^[ \t]+|[ \t]+$/, "", $NF); print $NF; exit}')"
if [ -z "${DEVICE:-}" ] || [ -z "${VOLUME:-}" ]; then
  echo "error: failed to mount RW DMG" >&2
  exit 1
fi

cleanup() {
  if [ -n "${DEVICE:-}" ]; then
    hdiutil detach "$DEVICE" -quiet 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Finder window: app left, Applications right, optional drag arrow background.
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    try
      set background picture of viewOptions to file ".background:background.png"
    end try
    set position of item "RazerMenuBarApp.app" to {150, 180}
    set position of item "Applications" to {450, 180}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
APPLESCRIPT

chmod -Rf go-w "$VOLUME" 2>/dev/null || true
sync
hdiutil detach "$DEVICE"
DEVICE=""
trap - EXIT

hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f -- "$DMG_RW"
rm -rf "$STAGING"

echo "Created $DMG"
