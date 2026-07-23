#!/usr/bin/env bash
# Config-drift detection (2026-07-23): a gate DISABLED in .shipgate.json while the repo has since grown
# real capability for it (a test suite, a lint config, a tsconfig, a build script) used to be
# INDISTINGUISHABLE from a legitimately-not-applicable disabled gate — both printed a plain
# `[SKIP] <gate> (disabled)` line. Real-world origin: a repo's .shipgate.json was committed "docs-only,
# tests off" when true; the repo grew a pytest suite + 8 Python files; the config never caught up; `/ship`
# on a 20-commit push reported clean gates while never running the 174-test suite. This is the OTHER HALF
# of spec §16 ("no silent pass on a missing command" covers an ENABLED gate with nothing to run; this
# covers a DISABLED gate with something TO run).
#
# Design (argued, not assumed — see DECISIONS.md for the full writeup):
#   - Detection is CHEAP: reuses the existing root-marker auto-detect (sg_detect_*_cmd) first, and only
#     falls back to a filename-pattern scan (no execution, ever) when that's empty — this is what catches
#     the real-world case above, where the suite lives in a subdir with no root-level marker.
#   - `[DRIFT]` (no `reason` recorded on the gate) is a DIFFERENT signal from `[SKIP]`, distinct enough
#     that /ship's orchestration (SKILL.md) PAUSES for an explicit acknowledgment — same weight as the
#     existing "no command detected" guard for an ENABLED gate.
#   - `[DRIFT-ACK]` (a `reason` IS recorded) does NOT pause — the human already made and DATED a conscious
#     decision; nagging every ship for something already decided is exactly the "trains people to ignore
#     the line" failure mode flagged when this was scoped. It still prints every time (the premise is no
#     longer buried in a commit message from eight weeks ago), so a stale reason can be caught by eye.
#   - A legitimately-not-applicable gate (nothing detected) stays a plain, silent `[SKIP]` — unchanged.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/assert.sh"; . "$DIR/../lib/config.sh"; . "$DIR/../lib/detect.sh"
SG="$DIR/../ship-gate.sh"

# ---------------------------------------------------------------------------------------------------------
# sg_detect_capability <dir> <gate> — cheap FS-only signal, no execution. Empty when nothing detected.
# ---------------------------------------------------------------------------------------------------------
EMPTY=$(mktemp -d)
assert_eq "$(sg_detect_capability "$EMPTY" tests)" "" "capability: empty dir => no tests signal"
assert_eq "$(sg_detect_capability "$EMPTY" lint)" "" "capability: empty dir => no lint signal"
assert_eq "$(sg_detect_capability "$EMPTY" typecheck)" "" "capability: empty dir => no typecheck signal"
assert_eq "$(sg_detect_capability "$EMPTY" build)" "" "capability: empty dir => no build signal"

# tests: root marker present (package.json) => detected via the existing root-detect path.
ROOTNODE=$(mktemp -d); echo '{}' > "$ROOTNODE/package.json"
assert_contains "$(sg_detect_capability "$ROOTNODE" tests)" "npm test" "capability: root package.json => tests via root marker"

# tests: NO root marker, but a nested pytest suite (the real-world LinkedIn-repo shape: tests live under
# .claude/scripts/, no pyproject.toml/requirements*.txt anywhere) => still detected via the filename scan.
NESTEDPY=$(mktemp -d); mkdir -p "$NESTEDPY/.claude/scripts"
: > "$NESTEDPY/.claude/scripts/test_foo.py"; : > "$NESTEDPY/.claude/scripts/test_bar.py"
cap=$(sg_detect_capability "$NESTEDPY" tests)
assert_contains "$cap" "test_" "capability: nested test_*.py files detected with no root marker"
assert_contains "$cap" "2" "capability: nested-scan message includes a count"

# tests: node_modules is excluded from the fallback scan (a dependency's own tests are not the user's suite).
NM=$(mktemp -d); mkdir -p "$NM/node_modules/dep"; : > "$NM/node_modules/dep/foo.test.js"
assert_eq "$(sg_detect_capability "$NM" tests)" "" "capability: node_modules excluded from tests scan"

