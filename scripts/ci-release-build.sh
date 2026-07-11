#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData"
OUT="$ROOT/build/Release"
ARCH="${RELEASE_ARCH:-arm64}"
MARKETING_VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' "$ROOT/project.yml")"
GIT_REVISION="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"

cd "$ROOT"
mkdir -p "$OUT"

bash "$ROOT/scripts/generate-xcodeproj.sh"

rm -rf "$DERIVED" "$ROOT/.swiftpm/xcode"

echo "Building RazerMenuBarApp (Release, ${ARCH})…"
xcodebuild \
  -scheme RazerMenuBarApp \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  ARCHS="$ARCH" \
  ONLY_ACTIVE_ARCH=NO \
  EXCLUDED_ARCHS= \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  build

APP_SRC="$DERIVED/Build/Products/Release/RazerMenuBarApp.app"
if [ ! -d "$APP_SRC" ]; then
  echo "error: app bundle not found at $APP_SRC" >&2
  exit 1
fi

xattr -cr "$APP_SRC" 2>/dev/null || true
codesign --force --deep --sign - "$APP_SRC"

APP_DST="$OUT/RazerMenuBarApp.app"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "Building RazerProbeCLI (Release, ${ARCH})…"
swift build -c release --arch "$ARCH" --product RazerProbeCLI
cp "$ROOT/.build/release/RazerProbeCLI" "$OUT/RazerProbeCLI"

APP_BIN="$APP_DST/Contents/MacOS/RazerMenuBarApp"
CLI_BIN="$OUT/RazerProbeCLI"
for bin in "$APP_BIN" "$CLI_BIN"; do
  info="$(lipo -info "$bin")"
  echo "lipo: $info"
  if ! echo "$info" | grep -Eq "(^| )${ARCH}( |$)"; then
    echo "error: expected architecture ${ARCH} in $bin" >&2
    echo "  got: $info" >&2
    exit 1
  fi
done

BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DST/Contents/Info.plist")"
if [ "$BUNDLE_VERSION" != "$MARKETING_VERSION" ]; then
  echo "error: CFBundleShortVersionString (${BUNDLE_VERSION}) != MARKETING_VERSION (${MARKETING_VERSION})" >&2
  exit 1
fi

cat > "$OUT/BUILD_REVISION" <<EOF
git_revision=${GIT_REVISION}
marketing_version=${MARKETING_VERSION}
arch=${ARCH}
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

echo "Running unit tests…"
swift test -c release --arch "$ARCH" --disable-sandbox

echo "Release artifacts:"
ls -la "$OUT"
