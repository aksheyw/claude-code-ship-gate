#!/usr/bin/env bash
# P2 (uncovered-suite detection) + P4 (CI-awareness). The `doctor` subcommand + its detect helpers find
# suites the single configured tests.command would silently SKIP (the S149 gap that motivated this: a root
# `npx vitest run` that never touched the functions/ suite or the Firestore-rules emulator suite while still
# reporting "tests PASS"). `doctor` is ADVISORY — it WARNs and always exits 0; it never blocks a push.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/assert.sh"; . "$DIR/../lib/detect.sh"
SG="$DIR/../ship-gate.sh"

# ---------------------------------------------------------------------------------------------------------
# Task 2.1 — sg_detect_uncovered <dir>: one line per suite the root tests.command would miss. The four kinds:
# a nested package.json with its own test script; an extra/named unit-test config; an e2e suite (dir/config);
# a *.rules security-rules file (needs an emulator suite). A plain single-suite repo emits NOTHING (no
# over-flagging); an empty dir emits nothing.
# ---------------------------------------------------------------------------------------------------------
U=$(mktemp -d)
printf '%s' '{"scripts":{"test":"vitest run"}}' > "$U/package.json"   # root suite (covered) — NOT flagged
: > "$U/vitest.config.ts"                                             # the single root config — NOT flagged
mkdir -p "$U/functions"; printf '%s' '{"scripts":{"test":"vitest run"}}' > "$U/functions/package.json"
: > "$U/vitest.config.functions.ts"                                  # named variant => extra config
mkdir -p "$U/e2e"; : > "$U/e2e/login.spec.ts"
printf 'rules_version="2";\n' > "$U/firestore.rules"
uout=$(sg_detect_uncovered "$U")
assert_contains "$uout" "functions/package.json" "uncovered: nested package.json with a test script flagged"
assert_contains "$uout" "vitest.config.functions.ts" "uncovered: named-variant test config flagged"
assert_contains "$uout" "e2e" "uncovered: e2e directory flagged"
assert_contains "$uout" "firestore.rules" "uncovered: *.rules security-rules file flagged"

# Control: a plain single-suite repo (root package.json + a single root vitest.config.ts) flags NOTHING.
C=$(mktemp -d); printf '%s' '{"scripts":{"test":"vitest run"}}' > "$C/package.json"; : > "$C/vitest.config.ts"
cout=$(sg_detect_uncovered "$C")
assert_eq "$([ -z "$cout" ] && echo empty || echo "nonempty:$cout")" "empty" "no over-flag: single-suite repo => no uncovered suites"

# Empty dir => no output.
E=$(mktemp -d)
assert_eq "$([ -z "$(sg_detect_uncovered "$E")" ] && echo empty || echo nonempty)" "empty" "empty dir => no output"

# node_modules is ignored (a dependency's nested package.json/test config is not the user's suite).
NM=$(mktemp -d); printf '%s' '{"scripts":{"test":"x"}}' > "$NM/package.json"
mkdir -p "$NM/node_modules/dep"; printf '%s' '{"scripts":{"test":"y"}}' > "$NM/node_modules/dep/package.json"
: > "$NM/node_modules/dep/vitest.config.functions.ts"
assert_eq "$([ -z "$(sg_detect_uncovered "$NM")" ] && echo empty || echo nonempty)" "empty" "node_modules ignored (not the user's suites)"

# ---------------------------------------------------------------------------------------------------------
# Task 2.2 — `ship-gate.sh doctor <dir>`: print a [WARN] uncovered suite line for each detection and ALWAYS
# exit 0 (advisory, never blocks). A clean single-suite repo reports no uncovered suites and still exits 0.
# ---------------------------------------------------------------------------------------------------------
drc=0; dout=$(bash "$SG" doctor "$U" 2>&1) || drc=$?
assert_eq "$drc" "0" "doctor: exits 0 even WITH uncovered suites (advisory, never blocks)"
assert_contains "$dout" "[WARN] uncovered suite:" "doctor: emits a [WARN] uncovered suite line"
assert_contains "$dout" "functions/package.json" "doctor: surfaces the nested-package suite path"

