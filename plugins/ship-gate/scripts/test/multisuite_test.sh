#!/usr/bin/env bash
# P1 (S149): multi-suite / area-conditional deterministic gates. The tests/lint/typecheck/build command may
# be a string (today) OR an array of {command, when:[git-pathspec,...]} suites. A suite runs iff a changed
# file matches its `when` pathspecs (omitted = always); ANY in-scope suite failing fails the gate. Scope is
# FAIL-SAFE: when the shipped change-set can't be determined, every when-suite runs (over-run, never skip).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/assert.sh"; . "$DIR/../lib/config.sh"
SG="$DIR/../ship-gate.sh"

# ---------------------------------------------------------------------------------------------------------
# Task 1.1 — sg_change_base: the merge-base vs the protected branch when HEAD is ahead of it; "" otherwise.
# "" => callers fail-safe RUN every when-conditional suite.
# ---------------------------------------------------------------------------------------------------------
R=$(mktemp -d); ( cd "$R" && git init -q && git config user.email t@t && git config user.name t \
  && printf '{"mainBranch":"main"}' > .shipgate.json && git add . && git commit -q -m init && git branch -M main \
  && git checkout -q -b feature && printf x > f && git add f && git commit -q -m work )
exp=$(git -C "$R" merge-base main HEAD)
assert_eq "$(sg_change_base "$R")" "$exp" "feature branch: change-base = merge-base(main, HEAD)"
assert_eq "$([ -n "$(sg_change_base "$R")" ] && echo nonempty || echo empty)" "nonempty" "feature branch: change-base non-empty"

( cd "$R" && git checkout -q main )
assert_eq "$(sg_change_base "$R")" "" "on protected branch (HEAD==base): change-base empty => fail-safe run"

N=$(mktemp -d)
assert_eq "$(sg_change_base "$N")" "" "non-repo dir: change-base empty"

# ---------------------------------------------------------------------------------------------------------
# Task 1.2 — sg_suite_in_scope <dir> <key> <idx> <base>: run (0) iff a changed file matches the suite's
# `when` git-pathspecs (committed base..HEAD, unstaged, STAGED, or UNTRACKED — gates run BEFORE commit).
# omitted when => always; base "" => fail-safe run.
# ---------------------------------------------------------------------------------------------------------
in_scope(){ sg_suite_in_scope "$1" "$2" "$3" "$4" && echo yes || echo no; }

# feature branch: x.rules + src/a.ts committed; config has 3 tests suites (when *.rules / when functions / none)
R2=$(mktemp -d); ( cd "$R2" && git init -q && git config user.email t@t && git config user.name t && git branch -M main \
  && printf '%s' '{"mainBranch":"main","gates":{"tests":{"enabled":true,"command":[{"command":"true","when":["*.rules"]},{"command":"true","when":["functions"]},{"command":"true"}]}}}' > .shipgate.json \
  && git add . && git commit -q -m init && git checkout -q -b feature \
  && printf x > x.rules && mkdir -p src && printf y > src/a.ts && git add x.rules src/a.ts && git commit -q -m work )
base2=$(sg_change_base "$R2")
assert_eq "$(in_scope "$R2" tests 0 "$base2")" "yes" "suite0 when:[*.rules] + x.rules changed => in scope"
assert_eq "$(in_scope "$R2" tests 1 "$base2")" "no"  "suite1 when:[functions] (no functions change) => out of scope"
assert_eq "$(in_scope "$R2" tests 2 "$base2")" "yes" "suite2 no when => always in scope"

# HIGH #1: a new suite's files exist ONLY as staged/untracked (gates run pre-commit) => must be IN scope.
R3=$(mktemp -d); ( cd "$R3" && git init -q && git config user.email t@t && git config user.name t && git branch -M main \
  && printf '%s' '{"mainBranch":"main","gates":{"tests":{"enabled":true,"command":[{"command":"true","when":["*.rules"]}]}}}' > .shipgate.json \
  && git add . && git commit -q -m init && git checkout -q -b feature && printf c > code.ts && git add code.ts && git commit -q -m work )
base3=$(sg_change_base "$R3")
assert_eq "$(in_scope "$R3" tests 0 "$base3")" "no"  "no *.rules anywhere => out of scope (control)"
( cd "$R3" && printf r > new.rules && git add new.rules )
assert_eq "$(in_scope "$R3" tests 0 "$base3")" "yes" "STAGED new.rules => in scope (HIGH #1: gates run pre-commit)"
( cd "$R3" && git reset -q new.rules )   # now untracked
assert_eq "$(in_scope "$R3" tests 0 "$base3")" "yes" "UNTRACKED new.rules => in scope (HIGH #1)"
assert_eq "$(in_scope "$R3" tests 0 "")" "yes" "base='' (indeterminate change-set) => when-suite runs (fail-safe)"

