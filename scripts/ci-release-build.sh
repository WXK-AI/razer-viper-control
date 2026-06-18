#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData"
OUT="$ROOT/build/Release"

cd "$ROOT"
mkdir -p "$OUT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen is required (brew install xcodegen)" >&2
  exit 1
fi

xcodegen generate

rm -rf "$DERIVED" "$ROOT/.swiftpm/xcode"

echo "Building RazerMenuBarApp (Release)…"
xcodebuild \
  -scheme RazerMenuBarApp \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  build

APP="$DERIVED/Build/Products/Release/RazerMenuBarApp.app"
if [ ! -d "$APP" ]; then
  echo "error: app bundle not found at $APP" >&2
  exit 1
fi

xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP"

cp -R "$APP" "$OUT/"

echo "Building RazerProbeCLI (Release)…"
swift build -c release --product RazerProbeCLI
cp "$ROOT/.build/release/RazerProbeCLI" "$OUT/"

echo "Running unit tests…"
swift test -c release --disable-sandbox

echo "Release artifacts:"
ls -la "$OUT"