# GIT-IGNORED paths must NOT count (found by dogfooding against the repo that motivated this feature: it
# has linked worktrees under a git-excluded .claude/worktrees/ holding COPIES of the real suite, so a raw
# filesystem scan reported 8 test files and named an untracked worktree copy as the example, when the real
# tracked suite is 5 files). The gate cares about the repo's own code, so candidate discovery must respect
# .gitignore AND .git/info/exclude — i.e. git's own view — falling back to a plain scan outside a repo.
# NOTE the ignored dir here is `thirdparty/`, NOT `vendor/` — `vendor/` is pruned unconditionally (see the
# separate vendor assert below), so using it here would make this test pass for the wrong reason and stop
# exercising .gitignore at all.
GI=$(mktemp -d); git -C "$GI" init -q
git -C "$GI" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$GI/src" "$GI/thirdparty/copy"
: > "$GI/src/test_real.py"                     # tracked-able, counts
: > "$GI/thirdparty/copy/test_copy.py"         # ignored, must NOT count
printf 'thirdparty/\n' > "$GI/.gitignore"
gicap=$(sg_detect_capability "$GI" tests)
assert_contains "$gicap" "1 test file(s)" "capability: git-ignored paths excluded from the count"
assert_contains "$gicap" "src/test_real.py" "capability: the named example is a real (non-ignored) file"
case "$gicap" in *thirdparty*) assert_eq "leaked-ignored" "excluded" "capability: an ignored path must never be named as the example";; *) : ;; esac

# Vendored third-party code is pruned even when TRACKED (Go's `go mod vendor` output is routinely committed
# and is full of *_test.go). Counting a dependency's tests as "this repo grew a suite" is a false positive.
VD=$(mktemp -d); git -C "$VD" init -q
mkdir -p "$VD/vendor/dep" "$VD/app"
: > "$VD/vendor/dep/thing_test.go"; : > "$VD/app/main_test.go"
git -C "$VD" add -A >/dev/null 2>&1
git -C "$VD" -c user.email=t@t -c user.name=t commit -qm vendored
vdcap=$(sg_detect_capability "$VD" tests)
assert_contains "$vdcap" "1 test file(s)" "capability: tracked vendor/ pruned (dependency tests are not the repo's suite)"
case "$vdcap" in *vendor*) assert_eq "counted-vendor" "pruned" "capability: vendor/ must never be the named example";; *) : ;; esac

# agy review #5 (CONFIRMED): `git ls-files` QUOTES paths containing non-ASCII bytes ("dir/t\303\251st.py"),
# so a raw read both fails the *.py pattern match (trailing quote) and would print a mangled example path.
# `-z` + `read -d ''` returns the true byte-exact path. Without this, a non-ASCII-named test file is INVISIBLE
# to drift detection — a silent miss, the exact failure mode this feature exists to prevent.
# (The fixture keeps a VALID `test_` prefix and puts the non-ASCII bytes in the rest of the name — a name
# like `tést_x.py` would fail the convention check on its own merits and prove nothing about quoting.)
UNI=$(mktemp -d); git -C "$UNI" init -q; mkdir -p "$UNI/dir"
: > "$UNI/dir/test_café_señor.py"
unicap=$(sg_detect_capability "$UNI" tests)
assert_contains "$unicap" "1 test file(s)" "capability: non-ASCII filename detected (git -z, not quoted output)"
assert_contains "$unicap" "test_café_señor.py" "capability: non-ASCII example path is byte-exact, not backslash-escaped"
case "$unicap" in *'\3'*) assert_eq "escaped" "byte-exact" "capability: example must not contain git's octal escapes";; *) : ;; esac

# agy review #6 (CONFIRMED): `git ls-files --cached` lists INDEX entries, so a test file deleted on disk but
# not yet staged still appeared — inflating the count and naming a file that no longer exists.
DEL=$(mktemp -d); git -C "$DEL" init -q; mkdir -p "$DEL/t"
: > "$DEL/t/test_gone.py"; : > "$DEL/t/test_here.py"
git -C "$DEL" add -A >/dev/null 2>&1
git -C "$DEL" -c user.email=t@t -c user.name=t commit -qm both
rm "$DEL/t/test_gone.py"
delcap=$(sg_detect_capability "$DEL" tests)
assert_contains "$delcap" "1 test file(s)" "capability: tracked-but-deleted file not counted"
case "$delcap" in *test_gone*) assert_eq "named-missing" "skipped" "capability: a file absent from disk must never be the named example";; *) : ;; esac