# ---------------------------------------------------------------------------------------------------------
# Task 1.3 / 1.4 — `ship-gate.sh run` executes the tests gate's command whether string or suite-array, and
# preserves deterministic semantics: ANY in-scope suite non-zero => gate FAIL => run exits 1; an out-of-scope
# suite is skipped; an empty array warns (no silent pass); string/null back-compat unchanged.
# ---------------------------------------------------------------------------------------------------------
# Build a feature-branch repo; only the tests gate is enabled. $1 = tests `command` JSON; $2 = "rules" to add
# a committed *.rules file (so a when:[*.rules] suite is in scope).
build_run_repo(){ local tcmd="$1" addrules="${2:-}" d
  d=$(mktemp -d); ( cd "$d" && git init -q && git config user.email t@t && git config user.name t && git branch -M main \
    && printf '%s' "{\"mainBranch\":\"main\",\"gates\":{\"tests\":{\"enabled\":true,\"command\":$tcmd},\"lint\":{\"enabled\":false},\"typecheck\":{\"enabled\":false},\"build\":{\"enabled\":false},\"secretScan\":{\"enabled\":false}}}" > .shipgate.json \
    && git add . && git commit -q -m init && git checkout -q -b feature && printf c > code.ts && git add code.ts && git commit -q -m work ) >/dev/null 2>&1
  [ "$addrules" = rules ] && ( cd "$d" && printf r > app.rules && git add app.rules && git commit -q -m rules ) >/dev/null 2>&1
  printf '%s' "$d"; }
run_out=""; run_rc=0
do_run(){ if run_out=$(bash "$SG" run "$1" 2>&1); then run_rc=0; else run_rc=$?; fi; }
# A push is BLOCKED iff `run` exits non-zero (the deterministic-safety property — exit 1 gate-fail OR exit 2
# fail-closed config error are both "blocked"; the specific code is not load-bearing).
blocked(){ [ "$run_rc" -ne 0 ] && echo blocked || echo allowed; }

do_run "$(build_run_repo '"true"')";  assert_eq "$run_rc" "0" "back-compat: string command 'true' => gate passes (exit 0)"
do_run "$(build_run_repo '"false"')"; assert_eq "$run_rc" "1" "back-compat: string command 'false' => gate fails (exit 1)"

do_run "$(build_run_repo '[{"command":"false","when":["*.rules"]},{"command":"true"}]')"
assert_eq "$run_rc" "0" "array: failing suite OUT of scope (no *.rules) is skipped => gate passes"
assert_contains "$run_out" "SKIP" "array: out-of-scope suite logs a [SKIP]"

do_run "$(build_run_repo '[{"command":"false","when":["*.rules"]},{"command":"true"}]' rules)"
assert_eq "$run_rc" "1" "array: failing suite IN scope (*.rules changed) runs => gate FAILS (deterministic)"

do_run "$(build_run_repo '[{"command":"true"},{"command":"false"}]')"
assert_eq "$run_rc" "1" "array: a failing no-when suite always runs => gate FAILS"

do_run "$(build_run_repo '[{"command":"true"},{"command":"true"}]')"
assert_eq "$run_rc" "0" "array: all in-scope suites pass => gate passes"

do_run "$(build_run_repo '[]')"
assert_eq "$run_rc" "0" "empty suite array => no failure (nothing ran)"
assert_contains "$run_out" "WARN" "empty suite array => visible [WARN] (never a silent green)"

# ---------------------------------------------------------------------------------------------------------
# Task 1.3b (review HIGH #2) — `detect` must NOT emit the raw multi-line JSON array as the `tests` value
# (that would corrupt /ship-init's scaffold). For an array command it emits a single-line <multi-suite> note.
# ---------------------------------------------------------------------------------------------------------
D4=$(mktemp -d); ( cd "$D4" && git init -q && git config user.email t@t && git config user.name t && git branch -M main \
  && printf '%s' '{"mainBranch":"main","gates":{"tests":{"enabled":true,"command":[{"command":"npm test"},{"command":"npm test","when":["functions"]}]}}}' > .shipgate.json ) >/dev/null 2>&1
