#!/usr/bin/env bash
# Worktree marker branch-mismatch fix (proposal 2026-06-13 A+B): the pass marker is a COMMIT-identity
# token (was branch+session-HEAD), stored in the COMMON git-dir (was per-worktree). A /ship from a linked
# worktree on a feature branch that integrates into the protected branch must be able to push it.
# This is the hook<->runner AGREEMENT test for the marker contract (cf. branch_agreement_test.sh for the
# branch-resolution contract): the runner WRITES the marker; the hook READS it; both sides must agree on
# the LOCATION (common git-dir, anchored) AND the commit-identity SEMANTICS, across primary / subdir /
# linked-worktree checkouts. The marker read/write path is NOT the locked awk push-detection parser.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/assert.sh"; . "$DIR/../lib/config.sh"; . "$DIR/../lib/marker.sh"
CP="$DIR/../check-push.sh"; SG="$DIR/../ship-gate.sh"
GCFG_NONE="$(mktemp -u)"   # hermetic: nonexistent path => "no global config"

# Hook decision for "git push origin <b>" run inside <cwd>. Allowed push => exit 0, empty output;
# a gated push with no/invalid marker => a deny JSON payload.
push_out(){ local cwd="$1" b="$2"
  printf '{"tool_input":{"command":"git push origin %s"}}' "$b" | \
    ( cd "$cwd" && SHIPGATE_GLOBAL_CONFIG="$GCFG_NONE" bash "$CP" 2>/dev/null ); }

# Build a fresh repo: primary checkout on protected "main"; a linked worktree on "feature/x" that did the
# work; /ship integrates feature/x into main via a --no-ff MERGE (main's tip becomes a NEW commit, distinct
# from the feature tip — so the test exercises commit-identity, not an accidental FF coincidence).
# Sets globals R (primary dir) and WT (linked worktree dir).
build(){
  R=$(mktemp -d); ( cd "$R" && git init -q && git config user.email t@t && git config user.name t \
    && printf '{"mainBranch":"main"}' > .shipgate.json && git add .shipgate.json && git commit -q -m init \
    && git branch -M main )
  WT=$(mktemp -u); git -C "$R" worktree add -q "$WT" -b feature/x
  ( cd "$WT" && printf 'work' > f.txt && git add f.txt && git commit -q -m "feature work" )
  git -C "$R" merge -q --no-ff feature/x -m "merge feature/x"; }

# 1. THE BUG (now fixed): /ship from the worktree writes the marker and pushes main => ALLOW.
build
bash "$SG" write-marker "$WT" >/dev/null 2>&1
assert_eq "$(push_out "$WT" main)" "" \
  "worktree-on-feature: push protected 'main' after /ship --no-ff merge + marker => ALLOW"

# 2. CONTROL — no marker => deny (proves the allow above is the marker, not a worktree bypass).
build
assert_contains "$(push_out "$WT" main)" "deny" \
  "worktree-on-feature: push 'main' with NO marker => deny (control)"

# 3. CONTROL — stale marker: main advances after the marker is written => deny (commit-identity has teeth;
#    the gate validates the COMMIT being pushed, not merely "a marker exists / branch matches").
build
bash "$SG" write-marker "$WT" >/dev/null 2>&1
git -C "$R" commit -q --allow-empty -m "another commit on main after /ship"
assert_contains "$(push_out "$WT" main)" "deny" \
  "worktree-on-feature: marker then main advances => deny (gate checks the pushed commit, not the branch)"

# 4. AGREEMENT — the runner's write path and the hook's read path are the SAME common-dir location, whether
#    resolved from the worktree or the primary (writer and reader can never diverge).
build
P_WT="$(sg_marker_path "$WT")"; P_R="$(sg_marker_path "$R")"
assert_eq "$P_WT" "$P_R" "marker path resolves identically from the worktree and the primary (shared common-dir)"
assert_contains "$P_WT" "/.git/shipgate/last-pass.json" "marker lives under the repo's .git, not a stray path"
# The heart of Fix B: the worktree's marker is the SHARED common-dir file, NOT an isolated per-worktree
# (.git/worktrees/<name>/...) one — which is why a primary-written marker is visible to a worktree's hook.
case "$P_WT" in *"/worktrees/"*) _loc=per-worktree;; *) _loc=shared;; esac
assert_eq "$_loc" "shared" "worktree marker resolves to the SHARED common-dir, not .git/worktrees/<name>/"

# 5. SUBDIR write — /ship run from a SUBDIR of the primary writes a marker the worktree's hook honors
#    (anchored common-dir resolution is correct from a subdir, mirroring the disable sentinel).
build
mkdir -p "$R/nested/deep"
bash "$SG" write-marker "$R/nested/deep" >/dev/null 2>&1
assert_eq "$(push_out "$WT" main)" "" \
  "marker written from a primary SUBDIR is honored by the worktree's push of 'main' => ALLOW"

# 6. PRIMARY writes, WORKTREE reads (the proposal's Fix-B scenario) — a marker written from the primary
#    checkout (on main) is visible to the hook firing in a linked worktree.
build
bash "$SG" write-marker "$R" >/dev/null 2>&1
assert_eq "$(push_out "$WT" main)" "" \
  "marker written from the PRIMARY checkout is visible to the worktree's hook => ALLOW"

assert_summary
