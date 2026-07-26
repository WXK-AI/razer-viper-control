#!/bin/bash
# Adversarial fixture suite for scripts/check-release-publisher.sh.
#
# Every fixture is a tiny workflow that a whole-file grep would score wrongly:
# publishers hidden in comments, 'prerelease: true' living only in echo prose or
# in a release body: | block, mutable @main / @v2 pins, a second publisher, a
# shell `gh -R owner/repo release create`, and token-bearing run steps that can
# forge refs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKER="$ROOT/scripts/check-release-publisher.sh"
TEST_TMP="$(mktemp -d /tmp/razer-release-publisher-test.XXXXXX)"
failures=0

cleanup() {
  case "$TEST_TMP" in
    /tmp/razer-release-publisher-test.*)
      rm -rf -- "$TEST_TMP"
      ;;
    *)
      printf 'FAIL: refusing to clean unexpected test path: %s\n' "$TEST_TMP" >&2
      ;;
  esac
}
trap cleanup EXIT

pass() { printf 'PASS: %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

write_fixture() {
  local path="$1"
  shift
  printf '%s\n' "$@" > "$path"
}

expect_ok() {
  local label="$1"
  local mode="$2"
  local fixture="$3"
  if bash "$CHECKER" "--mode=$mode" "$fixture" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label"
  fi
}

expect_violation() {
  local label="$1"
  local mode="$2"
  local fixture="$3"
  # Require exit 1 specifically: a usage error (exit 2) means the checker never
  # ran, and counting it as "violation caught" would fake coverage.
  local status=0
  bash "$CHECKER" "--mode=$mode" "$fixture" >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 1 ]; then
    pass "$label"
  else
    fail "$label (expected exit 1, got $status)"
  fi
}

expect_usage_error() {
  local label="$1"
  shift
  local status=0
  bash "$CHECKER" "$@" >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 2 ]; then
    pass "$label"
  else
    fail "$label (expected exit 2, got $status)"
  fi
}

if [ ! -f "$CHECKER" ]; then
  fail "release publisher checker missing: $CHECKER"
  exit 1
fi

PINNED_PUBLISHER="softprops/action-gh-release@3bb12739c298aeb8a4eeaf626c5b8d85266b0e65"
PINNED_ARTIFACT="actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"

wf_header=(
  'name: Release'
  'on:'
  '  push:'
  '    tags:'
  '      - "v*"'
  'permissions:'
  '  contents: write'
  '  actions: write'
  'jobs:'
  '  release:'
  '    runs-on: macos-15'
  '    steps:'
  '      - name: Checkout with full tag history'
  '        # Pin to major v4 tag commit so Dependabot can still propose updates.'
  '        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1'
  '        with:'
  '          fetch-depth: 0'
  '          persist-credentials: false'
)

wf_artifact_ok=(
  '      - name: Upload unnotarized test package'
  "        uses: $PINNED_ARTIFACT # v4"
  '        with:'
  '          name: UNNOTARIZED-TEST-BUILD'
  '          path: |'
  '            build/Release/RazerMenuBarApp-macOS.dmg'
  '            build/Release/SHA256SUMS.txt'
  '          if-no-files-found: error'
  '          retention-days: 7'
)

wf_artifact_renamed=(
  '      - name: Upload unnotarized test package'
  "        uses: $PINNED_ARTIFACT # v4"
  '        with:'
  '          name: build-output'
  '          path: |'
  '            build/Release/RazerMenuBarApp-macOS.dmg'
  '          if-no-files-found: error'
  '          retention-days: 7'
)

wf_artifact_unpinned=(
  '      - name: Upload unnotarized test package'
  '        uses: actions/upload-artifact@v4'
  '        with:'
  '          name: UNNOTARIZED-TEST-BUILD'
  '          path: build/Release/SHA256SUMS.txt'
  '          retention-days: 7'
)

wf_artifact_no_retention=(
  '      - name: Upload unnotarized test package'
  "        uses: $PINNED_ARTIFACT # v4"
  '        with:'
  '          name: UNNOTARIZED-TEST-BUILD'
  '          path: build/Release/SHA256SUMS.txt'
)