det=$(cd "$D4" && bash "$SG" detect "$D4" 2>/dev/null)
tval=$(printf '%s' "$det" | jq -r .tests 2>/dev/null)
assert_eq "$(printf '%s' "$tval" | wc -l | tr -d ' ')" "0" "detect: array tests => single-line value (no multi-line JSON blob)"
assert_contains "$tval" "multi-suite" "detect: array tests => a <multi-suite> placeholder, not raw JSON"

# ---------------------------------------------------------------------------------------------------------
# Adversarial audit hardening (2026-06-20). The array path dropped the string path's [ -n ] guard, so a
# MALFORMED suite array (bare strings, empty/missing command) ran `eval ""` => false [PASS] (a silent green
# no-op — the exact failure this feature kills). And a `when` pathspec git can't evaluate (invalid magic, or
# a brace glob git won't expand) silently SKIPPED. Malformed shape => FAIL-CLOSED; unevaluable when => RUN.
# ---------------------------------------------------------------------------------------------------------
do_run "$(build_run_repo '["true","false"]')"
assert_eq "$(blocked)" "blocked" "array of BARE STRINGS (not {command} objects) => fail-closed, never a silent pass"
do_run "$(build_run_repo '[{"command":""}]')"
assert_eq "$(blocked)" "blocked" "array suite with an EMPTY command => fail-closed (not eval-\"\"-passes)"
do_run "$(build_run_repo '[{"when":["*.rules"]}]')"
assert_eq "$(blocked)" "blocked" "array suite MISSING the command key => fail-closed"
do_run "$(build_run_repo '[{"command":"true"},{"command":"true"}]')"
assert_eq "$run_rc" "0" "control: a well-formed suite array still passes (validation isn't over-strict)"

# brace glob in `when` (git won't expand it; would silently match nothing) => fail-safe RUN.
B=$(mktemp -d); ( cd "$B" && git init -q && git config user.email t@t && git config user.name t && git branch -M main \
  && printf '%s' '{"mainBranch":"main","gates":{"tests":{"enabled":true,"command":[{"command":"false","when":["*.{tsx,jsx}"]}]},"lint":{"enabled":false},"typecheck":{"enabled":false},"build":{"enabled":false},"secretScan":{"enabled":false}}}' > .shipgate.json \
  && git add . && git commit -q -m init && git checkout -q -b feature && mkdir -p src && printf c > src/Component.tsx && git add src/Component.tsx && git commit -q -m tsx ) >/dev/null 2>&1
do_run "$B"
assert_eq "$run_rc" "1" "brace-glob when (*.{tsx,jsx}) + a real .tsx change => suite RUNS (fail-safe) => failing suite fails gate"

# invalid git pathspec magic in `when` (git errors) => fail-safe RUN, not silent skip.
M=$(mktemp -d); ( cd "$M" && git init -q && git config user.email t@t && git config user.name t && git branch -M main \
  && printf '%s' '{"mainBranch":"main","gates":{"tests":{"enabled":true,"command":[{"command":"false","when":[":(badmagic)x"]}]},"lint":{"enabled":false},"typecheck":{"enabled":false},"build":{"enabled":false},"secretScan":{"enabled":false}}}' > .shipgate.json \
  && git add . && git commit -q -m init && git checkout -q -b feature && printf c > code.ts && git add code.ts && git commit -q -m w ) >/dev/null 2>&1
do_run "$M"
assert_eq "$run_rc" "1" "invalid pathspec magic in when => git errors => fail-safe RUN => failing suite fails gate"

# ---------------------------------------------------------------------------------------------------------
# Deep-review hardening (2026-06-20, 14-lens). The array path was hardened, but the runtime never validated
# config STRUCTURE against the schema, so malformed shapes silently disabled/skipped gates => false PASS.
# All five reproduced fail-open; each must now be BLOCKED (fail-closed) or RUN (fail-safe), never a green no-op.
# ---------------------------------------------------------------------------------------------------------
# F1 [CRITICAL]: a scalar JSON-boolean command (command:true) evaled the shell builtin `true` => [PASS] exit 0.
do_run "$(build_run_repo 'true')"
assert_eq "$(blocked)" "blocked" "F1: scalar command:true (JSON bool) => fail-closed (not a builtin-true [PASS])"
do_run "$(build_run_repo '42')"
assert_eq "$(blocked)" "blocked" "F1: scalar command:42 (JSON number) => fail-closed"

