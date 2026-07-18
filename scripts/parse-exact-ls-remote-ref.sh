#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: parse-exact-ls-remote-ref.sh <exact-ref>" >&2
  exit 2
fi

awk -v target_ref="$1" '
  $2 == target_ref {
    matches++
    object_id = $1
  }

  END {
    if (matches == 0) {
      exit 1
    }
    if (matches != 1) {
      printf "error: duplicate exact ls-remote records for %s\n", target_ref > "/dev/stderr"
      exit 2
    }
    print object_id
  }
'
