#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/assert.sh"
SG="$DIR/../ship-gate.sh"
# detect
P=$(mktemp -d); echo '{}' > "$P/package.json"; : > "$P/pnpm-lock.yaml"
OUT=$(bash "$SG" detect "$P")
assert_contains "$OUT" "pnpm test" "detect emits resolved test cmd"
assert_contains "$OUT" "\"deploy\"" "detect emits deploy field"
# run: passing project => exit 0
R=$(mktemp -d); ( cd "$R" && git init -q )
cat > "$R/.shipgate.json" <<'J'
{ "gates": { "tests":{"enabled":true,"command":"true"}, "lint":{"enabled":false}, "typecheck":{"enabled":false}, "build":{"enabled":false}, "secretScan":{"enabled":false} } }
J
assert_eq "$(bash "$SG" run "$R" >/dev/null 2>&1; echo $?)" "0" "run passes when gates pass"
# run: failing first gate short-circuits (lint must NOT run)
cat > "$R/.shipgate.json" <<'J'
{ "gates": { "tests":{"enabled":true,"command":"false"}, "lint":{"enabled":true,"command":"touch RAN_LINT"}, "typecheck":{"enabled":false}, "build":{"enabled":false}, "secretScan":{"enabled":false} } }
J
rm -f "$R/RAN_LINT"
assert_eq "$(bash "$SG" run "$R" >/dev/null 2>&1; echo $?)" "1" "run fails when first gate fails"
assert_eq "$([ -f "$R/RAN_LINT" ] && echo yes || echo no)" "no" "run short-circuits (later gate not run)"
# run: secretScan integration catches a staged key
cat > "$R/.shipgate.json" <<'J'
{ "gates": { "tests":{"enabled":true,"command":"true"}, "lint":{"enabled":false}, "typecheck":{"enabled":false}, "build":{"enabled":false}, "secretScan":{"enabled":true} } }
J
printf 'k="sk-or-v1-%s"\n' "$(printf 'a%.0s' {1..40})" > "$R/leak.js"; ( cd "$R" && git add leak.js )
assert_eq "$(bash "$SG" run "$R" >/dev/null 2>&1; echo $?)" "1" "run fails on staged secret"
( cd "$R" && git rm -q --cached leak.js ); rm -f "$R/leak.js"
# run: malformed config must fail CLOSED (C1 regression)
echo 'not json' > "$R/.shipgate.json"
assert_eq "$(bash "$SG" run "$R" >/dev/null 2>&1; echo $?)" "2" "run fails closed on invalid config"
# protected-branch: the single merge/push target = first line of the shared protected set
GN=$(mktemp -u)
PB=$(mktemp -d); ( cd "$PB" && git init -q ); printf '{"mainBranch":"trunk"}' > "$PB/.shipgate.json"
assert_eq "$(SHIPGATE_GLOBAL_CONFIG="$GN" bash "$SG" protected-branch "$PB")" "trunk" "protected-branch: explicit mainBranch => trunk"
PB2=$(mktemp -d); ( cd "$PB2" && git init -q )
assert_eq "$(SHIPGATE_GLOBAL_CONFIG="$GN" bash "$SG" protected-branch "$PB2")" "main" "protected-branch: no config/no remote => main (first of {main,master} fallback)"
assert_summary
