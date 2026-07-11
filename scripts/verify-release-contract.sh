#!/bin/bash
# Verify release packaging contracts without mutating production paths unsafely.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/Release"
ARCH="${RELEASE_ARCH:-arm64}"
MARKETING_VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' "$ROOT/project.yml")"
failures=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

echo "=== verify-release-contract ==="

# 1) Shell syntax
for script in "$ROOT"/scripts/*.sh; do
  if bash -n "$script"; then
    pass "bash -n $(basename "$script")"
  else
    fail "bash -n $(basename "$script")"
  fi
done

# 2) package-dmg path safety self-test
if bash "$ROOT/scripts/package-dmg.sh" --self-test; then
  pass "package-dmg rejects directory / non-.dmg paths and removes stale files with rm -f"
else
  fail "package-dmg --self-test"
fi

# 3) Tag / marketing version equality when a release tag is provided
normalize_tag() {
  local tag="$1"
  tag="${tag#refs/tags/}"
  tag="${tag#v}"
  printf '%s' "$tag"
}

TAG_RAW="${RELEASE_TAG:-${GITHUB_REF_NAME:-}}"
if [ -n "$TAG_RAW" ]; then
  TAG_VERSION="$(normalize_tag "$TAG_RAW")"
  if [ "$TAG_VERSION" = "$MARKETING_VERSION" ]; then
    pass "release tag ${TAG_RAW} matches MARKETING_VERSION ${MARKETING_VERSION}"
  else
    fail "release tag ${TAG_RAW} (normalized ${TAG_VERSION}) != MARKETING_VERSION ${MARKETING_VERSION}"
  fi
else
  echo "SKIP: no RELEASE_TAG/GITHUB_REF_NAME; tag equality not checked"
fi

# 4) Optional artifact checks when build/Release exists
if [ -d "$OUT/RazerMenuBarApp.app" ]; then
  plist="$OUT/RazerMenuBarApp.app/Contents/Info.plist"
  bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
  if [ "$bundle_version" = "$MARKETING_VERSION" ]; then
    pass "CFBundleShortVersionString (${bundle_version}) == MARKETING_VERSION"
  else
    fail "CFBundleShortVersionString (${bundle_version}) != MARKETING_VERSION (${MARKETING_VERSION})"
  fi

  app_bin="$OUT/RazerMenuBarApp.app/Contents/MacOS/RazerMenuBarApp"
  if [ -f "$app_bin" ]; then
    info="$(lipo -info "$app_bin")"
    if echo "$info" | grep -Eq "(^| )${ARCH}( |$)"; then
      pass "app architecture includes ${ARCH} ($info)"
    else
      fail "app architecture missing ${ARCH}: $info"
    fi
  fi

  if [ -f "$OUT/RazerProbeCLI" ]; then
    info="$(lipo -info "$OUT/RazerProbeCLI")"
    if echo "$info" | grep -Eq "(^| )${ARCH}( |$)"; then
      pass "CLI architecture includes ${ARCH} ($info)"
    else
      fail "CLI architecture missing ${ARCH}: $info"
    fi
  fi

  if [ -f "$OUT/BUILD_REVISION" ]; then
    pass "BUILD_REVISION metadata present"
  else
    fail "BUILD_REVISION missing (ci-release-build.sh should write it)"
  fi
else
  echo "SKIP: no app in build/Release; artifact lipo/version checks deferred"
fi

# 5) shellcheck when available (required in CI via workflow install)
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x "$ROOT"/scripts/*.sh; then
    pass "shellcheck scripts/*.sh"
  else
    fail "shellcheck scripts/*.sh"
  fi
else
  echo "SKIP: shellcheck not installed (CI installs it)"
fi

if [ "$failures" -ne 0 ]; then
  echo "=== ${failures} failure(s) ===" >&2
  exit 1
fi

echo "=== all checks passed ==="