# F2 [HIGH]: a malformed `when` TYPE (object / array-of-arrays) was value-iterated, dropping the real
# pathspecs, so the suite silently skipped. The fixed brace/magic guards only cover string ELEMENTS.
# command:true so the ONLY way this blocks is the validator rejecting the non-array when (a "false" command
# would also block via fail-safe RUN, masking a validator regression — R2 test-teeth finding).
do_run "$(build_run_repo '[{"command":"true","when":{"src":"x"}}]')"
assert_eq "$(blocked)" "blocked" "F2: array suite when:{object} => fail-closed by the validator (teeth: command is true)"
do_run "$(build_run_repo '[{"command":"false","when":[["*.rules"]]}]')"
assert_eq "$(blocked)" "blocked" "F2: array suite when:[[...]] (array-of-arrays) => fail-closed"
do_run "$(build_run_repo '[{"command":"false","when":[123]}]')"
assert_eq "$(blocked)" "blocked" "F2: array suite when:[123] (non-string element) => fail-closed"

# F3 [HIGH]: a scalar-typed gate ("tests":"npm test" instead of an object) made every .enabled read jq-error
# => empty => [SKIP] disabled => exit 0. sg_guard_config only checked .mainBranch, not gate structure.
G=$(mktemp -d); ( cd "$G" && git init -q && git config user.email t@t && git config user.name t && git branch -M main \
  && printf '%s' '{"mainBranch":"main","gates":{"tests":"npm test","lint":{"enabled":false},"typecheck":{"enabled":false},"build":{"enabled":false},"secretScan":{"enabled":false}}}' > .shipgate.json \
  && git add . && git commit -q -m init && git checkout -q -b feature && printf c > code.ts && git add code.ts && git commit -q -m w ) >/dev/null 2>&1
do_run "$G"
assert_eq "$(blocked)" "blocked" "F3: scalar gate (tests:\"npm test\") => fail-closed, not silently disabled"
GA=$(mktemp -d); ( cd "$GA" && git init -q && git config user.email t@t && git config user.name t && git branch -M main \
  && printf '%s' '{"mainBranch":"main","gates":"all"}' > .shipgate.json \
  && git add . && git commit -q -m init && git checkout -q -b feature && printf c > code.ts && git add code.ts && git commit -q -m w ) >/dev/null 2>&1
do_run "$GA"
assert_eq "$(blocked)" "blocked" "F3: scalar .gates (total bypass) => fail-closed"

# F4 [MEDIUM]: `when` pathspecs were anchored to <dir> not the repo root. A subdir-placed .shipgate.json whose
# suite matches a repo-root/sibling file silently skipped (looked for <subdir>/<pathspec>).
S=$(mktemp -d); ( cd "$S" && git init -q && git config user.email t@t && git config user.name t && git branch -M main \
  && mkdir -p app shared && printf '%s' '{"mainBranch":"main","gates":{"tests":{"enabled":true,"command":[{"command":"false","when":["shared"]}]},"lint":{"enabled":false},"typecheck":{"enabled":false},"build":{"enabled":false},"secretScan":{"enabled":false}}}' > app/.shipgate.json \
  && git add . && git commit -q -m init && git checkout -q -b feature && printf c > shared/util.ts && git add shared/util.ts && git commit -q -m work ) >/dev/null 2>&1
do_run "$S/app"
assert_eq "$(blocked)" "blocked" "F4: subdir config, when:[shared] matches a repo-root file => suite RUNS (root-anchored) => fails gate"

# F5 [LOW]: a present-but-non-boolean `enabled` (0/null/1/[]) was string-compared to "true" => silently OFF.
E=$(mktemp -d); ( cd "$E" && git init -q && git config user.email t@t && git config user.name t && git branch -M main \
  && printf '%s' '{"mainBranch":"main","gates":{"tests":{"enabled":0,"command":"false"},"lint":{"enabled":false},"typecheck":{"enabled":false},"build":{"enabled":false},"secretScan":{"enabled":false}}}' > .shipgate.json \
  && git add . && git commit -q -m init && git checkout -q -b feature && printf c > code.ts && git add code.ts && git commit -q -m w ) >/dev/null 2>&1
do_run "$E"
assert_eq "$(blocked)" "blocked" "F5: enabled:0 (non-boolean) => fail-closed, not silently disabled"

