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

# 5) Release publisher checker fixture tests
if bash "$ROOT/scripts/test-release-publisher-checker.sh"; then
  pass "release publisher checker fixture tests"
else
  fail "release publisher checker fixture tests"
fi

# 6) Workflow permissions checker fixture tests
if bash "$ROOT/scripts/test-workflow-permissions-checker.sh"; then
  pass "workflow permissions checker fixture tests"
else
  fail "workflow permissions checker fixture tests"
fi

# 7) Workflow run scripts must receive GitHub values through env, never expression interpolation
RELEASE_WORKFLOW="$ROOT/.github/workflows/release.yml"
CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"
if bash "$ROOT/scripts/check-workflow-run-interpolation.sh" "$RELEASE_WORKFLOW"; then
  pass "release workflow run scripts contain no direct GitHub expression interpolation"
else
  fail "release workflow run scripts directly interpolate GitHub expressions"
fi

# 8) Workflow authority surface: top-level permissions, the release-publishing
#    surface, action pinning, and ref mutation — for BOTH workflows.
#
#    These used to be whole-file / fixed-window greps, which could not express the
#    invariants they claimed. `grep -A2 '^permissions:$'` happens to span today's
#    block and can never notice a key that was ADDED (a silent 'id-token: write'
#    sailed straight through), and a whole-file grep for 'prerelease: true' or
#    'UNNOTARIZED-TEST-BUILD' is satisfied by a YAML comment, by release-body prose
#    or by an echo in an unrelated step. Both now go through structural awk
#    checkers that scope every match to the owning block/step, and those checkers
#    are themselves exercised by the fixture suites in sections 5 and 6.
if bash "$ROOT/scripts/check-workflow-permissions.sh" "$RELEASE_WORKFLOW" contents:write actions:write; then
  pass "release workflow top-level permissions are exactly contents: write + actions: write"
else
  fail "release workflow top-level permissions must be exactly contents: write and actions: write"
fi

if bash "$ROOT/scripts/check-workflow-permissions.sh" "$CI_WORKFLOW" contents:read; then
  pass "ci workflow top-level permissions are exactly contents: read"
else
  fail "ci workflow top-level permissions must be exactly contents: read"
fi

if bash "$ROOT/scripts/check-release-publisher.sh" --mode=release "$RELEASE_WORKFLOW"; then
  pass "release workflow publisher contract: one SHA-pinned softprops prerelease step + UNNOTARIZED-TEST-BUILD artifact"
else
  fail "release workflow violates the release publisher contract"
fi

if bash "$ROOT/scripts/check-release-publisher.sh" --mode=forbid "$CI_WORKFLOW"; then
  pass "ci workflow contains no GitHub Release publisher step"
else
  fail "ci workflow must not contain a GitHub Release publisher step, at any pin level"
fi

checkout_count="$(grep -Ec 'uses:[[:space:]]*actions/checkout@' "$RELEASE_WORKFLOW" || true)"
non_persisting_checkout_count="$(grep -Ec 'persist-credentials:[[:space:]]*false' "$RELEASE_WORKFLOW" || true)"
if [ "$checkout_count" -gt 0 ] && [ "$non_persisting_checkout_count" -eq "$checkout_count" ]; then
  pass "release workflow disables credential persistence for every checkout"
else
  fail "release workflow must set persist-credentials: false for every checkout"
fi

# Every action reference in both workflows must be a full 40-hex commit SHA.
# The old rule only rejected '@v[0-9]', so 'uses: owner/repo@main', a branch name
# or a short SHA passed every check in this file.
unpinned_uses="$(
  awk '
    function is_hex40(s) {
      if (length(s) != 40) { return 0 }
      if (s ~ /[^0-9a-f]/) { return 0 }
      return 1
    }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*/ {
      v = $0
      sub(/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*/, "", v)
      sub(/[[:space:]]+#.*$/, "", v)
      sub(/[[:space:]]+$/, "", v)
      if (v ~ /^".*"$/) { v = substr(v, 2, length(v) - 2) }
      at = index(v, "@")
      spec = (at > 0 ? substr(v, 1, at - 1) : v)
      ref = (at > 0 ? substr(v, at + 1) : "")
      if (spec !~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/ || is_hex40(ref) == 0) {
        printf "  %s:%d: uses: %s\n", FILENAME, FNR, v
      }
    }
  ' "$RELEASE_WORKFLOW" "$CI_WORKFLOW"
)"
if [ -z "$unpinned_uses" ]; then
  pass "every workflow 'uses:' pins <owner>/<repo>@<40-hex commit SHA>"
else
  fail "workflow actions must be pinned as <owner>/<repo>@<40-hex commit SHA> (a trailing '# v1.2.3' comment is fine)"
  printf '%s\n' "$unpinned_uses" >&2
fi

# Ref mutation: neither the release workflow nor any script it can reach may
# create or move a ref. This previously scanned release.yml only, so a stray
# 'push' or force-moved tag inside one of the scripts release.yml invokes was
# invisible to it. Matches are anchored to shell COMMAND position (start of line,
# after a separator, or inside a command substitution) so that comments,
# diagnostics and checker fixtures that merely NAME these commands do not trip it.
# Command position includes one leading shell keyword ('if git push ...'),
# and git may carry a -C <dir> option before the verb.
# Known limits: a bare '( ... )' subshell open is not command position (it
# would trip on diagnostics that NAME these commands in parentheses), and
# commands hidden inside eval'd strings or variable indirection ("$cmd" push)
# are not seen; unanchored matching is what made the old rule unusable across
# scripts, so those stay out of scope deliberately.
ref_cmd_start='(^|[;&|`]|\$\()[[:space:]]*((if|then|else|elif|do|while|until|eval|exec|command|sudo|time)[[:space:]]+)?'
ref_git='git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?'
ref_mutation_hits=""
for candidate in "$RELEASE_WORKFLOW" "$ROOT"/scripts/*.sh; do
  if grep -Eq "${ref_cmd_start}${ref_git}(push|update-ref)" "$candidate" \
    || grep -Eq "${ref_cmd_start}${ref_git}tag[[:space:]]+(-f|--force)" "$candidate" \
    || grep -Eq "${ref_cmd_start}(gh|curl)[[:space:]][^;&|]*git/refs" "$candidate"; then
    ref_mutation_hits="${ref_mutation_hits} $(basename "$candidate")"
  fi
done
if [ -z "$ref_mutation_hits" ]; then
  pass "release workflow and scripts/*.sh never create or move refs"
else
  fail "ref-mutating command in:${ref_mutation_hits} — release automation must never push, force-move or API-write a ref"
fi

# 9) Future notarization must use a Keychain profile and fail safe before mutation
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

# 10) package-dmg path safety self-test
if bash "$ROOT/scripts/package-dmg.sh" --self-test; then
  pass "package-dmg rejects directory / non-.dmg paths and removes stale files with rm -f"
else
  fail "package-dmg --self-test"
fi

# 11) Exact tag validation and marketing version equality when a release tag is provided
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

# 12) Artifact checks — required when VERIFY_RELEASE_ARTIFACTS=1; otherwise skipped
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

# 13) shellcheck when available (required in CI via workflow install)
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

# 14) Task 7/8 hardening contracts (XcodeGen digest verification, unnotarized marker)
#     Action pinning, permissions and the publisher surface for BOTH workflows are
#     asserted once, structurally, in section 8 — never re-grepped here.
PACKAGE_DMG_SCRIPT="$ROOT/scripts/package-dmg.sh"

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