crc=0; cdout=$(bash "$SG" doctor "$C" 2>&1) || crc=$?
assert_eq "$crc" "0" "doctor: clean single-suite repo exits 0"
assert_contains "$cdout" "no uncovered suites" "doctor: clean repo reports no uncovered suites"
case "$cdout" in *"[WARN] uncovered suite:"*) assert_eq "warned" "clean" "doctor: clean repo must NOT warn about uncovered suites";; *) assert_eq "clean" "clean" "doctor: clean repo emits no uncovered-suite warning";; esac

# ---------------------------------------------------------------------------------------------------------
# Task 4.1 — sg_detect_ci <dir>: name the CI system when a config is present, "" when none. Plus `detect`
# surfaces a `ci` field so /ship-init can tell the user the gate is the sole automated check.
# ---------------------------------------------------------------------------------------------------------
GHA=$(mktemp -d); mkdir -p "$GHA/.github/workflows"; : > "$GHA/.github/workflows/ci.yml"; printf '{}' > "$GHA/package.json"
assert_eq "$(sg_detect_ci "$GHA")" "GitHub Actions" "ci: .github/workflows/*.yml => GitHub Actions"
GL=$(mktemp -d); : > "$GL/.gitlab-ci.yml"
assert_eq "$(sg_detect_ci "$GL")" "GitLab CI" "ci: .gitlab-ci.yml => GitLab CI"
CC=$(mktemp -d); mkdir -p "$CC/.circleci"; : > "$CC/.circleci/config.yml"
assert_eq "$(sg_detect_ci "$CC")" "CircleCI" "ci: .circleci/config.yml => CircleCI"
NOCI=$(mktemp -d)
assert_eq "$(sg_detect_ci "$NOCI")" "" "ci: no CI config => empty"
# detect JSON includes the ci field
detci=$(bash "$SG" detect "$GHA" 2>/dev/null | jq -r .ci)
assert_eq "$detci" "GitHub Actions" "detect: emits a ci field naming the detected CI"

# ---------------------------------------------------------------------------------------------------------
# Task 4.2 — doctor surfaces CI status: a clear "no CI detected — this gate is your only automated check"
# when none is configured; a confirming "CI detected: <name>" when one is. Still exits 0.
# ---------------------------------------------------------------------------------------------------------
ncrc=0; ncout=$(bash "$SG" doctor "$U" 2>&1) || ncrc=$?    # U has no CI config
assert_eq "$ncrc" "0" "doctor: no-CI repo still exits 0"
assert_contains "$ncout" "no CI detected" "doctor: warns when no CI is configured (gate is the sole check)"
ghaout=$(bash "$SG" doctor "$GHA" 2>&1)
assert_contains "$ghaout" "CI detected: GitHub Actions" "doctor: confirms the detected CI system"

# ---------------------------------------------------------------------------------------------------------
# Deep-review L1-1 — jest named-variant configs (jest.config.<name>.* and jest.<word>.config.*) are separate
# suites bare `jest` skips (it only reads jest.config.{js,ts,...}). Flag them at root AND nested, symmetric
# with vitest. A plain root jest.config.js is the normal single config and must NOT be flagged.
# ---------------------------------------------------------------------------------------------------------
J=$(mktemp -d); printf '%s' '{"scripts":{"test":"jest"}}' > "$J/package.json"
: > "$J/jest.config.js"                 # plain root single config => NOT flagged
: > "$J/jest.config.integration.js"     # jest.config.<name>.* variant (root) => flagged
: > "$J/jest.e2e.config.js"             # jest.<word>.config.* variant (root) => flagged
mkdir -p "$J/sub"; : > "$J/sub/jest.e2e.config.js"   # jest.<word>.config.* nested => flagged
jout=$(sg_detect_uncovered "$J")
assert_contains "$jout" "jest.config.integration.js" "uncovered: root jest.config.<name> variant flagged (L1-1)"
assert_contains "$jout" "jest.e2e.config.js" "uncovered: jest.<word>.config.* variant flagged at root + nested (L1-1)"
if printf '%s\n' "$jout" | grep -qx "extra test-runner config: jest.config.js"; then plainj=flagged; else plainj=ok; fi
assert_eq "$plainj" "ok" "uncovered: plain root jest.config.js NOT flagged (L1-1 control — no over-flag)"

