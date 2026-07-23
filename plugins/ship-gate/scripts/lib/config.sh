#!/usr/bin/env bash
# Loads .shipgate.json merged over built-in defaults. Requires jq.
sg_defaults(){ cat <<'JSON'
{ "mainBranch": "main",
  "gates": { "tests": {"enabled":true,"command":null}, "lint": {"enabled":true,"command":null},
    "typecheck": {"enabled":true,"command":null}, "build": {"enabled":false,"command":null},
    "secretScan": {"enabled":true},
    "codeReview": {"enabled":true,"skill":"ship-review","upgrade":null},
    "security": {"enabled":true,"skill":"ship-security","upgrade":null},
    "uat": {"enabled":true,"skill":"verify","mode":"confidence"} },
  "heavyGates": { "audit": {"skill":"deep-review","upgrade":"audit","suggestWhen":{"filesChanged":15,"areasChanged":3,"riskyPaths":true}},
    "deep": {"skill":"deep-review","upgrade":"deep-review","suggestWhen":{"diffLines":400,"riskyPaths":true,"release":true}} },
  "regression": {"enabled":false,"skill":"ai-regression-testing","runWhen":"test-affecting"},
  "scoping": { "docs":["**/*.md","docs/**"], "ui":["src/components/**","src/pages/**","**/*.{tsx,jsx,vue,svelte}"],
    "security":["**/auth/**","**/*payment*","**/*.rules","**/migrations/**","**/.env*","api/**","package.json","requirements*.txt","go.mod","Cargo.toml","pubspec.yaml"] },
  "deploy": {"autoDetect":true,"warnOnPush":true},
  "hotfix": {"skipGates":["uat","regression","audit","deep"]},
  "markerTtlSeconds": 900 }
JSON
}
# sg_config_get <project-dir> <jq-filter>  — returns non-zero (fail CLOSED) on invalid config JSON.
sg_config_get(){ local dir="$1" filter="$2" cfg="$1/.shipgate.json"
  if [ -f "$cfg" ]; then
    jq empty "$cfg" 2>/dev/null || { echo "shipgate: invalid JSON in $cfg" >&2; return 2; }
    jq -n --argjson d "$(sg_defaults)" --argjson o "$(cat "$cfg")" '$d * $o' | jq -r "$filter"
  else sg_defaults | jq -r "$filter"; fi; }
# Echo the merged config (defaults <- .shipgate.json) as JSON. Non-zero on invalid JSON.
sg_merged_config(){ local dir="$1" cfg="$1/.shipgate.json"
  if [ -f "$cfg" ]; then
    jq empty "$cfg" 2>/dev/null || return 2
    jq -n --argjson d "$(sg_defaults)" --argjson o "$(cat "$cfg")" '$d * $o'
  else sg_defaults; fi; }
