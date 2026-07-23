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

# 6) Release workflow publishes an unnotarized GitHub prerelease (contents: write)
#    CI remains read-only with no publisher. No git push of tags from either workflow.
if grep -A2 '^permissions:$' "$RELEASE_WORKFLOW" \
  | grep -Eq '^  contents:[[:space:]]*write([[:space:]]|#|$)'; then
  pass "release workflow top-level contents permission is write (GitHub Release assets)"
else
  fail "release workflow top-level contents permission must be write (for release assets)"
fi

if ! grep -Eq '^[[:space:]]*contents:[[:space:]]*write([[:space:]]|#|$)' "$RELEASE_WORKFLOW"; then
  fail "release workflow must grant contents: write for GitHub Release publish"
else
  pass "release workflow grants contents: write for GitHub Release publish"
fi

checkout_count="$(grep -Ec 'uses:[[:space:]]*actions/checkout@' "$RELEASE_WORKFLOW" || true)"
non_persisting_checkout_count="$(grep -Ec 'persist-credentials:[[:space:]]*false' "$RELEASE_WORKFLOW" || true)"
if [ "$checkout_count" -gt 0 ] && [ "$non_persisting_checkout_count" -eq "$checkout_count" ]; then
  pass "release workflow disables credential persistence for every checkout"
else
  fail "release workflow must set persist-credentials: false for every checkout"
fi

if grep -Eq 'git[[:space:]]+push' "$RELEASE_WORKFLOW"; then
  fail "release workflow must not push tags or refs"
else
  pass "release workflow does not push tags or refs"
fi

# Require SHA-pinned softprops/action-gh-release with prerelease: true.
# Reject unpinned softprops @vN (covered globally later), shell `gh release`, and
# softprops without prerelease: true.
if grep -Eq 'uses:[[:space:]]*softprops/action-gh-release@[0-9a-f]{40}' "$RELEASE_WORKFLOW" \
  && grep -Eq 'prerelease:[[:space:]]*true' "$RELEASE_WORKFLOW"; then
  pass "release workflow uses SHA-pinned softprops/action-gh-release with prerelease: true"
else
  fail "release workflow must use softprops/action-gh-release@<40-hex-sha> with prerelease: true"
fi

if grep -Eq 'uses:[[:space:]]*softprops/action-gh-release@v[0-9]' "$RELEASE_WORKFLOW"; then
  fail "softprops/action-gh-release must be SHA-pinned (not mutable @vN)"
else
  pass "softprops/action-gh-release is not pinned to a mutable @vN tag"
fi

if grep -Eq 'actions/upload-release-asset|gh[[:space:]]+release' "$RELEASE_WORKFLOW"; then
  fail "release workflow must not use unpinned shell gh release or upload-release-asset"
else
  pass "release workflow has no shell gh release / upload-release-asset publisher"
fi

# Short-retention Actions artifact upload remains required alongside the prerelease.
# Requires actions: write; must remain SHA-pinned and named UNNOTARIZED-TEST-BUILD.
if grep -Eq 'uses:[[:space:]]*actions/upload-artifact@[0-9a-f]{40}' "$RELEASE_WORKFLOW" \
  && grep -Eq 'UNNOTARIZED-TEST-BUILD' "$RELEASE_WORKFLOW" \
  && grep -Eq 'retention-days:[[:space:]]*[0-9]+' "$RELEASE_WORKFLOW"; then
  pass "release workflow uploads SHA-pinned short-retention UNNOTARIZED-TEST-BUILD artifact"
else
  fail "release workflow must SHA-pin actions/upload-artifact with UNNOTARIZED-TEST-BUILD and retention-days"
fi

# 7) Future notarization must use a Keychain profile and fail safe before mutation
SIGN_RELEASE_SCRIPT="$ROOT/scripts/sign-release.sh"
if grep -Eq -- '--password|--apple-id|--team-id|APPLE_APP_PASSWORD' "$SIGN_RELEASE_SCRIPT"; then
  fail "sign-release must not pass Apple notarization credentials on the command line"
else
  pass "sign-release contains no command-line Apple credential flags"
fi

# The dollar expression is intentionally literal: this contract inspects script source text.
# shellcheck disable=SC2016
if grep -Eq -- '--keychain-profile[[:space:]]+"\$NOTARY_KEYCHAIN_PROFILE"' "$SIGN_RELEASE_SCRIPT"; then
  pass "sign-release submits notarization with a Keychain profile"
else
  fail "sign-release must submit with --keychain-profile"
fi

if missing_notary_output="$(
  env -u NOTARY_KEYCHAIN_PROFILE -u DEVELOPER_ID \
    bash "$SIGN_RELEASE_SCRIPT" 2>&1
)" && printf '%s\n' "$missing_notary_output" | grep -q 'NOTARY_KEYCHAIN_PROFILE'; then
  pass "sign-release exits safely with setup guidance when notarization credentials are absent"
else
  fail "sign-release must exit before build/sign work when NOTARY_KEYCHAIN_PROFILE is absent"
fi

if grep -Eq 'spctl[[:space:]]+--assess' "$SIGN_RELEASE_SCRIPT"; then
  pass "sign-release performs post-staple Gatekeeper assessment (spctl --assess)"
else
  fail "sign-release must contain spctl --assess after stapling"
fi

# 8) package-dmg path safety self-test
if bash "$ROOT/scripts/package-dmg.sh" --self-test; then
  pass "package-dmg rejects directory / non-.dmg paths and removes stale files with rm -f"