# agy review #7 (CONFIRMED): when $d is a plain directory sitting inside a PARENT repo's ignored path,
# `git rev-parse` succeeds (it finds the parent's .git) but `ls-files` under $d returns NOTHING, so the git
# branch reported zero capability while real test files sat right there — a silent miss. If git can see no
# files at all under $d, git is not governing that tree: fall back to the plain filesystem scan.
PAR=$(mktemp -d); git -C "$PAR" init -q
git -C "$PAR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'ignored/\n' > "$PAR/.gitignore"; mkdir -p "$PAR/ignored/proj/src"
: > "$PAR/ignored/proj/src/test_thing.py"
parcap=$(sg_detect_capability "$PAR/ignored/proj" tests)
assert_contains "$parcap" "1 test file(s)" "capability: dir inside a parent repo's ignored path still scanned (no silent miss)"

# agy review #4 (CONFIRMED): a trailing slash on $d broke the find-fallback prefix strip, so the root
# Makefile came back as an absolute path, matched the `*/*` nested-check, and was silently dropped.
TS=$(mktemp -d); : > "$TS/Makefile"
assert_contains "$(sg_detect_capability "$TS" build)" "1 build file(s)" "capability: root Makefile detected (no trailing slash)"
assert_contains "$(sg_detect_capability "$TS/" build)" "1 build file(s)" "capability: root Makefile still detected WITH a trailing slash on the dir"

# agy review #8 (test hygiene): assert the RETURN STATUS explicitly on the no-capability path, not just the
# empty string. A crash inside `$(...)` also yields "", so an equality-only assert would pass on a crash.
ERC=$(mktemp -d); ercout=$(sg_detect_capability "$ERC" tests); erc=$?
assert_eq "$erc" "0" "capability: returns 0 (not a set -e abort) when nothing is detected"
assert_eq "$ercout" "" "capability: emits nothing when nothing is detected"

# .git/info/exclude (not just .gitignore) is honored too — that is what the motivating repo actually used.
IE=$(mktemp -d); git -C "$IE" init -q
git -C "$IE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$IE/app" "$IE/wt/nested"
: > "$IE/app/test_keep.py"; : > "$IE/wt/nested/test_drop.py"
printf 'wt/\n' >> "$IE/.git/info/exclude"
iecap=$(sg_detect_capability "$IE" tests)
assert_contains "$iecap" "1 test file(s)" "capability: .git/info/exclude honored (the motivating repo's real mechanism)"
assert_contains "$iecap" "app/test_keep.py" "capability: example comes from the non-excluded path"

# Outside a git repo the plain filesystem scan still works (no regression for a non-repo directory).
NR=$(mktemp -d); mkdir -p "$NR/pkg"; : > "$NR/pkg/test_plain.py"
assert_contains "$(sg_detect_capability "$NR" tests)" "1 test file(s)" "capability: non-git directory still scanned via find"

# lint: no root marker, but a nested .eslintrc => detected.
LINTNEST=$(mktemp -d); mkdir -p "$LINTNEST/sub"; : > "$LINTNEST/sub/.eslintrc.json"
assert_contains "$(sg_detect_capability "$LINTNEST" lint)" ".eslintrc" "capability: nested lint config detected"

# typecheck: a nested tsconfig.json (no root tsconfig) => detected.
TCNEST=$(mktemp -d); mkdir -p "$TCNEST/app"; : > "$TCNEST/app/tsconfig.json"
assert_contains "$(sg_detect_capability "$TCNEST" typecheck)" "tsconfig.json" "capability: nested tsconfig detected"

# build: a nested package.json with a build script (no root package.json) => detected.
BUILDNEST=$(mktemp -d); mkdir -p "$BUILDNEST/pkg"
printf '%s' '{"scripts":{"build":"tsc"}}' > "$BUILDNEST/pkg/package.json"
assert_contains "$(sg_detect_capability "$BUILDNEST" build)" "package.json" "capability: nested build script detected"

# build: a nested package.json with NO build script must not false-positive.
BUILDNONE=$(mktemp -d); mkdir -p "$BUILDNONE/pkg"
printf '%s' '{"scripts":{"test":"x"}}' > "$BUILDNONE/pkg/package.json"
assert_eq "$(sg_detect_capability "$BUILDNONE" build)" "" "capability: nested package.json without a build script => no signal"

