#!/bin/bash
# Centralized XcodeGen generation with a pinned compatible version.
# project.yml uses projectFormat: xcode15 — do not sed objectVersion after generate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Pin must match CI (see .github/workflows). Override with XCODEGEN_VERSION if needed.
REQUIRED_XCODEGEN_VERSION="${XCODEGEN_VERSION:-2.45.4}"

cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen is required (brew install xcodegen)" >&2
  echo "Expected version: ${REQUIRED_XCODEGEN_VERSION}" >&2
  exit 1
fi

installed="$(xcodegen --version 2>/dev/null | awk '{print $NF; exit}')"
if [ -z "$installed" ]; then
  echo "error: could not read xcodegen version" >&2
  exit 1
fi

if [ "$installed" != "$REQUIRED_XCODEGEN_VERSION" ]; then
  echo "error: xcodegen ${installed} found; required ${REQUIRED_XCODEGEN_VERSION}" >&2
  echo "Install the pinned version, or set XCODEGEN_VERSION=${installed} only if you intentionally override." >&2
  exit 1
fi

echo "Generating Xcode project with XcodeGen ${installed}…"
xcodegen generate