# Deep-review round 2 (R2-LENSA-01): vitest infix-form config (vitest.<word>.config.<ext>) is the direct
# analog of jest.<word>.config.* and must be flagged at root + nested, SYMMETRIC with jest. (Round 1's jest
# fix added jest.*.config.* but left the vitest infix out, creating a reverse asymmetry.) A plain root
# vitest.config.ts stays the normal single config (NOT flagged).
VI=$(mktemp -d); printf '%s' '{"scripts":{"test":"vitest"}}' > "$VI/package.json"
: > "$VI/vitest.config.ts"              # plain root single config => NOT flagged
: > "$VI/vitest.e2e.config.ts"          # vitest.<word>.config.* infix (root) => flagged
mkdir -p "$VI/sub"; : > "$VI/sub/vitest.integration.config.ts"   # nested infix => flagged
viout=$(sg_detect_uncovered "$VI")
assert_contains "$viout" "vitest.e2e.config.ts" "uncovered: root vitest.<word>.config.* infix flagged (R2 symmetry)"
assert_contains "$viout" "sub/vitest.integration.config.ts" "uncovered: nested vitest infix flagged (R2)"
if printf '%s\n' "$viout" | grep -qx "extra test-runner config: vitest.config.ts"; then plainv=flagged; else plainv=ok; fi
assert_eq "$plainv" "ok" "uncovered: plain root vitest.config.ts still NOT flagged (R2 control)"

# ---------------------------------------------------------------------------------------------------------
# Deep-review L1-2 — a glob bracket '[' in the repo's absolute path must NOT defeat nested-config detection
# (the old `-path "$d/*/*"` treated $d as a glob; '[b]' became a char class). Depth is now decided on the
# prefix-stripped RELATIVE path (literal), so it is glob-immune.
# ---------------------------------------------------------------------------------------------------------
BR=$(mktemp -d); BD="$BR/a[b]c"; mkdir -p "$BD/functions"
printf '%s' '{"scripts":{"test":"x"}}' > "$BD/package.json"; : > "$BD/functions/jest.config.js"
assert_contains "$(sg_detect_uncovered "$BD")" "functions/jest.config.js" "uncovered: nested config under a '[' path still flagged (L1-2)"

# ---------------------------------------------------------------------------------------------------------
# Deep-review LENS2-01 — common CI systems with canonical config paths must not read as absent (else doctor
# wrongly emits "no CI detected"). Buildkite / Drone / AppVeyor.
# ---------------------------------------------------------------------------------------------------------
BK=$(mktemp -d); mkdir -p "$BK/.buildkite"; : > "$BK/.buildkite/pipeline.yml"
assert_eq "$(sg_detect_ci "$BK")" "Buildkite" "ci: .buildkite/pipeline.yml => Buildkite (LENS2-01)"
DR=$(mktemp -d); : > "$DR/.drone.yml"
assert_eq "$(sg_detect_ci "$DR")" "Drone CI" "ci: .drone.yml => Drone CI (LENS2-01)"
AV=$(mktemp -d); : > "$AV/appveyor.yml"
assert_eq "$(sg_detect_ci "$AV")" "AppVeyor" "ci: appveyor.yml => AppVeyor (LENS2-01)"
AV2=$(mktemp -d); : > "$AV2/.appveyor.yml"
assert_eq "$(sg_detect_ci "$AV2")" "AppVeyor" "ci: .appveyor.yml => AppVeyor (LENS2-01)"

assert_summary
