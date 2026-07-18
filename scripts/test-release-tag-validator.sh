#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="$ROOT/scripts/validate-release-tag.sh"
TEST_TMP="$(mktemp -d /tmp/razer-release-tag-test.XXXXXX)"
failures=0

cleanup() {
  case "$TEST_TMP" in
    /tmp/razer-release-tag-test.*)
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

expect_valid() {
  local tag="$1"
  if bash "$VALIDATOR" "$tag" >/dev/null 2>&1; then
    pass "accepted valid release tag $(printf '%q' "$tag")"
  else
    fail "rejected valid release tag $(printf '%q' "$tag")"
  fi
}

expect_invalid() {
  local tag="$1"
  if bash "$VALIDATOR" "$tag" >/dev/null 2>&1; then
    fail "accepted invalid release tag $(printf '%q' "$tag")"
  else
    pass "rejected invalid release tag $(printf '%q' "$tag")"
  fi
}

if [ ! -f "$VALIDATOR" ]; then
  fail "release tag validator missing: $VALIDATOR"
  exit 1
fi

expect_valid "v0.0.0"
expect_valid "v1.0.2"
expect_valid "v12.345.6789"

expect_invalid 'v$(id)'
expect_invalid 'v1.2.3";id'
expect_invalid "v1.2.3';id"
expect_invalid $'v1.2.3\nid'
expect_invalid "refs/tags/v1.2.3"
expect_invalid "v1.2.3-rc.1"
expect_invalid "v1.2"
expect_invalid "release-v1.2.3"
expect_invalid "v1.2.3-trailing"
expect_invalid ""
expect_invalid "--self-test"

SENTINEL="$TEST_TMP/command-substitution-executed"
COMMAND_SUBSTITUTION_TAG='v$(touch '"$SENTINEL"')'
expect_invalid "$COMMAND_SUBSTITUTION_TAG"
if [ -e "$SENTINEL" ]; then
  fail "literal command substitution created sentinel: $SENTINEL"
else
  pass "literal command substitution did not create sentinel"
fi

if [ "$failures" -ne 0 ]; then
  printf '=== %d release tag validator test failure(s) ===\n' "$failures" >&2
  exit 1
fi

echo "=== release tag validator tests passed ==="
