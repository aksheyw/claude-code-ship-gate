#!/usr/bin/env bash
# Phase-C close-out: the /ship off|on sentinel is written by the RUNNER (ship-gate.sh disable|enable),
# anchored + worktree-safe, so it lands EXACTLY where the hook (check-push.sh, A7-anchored) reads it.
# Regression for the CRITICAL un-anchored `git rev-parse --git-common-dir` subdir misfire: writing the
# sentinel from a repo SUBDIR (or a linked worktree) must still disable the gate at the repo root.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/assert.sh"; . "$DIR/../lib/config.sh"
SG="$DIR/../ship-gate.sh"; CP="$DIR/../check-push.sh"
GCFG_NONE="$(mktemp -u)"   # hermetic: a path that does not exist => "no global config"

# Hook decision for "git push origin <b>" run inside <cwd>, with a pinned hermetic global config.
# Gated push to a protected branch with no marker => deny output; an allowed push => exit 0, NO output.
push_out(){ local cwd="$1" b="$2"
  printf '{"tool_input":{"command":"git push origin %s"}}' "$b" | \
    ( cd "$cwd" && SHIPGATE_GLOBAL_CONFIG="$GCFG_NONE" bash "$CP" 2>/dev/null ); }

# A gated repo: opted in (.shipgate.json present), on main, no marker => push to main DENIES.
R=$(mktemp -d); ( cd "$R" && git init -q && git commit -q --allow-empty -m i && git branch -M main 2>/dev/null ); printf '{}' > "$R/.shipgate.json"
assert_contains "$(push_out "$R" main)" "deny" "baseline: gated repo denies the un-marked push to main"

# disable via the runner => sentinel lands where the hook reads it => push ALLOWS (empty output)
bash "$SG" disable "$R" >/dev/null 2>&1
assert_eq "$(bash "$SG" status "$R")" "off" "status reports off after disable"
S=$(sg_disabled_sentinel "$R")
assert_eq "$([ -f "$S" ] && echo yes || echo no)" "yes" "disable writes the sentinel at the anchored path"
assert_eq "$(push_out "$R" main)" "" "disabled repo allows the push (hook reads the same sentinel)"

# enable via the runner => sentinel removed => push DENIES again
bash "$SG" enable "$R" >/dev/null 2>&1
assert_eq "$(bash "$SG" status "$R")" "on" "status reports on after enable"
assert_eq "$([ -f "$S" ] && echo yes || echo no)" "no" "enable removes the sentinel"
assert_contains "$(push_out "$R" main)" "deny" "re-enabled repo denies the un-marked push again"

# CRITICAL regression: disable run from a repo SUBDIR must still disable the gate at the repo root.
# (The old un-anchored `git rev-parse --git-common-dir` wrote the sentinel relative to the subdir CWD,
# so the hook — reading anchored from the root — never saw it and kept gating.)
SUB="$R/nested/deep"; mkdir -p "$SUB"
bash "$SG" disable "$SUB" >/dev/null 2>&1
assert_eq "$(bash "$SG" status "$SUB")" "off" "status off when run from a subdir"
assert_eq "$(push_out "$R" main)" "" "disable from a SUBDIR still disables the gate at the repo root"
bash "$SG" enable "$SUB" >/dev/null 2>&1
assert_contains "$(push_out "$R" main)" "deny" "enable from a SUBDIR re-gates the repo root"

# Worktree parity: a linked worktree shares the common-dir, so disabling there disables the main gate.
WT=$(mktemp -u)
if ( cd "$R" && git worktree add -q "$WT" -b wtbranch 2>/dev/null ); then
  bash "$SG" disable "$WT" >/dev/null 2>&1
  assert_eq "$(push_out "$R" main)" "" "disable from a linked WORKTREE disables the shared gate"
  bash "$SG" enable "$WT" >/dev/null 2>&1
  assert_contains "$(push_out "$R" main)" "deny" "enable from a linked WORKTREE re-gates the shared repo"
  ( cd "$R" && git worktree remove --force "$WT" 2>/dev/null ) || true
fi

# status/disable/enable are consistent: a non-repo dir errors (exit 2), never a misleading "on".
NONREPO=$(mktemp -d)
set +e; bash "$SG" status "$NONREPO" >/dev/null 2>&1; rc_status=$?; set -e
assert_eq "$([ "$rc_status" -ne 0 ] && echo nonzero || echo zero)" "nonzero" "status on a non-repo dir exits non-zero (consistent with disable/enable)"
rmdir "$NONREPO" 2>/dev/null || true

assert_summary
