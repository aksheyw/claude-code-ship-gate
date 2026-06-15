#!/usr/bin/env bash
# P8-1 CONTRACT GUARD: the hook (check-push.sh, self-contained) and the runner
# (lib/config.sh sg_protected_branches) MUST resolve the SAME protected branch set on the same repo,
# across EVERY rung of the ladder (per-repo -> global GCFG -> $SHIPGATE_MAIN_BRANCH -> origin/HEAD ->
# {main,master}). If they diverge, the orchestrator gates/marks/pushes one branch while the hook
# protects another -> the hook denies the push it just authorized (the ship-stopper the deep review caught).
# This test asserts: for each scenario, the runner reports the expected set AND the hook gates each
# branch the runner reports. Hermetic: SHIPGATE_GLOBAL_CONFIG is always pinned to a controlled path.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/assert.sh"; . "$DIR/../lib/config.sh"; CP="$DIR/../check-push.sh"
GCFG_NONE="$(mktemp -u)"   # a path that does not exist => "no global config" (hermetic default)

# Hook decision for "git push origin <branch>" run inside <dir>, with a pinned global config + env mainBranch.
# An empty mb is treated as unset by both hook and runner ([ -n "${SHIPGATE_MAIN_BRANCH:-}" ] is false).
check_gated(){ local d="$1" b="$2" gc="${3:-$GCFG_NONE}" mb="${4:-}"
  printf '{"tool_input":{"command":"git push origin %s"}}' "$b" | \
    ( cd "$d" && SHIPGATE_GLOBAL_CONFIG="$gc" SHIPGATE_MAIN_BRANCH="$mb" bash "$CP" 2>/dev/null ); }
runner(){ local d="$1" gc="${2:-$GCFG_NONE}" mb="${3:-}"
  SHIPGATE_GLOBAL_CONFIG="$gc" SHIPGATE_MAIN_BRANCH="$mb" sg_protected_branches "$d"; }

# agree <label> <dir> <gcfg> <env-mainbranch> <expected-set>
agree(){ local label="$1" dir="$2" gc="$3" mb="$4" expect="$5" rs
  rs=$(runner "$dir" "$gc" "$mb")
  assert_eq "$(printf '%s' "$rs" | tr '\n' ' ')" "$expect" "B3 ($label): runner reports '$expect'"
  for b in $rs; do
    assert_contains "$(check_gated "$dir" "$b" "$gc" "$mb")" "deny" "B3 ($label): hook gates '$b' (agrees with runner — P8-1)"
  done
}

# 1. no remote, no config => {main, master} fallback
R1=$(mktemp -d); ( cd "$R1" && git init -q && git commit -q --allow-empty -m i && git branch -M main 2>/dev/null ); printf '{}' > "$R1/.shipgate.json"
agree "fallback" "$R1" "$GCFG_NONE" "" "main master"

# 2. explicit per-repo .mainBranch
R2=$(mktemp -d); ( cd "$R2" && git init -q && git commit -q --allow-empty -m i && git branch -M trunk 2>/dev/null ); printf '{"mainBranch":"trunk"}' > "$R2/.shipgate.json"
agree "per-repo" "$R2" "$GCFG_NONE" "" "trunk"

# 3. origin/HEAD = master (auto-detect)
UP=$(mktemp -d); git -C "$UP" init -q --bare
W=$(mktemp -d); git clone -q "$UP" "$W" 2>/dev/null
( cd "$W" && git config user.email t@t && git config user.name t && git checkout -q -b master && git commit -q --allow-empty -m i && git push -q -u origin master 2>/dev/null && git remote set-head origin master >/dev/null 2>&1 )
printf '{}' > "$W/.shipgate.json"
agree "origin/HEAD" "$W" "$GCFG_NONE" "" "master"

# 4. global GCFG .mainBranch (per-repo {} so the repo is gated; the branch comes from the GLOBAL config)
R4=$(mktemp -d); ( cd "$R4" && git init -q && git commit -q --allow-empty -m i && git branch -M main 2>/dev/null ); printf '{}' > "$R4/.shipgate.json"
GC=$(mktemp); printf '{"mainBranch":"release"}' > "$GC"
agree "global GCFG" "$R4" "$GC" "" "release"
rm -f "$GC"

# 5. $SHIPGATE_MAIN_BRANCH env rung (per-repo {} so the repo is gated)
R5=$(mktemp -d); ( cd "$R5" && git init -q && git commit -q --allow-empty -m i && git branch -M main 2>/dev/null ); printf '{}' > "$R5/.shipgate.json"
agree "env" "$R5" "$GCFG_NONE" "ship" "ship"

# 6. malformed mainBranch value: null is IGNORED by BOTH (fail-closed) => {main master}
R6=$(mktemp -d); ( cd "$R6" && git init -q && git commit -q --allow-empty -m i && git branch -M main 2>/dev/null ); printf '{"mainBranch":null}' > "$R6/.shipgate.json"
agree "null-mainBranch" "$R6" "$GCFG_NONE" "" "main master"
# 7. empty-string mainBranch: IGNORED by BOTH => {main master} (was a hook/runner DIVERGENCE before the fix)
R7=$(mktemp -d); ( cd "$R7" && git init -q && git commit -q --allow-empty -m i && git branch -M main 2>/dev/null ); printf '{"mainBranch":""}' > "$R7/.shipgate.json"
agree "empty-mainBranch" "$R7" "$GCFG_NONE" "" "main master"
# 8. MALFORMED per-repo JSON: gated (opt-in), branch resolution falls through => {main master}; no set-e abort
R8=$(mktemp -d); ( cd "$R8" && git init -q && git commit -q --allow-empty -m i && git branch -M main 2>/dev/null ); printf '{ not valid json' > "$R8/.shipgate.json"
agree "malformed-per-repo" "$R8" "$GCFG_NONE" "" "main master"

assert_summary
