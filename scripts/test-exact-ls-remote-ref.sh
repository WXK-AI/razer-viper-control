#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARSER="$ROOT/scripts/parse-exact-ls-remote-ref.sh"
TARGET_REF="refs/tags/v1.0.2"
failures=0

pass() { printf 'PASS: %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

run_parser() {
  local records="$1"
  set +e
  PARSER_OUTPUT="$(printf '%s\n' "$records" | bash "$PARSER" "$TARGET_REF" 2>/dev/null)"
  PARSER_STATUS=$?
  set -e
}

expect_object() {
  local label="$1"
  local expected="$2"
  local records="$3"
  run_parser "$records"
  if [ "$PARSER_STATUS" -eq 0 ] && [ "$PARSER_OUTPUT" = "$expected" ]; then
    pass "$label"
  else
    fail "$label (status=$PARSER_STATUS output=${PARSER_OUTPUT:-<empty>})"
  fi
}

expect_status() {
  local label="$1"
  local expected_status="$2"
  local records="$3"
  run_parser "$records"
  if [ "$PARSER_STATUS" -eq "$expected_status" ] && [ -z "$PARSER_OUTPUT" ]; then
    pass "$label"
  else
    fail "$label (status=$PARSER_STATUS output=${PARSER_OUTPUT:-<empty>})"
  fi
}

if [ ! -f "$PARSER" ]; then
  fail "exact ls-remote ref parser missing: $PARSER"
  exit 1
fi

LIGHTWEIGHT_OBJECT="1111111111111111111111111111111111111111"
SUFFIX_OBJECT="2222222222222222222222222222222222222222"
ANNOTATED_OBJECT="3333333333333333333333333333333333333333"
PEELED_COMMIT="4444444444444444444444444444444444444444"

expect_object \
  "selected only the exact ref among suffix-matching records" \
  "$LIGHTWEIGHT_OBJECT" \
  "$SUFFIX_OBJECT refs/archive/$TARGET_REF
$LIGHTWEIGHT_OBJECT $TARGET_REF
$SUFFIX_OBJECT refs/heads/$TARGET_REF"

expect_status \
  "reported exact ref absence distinctly" \
  1 \
  "$SUFFIX_OBJECT refs/archive/$TARGET_REF
$SUFFIX_OBJECT refs/heads/$TARGET_REF"

expect_status \
  "rejected duplicate exact ref records" \
  2 \
  "$LIGHTWEIGHT_OBJECT $TARGET_REF
$ANNOTATED_OBJECT $TARGET_REF"

expect_object \
  "returned lightweight tag object identity" \
  "$LIGHTWEIGHT_OBJECT" \
  "$LIGHTWEIGHT_OBJECT $TARGET_REF"

expect_object \
  "returned annotated tag object instead of peeled commit" \
  "$ANNOTATED_OBJECT" \
  "$ANNOTATED_OBJECT $TARGET_REF
$PEELED_COMMIT $TARGET_REF^{}"

if [ "$failures" -ne 0 ]; then
  printf '=== %d exact ls-remote ref parser test failure(s) ===\n' "$failures" >&2
  exit 1
fi

echo "=== exact ls-remote ref parser tests passed ==="
