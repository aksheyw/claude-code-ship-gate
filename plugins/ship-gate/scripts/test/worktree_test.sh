#!/usr/bin/env bash
# P8-7: in a LINKED worktree, the marker must resolve via the per-worktree git-dir, not <toplevel>/.git
# (which is a FILE there). A push to the protected branch from the worktree, right after /ship wrote a
# marker, must be ALLOWED. Exercises BOTH the runner write-path (sg_marker_write) and the hook read-path.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/assert.sh"; CP="$DIR/../check-push.sh"; SG="$DIR/../ship-gate.sh"
GCFG_NONE="$(mktemp -u)"
R=$(mktemp -d); ( cd "$R" && git init -q && git config user.email t@t && git config user.name t \
  && printf '{"mainBranch":"main"}' > .shipgate.json && git add .shipgate.json && git commit -q -m init \
  && git branch -M scratch && git branch main )   # main worktree on non-protected "scratch"; protected branch "main" exists
WT=$(mktemp -u); git -C "$R" worktree add -q "$WT" main   # linked worktree checks out the protected branch "main"
test "$([ -f "$WT/.git" ] && echo file)" = file || { echo "PRECONDITION FAILED: $WT/.git is not a file"; exit 1; }
# runner writes a marker for the worktree HEAD (this is what /ship does on green)
bash "$SG" write-marker "$WT" >/dev/null 2>&1
# push the protected branch from inside the worktree => must be ALLOWED (marker resolves via git-dir)
out=$( cd "$WT" && printf '{"tool_input":{"command":"git push origin main"}}' | SHIPGATE_GLOBAL_CONFIG="$GCFG_NONE" bash "$CP" )
assert_eq "$out" "" "B4: worktree push to protected 'main' WITH fresh marker => allow (marker via git-dir, not \$REPO/.git)"
# control: with NO marker, the same worktree push is denied (proves the allow above is the marker, not a bypass)
rm -f "$(git -C "$WT" rev-parse --git-dir)/shipgate/last-pass.json"
out2=$( cd "$WT" && printf '{"tool_input":{"command":"git push origin main"}}' | SHIPGATE_GLOBAL_CONFIG="$GCFG_NONE" bash "$CP" )
assert_contains "$out2" "deny" "B4: worktree push to 'main' with NO marker => deny (control)"
git -C "$R" worktree remove --force "$WT" 2>/dev/null || true
assert_summary