# ---------------------------------------------------------------------------------------------------------
# Deep-review ROUND 2 (2026-06-20). The round-1 empty-string fixes left whitespace one transformation away:
# a WHITESPACE command no-op-passes (length>0 counts spaces); a WHITESPACE `when` matches nothing => silent
# skip. A whitespace COMMAND is a config error => fail-closed; a whitespace WHEN can't scope => fail-safe RUN.
# ---------------------------------------------------------------------------------------------------------
do_run "$(build_run_repo '"   "')"
assert_eq "$(blocked)" "blocked" "R2: whitespace-only STRING command => fail-closed (not eval-no-op [PASS])"
do_run "$(build_run_repo '[{"command":"   "}]')"
assert_eq "$(blocked)" "blocked" "R2: whitespace-only SUITE command => fail-closed"
do_run "$(build_run_repo '[{"command":"false","when":["   "]}]')"
assert_eq "$(blocked)" "blocked" "R2: whitespace-only when => fail-safe RUN (suite runs) => failing gate blocks"
do_run "$(build_run_repo '[{"command":"true","when":["  ","\t"]}]')"
assert_eq "$run_rc" "0" "R2 control: whitespace when + passing suite => suite runs (fail-safe) and passes"
assert_contains "$run_out" "tests[0]: true" "R2 control teeth: whitespace when => the suite actually RAN (not silently skipped)"

# ---------------------------------------------------------------------------------------------------------
# Deep-review ROUND 3 (2026-06-20).
# F1: a UNICODE-whitespace `when` (NBSP U+00A0) defeated the bash ASCII-only [:space:] trim (C locale) while
#     the jq validator's gsub is Unicode-aware => silent skip. Trim is now done in jq (locale-independent).
# F2: the structural guard was shared by `detect`, so a malformed config made detect (a read-only scaffold
#     helper that never gates) exit 2 — breaking /ship-init's repair path. detect must tolerate it; only `run`
#     (the push-gating path) fail-closes on structure.
# ---------------------------------------------------------------------------------------------------------
do_run "$(build_run_repo '[{"command":"false","when":[" "]}]')"
assert_eq "$(blocked)" "blocked" "R3 F1: NBSP-only when => fail-safe RUN (suite runs) => failing gate blocks"

DM=$(mktemp -d); ( cd "$DM" && git init -q && git config user.email t@t && git config user.name t && git branch -M main \
  && printf '{"name":"x"}' > package.json && printf '%s' '{"gates":{"tests":{"enabled":"yes"}}}' > .shipgate.json ) >/dev/null 2>&1
det_rc=0; det_out=$(bash "$SG" detect "$DM" 2>/dev/null) || det_rc=$?
assert_eq "$det_rc" "0" "R3 F2: detect on a structurally-malformed config still scaffolds (exit 0), not fail-closed"
assert_contains "$det_out" "npm test" "R3 F2: detect still surfaces the detected command despite the broken config"
do_run "$DM"
assert_eq "$(blocked)" "blocked" "R3 F2 control: run on the SAME malformed config STILL fail-closes (structural guard kept on the gating path)"

# ---------------------------------------------------------------------------------------------------------
# Deep-review ROUND 4. A git EXCLUDE pathspec (:!*.md) is a REAL, evaluable pathspec — NOT an unmatchable typo
# — so it scopes normally: the suite runs on any non-excluded change, and is correctly skipped only when EVERY
# changed file is excluded. (Round-3's schema docstring wrongly lumped "exclude-only" with whitespace; fixed.)
# ---------------------------------------------------------------------------------------------------------
EX=$(mktemp -d); ( cd "$EX" && git init -q && git config user.email t@t && git config user.name t && git branch -M main \
  && printf '%s' '{"mainBranch":"main","gates":{"tests":{"enabled":true,"command":[{"command":"false","when":[":!*.md"]}]},"lint":{"enabled":false},"typecheck":{"enabled":false},"build":{"enabled":false},"secretScan":{"enabled":false}}}' > .shipgate.json \
  && git add . && git commit -q -m init && git checkout -q -b feature && printf c > code.ts && git add code.ts && git commit -q -m work ) >/dev/null 2>&1
do_run "$EX"
assert_eq "$(blocked)" "blocked" "R4: exclude when :!*.md + a non-md change (code.ts) => suite IN scope => failing gate blocks"

EX2=$(mktemp -d); ( cd "$EX2" && git init -q && git config user.email t@t && git config user.name t && git branch -M main \
  && printf '%s' '{"mainBranch":"main","gates":{"tests":{"enabled":true,"command":[{"command":"false","when":[":!*.md"]}]},"lint":{"enabled":false},"typecheck":{"enabled":false},"build":{"enabled":false},"secretScan":{"enabled":false}}}' > .shipgate.json \
  && git add . && git commit -q -m init && git checkout -q -b feature && printf d > readme.md && git add readme.md && git commit -q -m docs ) >/dev/null 2>&1
do_run "$EX2"
assert_eq "$run_rc" "0" "R4: exclude when :!*.md + ONLY a .md change => correctly out of scope => suite skips => gate passes"

assert_summary