# Builds the publisher step into PUB.
#   $1 = full uses: value
#   $2 = prerelease line to place in with:, or empty to omit the key entirely
#   $3 = optional extra with: line to omit ("files" or "fail_on_unmatched_files")
# R8: the clobber guard that must precede the publisher. A read-only probe,
# so the token allowlist (R6) accepts it.
wf_guard=(
  '      - name: Guard against clobbering an existing release'
  '        env:'
  '          GH_TOKEN: token-placeholder'
  '        run: |'
  '          gh api "repos/o/r/releases?per_page=100" --jq . > /dev/null'
)

make_publisher() {
  local uses="$1"
  local prerelease="$2"
  local omit="${3:-}"
  PUB=(
    '      - name: Publish unnotarized GitHub prerelease'
    "        uses: $uses"
    '        with:'
    '          tag_name: v1.0.4'
    '          name: v1.0.4 (unnotarized test build)'
  )
  if [ -n "$prerelease" ]; then
    PUB+=("          $prerelease")
  fi
  PUB+=(
    '          generate_release_notes: true'
    '          body: |'
    '            Unnotarized test build, not notarized by Apple.'
  )
  if [ "$omit" != "files" ]; then
    PUB+=(
      '          files: |'
      '            build/Release/RazerMenuBarApp-macOS.dmg'
      '            build/Release/SHA256SUMS.txt'
    )
  fi
  if [ "$omit" != "fail_on_unmatched_files" ]; then
    PUB+=('          fail_on_unmatched_files: true')
  fi
  PUB+=(
    '        env:'
    '          GITHUB_TOKEN: token-placeholder'
  )
  # Publisher without the R8 guard, for the guard-specific negative fixtures.
  PUB_NOGUARD=("${PUB[@]}")
  PUB=("${wf_guard[@]}" "${PUB[@]}")
}

wf_confirm=(
  '      - name: Confirm unnotarized prerelease published'
  '        run: |'
  '          echo "UNNOTARIZED PRERELEASE published with prerelease: true"'
  '          echo "7-day Actions artifact UNNOTARIZED-TEST-BUILD uploaded"'
)

# --- 1. happy path -----------------------------------------------------------
make_publisher "$PINNED_PUBLISHER # v2" 'prerelease: true'
write_fixture "$TEST_TMP/release-ok.yml" \
  "${wf_header[@]}" "${wf_artifact_ok[@]}" "${PUB[@]}" "${wf_confirm[@]}"

# --- 2. prerelease: true only as echo prose and body: | text -----------------
write_fixture "$TEST_TMP/prerelease-text-only.yml" \
  "${wf_header[@]}" \
  "${wf_artifact_ok[@]}" \
  '      - name: Publish unnotarized GitHub prerelease' \
  "        uses: $PINNED_PUBLISHER # v2" \
  '        with:' \
  '          tag_name: v1.0.4' \
  '          body: |' \
  '            This build is published with prerelease: true on GitHub Releases.' \
  '            prerelease: true' \
  '          files: |' \
  '            build/Release/SHA256SUMS.txt' \
  '          fail_on_unmatched_files: true' \
  '        env:' \
  '          GITHUB_TOKEN: token-placeholder' \
  '      - name: Announce' \
  '        run: echo "prerelease: true"'

# --- 3/4. prerelease false / missing ----------------------------------------
make_publisher "$PINNED_PUBLISHER # v2" 'prerelease: false'
write_fixture "$TEST_TMP/prerelease-false.yml" \
  "${wf_header[@]}" "${wf_artifact_ok[@]}" "${PUB[@]}" "${wf_confirm[@]}"

make_publisher "$PINNED_PUBLISHER # v2" ''
write_fixture "$TEST_TMP/prerelease-missing.yml" \
  "${wf_header[@]}" "${wf_artifact_ok[@]}" "${PUB[@]}" "${wf_confirm[@]}"

