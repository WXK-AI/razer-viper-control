#!/bin/bash
# Adversarial fixtures for scripts/check-workflow-permissions.sh.
# The point of the checker is EXACT-SET matching of the top-level permissions
# block, so every fixture here targets a case the old `grep -A2` window either
# missed (added key, comment line, blank line) or got wrong (key order).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKER="$ROOT/scripts/check-workflow-permissions.sh"
TEST_TMP="$(mktemp -d /tmp/razer-workflow-perms-test.XXXXXX)"
failures=0

cleanup() {
  case "$TEST_TMP" in
    /tmp/razer-workflow-perms-test.*)
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

# expect_ok <label> <fixture> <key>:<value>...
expect_ok() {
  local label="$1"
  local fixture="$2"
  shift 2
  local status=0
  bash "$CHECKER" "$fixture" "$@" >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 0 ]; then
    pass "$label"
  else
    fail "$label (expected exit 0, got $status)"
  fi
}

# expect_violation <label> <fixture> <key>:<value>...
expect_violation() {
  local label="$1"
  local fixture="$2"
  shift 2
  local status=0
  bash "$CHECKER" "$fixture" "$@" >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 1 ]; then
    pass "$label"
  else
    fail "$label (expected exit 1, got $status)"
  fi
}

# expect_usage <label> <arg>...
expect_usage() {
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
  fail "workflow permissions checker missing: $CHECKER"
  exit 1
fi

write_fixture "$TEST_TMP/exact.yml" \
  'name: Release' \
  'on:' \
  '  push:' \
  '    tags:' \
  '      - "v*"' \
  'permissions:' \
  '  contents: write' \
  '  actions: write' \
  'jobs:' \
  '  release:' \
  '    runs-on: macos-15'

write_fixture "$TEST_TMP/reversed.yml" \
  'permissions:' \
  '  actions: write' \
  '  contents: write' \
  'jobs:' \
  '  release:' \
  '    runs-on: macos-15'

write_fixture "$TEST_TMP/extra-key.yml" \
  'permissions:' \
  '  contents: write' \
  '  actions: write' \
  '  id-token: write' \
  'jobs:' \
  '  release:' \
  '    runs-on: macos-15'

write_fixture "$TEST_TMP/missing-key.yml" \
  'permissions:' \
  '  contents: write' \
  'jobs:' \
  '  release:' \
  '    runs-on: macos-15'

write_fixture "$TEST_TMP/wrong-value.yml" \
  'permissions:' \
  '  contents: read' \
  '  actions: write' \
  'jobs:' \
  '  release:' \
  '    runs-on: macos-15'

write_fixture "$TEST_TMP/comment-inside.yml" \
  'permissions:' \
  '  # GitHub Release assets need write; keep this block minimal.' \
  '  contents: write' \
  '  actions: write' \
  'jobs:' \
  '  release:' \
  '    runs-on: macos-15'

write_fixture "$TEST_TMP/inline-comment.yml" \
  'permissions:' \
  '  contents: write   # create/update GitHub Release + upload assets' \
  '  actions: write    # short-retention Actions artifact' \
  'jobs:' \
  '  release:' \
  '    runs-on: macos-15'

write_fixture "$TEST_TMP/blank-line-inside.yml" \
  'permissions:' \
  '  contents: write' \
  '' \
  '  actions: write' \
  'jobs:' \
  '  release:' \
  '    runs-on: macos-15'

write_fixture "$TEST_TMP/nested-job-permissions.yml" \
  'permissions:' \
  '  contents: write' \
  '  actions: write' \
  'jobs:' \
  '  release:' \
  '    runs-on: macos-15' \
  '    permissions:' \
  '      contents: write' \
  '      id-token: write'

write_fixture "$TEST_TMP/only-job-permissions.yml" \
  'name: Release' \
  'jobs:' \
  '  release:' \
  '    runs-on: macos-15' \
  '    permissions:' \
  '      contents: write' \
  '      actions: write'

write_fixture "$TEST_TMP/no-permissions.yml" \
  'name: Release' \
  'on:' \
  '  push:' \
  'jobs:' \
  '  release:' \
  '    runs-on: macos-15'

write_fixture "$TEST_TMP/ci-style.yml" \
  'name: CI' \
  'env:' \
  '  XCODEGEN_VERSION: "2.45.4"' \
  'permissions:' \
  '  contents: read' \
  'jobs:' \
  '  scripts:' \
  '    runs-on: macos-15'

write_fixture "$TEST_TMP/ci-style-extra.yml" \
  'permissions:' \
  '  contents: read' \
  '  actions: read' \
  'jobs:' \
  '  scripts:' \
  '    runs-on: macos-15'

write_fixture "$TEST_TMP/quoted-value.yml" \
  'permissions:' \
  '  contents: "write"' \
  '  actions: write' \
  'jobs:' \
  '  release:' \
  '    runs-on: macos-15'

write_fixture "$TEST_TMP/empty-block.yml" \
  'permissions:' \
  'jobs:' \
  '  release:' \
  '    runs-on: macos-15'

write_fixture "$TEST_TMP/inline-read-all.yml" \
  'permissions: read-all' \
  'jobs:' \
  '  release:' \
  '    runs-on: macos-15'

write_fixture "$TEST_TMP/duplicate-block.yml" \
  'permissions:' \
  '  contents: write' \
  '  actions: write' \
  'jobs:' \
  '  release:' \
  '    runs-on: macos-15' \
  'permissions:' \
  '  contents: write' \
  '  actions: write'

# A key/value pair that only LOOKS like a permission, sitting outside the block:
# the block ended at the column-0 "jobs:" key, so this must not be collected.
write_fixture "$TEST_TMP/lookalike-outside-block.yml" \
  'permissions:' \
  '  contents: write' \
  '  actions: write' \
  'jobs:' \
  '  release:' \
  '    runs-on: macos-15' \
  '    env:' \
  '      id-token: write'

# Comment lines at column 0 must not be mistaken for the next top-level key.
write_fixture "$TEST_TMP/column0-comment.yml" \
  'permissions:' \
  '  contents: write' \
  '# a column-0 comment does not close the block' \
  '  actions: write' \
  'jobs:' \
  '  release:' \
  '    runs-on: macos-15'

expect_ok "exact match contents:write + actions:write" \
  "$TEST_TMP/exact.yml" contents:write actions:write
expect_ok "key order does not matter" \
  "$TEST_TMP/reversed.yml" contents:write actions:write
expect_ok "expected-pair order does not matter" \
  "$TEST_TMP/exact.yml" actions:write contents:write
expect_ok "comment line inside the block" \
  "$TEST_TMP/comment-inside.yml" contents:write actions:write
expect_ok "inline trailing comments on value lines" \
  "$TEST_TMP/inline-comment.yml" contents:write actions:write
expect_ok "blank line inside the block" \
  "$TEST_TMP/blank-line-inside.yml" contents:write actions:write
expect_ok "column-0 comment does not close the block" \
  "$TEST_TMP/column0-comment.yml" contents:write actions:write
expect_ok "quoted value unquoted before comparison" \
  "$TEST_TMP/quoted-value.yml" contents:write actions:write
expect_ok "ci-style single contents:read key" \
  "$TEST_TMP/ci-style.yml" contents:read
expect_ok "lookalike key outside the block is ignored" \
  "$TEST_TMP/lookalike-outside-block.yml" contents:write actions:write

expect_violation "added id-token:write is an extra key" \
  "$TEST_TMP/extra-key.yml" contents:write actions:write
expect_violation "missing actions:write key" \
  "$TEST_TMP/missing-key.yml" contents:write actions:write
expect_violation "wrong value contents:read where write expected" \
  "$TEST_TMP/wrong-value.yml" contents:write actions:write
expect_violation "job-level nested permissions block" \
  "$TEST_TMP/nested-job-permissions.yml" contents:write actions:write
expect_violation "job-level permissions with no top-level block" \
  "$TEST_TMP/only-job-permissions.yml" contents:write actions:write
expect_violation "no permissions block at all" \
  "$TEST_TMP/no-permissions.yml" contents:write actions:write
expect_violation "ci-style block with an extra actions:read key" \
  "$TEST_TMP/ci-style-extra.yml" contents:read
expect_violation "ci-style contents:read fails a contents:write contract" \
  "$TEST_TMP/ci-style.yml" contents:write
expect_violation "empty top-level permissions block" \
  "$TEST_TMP/empty-block.yml" contents:write actions:write
expect_violation "inline permissions: read-all is not a block mapping" \
  "$TEST_TMP/inline-read-all.yml" contents:write actions:write
expect_violation "duplicate top-level permissions blocks" \
  "$TEST_TMP/duplicate-block.yml" contents:write actions:write

status=0
bash "$CHECKER" >/dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then
  pass "rejected invocation with no arguments"
else
  fail "rejected invocation with no arguments (expected exit 2, got $status)"
fi

expect_usage "rejected workflow with no expected pairs" "$TEST_TMP/exact.yml"
expect_usage "rejected missing workflow file" "$TEST_TMP/does-not-exist.yml" contents:write
expect_usage "rejected pair without a colon" "$TEST_TMP/exact.yml" contents
expect_usage "rejected pair with an empty value" "$TEST_TMP/exact.yml" contents:
expect_usage "rejected duplicate expected key" \
  "$TEST_TMP/exact.yml" contents:write contents:read

REAL_RELEASE="$ROOT/.github/workflows/release.yml"
REAL_CI="$ROOT/.github/workflows/ci.yml"

if [ -f "$REAL_RELEASE" ]; then
  expect_ok "real release.yml declares exactly contents:write + actions:write" \
    "$REAL_RELEASE" contents:write actions:write
else
  fail "real release workflow missing: $REAL_RELEASE"
fi

if [ -f "$REAL_CI" ]; then
  expect_ok "real ci.yml declares exactly contents:read" \
    "$REAL_CI" contents:read
  expect_violation "real ci.yml does not grant contents:write" \
    "$REAL_CI" contents:write
else
  fail "real ci workflow missing: $REAL_CI"
fi

if [ "$failures" -ne 0 ]; then
  printf '=== %d workflow permissions checker test failure(s) ===\n' "$failures" >&2
  exit 1
fi

echo "=== workflow permissions checker tests passed ==="
