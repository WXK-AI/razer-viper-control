#!/bin/bash
# Structural analyzer for a GitHub Actions workflow's release-publishing surface.
#
# Whole-file greps for strings like 'prerelease: true' or 'UNNOTARIZED-TEST-BUILD'
# are satisfied by YAML comments, by release-note body text and by echo prose, so
# they cannot express "this step publishes the release". This checker parses steps
# STRUCTURALLY by indentation, using the same awk idiom as
# scripts/check-workflow-run-interpolation.sh (no python/ruby/yq dependency), and:
#
#   * ignores any line whose first non-space character is '#' (YAML comment)
#   * ignores block-scalar bodies (body: | ... , files: | ... ) as TEXT
#   * scopes every match to the owning step, never to the whole file
#
# usage:
#   check-release-publisher.sh --mode=release <workflow.yml>
#   check-release-publisher.sh --mode=forbid  <workflow.yml>
#
# exit 0  contract satisfied
# exit 1  violation ('file:line: RULE: reason' diagnostics on stderr)
# exit 2  usage error
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: check-release-publisher.sh --mode=release|forbid <workflow.yml>

  --mode=release   require exactly one SHA-pinned softprops/action-gh-release
                   publisher and its full prerelease contract (R1-R8)
  --mode=forbid    require that no release publisher step exists at all

exit codes: 0 = contract satisfied, 1 = violation, 2 = usage error
USAGE
}

if [ "$#" -eq 0 ]; then
  usage
  exit 2
fi

mode=""
workflow=""
extra_operands=0

for arg in "$@"; do
  case "$arg" in
    --mode=*)
      mode="${arg#--mode=}"
      ;;
    -h|--help)
      usage
      exit 2
      ;;
    -*)
      printf 'error: unknown option: %s\n' "$arg" >&2
      usage
      exit 2
      ;;
    *)
      if [ -n "$workflow" ]; then
        extra_operands=1
      else
        workflow="$arg"
      fi
      ;;
  esac
done

if [ "$extra_operands" -ne 0 ]; then
  printf 'error: exactly one workflow file is supported\n' >&2
  usage
  exit 2
fi

if [ -z "$mode" ] || [ -z "$workflow" ]; then
  usage
  exit 2
fi

case "$mode" in
  release|forbid) ;;
  *)
    printf 'error: unsupported mode: %s\n' "$mode" >&2
    usage
    exit 2
    ;;
esac

if [ ! -f "$workflow" ]; then
  printf 'error: workflow file not found: %s\n' "$workflow" >&2
  exit 2
fi

