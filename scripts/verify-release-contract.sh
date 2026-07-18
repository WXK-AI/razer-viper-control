#!/bin/bash
# Verify release packaging contracts without mutating production paths unsafely.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/Release"
ARCH="${RELEASE_ARCH:-arm64}"
MARKETING_VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' "$ROOT/project.yml")"
GIT_HEAD="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
# Set VERIFY_RELEASE_ARTIFACTS=1 after a successful ci-release-build (CI post-build step).
VERIFY_ARTIFACTS="${VERIFY_RELEASE_ARTIFACTS:-0}"
failures=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

meta_field() {
  local key="$1"
  local file="$2"
  awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$file"
}

require_exact_arch() {
  local label="$1"
  local bin="$2"
  if [ ! -f "$bin" ]; then
    fail "${label} binary missing: $bin"
    return
  fi
  local archs
  archs="$(lipo -archs "$bin")"
  if [ "$archs" = "$ARCH" ]; then
    pass "${label} architecture exactly ${ARCH}"
  else
    fail "${label} architecture must be exactly '${ARCH}', got '${archs}'"
  fi
}

echo "=== verify-release-contract ==="

# 1) Shell syntax
for script in "$ROOT"/scripts/*.sh; do
  if bash -n "$script"; then
    pass "bash -n $(basename "$script")"
  else
    fail "bash -n $(basename "$script")"
  fi
done

# 2) Release tag validator tests
if bash "$ROOT/scripts/test-release-tag-validator.sh"; then
  pass "release tag validator exact-format tests"
else
  fail "release tag validator exact-format tests"
fi

# 3) Exact ls-remote ref parser tests
if bash "$ROOT/scripts/test-exact-ls-remote-ref.sh"; then
  pass "exact ls-remote ref parser tests"
else
  fail "exact ls-remote ref parser tests"
fi

# 4) Workflow run interpolation checker fixture tests
if bash "$ROOT/scripts/test-workflow-run-interpolation-checker.sh"; then
  pass "workflow run interpolation checker fixture tests"
else
  fail "workflow run interpolation checker fixture tests"
fi

# 5) Workflow run scripts must receive GitHub values through env, never expression interpolation
RELEASE_WORKFLOW="$ROOT/.github/workflows/release.yml"
if bash "$ROOT/scripts/check-workflow-run-interpolation.sh" "$RELEASE_WORKFLOW"; then
  pass "release workflow run scripts contain no direct GitHub expression interpolation"
else
  fail "release workflow run scripts directly interpolate GitHub expressions"
fi

# 6) package-dmg path safety self-test
if bash "$ROOT/scripts/package-dmg.sh" --self-test; then
  pass "package-dmg rejects directory / non-.dmg paths and removes stale files with rm -f"
else
  fail "package-dmg --self-test"
fi

# 7) Exact tag validation and marketing version equality when a release tag is provided
TAG_RAW="${RELEASE_TAG:-${GITHUB_REF_NAME:-}}"
if [ -n "$TAG_RAW" ]; then
  if bash "$ROOT/scripts/validate-release-tag.sh" "$TAG_RAW"; then
    TAG_VERSION="${TAG_RAW#v}"
    if [ "$TAG_VERSION" = "$MARKETING_VERSION" ]; then
      pass "release tag ${TAG_RAW} matches MARKETING_VERSION ${MARKETING_VERSION}"
    else
      fail "release tag ${TAG_RAW} (version ${TAG_VERSION}) != MARKETING_VERSION ${MARKETING_VERSION}"
    fi
  else
    fail "release tag is unsafe or unsupported; version comparison skipped"
  fi
else
  echo "SKIP: no RELEASE_TAG/GITHUB_REF_NAME; tag equality not checked"
fi

# 8) Artifact checks — required when VERIFY_RELEASE_ARTIFACTS=1; otherwise skipped
#    (avoids false passes on stale/partial build/Release trees during pre-build).
if [ "$VERIFY_ARTIFACTS" = "1" ]; then
  APP="$OUT/RazerMenuBarApp.app"
  CLI="$OUT/RazerProbeCLI"
  META="$OUT/BUILD_REVISION"
  APP_BIN="$APP/Contents/MacOS/RazerMenuBarApp"

  if [ ! -d "$APP" ]; then
    fail "app bundle missing: $APP"
  fi
  if [ ! -f "$CLI" ]; then
    fail "CLI binary missing: $CLI"
  fi
  if [ ! -f "$META" ]; then
    fail "BUILD_REVISION missing: $META"
  fi

  if [ -d "$APP" ]; then
    plist="$APP/Contents/Info.plist"
    if [ -f "$plist" ]; then
      bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
      if [ "$bundle_version" = "$MARKETING_VERSION" ]; then
        pass "CFBundleShortVersionString (${bundle_version}) == MARKETING_VERSION"
      else
        fail "CFBundleShortVersionString (${bundle_version}) != MARKETING_VERSION (${MARKETING_VERSION})"
      fi
    else
      fail "Info.plist missing in app bundle"
    fi
    require_exact_arch "app" "$APP_BIN"
  fi

  if [ -f "$CLI" ]; then
    require_exact_arch "CLI" "$CLI"
  fi

  if [ -f "$META" ]; then
    recorded_rev="$(meta_field git_revision "$META")"
    recorded_ver="$(meta_field marketing_version "$META")"
    recorded_arch="$(meta_field arch "$META")"
    recorded_built="$(meta_field built_at "$META")"

    if [ -z "$GIT_HEAD" ]; then
      fail "unable to resolve current git HEAD for BUILD_REVISION comparison"
    elif [ "$recorded_rev" = "$GIT_HEAD" ]; then
      pass "BUILD_REVISION.git_revision matches HEAD (${GIT_HEAD})"
    else
      fail "BUILD_REVISION.git_revision (${recorded_rev:-<empty>}) != HEAD (${GIT_HEAD})"
    fi

    if [ "$recorded_ver" = "$MARKETING_VERSION" ]; then
      pass "BUILD_REVISION.marketing_version matches ${MARKETING_VERSION}"
    else
      fail "BUILD_REVISION.marketing_version (${recorded_ver:-<empty>}) != ${MARKETING_VERSION}"
    fi

    if [ "$recorded_arch" = "$ARCH" ]; then
      pass "BUILD_REVISION.arch matches ${ARCH}"
    else
      fail "BUILD_REVISION.arch (${recorded_arch:-<empty>}) != ${ARCH}"
    fi

    if [ -n "$recorded_built" ]; then
      pass "BUILD_REVISION.built_at present (${recorded_built})"
    else
      fail "BUILD_REVISION.built_at missing"
    fi
  fi
else
  echo "SKIP: artifact checks (set VERIFY_RELEASE_ARTIFACTS=1 after ci-release-build)"
fi

# 9) shellcheck when available (required in CI via workflow install)
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
