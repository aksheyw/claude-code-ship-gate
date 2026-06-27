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
assert_summary
