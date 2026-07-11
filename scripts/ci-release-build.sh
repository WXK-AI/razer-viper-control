#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData"
OUT="$ROOT/build/Release"
ARCH="${RELEASE_ARCH:-arm64}"
MARKETING_VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' "$ROOT/project.yml")"

cd "$ROOT"

require_clean_worktree() {
  local dirty
  dirty="$(git status --porcelain --untracked-files=normal)"
  if [ -n "$dirty" ]; then
    echo "error: release build requires a clean git worktree (commit or stash changes first)" >&2
    echo "$dirty" >&2
    exit 1
  fi
}

require_clean_worktree

GIT_REVISION="$(git rev-parse HEAD 2>/dev/null || true)"
if [ -z "${GIT_REVISION}" ]; then
  echo "error: unable to resolve git HEAD for BUILD_REVISION" >&2
  exit 1
fi

mkdir -p "$ROOT/build"
STAGING="$(mktemp -d "$ROOT/build/release-staging.XXXXXX")"

cleanup_staging() {
  if [ -n "${STAGING:-}" ] && [ -d "$STAGING" ]; then
    rm -rf "$STAGING"
  fi
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

# Re-check cleanliness after the build so generated/tracked churn cannot slip through.
require_clean_worktree

# Marker is written only after every build + test step succeeds.
cat > "$STAGING/BUILD_REVISION" <<EOF
git_revision=${GIT_REVISION}
marketing_version=${MARKETING_VERSION}
arch=${ARCH}
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# Promote with backup so a failed mv restores the previous valid release tree.
BACKUP=""
if [ -e "$OUT" ]; then
  BACKUP="$(mktemp -d "$ROOT/build/release-backup.XXXXXX")"
  rmdir "$BACKUP"
  if ! mv "$OUT" "$BACKUP"; then
    echo "error: failed to move existing release directory aside" >&2
    exit 1
  fi
fi

if ! mv "$STAGING" "$OUT"; then
  echo "error: failed to promote staging release directory" >&2
  if [ -n "$BACKUP" ] && [ -e "$BACKUP" ]; then
    mv "$BACKUP" "$OUT" || echo "error: also failed to restore previous release from $BACKUP" >&2
  fi
  exit 1
fi

STAGING=""
trap - EXIT
if [ -n "$BACKUP" ]; then
  rm -rf "$BACKUP"
fi

echo "Release artifacts:"
ls -la "$OUT"