# ---------------------------------------------------------------------------------------------------------
# `ship-gate.sh run` integration — [DRIFT] / [DRIFT-ACK] / plain [SKIP], per gate.reason.
# ---------------------------------------------------------------------------------------------------------
mk_git_repo(){ local d; d=$(mktemp -d); git -C "$d" init -q; git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; printf '%s\n' "$d"; }

# Case A: tests disabled, repo has a nested pytest suite, NO reason recorded => [DRIFT], not silent [SKIP].
A=$(mk_git_repo); mkdir -p "$A/.claude/scripts"; : > "$A/.claude/scripts/test_x.py"
cat > "$A/.shipgate.json" <<'JSON'
{ "gates": { "tests": {"enabled": false}, "lint": {"enabled": false}, "typecheck": {"enabled": false} } }
JSON
arc=0; aout=$(bash "$SG" run "$A" 2>&1) || arc=$?
assert_contains "$aout" "[DRIFT] tests:" "run: disabled tests + detected capability => [DRIFT] line"
assert_contains "$aout" "test_x.py" "run: [DRIFT] line names the detected evidence"
assert_contains "$aout" "/ship doctor" "run: [DRIFT] line points at the fix-it tool"
case "$aout" in *"[SKIP] tests"*) assert_eq "silent-skip" "no-silent-skip" "run: tests must NOT ALSO print a plain [SKIP] when DRIFT fires";; *) : ;; esac

# Case B: same repo shape, but lint/typecheck have nothing to detect (no .eslintrc, no tsconfig anywhere)
# => plain [SKIP], never [DRIFT] — a legitimately-not-applicable disabled gate must stay quiet.
assert_contains "$aout" "[SKIP] lint (disabled)" "run: lint disabled + nothing detected => plain silent [SKIP]"
assert_contains "$aout" "[SKIP] typecheck (disabled)" "run: typecheck disabled + nothing detected => plain silent [SKIP]"

# Case C: tests disabled WITH a recorded reason => [DRIFT-ACK], not [DRIFT] — a conscious, dated decision
# is a different (lower-friction) signal, not a silent skip either.
C=$(mk_git_repo); mkdir -p "$C/.claude/scripts"; : > "$C/.claude/scripts/test_y.py"
cat > "$C/.shipgate.json" <<'JSON'
{ "gates": { "tests": {"enabled": false, "reason": "docs-only repo", "since": "2026-06-13"}, "lint": {"enabled": false}, "typecheck": {"enabled": false} } }
JSON
crc=0; cout=$(bash "$SG" run "$C" 2>&1) || crc=$?
assert_contains "$cout" "[DRIFT-ACK] tests:" "run: reason recorded => [DRIFT-ACK], not [DRIFT]"
assert_contains "$cout" "docs-only repo" "run: [DRIFT-ACK] line surfaces the recorded reason"
case "$cout" in *"[DRIFT] tests:"*) assert_eq "wrong-tag" "driftack" "run: must not ALSO emit a plain [DRIFT] tag when reason is set";; *) : ;; esac

# Case D: gate ENABLED => runner behavior is completely unaffected (no drift text can appear for an
# enabled gate; back-compat is total). Use a real command so the gate passes.
D=$(mk_git_repo)
cat > "$D/.shipgate.json" <<'JSON'
{ "gates": { "tests": {"enabled": true, "command": "true"}, "lint": {"enabled": false}, "typecheck": {"enabled": false} } }
JSON
drc=0; dout=$(bash "$SG" run "$D" 2>&1) || drc=$?
assert_eq "$drc" "0" "run: enabled gate with a passing command still exits 0 (unaffected by drift logic)"
case "$dout" in *"DRIFT"*) assert_eq "drift-on-enabled" "no-drift" "run: an ENABLED gate must never emit DRIFT text";; *) : ;; esac

# Case E: disabled + nothing detected anywhere (a genuinely non-applicable repo) => stays a plain [SKIP],
# not [DRIFT] — the core no-false-positive contract.
E=$(mk_git_repo)
cat > "$E/.shipgate.json" <<'JSON'
{ "gates": { "tests": {"enabled": false}, "lint": {"enabled": false}, "typecheck": {"enabled": false} } }
JSON
erc=0; eout=$(bash "$SG" run "$E" 2>&1) || erc=$?
assert_contains "$eout" "[SKIP] tests (disabled)" "run: disabled + no capability anywhere => plain [SKIP] (no false positive)"
case "$eout" in *"DRIFT"*) assert_eq "false-positive" "no-drift" "run: no capability => must never emit DRIFT";; *) : ;; esac

