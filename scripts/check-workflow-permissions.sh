#!/bin/bash
# Structural check of a workflow's TOP-LEVEL `permissions:` block.
#
# Replaces the fragile `grep -A2 '^permissions:$' | grep ...` fixed-window idiom.
# An -A<N> window happens to fit today's block exactly, so it silently stops
# matching the moment the block grows a third key, a comment line, or a blank
# line — and it is order sensitive. Worse, a window check can only assert that
# some key is present; it can never notice a key that was ADDED (an extra
# `id-token: write` sails straight through). This walks the block structurally
# instead: start at a column-0 `permissions:` key, end at the next column-0 key,
# then compare the parsed key/value set against the expected set EXACTLY.
#
# Repo contract enforced here: permissions are declared exactly ONCE, at the top
# level of the workflow. A job-level (indented) `permissions:` block is a hard
# failure — a per-job grant widens the job token without changing the top-level
# block that every reviewer (and this check) actually reads, so the two would
# disagree about what the workflow can do.
#
# Known scope limit: this is a line-structural scan, not a YAML parser. Text
# inside a block scalar that looks like an indented `permissions:` mapping key
# would be reported as a nested block. That is the safe direction to fail, and
# no workflow in this repo embeds such text.
#
# usage: check-workflow-permissions.sh <workflow.yml> <key>:<value> [<key>:<value> ...]
#
# exit 0  top-level block declares exactly the given pairs
# exit 1  mismatch: missing key, extra key, wrong value, nested block, or no block
# exit 2  usage error
set -euo pipefail

usage() {
  echo "usage: check-workflow-permissions.sh <workflow.yml> <key>:<value> [<key>:<value> ...]" >&2
  exit 2
}

if [ "$#" -lt 2 ]; then
  usage
fi

workflow="$1"
shift

if [ ! -f "$workflow" ]; then
  printf 'error: workflow file not found: %s\n' "$workflow" >&2
  exit 2
fi

spec=""
seen_keys=""
for pair in "$@"; do
  if ! [[ "$pair" =~ ^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$ ]]; then
    printf 'error: expected <key>:<value>, got: %s\n' "$pair" >&2
    usage
  fi
  key="${pair%%:*}"
  case " $seen_keys " in
    *" $key "*)
      printf 'error: duplicate expected key: %s\n' "$key" >&2
      usage
      ;;
  esac
  seen_keys="$seen_keys $key"
  spec="${spec:+$spec }$pair"
done

awk -v file="$workflow" -v spec="$spec" '
  function trim(s) {
    sub(/^[[:space:]]+/, "", s)
    sub(/[[:space:]]+$/, "", s)
    return s
  }

  # Strip a YAML inline comment: only whitespace-preceded "#" starts one, so
  # "write   # create release" loses the comment while "read-all#x" does not.
  function strip_comment(s) {
    sub(/[[:space:]]+#.*$/, "", s)
    return s
  }

  function unquote(s, first, last) {
    if (length(s) >= 2) {
      first = substr(s, 1, 1)
      last = substr(s, length(s), 1)
      if (first == last && (first == "\"" || first == squote)) {
        return substr(s, 2, length(s) - 2)
      }
    }
    return s
  }

  function report(msg, line) {
    if (line > 0) {
      printf "%s:%d: %s\n", file, line, msg > "/dev/stderr"
    } else {
      printf "%s: %s\n", file, msg > "/dev/stderr"
    }
    failures++
  }

  BEGIN {
    squote = sprintf("%c", 39)
    want_n = split(spec, pairs, / +/)
    for (i = 1; i <= want_n; i++) {
      at = index(pairs[i], ":")
      k = substr(pairs[i], 1, at - 1)
      want[k] = substr(pairs[i], at + 1)
      want_key[i] = k
    }
    in_block = 0
    top_count = 0
    got_n = 0
    nested_count = 0
    nested_first = 0
    failures = 0
  }

  # Blank lines and whole-line comments never open, close, or populate a block.
  /^[[:space:]]*$/ { next }
  /^[[:space:]]*#/ { next }

  {
    line = $0

    # Column-0 key: this is the only thing that opens or closes the top-level block.
    if (line ~ /^[^[:space:]]/) {
      in_block = 0

      if (line ~ /^permissions:([[:space:]]|$)/) {
        top_count++
        if (top_count > 1) {
          report("duplicate top-level permissions: block", FNR)
          next
        }
        rest = line
        sub(/^permissions:/, "", rest)
        rest = trim(strip_comment(rest))
        if (rest != "") {
          report("top-level permissions: must be a block mapping of key: value pairs, got inline value " squote rest squote, FNR)
          next
        }
        in_block = 1
      }
      next
    }

    # Indented permissions: — a job-level (or otherwise nested) grant.
    if (line ~ /^[[:space:]]+permissions:([[:space:]]|$)/) {
      nested_count++
      if (nested_first == 0) {
        nested_first = FNR
      }
      next
    }

    if (!in_block) {
      next
    }

    entry = trim(strip_comment(line))
    if (entry == "") {
      next
    }

    at = index(entry, ":")
    if (at == 0) {
      report("unparsable entry in top-level permissions block: " entry, FNR)
      next
    }

    k = trim(substr(entry, 1, at - 1))
    v = unquote(trim(substr(entry, at + 1)))

    if (k in got) {
      report("duplicate permission key " squote k squote " in top-level block", FNR)
      next
    }

    got[k] = v
    got_line[k] = FNR
    got_key[++got_n] = k
  }

  END {
    if (nested_count > 0) {
      report(sprintf("nested (job-level) permissions: block found — %d occurrence(s), first at line %d; permissions must be declared once, at the top level", nested_count, nested_first), 0)
    }

    if (top_count == 0) {
      report("no top-level permissions: block found (expected a permissions: key at column 0)", 0)
    } else {
      for (i = 1; i <= want_n; i++) {
        k = want_key[i]
        if (!(k in got)) {
          report(sprintf("missing permission %s: %s", k, want[k]), 0)
        } else if (got[k] != want[k]) {
          report(sprintf("permission %s is %s%s%s, expected %s%s%s", k, squote, got[k], squote, squote, want[k], squote), got_line[k])
        }
      }
      for (i = 1; i <= got_n; i++) {
        k = got_key[i]
        if (!(k in want)) {
          report(sprintf("unexpected permission %s: %s (not in the required set)", k, got[k]), got_line[k])
        }
      }
    }

    if (failures) {
      printf "%s: top-level permissions must be exactly: %s\n", file, spec > "/dev/stderr"
      exit 1
    }
  }
' "$workflow"
