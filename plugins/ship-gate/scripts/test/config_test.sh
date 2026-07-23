#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/assert.sh"; . "$DIR/../lib/config.sh"
TMP=$(mktemp -d)
assert_eq "$(sg_config_get "$TMP" '.gates.tests.enabled')" "true" "default tests enabled"
assert_eq "$(sg_config_get "$TMP" '.mainBranch')" "main" "default mainBranch"
echo '{ "mainBranch": "trunk", "gates": { "build": { "enabled": true } } }' > "$TMP/.shipgate.json"
assert_eq "$(sg_config_get "$TMP" '.mainBranch')" "trunk" "override mainBranch"
assert_eq "$(sg_config_get "$TMP" '.gates.build.enabled')" "true" "override build"
assert_eq "$(sg_config_get "$TMP" '.gates.tests.enabled')" "true" "default survives merge"
echo '{ "gates": { "tests": { "command": "vitest" } } }' > "$TMP/.shipgate.json"
assert_eq "$(sg_config_get "$TMP" '.gates.tests.command')" "vitest" "override nested command only"
assert_eq "$(sg_config_get "$TMP" '.gates.tests.enabled')" "true" "sibling enabled survives nested override"

# P6: every shipped example config must be valid JSON AND pass the runtime structural validator — a user who
# copies an example into their repo must never get a config that fail-closes the gating path.
for ex in "$DIR/../../examples"/*.json; do
  jq empty "$ex" >/dev/null 2>&1 && jok=ok || jok=bad
  assert_eq "$jok" "ok" "example $(basename "$ex"): valid JSON"
  XT=$(mktemp -d); cp "$ex" "$XT/.shipgate.json"
  if sg_config_structure_ok "$XT"; then sok=ok; else sok=bad; fi
  assert_eq "$sok" "ok" "example $(basename "$ex"): passes sg_config_structure_ok (copyable without fail-close)"
done
# --------------------------------------------------------------------------------------------------
# Codex review 2026-07-23 (CONFIRMED FAIL-OPEN): an ENABLED command gate whose `command` is an EMPTY
# ARRAY passed structural validation, because jq's `all` over `[]` is vacuously true. The runner then
# warned "empty suite list" and returned SUCCESS, so `run` exited 0 with the tests gate having executed
# nothing at all. That is the deterministic tier reporting a pass without running — the exact failure
# class this whole plugin exists to prevent, and worse than a disabled gate because the user explicitly
# asked for it to be ON. An empty suite array is unambiguously a config ERROR (enabled, but nothing to
# run), so it must FAIL CLOSED like every other malformed structure.
EMPTYARR=$(mktemp -d)
printf '%s' '{"gates":{"tests":{"enabled":true,"command":[]}}}' > "$EMPTYARR/.shipgate.json"
if sg_config_structure_ok "$EMPTYARR"; then ea=accepted; else ea=rejected; fi
assert_eq "$ea" "rejected" "structure: an ENABLED gate with an empty suite array fails CLOSED (codex fail-open)"

# A DISABLED gate with an empty array is equally malformed — validation is about structure, not about
# whether the gate happens to be switched on, and a config repaired by flipping enabled:true must not
# suddenly become a silent no-op.
EMPTYOFF=$(mktemp -d)
printf '%s' '{"gates":{"tests":{"enabled":false,"command":[]}}}' > "$EMPTYOFF/.shipgate.json"
if sg_config_structure_ok "$EMPTYOFF"; then eo=accepted; else eo=rejected; fi
assert_eq "$eo" "rejected" "structure: an empty suite array is malformed regardless of enabled state"

# Control: a NON-empty suite array is still perfectly valid (no over-tightening).
OKARR=$(mktemp -d)
printf '%s' '{"gates":{"tests":{"enabled":true,"command":[{"command":"echo hi"}]}}}' > "$OKARR/.shipgate.json"
if sg_config_structure_ok "$OKARR"; then oa=ok; else oa=bad; fi
assert_eq "$oa" "ok" "structure: a non-empty suite array remains valid (control)"

assert_summary