# --- 5. commented-out publisher is not a publisher ---------------------------
write_fixture "$TEST_TMP/publisher-commented-out.yml" \
  "${wf_header[@]}" \
  "${wf_artifact_ok[@]}" \
  '      - name: Publish unnotarized GitHub prerelease' \
  "        # uses: $PINNED_PUBLISHER # v2" \
  '        # with:' \
  '        #   prerelease: true' \
  '        #   fail_on_unmatched_files: true' \
  '        run: echo "release publishing temporarily disabled"'

# --- 6-9. bad pins -----------------------------------------------------------
make_publisher 'softprops/action-gh-release@v2' 'prerelease: true'
write_fixture "$TEST_TMP/publisher-v2.yml" \
  "${wf_header[@]}" "${wf_artifact_ok[@]}" "${PUB[@]}"

make_publisher 'softprops/action-gh-release@main' 'prerelease: true'
write_fixture "$TEST_TMP/publisher-main.yml" \
  "${wf_header[@]}" "${wf_artifact_ok[@]}" "${PUB[@]}"

make_publisher 'softprops/action-gh-release@3bb12739c298aeb8a4eeaf626c5b8d85266b0e6' 'prerelease: true'
write_fixture "$TEST_TMP/publisher-39hex.yml" \
  "${wf_header[@]}" "${wf_artifact_ok[@]}" "${PUB[@]}"

make_publisher 'softprops/action-gh-release@3BB12739C298AEB8A4EEAF626C5B8D85266B0E65' 'prerelease: true'
write_fixture "$TEST_TMP/publisher-uppercase-hex.yml" \
  "${wf_header[@]}" "${wf_artifact_ok[@]}" "${PUB[@]}"

# --- 10. two publishers ------------------------------------------------------
make_publisher "$PINNED_PUBLISHER # v2" 'prerelease: true'
write_fixture "$TEST_TMP/two-publishers.yml" \
  "${wf_header[@]}" \
  "${wf_artifact_ok[@]}" \
  "${PUB[@]}" \
  '      - name: Also publish somewhere else' \
  '        uses: ncipollo/release-action@1a01f2a4bcbf1a4b6d0ba52b1a1d1b1e1f1a1b1c' \
  '        with:' \
  '          tag_name: v1.0.4' \
  '          prerelease: true'

# --- 11. shell publisher with flags between gh and release -------------------
write_fixture "$TEST_TMP/shell-publisher.yml" \
  "${wf_header[@]}" \
  "${wf_artifact_ok[@]}" \
  '      - name: Publish via gh' \
  '        env:' \
  '          GH_TOKEN: token-placeholder' \
  '        run: |' \
  '          set -euo pipefail' \
  '          gh -R owner/repo release create v1.0.4 --prerelease build/Release/SHA256SUMS.txt'

# --- 12-14. token allowlist on extra run steps -------------------------------
make_publisher "$PINNED_PUBLISHER # v2" 'prerelease: true'
write_fixture "$TEST_TMP/token-readonly-run.yml" \
  "${wf_header[@]}" \
  "${wf_artifact_ok[@]}" \
  "${PUB[@]}" \
  '      - name: Inspect existing release' \
  '        env:' \
  '          GITHUB_TOKEN: token-placeholder' \
  '        run: |' \
  '          gh api repos/o/r/releases/tags/v1.0.0'

write_fixture "$TEST_TMP/token-mutating-gh-api.yml" \
  "${wf_header[@]}" \
  "${wf_artifact_ok[@]}" \
  "${PUB[@]}" \
  '      - name: Move a ref' \
  '        env:' \
  '          GITHUB_TOKEN: token-placeholder' \
  '        run: |' \
  '          gh api repos/o/r/git/refs -f ref=refs/tags/v9'

# Same mutation split across a backslash continuation: the flag must not
# detach from `gh api` just because the command spans two physical lines.
# The trailing backslash inside the single-quoted fixture line is the point.
# shellcheck disable=SC1003
write_fixture "$TEST_TMP/token-mutating-gh-api-continuation.yml" \
  "${wf_header[@]}" \
  "${wf_artifact_ok[@]}" \
  "${PUB[@]}" \
  '      - name: Move a ref across a continuation' \
  '        env:' \
  '          GITHUB_TOKEN: token-placeholder' \
  '        run: |' \
  '          gh api repos/o/r/git/refs \' \
  '            -f ref=refs/tags/v9'

