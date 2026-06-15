#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/assert.sh"; . "$DIR/../lib/config.sh"
GCFG_NONE="$(mktemp -u)"; export SHIPGATE_GLOBAL_CONFIG="$GCFG_NONE"   # hermetic: no global config unless a case overrides
# 1. explicit per-repo config wins
R=$(mktemp -d); git -C "$R" init -q; printf '{"mainBranch":"trunk"}' > "$R/.shipgate.json"
assert_eq "$(sg_protected_branches "$R")" "trunk" "B1: explicit per-repo mainBranch wins"
# 2. global GCFG .mainBranch (no per-repo) is honored next — the rung the hook also honors (P8-1)
R_G=$(mktemp -d); git -C "$R_G" init -q
GC=$(mktemp); printf '{"mainBranch":"develop"}' > "$GC"
assert_eq "$(SHIPGATE_GLOBAL_CONFIG="$GC" sg_protected_branches "$R_G")" "develop" "B1: global GCFG mainBranch (no per-repo) wins next"
rm -f "$GC"
# 3. no config, no remote => {main master}
R2=$(mktemp -d); git -C "$R2" init -q
assert_eq "$(sg_protected_branches "$R2")" "$(printf 'main\nmaster')" "B1: no config/no remote => main+master fallback (one branch per line)"
# 4. origin/HEAD set to master => master
UP=$(mktemp -d); git -C "$UP" init -q --bare
W=$(mktemp -d); git clone -q "$UP" "$W" 2>/dev/null; git -C "$W" config user.email t@t; git -C "$W" config user.name t
git -C "$W" checkout -q -b master; git -C "$W" commit -q --allow-empty -m i; git -C "$W" push -q -u origin master 2>/dev/null
git -C "$W" remote set-head origin master >/dev/null 2>&1
assert_eq "$(sg_protected_branches "$W")" "master" "B1: origin/HEAD=master => master"
assert_summary