# Fail CLOSED on a malformed config STRUCTURE the schema forbids but the runtime would otherwise mis-handle
# into a SILENT gate skip / false PASS (deep-review 2026-06-20). The schema is editor-only; THIS is the
# runtime enforcement. Rejects: a non-object .gates or gate (a scalar gate => every .enabled read jq-errors
# => [SKIP] => exit 0); a non-boolean .gates.*.enabled (0/null/1/[] string-compared to "true" => silently
# OFF); a .command that is not null|string|array-of-{non-empty-string command, optional string-array when}
# (a JSON `true` command => eval builtin true => false [PASS]; an object/array-of-arrays `when` =>
# value-iterated => real pathspecs dropped => silent skip). Also rejects an EMPTY suite array: jq's `all`
# is vacuously true over `[]`, so `"tests":{"enabled":true,"command":[]}` used to VALIDATE, then the runner
# warned "empty suite list" and returned success — an ENABLED deterministic gate exiting 0 having run
# nothing (found by an independent Codex review 2026-07-23). Returns non-zero => sg_guard_config exits 2.
sg_config_structure_ok(){ local dir="$1" m
  m=$(sg_merged_config "$dir") || return 1
  printf '%s' "$m" | jq -e '
    (.gates | type == "object") and (.gates | to_entries | all(
      (.value | type == "object")
      and ((.value.enabled | type) == "boolean")
      and ( (.value | has("command") | not) or (.value.command == null)
            or ((.value.command | type) == "string" and (.value.command | gsub("\\s";"") | length) > 0)
            or ((.value.command | type) == "array" and (.value.command | length) > 0 and (.value.command | all(
                  (type == "object") and has("command")
                  and ((.command | type) == "string") and ((.command | gsub("\\s";"") | length) > 0)
                  and ((has("when") | not) or (.when == null)
                       or ((.when | type) == "array" and (.when | all(type == "string")))) )))
          )
    ))' >/dev/null 2>&1; }
# Phase 8: protected-branch resolution shared by runner + orchestrator. Mirrors the hook
# (check-push.sh) which replicates this inline (it must stay self-contained). Echoes one branch name
# PER LINE (matches the hook; safe for while-read and word-split consumers). Ladder (spec §5), first match wins:
#   per-repo .mainBranch -> global .mainBranch -> $SHIPGATE_MAIN_BRANCH -> origin/HEAD -> {main master}
# origin/HEAD uses symbolic-ref --quiet (robust: empty+exit1 when unset, so we fall through to the
# {main master} fallback rather than mis-resolving to the bogus branch "HEAD").
sg_protected_branches(){ local dir="$1" gcfg d m
  if [ -f "$dir/.shipgate.json" ]; then
    m=$(jq -r 'if (.mainBranch|type)=="string" and (.mainBranch|length)>0 then .mainBranch else empty end' "$dir/.shipgate.json" 2>/dev/null || true)
    [ -n "$m" ] && { printf '%s\n' "$m"; return 0; }
  fi
  gcfg="${SHIPGATE_GLOBAL_CONFIG:-${HOME:+$HOME/.shipgate.json}}"
  if [ -n "$gcfg" ] && [ -f "$gcfg" ]; then
    m=$(jq -r 'if (.mainBranch|type)=="string" and (.mainBranch|length)>0 then .mainBranch else empty end' "$gcfg" 2>/dev/null || true)
    [ -n "$m" ] && { printf '%s\n' "$m"; return 0; }
  fi
  [ -n "${SHIPGATE_MAIN_BRANCH:-}" ] && { printf '%s\n' "$SHIPGATE_MAIN_BRANCH"; return 0; }
  d=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo "")
  d="${d#origin/}"; [ -n "$d" ] && { printf '%s\n' "$d"; return 0; }
  printf 'main\nmaster\n'
}
# P1 (S149): base of the shipped change-set, used ONLY to SCOPE which `when`-conditional suites run (never
# to gate correctness). Echo the merge-base of the protected branch and HEAD when HEAD is AHEAD of it (so
# the shipped diff is observable); echo "" otherwise (no protected ref, HEAD not ahead, detached, or not a
# repo). "" => callers MUST fail-safe RUN every when-suite — the only safe direction for a safety gate.
sg_change_base(){ local dir="$1" p base head
  p=$(sg_protected_branches "$dir" | head -1)
  head=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || { echo ""; return 0; }
  base=$(git -C "$dir" merge-base "$p" HEAD 2>/dev/null) || { echo ""; return 0; }
  [ -n "$base" ] && [ "$base" != "$head" ] && { printf '%s\n' "$base"; return 0; }
  echo ""; }
# sg_changed_files <dir> — the AUTHORITATIVE list of files in the change being shipped, one path per line,
# computed in bash from git rather than from a model's reading of the diff.
#
# WHY THIS EXISTS: codeReview is a JUDGMENT gate — an LLM reads the diff and returns a verdict. On a large
# changeset a model reviews a subset and still reports "looks good", and nothing previously asserted
# otherwise; the deterministic tier had no say in WHICH files were examined. This is the same split the
# rest of the plugin runs on: engineering decides the part that must not be got wrong (the file list), the
# agent does the part that needs judgment (whether the code is any good). /ship diffs the reviewer's
# claimed coverage against this list before the gate may go green (SKILL.md step 4).
#
# It is a MANIFEST, never a gate: it always exits 0 and never blocks a push. Same four sources as
# sg_suite_in_scope, for the same reason — /ship runs the gates BEFORE committing, so a staged or
# brand-new untracked file is part of what ships and must be reviewed. core.quotePath=false keeps
# non-ASCII paths byte-exact (git would otherwise emit "caf\303\251.js", which a reviewer cannot match
# against the real diff). Ignored files are excluded by --exclude-standard / git's own rules.
sg_changed_files(){ local dir="$1" root base
  root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || { return 0; }
  [ -n "$root" ] || return 0
  base=$(sg_change_base "$dir")
  { [ -n "$base" ] && git -C "$root" -c core.quotePath=false diff --name-only "$base" HEAD 2>/dev/null
    git -C "$root" -c core.quotePath=false diff --name-only 2>/dev/null
    git -C "$root" -c core.quotePath=false diff --cached --name-only 2>/dev/null
    git -C "$root" -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null
    :; } | LC_ALL=C sort -u
  return 0; }