write_fixture "$TEST_TMP/token-git-push.yml" \
  "${wf_header[@]}" \
  "${wf_artifact_ok[@]}" \
  "${PUB[@]}" \
  '      - name: Push a tag' \
  '        env:' \
  '          GITHUB_TOKEN: token-placeholder' \
  '        run: |' \
  '          git push origin v1'

# --- R8: clobber guard presence and ordering ---------------------------------
write_fixture "$TEST_TMP/guard-missing.yml" \
  "${wf_header[@]}" "${wf_artifact_ok[@]}" "${PUB_NOGUARD[@]}"

write_fixture "$TEST_TMP/guard-after-publisher.yml" \
  "${wf_header[@]}" "${wf_artifact_ok[@]}" "${PUB_NOGUARD[@]}" "${wf_guard[@]}"

# --- 15. artifact renamed while prose still mentions the required name -------
write_fixture "$TEST_TMP/artifact-renamed.yml" \
  "${wf_header[@]}" "${wf_artifact_renamed[@]}" "${PUB[@]}" "${wf_confirm[@]}"

write_fixture "$TEST_TMP/artifact-unpinned.yml" \
  "${wf_header[@]}" "${wf_artifact_unpinned[@]}" "${PUB[@]}"

write_fixture "$TEST_TMP/artifact-no-retention.yml" \
  "${wf_header[@]}" "${wf_artifact_no_retention[@]}" "${PUB[@]}"

# --- required with: keys -----------------------------------------------------
make_publisher "$PINNED_PUBLISHER # v2" 'prerelease: true' 'files'
write_fixture "$TEST_TMP/publisher-no-files.yml" \
  "${wf_header[@]}" "${wf_artifact_ok[@]}" "${PUB[@]}"

make_publisher "$PINNED_PUBLISHER # v2" 'prerelease: true' 'fail_on_unmatched_files'
write_fixture "$TEST_TMP/publisher-no-fail-on-unmatched.yml" \
  "${wf_header[@]}" "${wf_artifact_ok[@]}" "${PUB[@]}"

# --- 16/17. forbid mode ------------------------------------------------------
ci_clean=(
  'name: CI'
  'on:'
  '  pull_request:'
  'permissions:'
  '  contents: read'
  'jobs:'
  '  scripts:'
  '    runs-on: macos-15'
  '    steps:'
  '      - name: Checkout'
  '        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1'
  '        with:'
  '          persist-credentials: false'
  '      - name: Install ShellCheck'
  '        run: brew install shellcheck'
  '      - name: Note'
  '        # softprops/action-gh-release is deliberately NOT used in CI'
  '        run: |'
  '          echo "CI never publishes a release; softprops/action-gh-release lives in release.yml"'
  '  tests:'
  '    runs-on: macos-15'
  '    steps:'
  '      - name: Swift tests'
  '        run: swift test --disable-sandbox'
)

write_fixture "$TEST_TMP/ci-clean.yml" "${ci_clean[@]}"

write_fixture "$TEST_TMP/ci-with-publisher.yml" \
  "${ci_clean[@]}" \
  '      - name: Sneak a release out of CI' \
  "        uses: $PINNED_PUBLISHER # v2" \
  '        with:' \
  '          tag_name: v1.0.4' \
  '          prerelease: true'

write_fixture "$TEST_TMP/ci-with-shell-publisher.yml" \
  "${ci_clean[@]}" \
  '      - name: Sneak a release out of CI' \
  '        env:' \
  '          GH_TOKEN: token-placeholder' \
  '        run: gh -R owner/repo release create v1.0.4'