else
  fail "package-dmg --self-test"
fi

# 9) Exact tag validation and marketing version equality when a release tag is provided
# Prefer RELEASE_TAG when set. Only fall back to GITHUB_REF_NAME when it looks like a
# release tag (v + digits.digits.digits). Branch names like "main" must SKIP, not FAIL.
TAG_RAW="${RELEASE_TAG:-}"
if [ -z "$TAG_RAW" ]; then
  case "${GITHUB_REF_NAME:-}" in
    v[0-9]*.[0-9]*.[0-9]*) TAG_RAW="$GITHUB_REF_NAME" ;;
  esac
fi
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
  echo "SKIP: no release tag (RELEASE_TAG unset and GITHUB_REF_NAME is not a v*.*.* tag); tag equality not checked"
fi

# 10) Artifact checks — required when VERIFY_RELEASE_ARTIFACTS=1; otherwise skipped
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

# 11) shellcheck when available (required in CI via workflow install)
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck_scripts=()
  for script in "$ROOT"/scripts/*.sh; do
    case "$(basename "$script")" in
      test-release-tag-validator.sh|test-workflow-run-interpolation-checker.sh) ;;
      *) shellcheck_scripts+=("$script") ;;
    esac
  done

  # These adversarial fixture suites intentionally single-quote literal command
  # substitutions and GitHub expressions; keep SC2016 enabled everywhere else.
  if shellcheck -x "${shellcheck_scripts[@]}" \
    && shellcheck -x -e SC2016 \
      "$ROOT/scripts/test-release-tag-validator.sh" \
      "$ROOT/scripts/test-workflow-run-interpolation-checker.sh"; then
    pass "shellcheck scripts/*.sh"
  else
    fail "shellcheck scripts/*.sh"
  fi
else
  echo "SKIP: shellcheck not installed (CI installs it)"
fi

# 12) Task 7/8 hardening contracts (SHA-pinned actions, XcodeGen digest, marker, ci.yml)
CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"
PACKAGE_DMG_SCRIPT="$ROOT/scripts/package-dmg.sh"

mutable_action_tag=0
for wf in "$CI_WORKFLOW" "$RELEASE_WORKFLOW"; do
  if grep -Eq 'uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@v[0-9]' "$wf"; then
    mutable_action_tag=1
  fi
done
if [ "$mutable_action_tag" -eq 0 ]; then
  pass "workflows pin actions to full commit SHAs (no mutable @vN tags)"
else
  fail "workflows must pin actions to full commit SHAs"
fi

if grep -Eq 'XCODEGEN_SHA256:' "$RELEASE_WORKFLOW" \
  && grep -Eq 'shasum[[:space:]]+-a[[:space:]]+256[[:space:]]+-c' "$RELEASE_WORKFLOW"; then
  pass "release workflow verifies XcodeGen download with XCODEGEN_SHA256 + shasum -a 256 -c"
else
  fail "release workflow must define XCODEGEN_SHA256 and verify with shasum -a 256 -c"
fi

if grep -Eq 'sudo[[:space:]]+cp[[:space:]].*xcodegen' "$RELEASE_WORKFLOW"; then
  fail "release workflow must not sudo cp xcodegen into /usr/local/bin"
else
  pass "release workflow does not sudo-install xcodegen into /usr/local/bin"
fi

if grep -Eq 'UNNOTARIZED_TEST_BUILD\.txt' "$PACKAGE_DMG_SCRIPT" \
  && grep -Eq 'UNNOTARIZED_TEST_BUILD\.txt' "$RELEASE_WORKFLOW"; then
  pass "UNNOTARIZED_TEST_BUILD.txt marker present in package-dmg.sh and release.yml"
else
  fail "UNNOTARIZED_TEST_BUILD.txt must appear in package-dmg.sh and release.yml"
fi

if grep -A1 '^permissions:$' "$CI_WORKFLOW" \
  | grep -Eq '^  contents:[[:space:]]*read[[:space:]]*$'; then
  pass "ci workflow top-level contents permission is read-only"
else
  fail "ci workflow top-level contents permission must be read-only"
fi

if grep -Eq '^[[:space:]]*contents:[[:space:]]*write([[:space:]]|#|$)' "$CI_WORKFLOW"; then
  fail "ci workflow must not grant contents: write"
else
  pass "ci workflow grants no contents: write permission"
fi

if grep -Eq 'softprops/action-gh-release|actions/upload-release-asset|gh[[:space:]]+release' "$CI_WORKFLOW"; then
  fail "ci workflow must not publish a GitHub Release"
else
  pass "ci workflow has no GitHub Release publisher"
fi

ci_checkout_count="$(grep -Ec 'uses:[[:space:]]*actions/checkout@' "$CI_WORKFLOW" || true)"
ci_non_persisting_checkout_count="$(grep -Ec 'persist-credentials:[[:space:]]*false' "$CI_WORKFLOW" || true)"
if [ "$ci_checkout_count" -gt 0 ] && [ "$ci_non_persisting_checkout_count" -eq "$ci_checkout_count" ]; then
  pass "ci workflow disables credential persistence for every checkout"
else
  fail "ci workflow must set persist-credentials: false for every checkout"
fi

if [ "$failures" -ne 0 ]; then
  echo "=== ${failures} failure(s) ===" >&2
  exit 1
fi

echo "=== all checks passed ==="