# sg_suite_in_scope <dir> <gate-key> <idx> <base>  -> exit 0 = run, 1 = skip.
# A `when`-conditional suite (P1) runs iff a changed file matches its `when` git-pathspecs, matched against
# the committed range (base..HEAD) AND unstaged-tracked AND STAGED AND UNTRACKED-new files: /ship runs the
# gates BEFORE committing, so a newly staged/untracked suite's files MUST count, else that suite is silently
# skipped (the exact false all-clear this fix kills). omitted/empty `when` => always run; base "" => fail-safe
# RUN. git does the glob match (pathspec '*' spans '/'; brace globs {a,b} are unsupported — list separately).
# bash-3.2-safe: NO mapfile; the `${#globs[@]}` guard MUST stay (a "${globs[@]}" on an empty array is fatal
# under set -u in bash 3.2). The `2>/dev/null || true` on each sg_config_get read prevents a set -e abort.
sg_suite_in_scope(){ local dir="$1" key="$2" i="$3" base="$4" wt g out root
  # `when` must be a JSON array to scope; omitted/null OR any malformed non-array `when` (object,
  # array-of-arrays, string, number) => fail-safe RUN (never value-iterate a malformed when, which would
  # drop the user's real pathspecs and silently skip — the runtime structural guard also fails this closed).
  wt=$(sg_config_get "$dir" ".gates.${key}.command[$i].when | type" 2>/dev/null || true)
  [ "$wt" = "array" ] || return 0
  [ -n "$base" ] || return 0
  # Trim leading/trailing whitespace from each pathspec IN JQ (gsub is Unicode-aware and locale-independent —
  # a bash [:space:] trim is ASCII-only under the C locale the runner inherits, so it would miss a NBSP/EM
  # space and feed it to git as a matches-nothing pathspec => silent skip; doing it here also keeps the trim
  # and the command-validator's gsub in lockstep). An all-whitespace entry trims to "" and is dropped, so a
  # `when:["   "]` (typo) drops to empty globs and the suite fail-safe RUNs; a padded ` *.rules ` => `*.rules`.
  local globs=(); while IFS= read -r g; do [ -n "$g" ] && globs+=("$g"); done \
    < <(sg_config_get "$dir" ".gates.${key}.command[$i].when[] | gsub(\"^\\\\s+|\\\\s+\$\";\"\")" 2>/dev/null || true)
  [ "${#globs[@]}" -gt 0 ] || return 0
  # A brace glob ({a,b}) is NOT a git pathspec — git matches it literally (i.e. nothing), which would
  # SILENTLY skip the suite (the docs warn users not to write these, but the schema can't stop them). Treat
  # an unsupported/uncertain pathspec as indeterminate scope => fail-safe RUN.
  for g in "${globs[@]}"; do case "$g" in *'{'*|*'}'*) return 0 ;; esac; done
  # `when` pathspecs are documented as repo-ROOT-relative, so match against the repo top-level, NOT $dir
  # (a .shipgate.json may legitimately be discovered from a subdir; matching relative to the subdir would
  # silently skip a suite whose files live elsewhere). Mirrors sg_disabled_sentinel's show-toplevel anchor.
  root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")
  # Match across committed (base..HEAD) + unstaged + staged + untracked. Each `|| return 0` is the fail-safe:
  # a git ERROR on a pathspec (e.g. invalid magic `:(badmagic)`) is INDETERMINATE, not "no match", so RUN —
  # never let a git error read as "nothing changed" and skip. A clean rc=0 empty result is a real no-match.
  # (Capturing rc via `||` also keeps a git error from aborting the hook under set -e.)
  out=$(git -C "$root" diff --name-only "$base" HEAD -- "${globs[@]}" 2>/dev/null) || return 0   # committed
  [ -n "$out" ] && return 0
  out=$(git -C "$root" diff --name-only -- "${globs[@]}" 2>/dev/null) || return 0                 # unstaged tracked
  [ -n "$out" ] && return 0
  out=$(git -C "$root" diff --cached --name-only -- "${globs[@]}" 2>/dev/null) || return 0        # staged
  [ -n "$out" ] && return 0
  out=$(git -C "$root" ls-files --others --exclude-standard -- "${globs[@]}" 2>/dev/null) || return 0  # untracked new
  [ -n "$out" ] && return 0
  return 1; }
# Worktree-safe git-dir helpers (raw rev-parse output; callers join to the repo dir as needed).
sg_git_dir(){ git -C "$1" rev-parse --git-dir 2>/dev/null || echo ".git"; }
sg_git_common_dir(){ git -C "$1" rev-parse --git-common-dir 2>/dev/null || echo ".git"; }
# Absolute path to the per-repo disable sentinel (/ship off writes it; the hook reads it). MUST resolve
# to the same path the hook computes (check-push.sh ladder step 4): anchor --git-common-dir to the repo
# ROOT (not the caller's CWD) so it is correct from a subdir, and join a relative result to the root so
# it is correct in a linked worktree (where it is the shared common dir). Echoes "" when not in a repo.
sg_disabled_sentinel(){ local dir="$1" root gcd
  root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "")
  [ -n "$root" ] || { echo ""; return 0; }
  gcd=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null || echo ".git")
  case "$gcd" in /*) : ;; *) gcd="$root/$gcd" ;; esac
  printf '%s/shipgate/disabled\n' "$gcd"; }
