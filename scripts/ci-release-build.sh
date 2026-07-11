#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData"
OUT="$ROOT/build/Release"
ARCH="${RELEASE_ARCH:-arm64}"
MARKETING_VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' "$ROOT/project.yml")"
GIT_REVISION="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"

if [ -z "${GIT_REVISION}" ] || [ "${GIT_REVISION}" = "unknown" ]; then
  echo "error: unable to resolve git HEAD for BUILD_REVISION" >&2
  exit 1
fi

cd "$ROOT"

STAGING="$ROOT/build/.release-staging-$$"
rm -rf "$STAGING"
mkdir -p "$STAGING"

cleanup_staging() {
  rm -rf "$STAGING"
}
trap cleanup_staging EXIT

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

cp -R "$APP_SRC" "$STAGING/RazerMenuBarApp.app"

echo "Building RazerProbeCLI (Release, ${ARCH})…"
swift build -c release --arch "$ARCH" --product RazerProbeCLI
cp "$ROOT/.build/release/RazerProbeCLI" "$STAGING/RazerProbeCLI"

require_exact_arch() {
  local bin="$1"
  local archs
  archs="$(lipo -archs "$bin")"
  echo "lipo -archs ${bin}: ${archs}"
  if [ "$archs" != "$ARCH" ]; then
    echo "error: expected exact architecture '${ARCH}' in $bin" >&2
    echo "  got: '${archs}'" >&2
    exit 1
  fi
}

APP_BIN="$STAGING/RazerMenuBarApp.app/Contents/MacOS/RazerMenuBarApp"
CLI_BIN="$STAGING/RazerProbeCLI"
require_exact_arch "$APP_BIN"
require_exact_arch "$CLI_BIN"

BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGING/RazerMenuBarApp.app/Contents/Info.plist")"
if [ "$BUNDLE_VERSION" != "$MARKETING_VERSION" ]; then
  echo "error: CFBundleShortVersionString (${BUNDLE_VERSION}) != MARKETING_VERSION (${MARKETING_VERSION})" >&2
  exit 1
fi

echo "Running unit tests…"
swift test -c release --arch "$ARCH" --disable-sandbox

# Marker is written only after every build + test step succeeds.
cat > "$STAGING/BUILD_REVISION" <<EOF
git_revision=${GIT_REVISION}
marketing_version=${MARKETING_VERSION}
arch=${ARCH}
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# Atomically replace the public release directory (drops stale DMG/ZIP/CLI/metadata).
mkdir -p "$ROOT/build"
rm -rf "$OUT"
mv "$STAGING" "$OUT"
trap - EXIT

echo "Release artifacts:"
ls -la "$OUT"
