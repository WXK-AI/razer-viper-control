#!/bin/bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: check-workflow-run-interpolation.sh <workflow.yml> [...]" >&2
  exit 2
fi

awk '
  function indentation(line, spaces) {
    spaces = line
    sub(/[^ ].*$/, "", spaces)
    return length(spaces)
  }

  function report(message, line) {
    printf "%s:%d: %s: %s\n", FILENAME, FNR, message, line > "/dev/stderr"
    failures = 1
  }

  {
    if (FNR == 1) {
      in_run = 0
    }

    line = $0
    indent = indentation(line)

    if (in_run && line !~ /^[[:space:]]*$/ && indent <= run_indent) {
      in_run = 0
    }

    if (line ~ /^ *(- +)?run: */) {
      remainder = line
      sub(/^ *(- +)?run: */, "", remainder)

      if (index(remainder, "${{") > 0) {
        report("GitHub expression directly interpolated in run command", line)
      }

      if (remainder ~ /^(\||>)/) {
        if (remainder ~ /^(\||>)([+-]|[1-9]|[+-][1-9]|[1-9][+-])?[[:space:]]*(#.*)?$/) {
          in_run = 1
          run_indent = indent
        } else {
          report("unrecognized run block scalar header", line)
        }
      }
      next
    }

    if (in_run && index(line, "${{") > 0) {
      report("GitHub expression directly interpolated in run block", line)
    }
  }

  END {
    if (failures) {
      exit 1
    }
  }
' "$@"