# --- assertions --------------------------------------------------------------
expect_ok        "accepted pinned prerelease publisher with full contract" release "$TEST_TMP/release-ok.yml"
expect_violation "rejected prerelease: true living only in echo/body text"  release "$TEST_TMP/prerelease-text-only.yml"
expect_violation "rejected publisher with prerelease: false"               release "$TEST_TMP/prerelease-false.yml"
expect_violation "rejected publisher with no prerelease key"               release "$TEST_TMP/prerelease-missing.yml"
expect_violation "rejected commented-out publisher as the only publisher"  release "$TEST_TMP/publisher-commented-out.yml"
expect_violation "rejected publisher pinned to @v2"                        release "$TEST_TMP/publisher-v2.yml"
expect_violation "rejected publisher pinned to @main"                      release "$TEST_TMP/publisher-main.yml"
expect_violation "rejected publisher pinned to a 39-hex ref"               release "$TEST_TMP/publisher-39hex.yml"
expect_violation "rejected publisher pinned to an uppercase-hex ref"       release "$TEST_TMP/publisher-uppercase-hex.yml"
expect_violation "rejected a second release publisher step"                release "$TEST_TMP/two-publishers.yml"
expect_violation "rejected shell gh -R owner/repo release create"          release "$TEST_TMP/shell-publisher.yml"
expect_ok        "accepted token on a read-only gh api run step"           release "$TEST_TMP/token-readonly-run.yml"
expect_violation "rejected token on a gh api git/refs -f run step"         release "$TEST_TMP/token-mutating-gh-api.yml"
expect_violation "rejected gh api mutation split by backslash continuation" release "$TEST_TMP/token-mutating-gh-api-continuation.yml"
expect_violation "rejected token on a git push run step"                   release "$TEST_TMP/token-git-push.yml"
expect_violation "rejected workflow with no clobber guard step"            release "$TEST_TMP/guard-missing.yml"
expect_violation "rejected clobber guard placed after the publisher"       release "$TEST_TMP/guard-after-publisher.yml"
expect_violation "rejected renamed upload-artifact despite echo mention"   release "$TEST_TMP/artifact-renamed.yml"
expect_violation "rejected unpinned actions/upload-artifact"               release "$TEST_TMP/artifact-unpinned.yml"
expect_violation "rejected upload-artifact without retention-days"         release "$TEST_TMP/artifact-no-retention.yml"
expect_violation "rejected publisher without files:"                       release "$TEST_TMP/publisher-no-files.yml"
expect_violation "rejected publisher without fail_on_unmatched_files:"     release "$TEST_TMP/publisher-no-fail-on-unmatched.yml"
expect_ok        "accepted publisher-free ci workflow"                     forbid  "$TEST_TMP/ci-clean.yml"
expect_violation "rejected softprops publisher in ci workflow"             forbid  "$TEST_TMP/ci-with-publisher.yml"
expect_violation "rejected shell gh release publisher in ci workflow"      forbid  "$TEST_TMP/ci-with-shell-publisher.yml"
expect_violation "rejected shell publisher in forbid mode"                 forbid  "$TEST_TMP/shell-publisher.yml"

expect_usage_error "rejected missing --mode" "$TEST_TMP/release-ok.yml"
expect_usage_error "rejected unsupported --mode value" "--mode=publish" "$TEST_TMP/release-ok.yml"
expect_usage_error "rejected missing workflow operand" "--mode=release"
expect_usage_error "rejected extra workflow operands" "--mode=release" "$TEST_TMP/release-ok.yml" "$TEST_TMP/ci-clean.yml"
expect_usage_error "rejected unknown option" "--mode=release" "--strict" "$TEST_TMP/release-ok.yml"
expect_usage_error "rejected missing workflow file" "--mode=release" "$TEST_TMP/does-not-exist.yml"

status=0
bash "$CHECKER" >/dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then
  pass "rejected invocation with no arguments"
else
  fail "rejected invocation with no arguments (expected exit 2, got $status)"
fi

# --- the real workflows must satisfy their contracts today -------------------
expect_ok "real release workflow satisfies the publisher contract" release "$ROOT/.github/workflows/release.yml"
expect_ok "real ci workflow contains no release publisher"          forbid  "$ROOT/.github/workflows/ci.yml"

if [ "$failures" -ne 0 ]; then
  printf '=== %d release publisher checker test failure(s) ===\n' "$failures" >&2
  exit 1
fi

echo "=== release publisher checker tests passed ==="
