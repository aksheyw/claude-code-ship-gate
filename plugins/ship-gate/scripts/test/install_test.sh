#!/usr/bin/env bash
# TDD test for install-local.sh (Mode A installer).
# Gate-B regression: fake HOME path MUST contain a space.
# Bash 3.2 compatible (macOS default shell).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/assert.sh"

INSTALLER="$DIR/../../../../install-local.sh"

# ---------------------------------------------------------------
# Setup: fake HOME with a space in the path (Gate-B regression)
# ---------------------------------------------------------------
BASE=$(mktemp -d)
FAKE="$BASE/has space"
mkdir -p "$FAKE/.claude/skills"
echo "old ship content" > "$FAKE/.claude/skills/ship.md"
printf '{"permissions":{"allow":[]}}' > "$FAKE/.claude/settings.json"

# ---------------------------------------------------------------
# First install run
# ---------------------------------------------------------------
HOME="$FAKE" bash "$INSTALLER" --yes

# ---------------------------------------------------------------
# Assert 1: skill directories and SKILL.md files exist
# ---------------------------------------------------------------
assert_eq "$([ -f "$FAKE/.claude/skills/ship/SKILL.md" ] && echo yes || echo no)" "yes" \
  "ship/SKILL.md installed"
assert_eq "$([ -f "$FAKE/.claude/skills/ship-init/SKILL.md" ] && echo yes || echo no)" "yes" \
  "ship-init/SKILL.md installed"
assert_eq "$([ -f "$FAKE/.claude/skills/ship-review/SKILL.md" ] && echo yes || echo no)" "yes" \
  "ship-review/SKILL.md installed"
assert_eq "$([ -f "$FAKE/.claude/skills/ship-security/SKILL.md" ] && echo yes || echo no)" "yes" \
  "ship-security/SKILL.md installed"

# ---------------------------------------------------------------
# Assert 2: No ${CLAUDE_PLUGIN_ROOT} token remains in any copied skill
# Use find+xargs to avoid grep pipefail issues on no-match (bash 3.2 safe)
# ---------------------------------------------------------------
PLUGIN_ROOT_FILES=$(find "$FAKE/.claude/skills/" -name '*.md' | \
  xargs grep -l '\${CLAUDE_PLUGIN_ROOT}' 2>/dev/null || true)
assert_eq "$([ -z "$PLUGIN_ROOT_FILES" ] && echo none || echo "$PLUGIN_ROOT_FILES")" "none" \
  "no \${CLAUDE_PLUGIN_ROOT} token in any copied skill"

# ---------------------------------------------------------------
# Assert 3: No ship-gate: namespace in any copied skill
# ---------------------------------------------------------------
NAMESPACE_FILES=$(find "$FAKE/.claude/skills/" -name '*.md' | \
  xargs grep -l 'ship-gate:' 2>/dev/null || true)
assert_eq "$([ -z "$NAMESPACE_FILES" ] && echo none || echo "$NAMESPACE_FILES")" "none" \
  "no ship-gate: namespace in any copied skill"

# ---------------------------------------------------------------
# Assert 4: ship/SKILL.md contains quoted absolute path to ship-gate.sh
#           AND that path resolves on disk
# ---------------------------------------------------------------
SHIP_SKILL="$FAKE/.claude/skills/ship/SKILL.md"

# Extract quoted path: bash "<abs>/scripts/ship-gate.sh"
EXTRACTED=$(grep -o 'bash "[^"]*scripts/ship-gate.sh"' "$SHIP_SKILL" 2>/dev/null | \
  head -1 | sed 's/bash "//;s/"$//' || true)
assert_eq "$([ -n "$EXTRACTED" ] && echo yes || echo no)" "yes" \
  "ship/SKILL.md contains quoted bash path to ship-gate.sh"
assert_eq "$([ -f "$EXTRACTED" ] && echo yes || echo no)" "yes" \
  "extracted ship-gate.sh path resolves on disk: $EXTRACTED"

# ---------------------------------------------------------------
# Assert 5: ship-init/SKILL.md also has rewritten path
# ---------------------------------------------------------------
INIT_SKILL="$FAKE/.claude/skills/ship-init/SKILL.md"
INIT_EXTRACTED=$(grep -o 'bash "[^"]*scripts/ship-gate.sh"' "$INIT_SKILL" 2>/dev/null | \
  head -1 | sed 's/bash "//;s/"$//' || true)
assert_eq "$([ -n "$INIT_EXTRACTED" ] && echo yes || echo no)" "yes" \
  "ship-init/SKILL.md contains quoted bash path to ship-gate.sh"
