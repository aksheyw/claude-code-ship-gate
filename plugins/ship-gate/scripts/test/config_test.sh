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
assert_summary