# ---------------------------------------------------------------------------------------------------------
# `ship-gate.sh doctor` — config-aware audit (extends the existing filesystem-only checks). Reads
# .shipgate.json when present; ALWAYS exits 0 (advisory); proposes a concrete fix using the SAME
# auto-detect the runner itself would use, so the suggestion is never fabricated.
# ---------------------------------------------------------------------------------------------------------
# Root-marker case: doctor can propose a real command.
F=$(mk_git_repo); echo '{"scripts":{"test":"vitest run"}}' > "$F/package.json"
cat > "$F/.shipgate.json" <<'JSON'
{ "gates": { "tests": {"enabled": false} } }
JSON
frc=0; fout=$(bash "$SG" doctor "$F" 2>&1) || frc=$?
assert_eq "$frc" "0" "doctor: config-drift audit still exits 0 (advisory)"
assert_contains "$fout" "config drift: tests disabled" "doctor: names the drifted gate"
assert_contains "$fout" "\"enabled\": true" "doctor: proposes a concrete enable-fix"
assert_contains "$fout" "npm test" "doctor: proposed fix uses the REAL auto-detected command (root marker => '<pm> test'), not a placeholder"

# No-root-marker case: doctor is honest that it can't auto-fill a command (never fabricates one).
G=$(mk_git_repo); mkdir -p "$G/.claude/scripts"; : > "$G/.claude/scripts/test_z.py"
cat > "$G/.shipgate.json" <<'JSON'
{ "gates": { "tests": {"enabled": false} } }
JSON
gout=$(bash "$SG" doctor "$G" 2>&1)
assert_contains "$gout" "config drift: tests disabled" "doctor: flags drift even with no root marker"
assert_contains "$gout" "inspect repo and set manually" "doctor: honest placeholder when no command can be auto-detected"

# Reason recorded => doctor shows the ack framing, not the enable-fix suggestion.
H=$(mk_git_repo); mkdir -p "$H/.claude/scripts"; : > "$H/.claude/scripts/test_h.py"
cat > "$H/.shipgate.json" <<'JSON'
{ "gates": { "tests": {"enabled": false, "reason": "legacy scripts, not maintained", "since": "2026-01-01"} } }
JSON
hout=$(bash "$SG" doctor "$H" 2>&1)
assert_contains "$hout" "reason: \"legacy scripts, not maintained\"" "doctor: surfaces the recorded reason verbatim"
assert_contains "$hout" "reconsider if stale" "doctor: ack framing prompts a periodic re-check, not a re-nag"

# Enabled gates are never audited for drift (nothing to fix if it's already on).
I=$(mk_git_repo); echo '{"scripts":{"test":"vitest run"}}' > "$I/package.json"
cat > "$I/.shipgate.json" <<'JSON'
{ "gates": { "tests": {"enabled": true} } }
JSON
iout=$(bash "$SG" doctor "$I" 2>&1)
case "$iout" in *"config drift: tests"*) assert_eq "audited" "not-audited" "doctor: an ENABLED gate must never be flagged as drifted";; *) : ;; esac

# No .shipgate.json at all — doctor's existing filesystem-only behavior must be completely unaffected.
J=$(mk_git_repo)
jrc=0; jout=$(bash "$SG" doctor "$J" 2>&1) || jrc=$?
assert_eq "$jrc" "0" "doctor: no-config repo still exits 0"
case "$jout" in *"config drift"*) assert_eq "audited" "not-audited" "doctor: no .shipgate.json => no config-drift lines at all (nothing to audit against)";; *) : ;; esac

# ---------------------------------------------------------------------------------------------------------
# sg_config_structure_ok must accept the new optional `reason`/`since` gate properties (additive; runtime
# validator must not fail-close a config that merely documents WHY a gate is off).
# ---------------------------------------------------------------------------------------------------------
K=$(mk_git_repo)
cat > "$K/.shipgate.json" <<'JSON'
{ "gates": { "tests": {"enabled": false, "reason": "docs-only", "since": "2026-06-13"} } }
JSON
okrc=0; sg_config_structure_ok "$K" || okrc=$?
assert_eq "$okrc" "0" "config: reason/since on a gate is structurally valid (does not fail-closed)"

assert_summary