assert_eq "$([ -f "$INIT_EXTRACTED" ] && echo yes || echo no)" "yes" \
  "extracted ship-gate.sh path in ship-init resolves on disk: $INIT_EXTRACTED"

# ---------------------------------------------------------------
# Assert 6: ship.md backup -- old file moved to ship.md.bak
# ---------------------------------------------------------------
assert_eq "$([ -f "$FAKE/.claude/skills/ship.md.bak" ] && echo yes || echo no)" "yes" \
  "ship.md.bak exists (old skill backed up)"
assert_eq "$([ -f "$FAKE/.claude/skills/ship.md" ] && echo yes || echo no)" "no" \
  "ship.md flat file is gone (replaced by ship/ directory install)"
BAK_CONTENT=$(cat "$FAKE/.claude/skills/ship.md.bak")
assert_eq "$BAK_CONTENT" "old ship content" \
  "ship.md.bak contains original content"

# ---------------------------------------------------------------
# Assert 7: settings.json is still valid JSON and preserves existing keys
# Use jq inside $() so set -e doesn't abort on jq failure
# ---------------------------------------------------------------
SETTINGS_VALID=$(jq empty "$FAKE/.claude/settings.json" 2>&1 && echo ok || echo bad)
assert_eq "$SETTINGS_VALID" "ok" "settings.json is valid JSON after install"

PERMS=$(jq -r '.permissions.allow | length' "$FAKE/.claude/settings.json" 2>/dev/null || true)
assert_eq "$PERMS" "0" "pre-existing permissions.allow preserved (not clobbered)"

# ---------------------------------------------------------------
# Assert 8: .hooks.PreToolUse exists with check-push.sh entry
# ---------------------------------------------------------------
HOOK_COUNT=$(jq '[.hooks.PreToolUse // [] | .[]] | length' "$FAKE/.claude/settings.json" 2>/dev/null || echo 0)
assert_eq "$([ "${HOOK_COUNT:-0}" -ge 1 ] && echo yes || echo no)" "yes" \
  "PreToolUse hook array has at least one entry"

HOOK_CMD=$(jq -r '.hooks.PreToolUse[0].hooks[0].command // ""' "$FAKE/.claude/settings.json" 2>/dev/null || true)
assert_contains "$HOOK_CMD" "check-push.sh" \
  "hook command references check-push.sh"
assert_contains "$HOOK_CMD" "bash " \
  "hook command is bash-prefixed"

# Extract path from command: bash "<path>/scripts/check-push.sh"
HOOK_PATH=$(printf '%s' "$HOOK_CMD" | sed 's/bash "//;s/"$//')
assert_eq "$([ -f "$HOOK_PATH" ] && echo yes || echo no)" "yes" \
  "check-push.sh path in settings.json resolves on disk: $HOOK_PATH"

# ---------------------------------------------------------------
# Assert 9: Idempotency -- run installer a second time
# ---------------------------------------------------------------
HOME="$FAKE" bash "$INSTALLER" --yes

# check-push.sh should appear EXACTLY ONCE across settings.json
DEDUP_COUNT=$(jq '[.. | strings] | map(select(test("check-push"))) | length' \
  "$FAKE/.claude/settings.json" 2>/dev/null || echo 0)
assert_eq "$DEDUP_COUNT" "1" "check-push.sh appears exactly once after second install (idempotent)"

SETTINGS_VALID2=$(jq empty "$FAKE/.claude/settings.json" 2>&1 && echo ok || echo bad)
assert_eq "$SETTINGS_VALID2" "ok" "settings.json still valid JSON after second install"

# ---------------------------------------------------------------
# Assert 7a: Hook entry shape (FIX 7a)
# ---------------------------------------------------------------
HOOK_MATCHER=$(jq -r '.hooks.PreToolUse[0].matcher // ""' "$FAKE/.claude/settings.json" 2>/dev/null || true)
assert_eq "$HOOK_MATCHER" "Bash" "PreToolUse[0].matcher == Bash"

# D9: the inner hook must NOT carry an `if` matcher. `if: "Bash(git push *)"` is an
# anchored-prefix permission rule (word boundary at the trailing space) that SKIPS the
# hook for any command not literally starting with "git push " -- e.g. `FOO=bar git push`,
# `git -C path push`, `GIT_SSH_COMMAND=x git push` -- which would proceed ALLOWED = a
# fail-open ABOVE check-push.sh. With no `if`, matcher:"Bash" runs check-push.sh on every
# Bash command and the script's own (hardened, O(n)) detection is the sole, complete gate.
# (See DECISIONS.md "Push-gate hook fires for all Bash".)
HOOK_IF=$(jq -r '.hooks.PreToolUse[0].hooks[0].if // ""' "$FAKE/.claude/settings.json" 2>/dev/null || true)
assert_eq "$HOOK_IF" '' "PreToolUse[0].hooks[0] has NO gating 'if' (D9: hook fires for all Bash; script is sole gate)"

