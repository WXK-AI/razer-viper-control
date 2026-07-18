#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKER="$ROOT/scripts/check-workflow-run-interpolation.sh"
TEST_TMP="$(mktemp -d /tmp/razer-workflow-check-test.XXXXXX)"
failures=0

cleanup() {
  case "$TEST_TMP" in
    /tmp/razer-workflow-check-test.*)
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

expect_safe() {
  local label="$1"
  local fixture="$2"
  if bash "$CHECKER" "$fixture" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label"
  fi
}

expect_unsafe() {
  local label="$1"
  local fixture="$2"
  if bash "$CHECKER" "$fixture" >/dev/null 2>&1; then
    fail "$label"
  else
    pass "$label"
  fi
}

if [ ! -f "$CHECKER" ]; then
  fail "workflow run interpolation checker missing: $CHECKER"
  exit 1
fi

write_fixture "$TEST_TMP/safe-blocks.yml" \
  'jobs:' \
  '  test:' \
  '    steps:' \
  '      - env:' \
  '          SAFE_REF: ${{ github.ref_name }}' \
  '        run: |' \
  '          printf '\''%s\n'\'' "$SAFE_REF"' \
  '      - run: >-' \
  '          printf '\''%s\n'\''' \
  '          "safe folded command"'

write_fixture "$TEST_TMP/safe-inline.yml" \
  'steps:' \
  '  - run: echo "$SAFE_REF"'

write_fixture "$TEST_TMP/safe-indent-chomp.yml" \
  'steps:' \
  '  - run: |2-' \
  '      echo "$SAFE_REF"'

write_fixture "$TEST_TMP/safe-chomp-indent.yml" \
  'steps:' \
  '  - run: |-2' \
  '      echo "$SAFE_REF"'

write_fixture "$TEST_TMP/safe-folded-indent-chomp.yml" \
  'steps:' \
  '  - run: >2-' \
  '      echo "$SAFE_REF"'

write_fixture "$TEST_TMP/safe-folded-chomp-indent.yml" \
  'steps:' \
  '  - run: >-2' \
  '      echo "$SAFE_REF"'

write_fixture "$TEST_TMP/safe-header-comments.yml" \
  'steps:' \
  '  - run: | # literal block comment' \
  '      echo "$SAFE_REF"' \
  '  - run: >2- # folded block comment' \
  '      echo "$SAFE_REF"'

write_fixture "$TEST_TMP/unsafe-literal.yml" \
  'steps:' \
  '  - run: |' \
  '      echo "${{ github.ref_name }}"'

write_fixture "$TEST_TMP/unsafe-folded.yml" \
  'steps:' \
  '  - run: >' \
  '      echo "${{ github.sha }}"'

write_fixture "$TEST_TMP/unsafe-indent-chomp.yml" \
  'steps:' \
  '  - run: |2-' \
  '      echo "${{ github.event_name }}"'

write_fixture "$TEST_TMP/unsafe-chomp-indent.yml" \
  'steps:' \
  '  - run: |-2' \
  '      echo "${{ github.event.inputs.tag }}"'

write_fixture "$TEST_TMP/unsafe-folded-indent-chomp.yml" \
  'steps:' \
  '  - run: >2-' \
  '      echo "${{ github.event_name }}"'

write_fixture "$TEST_TMP/unsafe-folded-chomp-indent.yml" \
  'steps:' \
  '  - run: >-2' \
  '      echo "${{ github.event.inputs.tag }}"'

write_fixture "$TEST_TMP/unsafe-header-comment.yml" \
  'steps:' \
  '  - run: | # literal shell block' \
  '      echo "${{ steps.tag.outputs.name }}"'

write_fixture "$TEST_TMP/unsafe-inline.yml" \
  'steps:' \
  '  - run: echo "${{ steps.commit.outputs.sha }}"'

expect_safe "accepted safe literal and folded run blocks" "$TEST_TMP/safe-blocks.yml"
expect_safe "accepted safe inline run command" "$TEST_TMP/safe-inline.yml"
expect_safe "accepted safe |2- run block" "$TEST_TMP/safe-indent-chomp.yml"
expect_safe "accepted safe |-2 run block" "$TEST_TMP/safe-chomp-indent.yml"
expect_safe "accepted safe >2- run block" "$TEST_TMP/safe-folded-indent-chomp.yml"
expect_safe "accepted safe >-2 run block" "$TEST_TMP/safe-folded-chomp-indent.yml"
expect_safe "accepted safe run block headers with comments" "$TEST_TMP/safe-header-comments.yml"
expect_unsafe "rejected expression in literal run block" "$TEST_TMP/unsafe-literal.yml"
expect_unsafe "rejected expression in folded run block" "$TEST_TMP/unsafe-folded.yml"
expect_unsafe "rejected expression in |2- run block" "$TEST_TMP/unsafe-indent-chomp.yml"
expect_unsafe "rejected expression in |-2 run block" "$TEST_TMP/unsafe-chomp-indent.yml"
expect_unsafe "rejected expression in >2- run block" "$TEST_TMP/unsafe-folded-indent-chomp.yml"
expect_unsafe "rejected expression in >-2 run block" "$TEST_TMP/unsafe-folded-chomp-indent.yml"
expect_unsafe "rejected expression after run block header comment" "$TEST_TMP/unsafe-header-comment.yml"
expect_unsafe "rejected expression in inline run command" "$TEST_TMP/unsafe-inline.yml"

if [ "$failures" -ne 0 ]; then
  printf '=== %d workflow checker test failure(s) ===\n' "$failures" >&2
  exit 1
fi

echo "=== workflow run interpolation checker tests passed ==="