if awk -v mode="$mode" -v wf="$workflow" '
  function spaces(n,   s) {
    s = ""
    while (n-- > 0) { s = s " " }
    return s
  }

  function indentation(l,   sp) {
    sp = l
    sub(/[^ ].*$/, "", sp)
    return length(sp)
  }

  function trim(s) {
    sub(/^[[:space:]]+/, "", s)
    sub(/[[:space:]]+$/, "", s)
    return s
  }

  # Drops a trailing YAML comment, e.g. "softprops/action-gh-release@<sha> # v2".
  function strip_comment(s) {
    sub(/[[:space:]]+#.*$/, "", s)
    return s
  }

  function key_of(l,   k) {
    if (l !~ /^[[:space:]]*[A-Za-z0-9_.-]+:([[:space:]]|$)/) { return "" }
    k = l
    sub(/^[[:space:]]*/, "", k)
    sub(/:.*$/, "", k)
    return k
  }

  function val_of(l,   v) {
    v = l
    sub(/^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*/, "", v)
    return v
  }

  function is_hex40(s) {
    if (length(s) != 40) { return 0 }
    if (s ~ /[^0-9a-f]/) { return 0 }
    return 1
  }

  function action_repo(u,   spec) {
    spec = u
    sub(/@.*$/, "", spec)
    return spec
  }

  function action_ref(u,   at) {
    at = index(u, "@")
    if (at == 0) { return "" }
    return substr(u, at + 1)
  }

  # SINGLE source of truth for "which actions publish a GitHub Release".
  # --mode=release and --mode=forbid both call this; never duplicate the list,
  # or the two modes drift apart and one of them stops catching a publisher.
  function is_publisher_action(u,   spec, parts, n, owner, repo, full) {
    spec = action_repo(u)
    n = split(spec, parts, "/")
    if (n < 2) { return 0 }
    owner = tolower(parts[1])
    repo = tolower(parts[2])
    full = owner "/" repo
    if (full == "actions/upload-artifact") { return 0 }
    if (full == "softprops/action-gh-release") { return 1 }
    if (full == "actions/create-release") { return 1 }
    if (full == "actions/upload-release-asset") { return 1 }
    if (full == "ncipollo/release-action") { return 1 }
    if (index(repo, "release") > 0) { return 1 }
    return 0
  }

  # Shell-word tokenizer for run: bodies. Command separators and redirections
  # collapse to a single "@" barrier token so a scan never runs past the end of
  # one command; everything else that is not a word/path character is dropped
  # (quotes, dollars, equals), which keeps --method=POST and -f a=b detectable.
  function normalize(l,   s) {
    s = l
    gsub(/[;&|<>()]+/, " @ ", s)
    gsub(/[^A-Za-z0-9_.@ \/-]/, " ", s)
    return s
  }

  # True when <cmd> is invoked with <want> as a later word of the SAME command,
  # so "gh -R owner/repo release create" matches while a naive gh[[:space:]]+release
  # regex would not.
  function cmd_has_sub(l, cmd, want,   t, n, i, j) {
    n = split(normalize(l), t, /[[:space:]]+/)
    for (i = 1; i <= n; i++) {
      if (t[i] != cmd) { continue }
      for (j = i + 1; j <= n; j++) {
        if (t[j] == "@") { break }
        if (t[j] == want) { return 1 }
      }
    }
    return 0
  }

  # gh api with -f/--field/-F/--raw-field/-X/--method: all force a non-GET request.
  function gh_api_flagged(l,   t, n, i, j, seen) {
    n = split(normalize(l), t, /[[:space:]]+/)
    for (i = 1; i <= n; i++) {
      if (t[i] != "gh") { continue }
      seen = 0
      for (j = i + 1; j <= n; j++) {
        if (t[j] == "@") { break }
        if (t[j] == "api") { seen = 1; continue }
        if (seen == 0) { continue }
        if (t[j] == "-f" || t[j] == "--field" || t[j] == "-F" ||
            t[j] == "--raw-field" || t[j] == "-X" || t[j] == "--method") { return 1 }
      }
    }
    return 0
  }

  function gh_api_releases_path(l,   t, n, i, j, seen) {
    n = split(normalize(l), t, /[[:space:]]+/)
    for (i = 1; i <= n; i++) {
      if (t[i] != "gh") { continue }
      seen = 0
      for (j = i + 1; j <= n; j++) {
        if (t[j] == "@") { break }
        if (t[j] == "api") { seen = 1; continue }
        if (seen == 0) { continue }
        if (t[j] ~ /(^|\/)releases(\/|$)/) { return 1 }
      }
    }
    return 0
  }

  function run_is_publisher(l) {
    if (cmd_has_sub(l, "gh", "release")) { return 1 }
    if (gh_api_flagged(l) && gh_api_releases_path(l)) { return 1 }
    return 0
  }

  function run_mutates_refs(l) {
    if (cmd_has_sub(l, "git", "push")) { return 1 }
    if (cmd_has_sub(l, "git", "tag")) { return 1 }
    if (cmd_has_sub(l, "git", "update-ref")) { return 1 }
    if (l ~ /git\/refs/) { return 1 }
    if (gh_api_flagged(l)) { return 1 }
    if (cmd_has_sub(l, "gh", "release")) { return 1 }
    return 0
  }

  function scan_logical(l) {
    if (st_runpub[cur] == 0 && run_is_publisher(l)) {
      st_runpub[cur] = 1
      st_runpubline[cur] = FNR
    }
    if (st_runbad[cur] == 0 && run_mutates_refs(l)) {
      st_runbad[cur] = 1
      st_runbadline[cur] = FNR
    }
  }

  function scan_run_line(l) {
    # Join shell backslash continuations into one logical command before
    # scanning: "gh api PATH \" + "-f ref=..." must be seen as a single
    # command, or the mutating flag detaches from `gh api` and evades the
    # token allowlist. Trailing spaces after the backslash would break the
    # continuation in a real shell, but joining anyway only widens detection.
    if (l ~ /\\[[:space:]]*$/) {
      sub(/\\[[:space:]]*$/, "", l)
      runbuf = runbuf " " l
      return
    }
    scan_logical(runbuf " " l)
    runbuf = ""
  }

  function flush_run_buffer() {
    if (runbuf != "") {
      scan_logical(runbuf)
      runbuf = ""
    }
  }

  function report(ln, rule, msg) {
    printf "%s:%d: %s: %s\n", wf, ln, rule, msg > "/dev/stderr"
    failures = 1
  }

  BEGIN {
    failures = 0
    nsteps = 0
    cur = 0
    in_steps = 0
    steps_indent = -1
    steps_item_indent = -1
    key_indent = -1
    in_with = 0
    with_indent = -1
    with_child = -1
    in_env = 0
    env_indent = -1
    env_child = -1
    in_block = 0
    block_indent = -1
    block_is_run = 0
    runbuf = ""
  }

  {
    line = $0

    # Blank lines never close a block scalar and carry no structure.
    if (line ~ /^[[:space:]]*$/) { next }

    # A line whose first non-space character is # is a comment: ignore it
    # entirely, so a commented-out publisher can never satisfy the contract.
    if (line ~ /^[[:space:]]*#/) { next }

    indent = indentation(line)

    # Block scalar bodies are TEXT, not mappings. Only run: bodies are scanned.
    if (in_block) {
      if (indent > block_indent) {
        if (block_is_run && cur > 0) { scan_run_line(line) }
        next
      }
      if (block_is_run && cur > 0) { flush_run_buffer() }
      in_block = 0
      block_is_run = 0
    }

    if (in_with && indent <= with_indent) { in_with = 0; with_child = -1 }
    if (in_env && indent <= env_indent) { in_env = 0; env_child = -1 }

    if (in_steps) {
      if (line ~ /^[[:space:]]*-([[:space:]]|$)/ &&
          ((steps_item_indent < 0 && indent >= steps_indent) || indent == steps_item_indent)) {
        # New step. Nested sequences (files:, path:) sit deeper than
        # steps_item_indent and are therefore never mistaken for steps.
        steps_item_indent = indent
        nsteps++
        cur = nsteps
        st_line[cur] = FNR
        in_with = 0
        in_env = 0
        with_child = -1
        env_child = -1
        match(line, /^[[:space:]]*-[[:space:]]*/)
        key_indent = RLENGTH
        line = spaces(key_indent) substr(line, key_indent + 1)
        indent = key_indent
      } else if (indent <= steps_indent) {
        in_steps = 0
        cur = 0
        in_with = 0
        in_env = 0
      }
    }

    k = key_of(line)
    if (k == "") { next }
    v = trim(strip_comment(val_of(line)))
    isblock = (v ~ /^(\||>)/)

    if (in_steps == 0) {
      if (k == "steps" && v == "") {
        in_steps = 1
        steps_indent = indent
        steps_item_indent = -1
        cur = 0
      } else if (isblock) {
        in_block = 1
        block_indent = indent
        block_is_run = 0
      }
      next
    }

    if (cur == 0) {
      if (isblock) { in_block = 1; block_indent = indent; block_is_run = 0 }
      next
    }

    if (in_with && indent > with_indent) {
      if (with_child < 0) { with_child = indent }
      if (indent == with_child) {
        withhas[cur ":" k] = 1
        withval[cur ":" k] = v
        withline[cur ":" k] = FNR
      }
    } else if (in_env && indent > env_indent) {
      if (env_child < 0) { env_child = indent }
      if (indent == env_child && (k == "GITHUB_TOKEN" || k == "GH_TOKEN")) {
        st_token[cur] = 1
        if (st_tokenline[cur] == 0) { st_tokenline[cur] = FNR }
      }
    } else if (indent == key_indent) {
      if (k == "with") {
        in_with = 1
        with_indent = indent
        with_child = -1
      } else if (k == "env") {
        in_env = 1
        env_indent = indent
        env_child = -1
      } else if (k == "uses") {
        st_uses[cur] = v
        st_usesline[cur] = FNR
      } else if (k == "name") {
        st_name[cur] = v
      } else if (k == "run") {
        st_hasrun[cur] = 1
        st_runline[cur] = FNR
        if (isblock == 0) { scan_run_line(v) }
      }
    }

    if (isblock) {
      in_block = 1
      block_indent = indent
      block_is_run = (k == "run" && indent == key_indent)
    }
  }

  END {
    # A run block that ends at EOF (possibly with a dangling continuation)
    # still needs its buffered command scanned.
    if (in_block && block_is_run && cur > 0) { flush_run_buffer() }

    npub = 0
    for (i = 1; i <= nsteps; i++) {
      st_pub[i] = 0
      if (st_uses[i] != "" && is_publisher_action(st_uses[i])) {
        st_pub[i] = 1
        st_publine[i] = st_usesline[i]
        st_pubwhy[i] = "uses: " st_uses[i]
      } else if (st_runpub[i]) {
        st_pub[i] = 1
        st_publine[i] = st_runpubline[i]
        st_pubwhy[i] = "shell release publish in run: block"
      }
      if (st_pub[i]) {
        npub++
        pubidx[npub] = i
      }
    }

    if (mode == "forbid") {
      for (p = 1; p <= npub; p++) {
        i = pubidx[p]
        report(st_publine[i], "FORBID",
               "release publisher step is not allowed in this workflow (" st_pubwhy[i] ")")
      }
      if (failures) { exit 1 }
      exit 0
    }

    # R1 exactly one release publisher step.
    if (npub == 0) {
      report(1, "R1", "no release publisher step found; exactly one softprops/action-gh-release step is required")
    } else if (npub > 1) {
      for (p = 1; p <= npub; p++) {
        i = pubidx[p]
        report(st_publine[i], "R1",
               "release publisher step " p " of " npub "; exactly one publisher is allowed (" st_pubwhy[i] ")")
      }
    }

    if (npub == 1) {
      p = pubidx[1]
      u = st_uses[p]

      # R2 the publisher is softprops/action-gh-release pinned to a 40-hex SHA.
      if (u == "") {
        report(st_publine[p], "R2",
               "release publisher must be a softprops/action-gh-release@<40-hex-sha> action step, not a shell publish")
      } else if (action_repo(u) != "softprops/action-gh-release") {
        report(st_usesline[p], "R2",
               "release publisher must be softprops/action-gh-release, got " action_repo(u))
      } else if (is_hex40(action_ref(u)) == 0) {
        report(st_usesline[p], "R2",
               "softprops/action-gh-release must be pinned to a 40-character lowercase commit SHA, got @" action_ref(u))
      }

      # R3 prerelease: true inside THIS step with: mapping.
      if (withhas[p ":prerelease"] != 1) {
        report(st_line[p], "R3",
               "publisher step with: mapping must set prerelease: true (key missing from this step)")
      } else if (withval[p ":prerelease"] != "true") {
        report(withline[p ":prerelease"], "R3",
               "publisher step prerelease must be exactly true, got " withval[p ":prerelease"])
      }

      # R4 fail_on_unmatched_files: true inside this step with: mapping.
      if (withhas[p ":fail_on_unmatched_files"] != 1) {
        report(st_line[p], "R4",
               "publisher step with: mapping must set fail_on_unmatched_files: true (key missing from this step)")
      } else if (withval[p ":fail_on_unmatched_files"] != "true") {
        report(withline[p ":fail_on_unmatched_files"], "R4",
               "publisher step fail_on_unmatched_files must be exactly true, got " withval[p ":fail_on_unmatched_files"])
      }

      # R5 tag_name: and files: inside this step with: mapping.
      if (withhas[p ":tag_name"] != 1) {
        report(st_line[p], "R5", "publisher step with: mapping must set tag_name:")
      }
      if (withhas[p ":files"] != 1) {
        report(st_line[p], "R5", "publisher step with: mapping must set files:")
      }

      # R8 the clobber guard must exist and run before the publisher. It is the
      # only thing standing between a workflow re-run and silently overwriting a
      # manually published (notarized) release that already owns the tag, so its
      # deletion must be loud, like every other invariant in this contract.
      guard = 0
      for (i = 1; i <= nsteps; i++) {
        if (st_name[i] == "Guard against clobbering an existing release") { guard = i; break }
      }
      if (guard == 0) {
        report(1, "R8",
               "missing run: step named exactly: Guard against clobbering an existing release (must precede the publisher)")
      } else {
        if (guard >= p) {
          report(st_line[guard], "R8", "clobber guard step must come before the release publisher step")
        }
        if (st_hasrun[guard] != 1) {
          report(st_line[guard], "R8", "clobber guard must be a run: step that probes the existing release")
        }
      }
    }

    # R6 token allowlist. With contents: write, a token-bearing run step that can
    # create or move refs re-enables tag forgery (a forged tag can be published as
    # a release), so the token must stay read-only in shell steps: only the vetted
    # publisher action may hold a write-capable GITHUB_TOKEN/GH_TOKEN.
    for (i = 1; i <= nsteps; i++) {
      if (st_token[i] != 1) { continue }
      if (st_pub[i] == 1) { continue }
      if (st_hasrun[i] != 1) {
        report(st_tokenline[i], "R6",
               "step is granted GITHUB_TOKEN/GH_TOKEN but is neither the release publisher nor a run: step")
        continue
      }
      if (st_runbad[i] == 1) {
        report(st_runbadline[i], "R6",
               "token-bearing run: step performs a ref/release-mutating command (git push, git tag, git update-ref, git/refs, mutating gh api, or gh release)")
      }
    }

    # R7 exactly one SHA-pinned actions/upload-artifact named UNNOTARIZED-TEST-BUILD.
    nart = 0
    for (i = 1; i <= nsteps; i++) {
      if (st_uses[i] == "") { continue }
      if (action_repo(st_uses[i]) != "actions/upload-artifact") { continue }
      nart++
      artidx[nart] = i
    }

    if (nart == 0) {
      report(1, "R7", "no actions/upload-artifact step found; the short-retention UNNOTARIZED-TEST-BUILD artifact is required")
    } else if (nart > 1) {
      for (p = 1; p <= nart; p++) {
        i = artidx[p]
        report(st_usesline[i], "R7",
               "actions/upload-artifact step " p " of " nart "; exactly one is allowed")
      }
    } else {
      a = artidx[1]
      if (is_hex40(action_ref(st_uses[a])) == 0) {
        report(st_usesline[a], "R7",
               "actions/upload-artifact must be pinned to a 40-character lowercase commit SHA, got @" action_ref(st_uses[a]))
      }
      if (withhas[a ":name"] != 1) {
        report(st_line[a], "R7", "upload-artifact with: mapping must set name: UNNOTARIZED-TEST-BUILD (key missing from this step)")
      } else if (withval[a ":name"] != "UNNOTARIZED-TEST-BUILD") {
        report(withline[a ":name"], "R7",
               "upload-artifact name must be UNNOTARIZED-TEST-BUILD, got " withval[a ":name"])
      }
      if (withhas[a ":retention-days"] != 1) {
        report(st_line[a], "R7", "upload-artifact with: mapping must set retention-days: <n> (key missing from this step)")
      } else if (withval[a ":retention-days"] !~ /^[0-9]+$/) {
        report(withline[a ":retention-days"], "R7",
               "upload-artifact retention-days must be a number, got " withval[a ":retention-days"])
      }
    }

    if (failures) { exit 1 }
  }
' "$workflow"; then
  exit 0
fi

exit 1