HOOK_TIMEOUT=$(jq -r '.hooks.PreToolUse[0].hooks[0].timeout // ""' "$FAKE/.claude/settings.json" 2>/dev/null || true)
assert_eq "$HOOK_TIMEOUT" "15" "PreToolUse[0].hooks[0].timeout == 15"

# ---------------------------------------------------------------
# Assert 10: references/ subdirectories preserved
# ---------------------------------------------------------------
assert_eq "$([ -f "$FAKE/.claude/skills/ship/references/scenario-matrix.md" ] && echo yes || echo no)" "yes" \
  "ship/references/scenario-matrix.md copied"
assert_eq "$([ -f "$FAKE/.claude/skills/ship-review/references/code-review-checklist.md" ] && echo yes || echo no)" "yes" \
  "ship-review/references/code-review-checklist.md copied"

# ---------------------------------------------------------------
# Assert 11: agents installed and have no ${CLAUDE_PLUGIN_ROOT}
# ---------------------------------------------------------------
assert_eq "$([ -f "$FAKE/.claude/agents/ship-reviewer.md" ] && echo yes || echo no)" "yes" \
  "ship-reviewer.md agent installed"

AGENT_PR_FILES=$(find "$FAKE/.claude/agents/" -name '*.md' | \
  xargs grep -l '\${CLAUDE_PLUGIN_ROOT}' 2>/dev/null || true)
assert_eq "$([ -z "$AGENT_PR_FILES" ] && echo none || echo "$AGENT_PR_FILES")" "none" \
  "no \${CLAUDE_PLUGIN_ROOT} in any copied agent"

# ---------------------------------------------------------------
# Phase E Assert: Layer-2 trigger rule installed + default-on enabled
# (the first/second installs above used the DEFAULT path — no --no-default-on)
# ---------------------------------------------------------------
assert_eq "$([ -f "$FAKE/.claude/rules/shipgate-trigger.md" ] && echo yes || echo no)" "yes" \
  "shipgate-trigger.md rule installed to ~/.claude/rules"
assert_contains "$(cat "$FAKE/.claude/rules/shipgate-trigger.md")" "/ship" \
  "installed rule references the /ship flow"
assert_eq "$(jq -r '.defaultEnabled' "$FAKE/.shipgate.json" 2>/dev/null || echo MISSING)" "true" \
  "default install enables defaultEnabled:true in ~/.shipgate.json"

# ---------------------------------------------------------------
# Assert 7b: CRITICAL-1 regression — empty settings.json (FIX 7b)
# Verifies that an empty settings.json is treated as {} (not fail-open).
# ---------------------------------------------------------------
BASE_B=$(mktemp -d)
FB="$BASE_B/has space"
mkdir -p "$FB/.claude/skills"
: > "$FB/.claude/settings.json"   # create empty settings.json
HOME="$FB" bash "$INSTALLER" --yes
HOOK_COUNT_B=$(jq -r '[.hooks.PreToolUse[]? | .hooks[]? | .command] | map(select(test("check-push"))) | length' \
  "$FB/.claude/settings.json" 2>/dev/null || echo 0)
assert_eq "$HOOK_COUNT_B" "1" "CRITICAL-1: hook installed despite empty settings.json start"
rm -rf "$BASE_B"

# ---------------------------------------------------------------
# Assert 7c: CRITICAL-2 regression — unrelated check-push.sh string (FIX 7c)
# Verifies the idempotency guard does NOT over-match unrelated contexts.
# ---------------------------------------------------------------
BASE_C=$(mktemp -d)
FC="$BASE_C/has space"
mkdir -p "$FC/.claude/skills"
# settings.json has check-push.sh in a permissions rule (unrelated to hook command)
printf '{"permissions":{"deny":["Bash(cat check-push.sh)"]}}' > "$FC/.claude/settings.json"
HOME="$FC" bash "$INSTALLER" --yes
HOOK_CMD_C=$(jq -r '.hooks.PreToolUse[0].hooks[0].command // ""' "$FC/.claude/settings.json" 2>/dev/null || true)
assert_contains "$HOOK_CMD_C" "check-push.sh" \
  "CRITICAL-2: hook installed even though check-push.sh appeared in unrelated permissions rule"
