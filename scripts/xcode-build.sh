#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData"

resolve_developer_dir() {
  if [ -n "${DEVELOPER_DIR:-}" ] && [ -d "$DEVELOPER_DIR" ]; then
    echo "$DEVELOPER_DIR"
    return
  fi

  local selected
  selected="$(xcode-select -p 2>/dev/null || true)"
  if [ -n "$selected" ] && [ -d "$selected" ]; then
    echo "$selected"
    return
  fi

  for app in /Applications/Xcode.app /Volumes/*/Applications/Xcode.app; do
    if [ -d "$app/Contents/Developer" ]; then
      echo "$app/Contents/Developer"
      return
    fi
  done

  echo "/Applications/Xcode.app/Contents/Developer"
}

DEVELOPER_DIR="$(resolve_developer_dir)"

if [ ! -d "$DEVELOPER_DIR" ]; then
  echo "error: Xcode not found at $DEVELOPER_DIR" >&2
  echo "Run: sudo xcode-select -s /path/to/Xcode.app/Contents/Developer" >&2
  exit 1
fi

cd "$ROOT"
xcodegen generate

rm -rf "$DERIVED"
rm -rf "$ROOT/.swiftpm/xcode"

DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild \
  -scheme RazerMenuBarApp \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  build
