#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: validate-release-tag.sh <vMAJOR.MINOR.PATCH>" >&2
  exit 2
fi

LC_ALL=C
if [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  exit 0
fi

printf 'error: release tag must match v<digits>.<digits>.<digits> exactly (got: %q)\n' "$1" >&2
exit 1