rm -rf "$BASE_C"

# ---------------------------------------------------------------
# Assert 7d: IMPORTANT-4 regression — invalid settings.json aborts in pre-flight (FIX 7d)
# Verifies that a non-object (but valid JSON) settings.json causes abort BEFORE copying skills.
# ---------------------------------------------------------------
BASE_D=$(mktemp -d)
FD="$BASE_D/has space"
mkdir -p "$FD/.claude/skills"
printf '[1,2,3]' > "$FD/.claude/settings.json"   # valid JSON but not an object
set +e; HOME="$FD" bash "$INSTALLER" --yes >/dev/null 2>&1; RC_D=$?; set -e
RC_D_LABEL=$([ "$RC_D" -ne 0 ] && echo nonzero || echo zero)
assert_eq "$RC_D_LABEL" "nonzero" "IMPORTANT-4: installer exits non-zero for invalid (array) settings.json"
# Verify no partial install: skills must NOT have been copied
NO_PARTIAL=$([ ! -f "$FD/.claude/skills/ship/SKILL.md" ] && echo absent || echo present)
assert_eq "$NO_PARTIAL" "absent" "IMPORTANT-4: no partial install (skills not copied) when settings.json is invalid"
rm -rf "$BASE_D"

# ---------------------------------------------------------------
# Phase E Assert: default-on merge is NON-CLOBBERING (preserves existing global keys)
# ---------------------------------------------------------------
BASE_E=$(mktemp -d)
FE="$BASE_E/has space"
mkdir -p "$FE/.claude/skills"
printf '{"mainBranch":"trunk","markerTtlSeconds":123}' > "$FE/.shipgate.json"
HOME="$FE" bash "$INSTALLER" --yes >/dev/null 2>&1
assert_eq "$(jq -r '.mainBranch' "$FE/.shipgate.json" 2>/dev/null || echo X)" "trunk" \
  "non-clobbering: pre-existing mainBranch preserved through default-on merge"
assert_eq "$(jq -r '.markerTtlSeconds' "$FE/.shipgate.json" 2>/dev/null || echo X)" "123" \
  "non-clobbering: pre-existing markerTtlSeconds preserved"
assert_eq "$(jq -r '.defaultEnabled' "$FE/.shipgate.json" 2>/dev/null || echo X)" "true" \
  "non-clobbering: defaultEnabled:true added alongside existing keys"
rm -rf "$BASE_E"

# ---------------------------------------------------------------
# Phase E Assert: --no-default-on leaves ~/.shipgate.json untouched but still installs the rule
# ---------------------------------------------------------------
BASE_F=$(mktemp -d)
FF="$BASE_F/has space"
mkdir -p "$FF/.claude/skills"
HOME="$FF" bash "$INSTALLER" --yes --no-default-on >/dev/null 2>&1
assert_eq "$([ -f "$FF/.shipgate.json" ] && echo present || echo absent)" "absent" \
  "--no-default-on: ~/.shipgate.json NOT created (ship-gate stays opt-in)"
assert_eq "$([ -f "$FF/.claude/rules/shipgate-trigger.md" ] && echo yes || echo no)" "yes" \
  "--no-default-on: the trigger rule is still installed (rule is independent of default-on)"
rm -rf "$BASE_F"

# ---------------------------------------------------------------
# Phase E Assert: invalid ~/.shipgate.json aborts pre-flight, no partial install, no clobber
# ---------------------------------------------------------------
BASE_G=$(mktemp -d)
FG="$BASE_G/has space"
mkdir -p "$FG/.claude/skills"
printf '[1,2,3]' > "$FG/.shipgate.json"   # valid JSON but not an object
set +e; HOME="$FG" bash "$INSTALLER" --yes >/dev/null 2>&1; RC_G=$?; set -e
assert_eq "$([ "$RC_G" -ne 0 ] && echo nonzero || echo zero)" "nonzero" \
  "invalid ~/.shipgate.json: installer exits non-zero"
assert_eq "$([ ! -f "$FG/.claude/skills/ship/SKILL.md" ] && echo absent || echo present)" "absent" \
  "invalid ~/.shipgate.json: no partial install (skills not copied)"
assert_eq "$(cat "$FG/.shipgate.json")" "[1,2,3]" \
  "invalid ~/.shipgate.json left untouched (no clobber)"
rm -rf "$BASE_G"

# ---------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------
rm -rf "$BASE"

assert_summary
