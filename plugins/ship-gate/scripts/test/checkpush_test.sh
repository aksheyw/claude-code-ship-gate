#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/assert.sh"; CP="$DIR/../check-push.sh"
R=$(mktemp -d); cd "$R"; git init -q; git commit -q --allow-empty -m init; git branch -M main 2>/dev/null || true
# Hermetic global config: a path OUTSIDE any test repo. Absent by default => "no global config"
# => the hook behaves as opt-in (today's behavior). Tests that need default-on/master-kill write to
# "$GCFG_TEST" and rm it afterward. NEVER read the developer's real ~/.shipgate.json.
GCFG_TEST="$(mktemp -u)"
# Opt-in: the repo must contain a .shipgate.json or the hook allows everything (Task 7.1).
printf '{"mainBranch":"main"}' > .shipgate.json
run(){  printf '{"tool_input":{"command":"%s"}}' "$1" | SHIPGATE_GLOBAL_CONFIG="$GCFG_TEST" bash "$CP"; }
# runj(): safe JSON for commands that themselves contain quotes (naive printf would emit invalid JSON).
runj(){ printf '%s' "$1" | jq -Rsc '{tool_input:{command: .}}' | SHIPGATE_GLOBAL_CONFIG="$GCFG_TEST" bash "$CP"; }
# --- On main, NO marker: pushes to main must be DENIED in all its forms ---
assert_contains "$(run 'git push origin main')"      "deny" "push origin main (no marker) => deny"
assert_contains "$(run 'git push')"                  "deny" "bare push while on main (no marker) => deny"
assert_contains "$(run 'git push -u origin main')"   "deny" "push -u origin main => deny"
assert_contains "$(run 'git push origin HEAD:main')" "deny" "push HEAD:main => deny"
# --- Non-push and non-main are ALLOWED (no output) ---
assert_eq "$(run 'git status')"                      ""     "non-push (git status) => allow (no output)"
assert_eq "$(run 'git commit -m x')"                 ""     "git commit => allow (no output)"
git checkout -q -b feature/x
assert_eq "$(run 'git push origin feature/x')"       ""     "feature-branch push => allow (no output)"
assert_eq "$(run 'git push')"                        ""     "bare push while on feature => allow (no output)"
# --- On main WITH a fresh valid marker: allowed ---
git checkout -q main
mkdir -p .git/shipgate
printf '{"head":"%s","branch":"main","ts":%s,"hotfix":false}' "$(git rev-parse HEAD)" "$(date +%s)" > .git/shipgate/last-pass.json
assert_eq "$(run 'git push origin main')"            ""     "push main WITH fresh marker => allow (no output)"
# --- On main, EXPIRED marker: denied again ---
printf '{"head":"%s","branch":"main","ts":1,"hotfix":false}' "$(git rev-parse HEAD)" > .git/shipgate/last-pass.json
assert_contains "$(run 'git push origin main')"      "deny" "push main with EXPIRED marker => deny"

# ============================================================
# TASK B — push detection is command-position-aware
# ============================================================
# On main, NO marker (a gated repo). These ARE git pushes and must DENY.
rm -f "$R/.git/shipgate/last-pass.json"
git checkout -q main
assert_contains "$(run 'cd subdir && git push')"     "deny" "B: 'cd subdir && git push' (segment starts with git push) => deny"
assert_contains "$(run 'git -C /some/path push')"    "deny" "B: 'git -C /some/path push' (global opt before push) => deny (evaluated against CWD)"
assert_contains "$(run 'git -c user.name=x push origin main')" "deny" "B: 'git -c kv push' (global -c opt) => deny"
assert_contains "$(run 'git --no-pager push origin main')"     "deny" "B: 'git --no-pager push' (boolean global opt) => deny"
# FALSE POSITIVE guards: a bare mention of 'git push' inside a string is NOT a push.
# These must ALLOW (no output) even on main with NO marker.
assert_eq "$(runj 'git commit -m "...git push..."')" "" "B: commit message containing 'git push' => allow (no output)"
assert_eq "$(runj 'echo "git push"')"                "" "B: echo of a quoted 'git push' => allow (no output)"
assert_eq "$(run 'echo git push later')"             "" "B: 'echo git push later' (first word is echo) => allow (no output)"
# SINGLE-quote mention must also allow (locks the octal \047 single-quote handling in awk).
SQ_CMD=$(printf "echo 'git push now'")
assert_eq "$(runj "$SQ_CMD")"                        "" "B: echo of a SINGLE-quoted 'git push' => allow (octal-quote handling)"

# ============================================================
# FIND 1 — .shipgate.json mainBranch / markerTtlSeconds ignored
# ============================================================
# Build a separate repo where mainBranch is "trunk"
R2=$(mktemp -d); cd "$R2"
git init -q; git commit -q --allow-empty -m init
git branch -M trunk 2>/dev/null || git checkout -q -b trunk
printf '{"mainBranch":"trunk"}' > .shipgate.json

# Push to "trunk" with no marker: MUST be denied (trunk IS the configured main)
assert_contains "$(run 'git push origin trunk')"  "deny" "F1: push to configured mainBranch=trunk (no marker) => deny"

# Control: on a non-trunk branch, push to "main" — "main" is neither the configured MAIN
# nor the current branch, so it is NOT the push destination for the protected branch.
git checkout -q -b feature/r2
assert_eq "$(run 'git push origin main')" "" "F1: push to 'main' when mainBranch=trunk (on feature branch) => allow (no output)"
git checkout -q trunk

# Custom markerTtlSeconds: marker ts=1 (ancient), ttl=1 → expired → deny
mkdir -p .git/shipgate
printf '{"head":"%s","branch":"trunk","ts":1,"hotfix":false}' "$(git rev-parse HEAD)" > .git/shipgate/last-pass.json
printf '{"mainBranch":"trunk","markerTtlSeconds":1}' > .shipgate.json
assert_contains "$(run 'git push origin trunk')" "deny" "F1: custom markerTtlSeconds=1 + ancient marker => deny (expired)"

# ============================================================
# FIND 2 — marker.branch is not validated
# ============================================================
cd "$R"  # back to the original main repo (on main)
git checkout -q main
# Write a marker where head == HEAD, ts is fresh, but branch is "feature/x"
mkdir -p .git/shipgate
printf '{"head":"%s","branch":"feature/x","ts":%s,"hotfix":false}' \
  "$(git rev-parse HEAD)" "$(date +%s)" > .git/shipgate/last-pass.json
assert_contains "$(run 'git push origin main')" "deny" "F2: marker.branch=feature/x vs target=main => deny (branch mismatch)"

# ============================================================
# FIND 3 — +main and feature:main refspecs evade detection
# ============================================================
# Remove any valid marker so we're purely testing refspec detection
rm -f "$R/.git/shipgate/last-pass.json"

git checkout -q -b feature/y  # on a feature branch now (CUR != main)

assert_contains "$(run 'git push origin +main')"       "deny" "F3: push origin +main (force) => detected as main push => deny"
assert_contains "$(run 'git push origin feature/y:main')" "deny" "F3: push origin feature/y:main => detected as main push => deny"
assert_contains "$(run 'git push origin +feature/y:main')" "deny" "F3: push origin +feature/y:main => detected as main push => deny"

# Control: main as SOURCE (main:other) while NOT on main => allow.
# Must stay on feature/y (CUR != main) so the hook can't gate via CUR=MAIN.
# The regex [ /+:]main(\s|$) does NOT match "main:other-branch" (token ends with ':'),
# so TARGET stays as CUR (feature/y) != MAIN, and the hook allows it.
assert_eq "$(run 'git push origin main:other-branch')" "" "F3: push origin main:other-branch (on feature/y) => main is source => allow"

# ============================================================
# OPT-IN — a repo with no .shipgate.json is NOT gated (Task 7.1, the root fix)
# ============================================================
# Fresh repo, on main, NO marker — but ALSO no .shipgate.json => must ALLOW (not opted in).
OPTOUT_REPO=$(mktemp -d); cd "$OPTOUT_REPO"
git init -q; git commit -q --allow-empty -m init; git branch -M main 2>/dev/null || true
assert_eq "$(run 'git push origin main')" "" "OPT-IN: push to main with NO .shipgate.json => allow (repo not opted in)"
# Now add a .shipgate.json with top-level enabled:false => opted out => still allow.
printf '{"mainBranch":"main","enabled":false}' > .shipgate.json
assert_eq "$(run 'git push origin main')" "" "OPT-IN: .shipgate.json with enabled:false => allow (opted out)"
# Flip enabled:true => gated again; on main, no marker => deny.
printf '{"mainBranch":"main","enabled":true}' > .shipgate.json
assert_contains "$(run 'git push origin main')" "deny" "OPT-IN: .shipgate.json with enabled:true => gated => deny (no marker)"

# ============================================================
# FIND 4 — self-containment: hook must work without lib/ directory
# ============================================================
# Copy ONLY check-push.sh into an isolated temp dir (no lib/ at all).
# Run it inside a fresh real git repo on main with no marker.
# It MUST emit deny — not crash/fail-open. The repo must opt in (.shipgate.json present).
ISO=$(mktemp -d)
cp "$DIR/../check-push.sh" "$ISO/check-push.sh"
ISO_REPO=$(mktemp -d); cd "$ISO_REPO"
git init -q; git commit -q --allow-empty -m init; git branch -M main 2>/dev/null || true
printf '{"mainBranch":"main"}' > .shipgate.json
# run the isolated copy (no lib/ exists next to it)
ISO_OUT=$(printf '{"tool_input":{"command":"git push origin main"}}' | SHIPGATE_GLOBAL_CONFIG="$(mktemp -u)" bash "$ISO/check-push.sh" 2>&1)
assert_contains "$ISO_OUT" "deny" "F4: hook in isolation (no lib/) on main no-marker => deny (not fail-open)"

# Also assert the hook source contains ZERO references to lib/config.sh
# Use grep -c; tolerate exit 1 (no match) via the assignment itself capturing the output.
# Under set -o pipefail, avoid grep in a pipeline — use process substitution instead.
LIB_REFS=$(grep -Ec 'lib/config\.sh' "$DIR/../check-push.sh" 2>/dev/null; true)
assert_eq "$LIB_REFS" "0" "F4: hook source must not reference lib/config.sh"

# ============================================================
# FIND 5 — corrupt marker ts must deny, not crash
# ============================================================
cd "$R"  # back to original main repo, on feature/y; switch to main
git checkout -q main
mkdir -p .git/shipgate
# marker with matching head + branch=main but ts is a non-numeric string
printf '{"head":"%s","branch":"main","ts":"notanumber","hotfix":false}' \
  "$(git rev-parse HEAD)" > .git/shipgate/last-pass.json
CORRUPT_OUT=$(printf '{"tool_input":{"command":"git push origin main"}}' | SHIPGATE_GLOBAL_CONFIG="$(mktemp -u)" bash "$DIR/../check-push.sh" 2>&1)
assert_contains "$CORRUPT_OUT" "deny" "F5: corrupt marker ts (non-numeric) => deny (fail-closed, not crash)"

# missing ts field entirely (ts emits empty)
printf '{"head":"%s","branch":"main","hotfix":false}' \
  "$(git rev-parse HEAD)" > .git/shipgate/last-pass.json
MISSING_TS_OUT=$(printf '{"tool_input":{"command":"git push origin main"}}' | SHIPGATE_GLOBAL_CONFIG="$(mktemp -u)" bash "$DIR/../check-push.sh" 2>&1)
assert_contains "$MISSING_TS_OUT" "deny" "F5: missing marker ts field => deny (fail-closed)"

# ============================================================
# FIND 6 — non-numeric markerTtlSeconds in .shipgate.json must not crash
# ============================================================
# Use a fresh repo, fresh valid marker, but .shipgate.json has non-numeric TTL.
# Correct behaviour: falls back to default 900s, fresh marker passes safely.
R3=$(mktemp -d); cd "$R3"
git init -q; git commit -q --allow-empty -m init; git branch -M main 2>/dev/null || true
printf '{"mainBranch":"main","markerTtlSeconds":"abc"}' > .shipgate.json
mkdir -p .git/shipgate
printf '{"head":"%s","branch":"main","ts":%s,"hotfix":false}' \
  "$(git rev-parse HEAD)" "$(date +%s)" > .git/shipgate/last-pass.json
BAD_TTL_OUT=$(printf '{"tool_input":{"command":"git push origin main"}}' | SHIPGATE_GLOBAL_CONFIG="$(mktemp -u)" bash "$DIR/../check-push.sh" 2>&1)
# The hook must not crash (exit 1 without JSON) — either allow (fresh marker + fallback 900)
# or deny is acceptable, but the output must NOT be a raw bash error
CRASH_LINES=$(echo "$BAD_TTL_OUT" | grep -Ec '^(bash:|check-push.sh:)' 2>/dev/null; true)
assert_eq "$CRASH_LINES" "0" \
  "F6: non-numeric markerTtlSeconds in config => no bash crash output"
# Fresh valid marker with 900s fallback: must ALLOW (no deny in output)
assert_eq "$BAD_TTL_OUT" "" "F6: non-numeric markerTtlSeconds + fresh marker => allow (falls back to 900)"

# ============================================================
# FIND 7 — malformed stdin must NOT crash (crash => Claude treats hook
# error as non-blocking => the push proceeds => FAIL-OPEN).
# Treat unparseable/empty stdin as "no command" => allow (exit 0, no output).
# Run in the gated on-main no-marker repo R so a crash or a deny would be visible.
# ============================================================
cd "$R"; git checkout -q main
rm -f "$R/.git/shipgate/last-pass.json"
printf '{"mainBranch":"main"}' > "$R/.shipgate.json"
# Non-JSON stdin: pipe raw bytes directly (NOT through runj). Must be exit 0, empty output, no crash.
# NOTE: this harness runs under `set -e`. Today (pre-fix) the hook crashes here with rc!=0,
# which would abort the whole test via the command substitution. Guard the capture with
# `|| NONJSON_RC=$?` so the assertion can RUN and report FAIL (RED) instead of killing the run.
NONJSON_RC=0
NONJSON_OUT=$(printf '%s' 'this is not json' | SHIPGATE_GLOBAL_CONFIG="$(mktemp -u)" bash "$CP" 2>&1) || NONJSON_RC=$?
assert_eq "$NONJSON_RC" "0" "F7: non-JSON stdin => exit 0 (no crash / fail-open)"
assert_eq "$NONJSON_OUT" "" "F7: non-JSON stdin => empty output (no crash, no deny)"
# Empty stdin: same contract.
EMPTY_RC=0
EMPTY_OUT=$(printf '%s' '' | SHIPGATE_GLOBAL_CONFIG="$(mktemp -u)" bash "$CP" 2>&1) || EMPTY_RC=$?
assert_eq "$EMPTY_RC" "0" "F7: empty stdin => exit 0 (no crash)"
assert_eq "$EMPTY_OUT" "" "F7: empty stdin => empty output"

# ============================================================
# FIND 8 — opt-out requires a true JSON boolean false.
# jq -r renders BOTH boolean false AND the string "false" as bare `false`,
# so {"enabled":"false"} (malformed — schema says boolean) used to silently
# un-gate the repo. Wrong direction for a security gate: a typo must fail
# CLOSED (stay gated), not disable the gate. Only boolean false opts out.
# ============================================================
cd "$R"; git checkout -q main
rm -f "$R/.git/shipgate/last-pass.json"
# STRING "false" is a malformed config => must stay GATED => deny (the bug was allow).
printf '{"mainBranch":"main","enabled":"false"}' > "$R/.shipgate.json"
assert_contains "$(run 'git push origin main')" "deny" "F8: enabled STRING \"false\" (malformed) => gated => deny (fail-closed)"
# Boolean false => genuine opt-out => allow.
printf '{"mainBranch":"main","enabled":false}' > "$R/.shipgate.json"
assert_eq "$(run 'git push origin main')" "" "F8: enabled boolean false => opted out => allow (no output)"
# Boolean true => gated => deny (no marker).
printf '{"mainBranch":"main","enabled":true}' > "$R/.shipgate.json"
assert_contains "$(run 'git push origin main')" "deny" "F8: enabled boolean true => gated => deny (no marker)"
# Restore the default gated config for any later assertions.
printf '{"mainBranch":"main"}' > "$R/.shipgate.json"

# ============================================================
# KNOWN LIMITATION (intentional, decided scope): detection matches DIRECT `git … push`
# invocations only. Pushes wrapped in bash -c / eval / $(...) / backticks are NOT detected —
# a command-string gate is not a sandbox; see DECISIONS.md. These asserts LOCK the boundary
# so any future change to detection scope is a conscious decision, not an accident.
# Run in the gated on-main no-marker repo R: if detection ever started matching wrappers,
# these would flip to deny and fail loudly.
# ============================================================
cd "$R"; git checkout -q main
rm -f "$R/.git/shipgate/last-pass.json"
printf '{"mainBranch":"main"}' > "$R/.shipgate.json"
assert_eq "$(runj 'bash -c "git push origin main"')" "" "SCOPE: bash -c wrapper => NOT detected => allow (known limitation)"
assert_eq "$(runj 'eval "git push origin main"')"     "" "SCOPE: eval wrapper => NOT detected => allow (known limitation)"

# ============================================================
# D2 (CRITICAL) — push detection must be O(n), not O(n^2).
# The old char-walk (${s:i:1} in a loop) is quadratic: a ~100k-char command takes
# ~100s. The hook times out at 15s and Claude treats a hook TIMEOUT as NON-BLOCKING
# => the gated push proceeds UNGATED = FAIL-OPEN. An attacker pads the command past
# the timeout to evade the gate. Detection must classify a 100k command well under
# the timeout. Bound = 2000ms (generous for slow CI; current code ~100s => RED).
# ============================================================
cd "$R"; git checkout -q main
rm -f "$R/.git/shipgate/last-pass.json"
printf '{"mainBranch":"main"}' > "$R/.shipgate.json"
# Build a ~100,000-char command WITHOUT the literal adjacent two-word push phrase.
# The "git -C /x push" form has no adjacent phrase (a global option sits between).
BIG=$(printf 'a%.0s' $(seq 1 100000))
PERF_CMD="$BIG ; git -C /x push"
PERF_JSON=$(printf '%s' "$PERF_CMD" | jq -Rsc '{tool_input:{command: .}}')
PERF_START=$(date +%s%N)
PERF_OUT=$(printf '%s' "$PERF_JSON" | SHIPGATE_GLOBAL_CONFIG="$(mktemp -u)" bash "$CP" 2>&1) || true
PERF_END=$(date +%s%N)
PERF_MS=$(( (PERF_END - PERF_START) / 1000000 ))
echo "D2: 100k-char classification took ${PERF_MS}ms"
assert_eq "$([ "$PERF_MS" -lt 2000 ] && echo ok)" "ok" "D2: 100k-char command classified in <2000ms (got ${PERF_MS}ms) — O(n) not O(n^2)"
# And it must still be DENIED (a real git -C /x push segment on gated main, no marker).
assert_contains "$PERF_OUT" "deny" "D2: 100k-char command ending in real 'git -C /x push' => deny (correct classification, not skipped)"

# Padding-cannot-evade: a large filler string that INCLUDES the word 'push' in the
# filler, followed by a REAL push segment, must still DENY (and within the bound).
# This proves the timeout-padding bypass is closed even when 'push' appears in noise.
PAD=$(printf 'push %.0s' $(seq 1 8000))   # ~40k chars, contains the word 'push' many times
PAD_CMD="echo $PAD ; git push origin main"
PAD_JSON=$(printf '%s' "$PAD_CMD" | jq -Rsc '{tool_input:{command: .}}')
PAD_START=$(date +%s%N)
PAD_OUT=$(printf '%s' "$PAD_JSON" | SHIPGATE_GLOBAL_CONFIG="$(mktemp -u)" bash "$CP" 2>&1) || true
PAD_END=$(date +%s%N)
PAD_MS=$(( (PAD_END - PAD_START) / 1000000 ))
echo "D2: padded(push)+real-push classification took ${PAD_MS}ms"
assert_contains "$PAD_OUT" "deny" "D2: ~40k filler containing 'push' + real 'git push origin main' => deny (padding cannot evade)"
assert_eq "$([ "$PAD_MS" -lt 2000 ] && echo ok)" "ok" "D2: padded push detection in <2000ms (got ${PAD_MS}ms)"

# ============================================================
# D1 (MEDIUM) — space-separated value-taking global options must be skipped so the
# subcommand position isn't mistaken for the option's value. These EVADE detection
# today (the path token is read as the subcommand) and ALLOW. They must DENY in a
# gated on-main no-marker repo. The '='-form already works and must keep working.
# ============================================================
cd "$R"; git checkout -q main
rm -f "$R/.git/shipgate/last-pass.json"
printf '{"mainBranch":"main"}' > "$R/.shipgate.json"
assert_contains "$(run 'git --git-dir /tmp/x push')"   "deny" "D1: 'git --git-dir /tmp/x push' (bare value-global) => deny"
assert_contains "$(run 'git --work-tree /tmp/x push')"  "deny" "D1: 'git --work-tree /tmp/x push' (bare value-global) => deny"
assert_contains "$(run 'git --namespace ns push')"      "deny" "D1: 'git --namespace ns push' (bare value-global) => deny"
# Regression: '='-form is a single token and must keep being detected.
assert_contains "$(run 'git --git-dir=/tmp/x push')"    "deny" "D1: 'git --git-dir=/tmp/x push' (=form, single token) => deny (regression)"
# Combined with refspec to main, on a feature branch (CUR != main): destination is main => deny.
git checkout -q -b feature/d1
assert_contains "$(run 'git --git-dir /tmp/x push origin main')" "deny" "D1: '--git-dir /path push origin main' on feature branch => deny (target main)"
git checkout -q main

# ============================================================
# D2 newlines — an UNQUOTED newline is a segment separator; a QUOTED newline stays
# in-token. The O(n) rewrite must preserve this (awk record-splitting must not eat
# embedded newlines). Run in gated on-main no-marker repo R.
# ============================================================
cd "$R"; git checkout -q main
rm -f "$R/.git/shipgate/last-pass.json"
printf '{"mainBranch":"main"}' > "$R/.shipgate.json"
# Unquoted newline separating an innocuous first segment from a real push segment => deny.
NL_CMD=$(printf 'echo hi\ngit push origin main')
NL_JSON=$(printf '%s' "$NL_CMD" | jq -Rsc '{tool_input:{command: .}}')
assert_contains "$(printf '%s' "$NL_JSON" | SHIPGATE_GLOBAL_CONFIG="$(mktemp -u)" bash "$CP" 2>&1)" "deny" "D2: unquoted newline is a segment separator (echo<NL>git push) => deny"
# A QUOTED newline keeps 'push' inside a string token => NOT a push => allow.
QNL_CMD=$(printf 'echo "a\ngit push"')
QNL_JSON=$(printf '%s' "$QNL_CMD" | jq -Rsc '{tool_input:{command: .}}')
assert_eq "$(printf '%s' "$QNL_JSON" | SHIPGATE_GLOBAL_CONFIG="$(mktemp -u)" bash "$CP" 2>&1)" "" "D2: quoted newline keeps 'git push' in-token (echo \"a<NL>git push\") => allow"

# ============================================================
# D7 (CRITICAL) — a leading env-assignment prefix must NOT hide a real push.
# A shell simple-command may be preceded by VAR=value assignments before the command
# word. seg_is_push() required token[0]=="git", so 'FOO=bar git push' had token[0]="FOO=bar"
# and EVADED detection (allow) while the shell really pushed. Fix: skip leading
# assignment tokens (^[A-Za-z_][A-Za-z0-9_]*=) then require the command word == git.
# Run in the gated on-main no-marker repo R: these MUST deny.
# ============================================================
cd "$R"; git checkout -q main
rm -f "$R/.git/shipgate/last-pass.json"
printf '{"mainBranch":"main"}' > "$R/.shipgate.json"
assert_contains "$(run 'FOO=bar git push origin main')"            "deny" "D7: leading env-assignment 'FOO=bar git push' => deny"
assert_contains "$(run 'GIT_SSH_COMMAND=x git push origin main')"  "deny" "D7: 'GIT_SSH_COMMAND=x git push' (ordinary env prefix) => deny"
assert_contains "$(runj 'X="a b" git push origin main')"           "deny" "D7: quoted-value env-assignment 'X=\"a b\" git push' => deny"
# Assignment AFTER a separator (the SECOND segment is the real push).
assert_contains "$(run 'true; FOO=1 git push origin main')"        "deny" "D7: assignment after separator 'true; FOO=1 git push' => deny"
# Multiple stacked assignments before git.
assert_contains "$(run 'A=1 B=2 git push origin main')"            "deny" "D7: multiple stacked assignments 'A=1 B=2 git push' => deny"
# FALSE-POSITIVE guards (must ALLOW): these are NOT a leading-assignment+git-push.
# 'echo FOO=bar' — first token is echo (a command word, not an assignment) => not git.
assert_eq "$(run 'echo FOO=bar git push')"                          ""     "D7: 'echo FOO=bar git push' (echo is command word) => allow"
# 'VAR=push git status' — skip VAR=push, command word git, subcommand status => allow.
assert_eq "$(run 'VAR=push git status')"                            ""     "D7: 'VAR=push git status' (assignment then git status) => allow"
# 'git=foo push' — git=foo is an assignment (skipped), command word becomes 'push' (not git).
assert_eq "$(run 'git=foo push')"                                   ""     "D7: 'git=foo push' (assignment, not a git invocation) => allow"

# ============================================================
# D8 (CRITICAL) — the awk state machine must honor backslash-escaped quotes so quote
# PARITY matches bash. The old loop toggled quote state on every '/" with NO escape
# handling, so an ODD number of \" before '; git push' left a phantom quote open across
# the separator and HID the push (allow) while the shell pushed. Fix: add an escaped
# flag; \" inside "" is a literal (quote stays parity-correct), \ outside quotes escapes
# next char. runj jq-encodes the raw string incl. backslashes. Gated on-main no-marker repo.
# ============================================================
cd "$R"; git checkout -q main
rm -f "$R/.git/shipgate/last-pass.json"
printf '{"mainBranch":"main"}' > "$R/.shipgate.json"
# echo "\"" — the \" is a literal quote INSIDE the double-quote; the quote closes after it.
# Quote parity is even at the ';' so the second segment 'git push origin main' splits => deny.
assert_contains "$(runj 'echo "\""; git push origin main')"            "deny" 'D8: echo "\""; git push => deny (escaped quote keeps parity)'
assert_contains "$(runj 'echo "a\"b"; git push origin main')"          "deny" 'D8: echo "a\"b"; git push => deny (escaped quote inside dquote)'
# Routine: commit with an escaped quote in the message, chained with && push.
assert_contains "$(runj 'git commit -m "a \"b" && git push origin main')" "deny" 'D8: git commit -m "a \"b" && git push => deny'
# Escaped quote inside a quoted assignment VALUE, then a real push (same segment).
assert_contains "$(runj 'X="a\"b" git push origin main')"              "deny" 'D8: X="a\"b" git push => deny (escape + env-assignment)'

# D8 false-positive guards (must ALLOW): the escape handling must not over-split or
# mis-open quotes so that a quoted mention LEAKS as a real push.
# A backslash-escaped semicolon outside quotes is LITERAL (no segment split) — the whole
# 'echo a\; git push' is ONE segment whose first token is echo => not git => allow.
assert_eq "$(run 'echo a\; git push')"                                 ""     "D8: 'echo a\\; git push' (escaped ; is literal, one segment) => allow"
# Trailing backslash at end-of-input must not crash and must not deny.
assert_eq "$(run 'echo hi \')"                                         ""     "D8: trailing backslash at EOF (no crash) => allow"
# Backslash inside SINGLE quotes is literal (no escaping) — 'echo '\''a\'\''; ...' style:
# a single-quoted string with a backslash, then the quote closes normally; mention only.
assert_eq "$(runj 'echo '"'"'a\b'"'"' ; echo "git push"')"             ""     "D8: backslash literal inside single quotes; only a quoted mention => allow"

# ============================================================
# D9 (CRITICAL) — bash ANSI-C quoting $'...' must honor backslash escapes so quote PARITY
# matches bash. In $'...', a \' is an ESCAPED apostrophe that does NOT close the string;
# the string ends at the next UNescaped '. The old machine treated $ as ordinary and the
# following ' as a PLAIN single-quote (backslash literal), so it CLOSED on the ' of \',
# then RE-OPENED at the real closing ' — leaving a phantom quote open across the separator
# and HIDING a real push (allow) while the shell pushed. An ODD number of \' flips parity.
# Embedding an apostrophe is the MAIN reason to use $'...', so this is a routine command
# shape (a commit message with an apostrophe, then push) — not an adversarial one.
#
# Test-string construction (byte-exactness REQUIRED): each $'...' command is built with
# printf using OCTAL escapes \047 (single-quote ') and \134 (backslash \) inside a SINGLE-
# quoted printf format, so the resulting bash variable holds the EXACT literal bytes
# ($, ', i, t, \, ', s, ...). This sidesteps the nested-quoting puzzle of writing a literal
# $'it\'s done' inline. runj() then jq-encodes the raw string into the tool JSON.
# Verified byte-exact via `printf ... | od -c` during development (each shows: $ ' ... \ '
# ... ' <sep> g i t   p u s h). Gated on-main no-marker repo R: these are REAL pushes => deny.
cd "$R"; git checkout -q main
rm -f "$R/.git/shipgate/last-pass.json"
printf '{"mainBranch":"main"}' > "$R/.shipgate.json"
# Case 1:  git commit -m $'it\'s done' ; git push
D9_C1=$(printf 'git commit -m $\047it\134\047s done\047 ; git push')
assert_contains "$(runj "$D9_C1")"  "deny" "D9: \$'it\\'s done' ; git push => deny (ANSI-C escaped apostrophe, odd parity)"
# Case 2:  git commit -m $'don\'t' && git push
D9_C2=$(printf 'git commit -m $\047don\134\047t\047 && git push')
assert_contains "$(runj "$D9_C2")"  "deny" "D9: \$'don\\'t' && git push => deny (ANSI-C escaped apostrophe)"
# Case 3:  git commit -m $'we\'re live' ; git push origin main
D9_C3=$(printf 'git commit -m $\047we\134\047re live\047 ; git push origin main')
assert_contains "$(runj "$D9_C3")"  "deny" "D9: \$'we\\'re live' ; git push origin main => deny"
# Case 4:  git add -A && git commit -m $'fix: user\'s bug' && git push origin main
D9_C4=$(printf 'git add -A && git commit -m $\047fix: user\134\047s bug\047 && git push origin main')
assert_contains "$(runj "$D9_C4")"  "deny" "D9: git add && commit -m \$'fix: user\\'s bug' && git push origin main => deny"
# Case 5:  git commit -m $'a\'b' | git push
D9_C5=$(printf 'git commit -m $\047a\134\047b\047 | git push')
assert_contains "$(runj "$D9_C5")"  "deny" "D9: \$'a\\'b' | git push => deny (pipe separator)"

# D9 regression / boundary (the fix must be $'-SPECIFIC, not a change to plain single-quotes):
# Plain single-quote with an internal backslash but NO $ — backslash is LITERAL, the string
# is 'a\' and closes at the 2nd '; then '; git push' is unquoted => deny. Proves we did NOT
# alter plain single-quote handling.
D9_PLAIN=$(printf '\047a\134\047 ; git push')
assert_contains "$(runj "$D9_PLAIN")" "deny" "D9: plain single-quote 'a\\' ; git push (NO \$) => deny (plain-sq unchanged)"
# EVEN count of escaped apostrophes in a BALANCED $'...' — $'a\'b\'c' is the ANSI-C string
# a'b'c, closes at the final '; the trailing '; git push' is unquoted => deny.
D9_EVEN=$(printf 'git commit -m $\047a\134\047b\134\047c\047 ; git push')
assert_contains "$(runj "$D9_EVEN")" "deny" "D9: \$'a\\'b\\'c' ; git push (even \\', balanced) => deny"
# A $'...' with NO push after it => allow (command word is echo; the ANSI-C string is inert).
D9_NOPUSH=$(printf 'echo $\047it\134\047s fine\047')
assert_eq "$(runj "$D9_NOPUSH")"      ""     "D9: echo \$'it\\'s fine' (no push) => allow (no output)"

# ============================================================
# FINAL RED-TEAM ROUND (F1/F2/SUBSHELL/F3) — four more real-push evasions.
# All four were proven to ACTUALLY push by the red-team. Strings are built with printf
# OCTAL escapes (\134=backslash, \011=TAB, \001=SOH, \047=single-quote) + real newlines,
# and were verified byte-exact via `od -c` during development. runj() jq-encodes the raw
# bytes into the tool JSON. Gated on-main no-marker repo R: every DENY case is a REAL push.
# ============================================================

# ------------------------------------------------------------
# F1 (CRITICAL) — backslash-newline line continuation.
# In bash, a backslash IMMEDIATELY followed by a newline is a LINE CONTINUATION: both bytes
# are removed and the surrounding text is JOINED. So `git \<NL>push` and `gi\<NL>t push` are
# BOTH `git push` at the shell. The old awk treated the escaped newline as an in-token byte
# (token = `\<NL>push` or `gi\<NL>t`), so the match missed => ALLOW while the shell pushed.
# Fix: a string-level gsub(/\\\n/,"","") on the reconstructed buffer BEFORE tokenizing.
# Safe inside single-quotes (where bash keeps \<NL> literal): the removal only SHORTENS inert
# quoted DATA — the ' boundaries (0x27, never \ or NL) are untouched, so it cannot forge or
# hide an unquoted push (proven: regression ALLOWs below).
# ------------------------------------------------------------
cd "$R"; git checkout -q main
rm -f "$R/.git/shipgate/last-pass.json"
printf '{"mainBranch":"main"}' > "$R/.shipgate.json"
# DENY: real pushes split by a continuation.
F1_A=$(printf 'git \134\npush origin main')
assert_contains "$(runj "$F1_A")" "deny" "F1: git \\<NL>push origin main (continuation after space) => deny"
F1_B=$(printf 'git \134\npush')
assert_contains "$(runj "$F1_B")" "deny" "F1: git \\<NL>push (bare, on main) => deny"
F1_C=$(printf 'gi\134\nt push origin main')
assert_contains "$(runj "$F1_C")" "deny" "F1: gi\\<NL>t push origin main (continuation inside the word git) => deny"
F1_D=$(printf 'git \134\n\134\npush origin main')
assert_contains "$(runj "$F1_D")" "deny" "F1: git \\<NL>\\<NL>push origin main (doubled continuation) => deny"
# F1 inside-word: a continuation can split the SUBCOMMAND WORD itself (pu\<NL>sh == push).
# These have NO literal "push" substring in the RAW command, so the cheap *push* pre-filter
# must strip continuations before testing — else it exits 0 (allow) before awk ever runs.
F1_E=$(printf 'git pu\134\nsh origin main')
assert_contains "$(runj "$F1_E")" "deny" "F1: git pu\\<NL>sh origin main (continuation splits 'push') => deny"
F1_F=$(printf 'git p\134\nush origin main')
assert_contains "$(runj "$F1_F")" "deny" "F1: git p\\<NL>ush origin main (continuation after 'p') => deny"
F1_G=$(printf 'git pus\134\nh')
assert_contains "$(runj "$F1_G")" "deny" "F1: git pus\\<NL>h (bare, continuation before 'h') => deny"
# REGRESSION ALLOW: the gsub must NOT create false positives.
# Double-quoted "git \<NL>push" — command word is echo; bash also removes \<NL> here, but the
# whole thing is echo's quoted argument, never a command => allow.
F1_QD=$(printf 'echo \042git \134\npush\042')
assert_eq "$(runj "$F1_QD")" "" "F1: echo \"git \\<NL>push\" (quoted continuation => echo command word) => allow"
# Single-quoted 'a\<NL>b' with NO push — gsub shortens inert data, quotes intact => allow.
F1_QS=$(printf 'echo \047a\134\nb\047')
assert_eq "$(runj "$F1_QS")" "" "F1: echo 'a\\<NL>b' (single-quoted data, no push) => allow"

# ------------------------------------------------------------
# F2 (MEDIUM) — tab/whitespace before the destination branch evades the refspec grep.
# On a FEATURE branch, `git push origin<TAB>main` pushes to main, but the refspec grep
# "[ /+:]${MAIN}(\s|$)" had a PRECEDING class with a literal space but NOT tab/newline, so
# origin<TAB>main did not match => TARGET stayed the feature branch => ALLOW. Fix: widen the
# preceding class to all whitespace: "[[:space:]/+:]". Must run on a FEATURE branch so the
# grep (not CUR==MAIN) decides the destination.
# ------------------------------------------------------------
cd "$R"; rm -f "$R/.git/shipgate/last-pass.json"; printf '{"mainBranch":"main"}' > "$R/.shipgate.json"
git checkout -q -b feature/f2
F2_TAB=$(printf 'git push origin\011main')
assert_contains "$(runj "$F2_TAB")" "deny" "F2: git push origin<TAB>main (on feature branch) => deny (tab before dest)"
# Keep: the space form still denies (regression on the widened class).
assert_contains "$(run 'git push origin main')" "deny" "F2: git push origin<SP>main (on feature branch) => deny (space form unchanged)"
# Keep: a genuinely non-main destination (tab-separated) still ALLOWs.
F2_OK=$(printf 'git push origin\011feature/f2')
assert_eq "$(runj "$F2_OK")" "" "F2: git push origin<TAB>feature/f2 (non-main dest) => allow"
git checkout -q main

# ------------------------------------------------------------
# SUBSHELL — push glued to a closing paren `)`. `(cd sub && git push)` and `(git push)` push,
# but `push` glues to `)` so the token was `push)` != `push` => ALLOW. `(` and `)` are shell
# metacharacters that ALWAYS separate commands. Fix: treat UNQUOTED `(`/`)` as additional
# segment separators in the awk segmenter (a quoted paren must NOT split).
# ------------------------------------------------------------
cd "$R"; git checkout -q main
rm -f "$R/.git/shipgate/last-pass.json"; printf '{"mainBranch":"main"}' > "$R/.shipgate.json"
assert_contains "$(run '(git push)')"               "deny" "SUBSHELL: (git push) => deny (close-paren ends the segment)"
assert_contains "$(run '(cd sub && git push)')"     "deny" "SUBSHELL: (cd sub && git push) => deny"
assert_contains "$(run '(true; git push)')"         "deny" "SUBSHELL: (true; git push) => deny"
# Also the OPEN paren must separate: leading '(' before git push.
assert_contains "$(run '( git push origin main )')" "deny" "SUBSHELL: ( git push origin main ) => deny (open paren separates)"
# REGRESSION ALLOW: a QUOTED paren must NOT split — command word is echo.
F_QPAREN=$(printf 'echo \042(git push)\042')
assert_eq "$(runj "$F_QPAREN")" "" "SUBSHELL: echo \"(git push)\" (parens quoted) => allow (no false positive)"
# Single-quoted parens likewise inert.
F_SPAREN=$(printf 'echo \047(git push)\047')
assert_eq "$(runj "$F_SPAREN")" "" "SUBSHELL: echo '(git push)' (parens single-quoted) => allow"

# ------------------------------------------------------------
# F3 (CRITICAL, exotic) — the RS="\001" sentinel can be split by an injected control byte.
# stdin was slurped with awk RS="\001" on the assumption 0x01 never appears in a command —
# false: a SOH rides through the JSON envelope and bash accepts it as a literal byte. awk then
# split $CMD into MULTIPLE records at the SOH; per-record state reset dropped the open quote =>
# parity scrambled => the trailing `; git push` leaked as ALLOW while the shell pushed.
# Fix: stop relying on a single-byte RS sentinel; read the ENTIRE stdin as ONE buffer (default
# RS=newline + reconstruct), treating any control byte (incl. 0x01) as an ordinary in-token
# char and preserving embedded real newlines as segment separators.
# ------------------------------------------------------------
cd "$R"; git checkout -q main
rm -f "$R/.git/shipgate/last-pass.json"; printf '{"mainBranch":"main"}' > "$R/.shipgate.json"
# DENY: a quoted SOH (which used to split the RS record) followed by a real push segment.
F3_A=$(printf 'echo \047a\001b\047 ; git push origin main')
assert_contains "$(runj "$F3_A")" "deny" "F3: echo 'a<SOH>b' ; git push origin main (SOH no longer splits the record) => deny"
# DENY: SOH OUTSIDE quotes earlier in the command, real push later. An unquoted SOH is an
# ordinary in-token byte (not a separator), so it must not perturb a later real push segment.
F3_B=$(printf 'echo a\001b ; git push origin main')
assert_contains "$(runj "$F3_B")" "deny" "F3: echo a<SOH>b ; git push origin main (unquoted SOH is an ordinary byte) => deny"
# DENY: a normal MULTI-LINE command with a real push on its own line still denies (real newline
# is still a segment separator — the F3 buffer reconstruction must not eat it).
F3_ML=$(printf 'echo building\ngit push origin main')
assert_contains "$(runj "$F3_ML")" "deny" "F3: multi-line (echo<NL>git push origin main) => deny (real newline still separates)"
# REGRESSION ALLOW: a benign multi-line command with a SOH and NO push stays allow (no crash,
# no false positive).
F3_BENIGN=$(printf 'echo a\001b\necho done')
assert_eq "$(runj "$F3_BENIGN")" "" "F3: echo a<SOH>b<NL>echo done (benign multi-line, SOH) => allow"

# ============================================================
# HEREDOC PAPERCUT — KNOWN LIMITATION (fail-closed, benign): no heredoc model. An
# unquoted-newline heredoc whose BODY contains a push line is conservatively DENIED — the
# detector splits on the unquoted newline and sees the body line as its own command. Safe
# (the shell does NOT push; the body is literal data fed to `cat`), just a usability
# papercut; documented in DECISIONS.md. Do NOT try to model heredocs.
cd "$R"; git checkout -q main
rm -f "$R/.git/shipgate/last-pass.json"
printf '{"mainBranch":"main"}' > "$R/.shipgate.json"
HEREDOC_CMD=$(printf 'cat <<EOF\ngit push origin main\nEOF')
assert_contains "$(runj "$HEREDOC_CMD")" "deny" "HEREDOC: cat<<EOF / git push / EOF => deny (KNOWN LIMITATION, fail-closed benign — shell does not push)"
# Contrast (correct ALLOW): a multiline DOUBLE-QUOTED string containing a push line keeps
# the push INSIDE the quote (the newline stays in-token) => not a separate command => allow.
DQ_NL_CMD=$(printf 'echo "a\ngit push origin main"')
assert_eq "$(runj "$DQ_NL_CMD")"         ""     "HEREDOC-contrast: double-quoted multiline with push line => allow (newline stays in-token)"

# ============================================================
# KNOWN LIMITATION (decided scope, see DECISIONS.md): the gate matches `git push` as a
# simple command (env-assignments + git globals + the push subcommand, quotes/escapes
# honored); it does NOT match pushes obscured by I/O redirection operators or invoked via
# a prefix/wrapper program. A command-string gate is a guardrail, not a sandbox.
# These assert ALLOW (in a gated on-main no-marker repo) so the boundary is locked: if a
# future change ever started matching them, these would flip to deny and fail loudly.
# ============================================================
cd "$R"; git checkout -q main
rm -f "$R/.git/shipgate/last-pass.json"
printf '{"mainBranch":"main"}' > "$R/.shipgate.json"
# Redirection-obscured: git is not the syntactic command word (a redirection op precedes it),
# or a redirection sits between git and push.
assert_eq "$(run '>/dev/null git push origin main')"  "" "SCOPE: '>/dev/null git push' (redirection-obscured) => allow (known limitation)"
assert_eq "$(run '2>&1 git push origin main')"         "" "SCOPE: '2>&1 git push' (redirection-obscured) => allow (known limitation)"
assert_eq "$(run 'git >log push origin main')"         "" "SCOPE: 'git >log push' (redirection between git and push) => allow (known limitation)"
# Prefix/wrapper programs: git is launched BY another program, not the command word.
assert_eq "$(run 'sudo git push origin main')"         "" "SCOPE: 'sudo git push' (wrapper program) => allow (known limitation)"
assert_eq "$(run 'time git push origin main')"         "" "SCOPE: 'time git push' (wrapper program) => allow (known limitation)"
assert_eq "$(run 'nice git push origin main')"         "" "SCOPE: 'nice git push' (wrapper program) => allow (known limitation)"
assert_eq "$(run 'env git push origin main')"          "" "SCOPE: 'env git push' (wrapper program) => allow (known limitation)"

# --- A1: SHIPGATE_DISABLE session kill (agent-proof; read from the hook env) ---
R=$(mktemp -d); cd "$R"; git init -q; git commit -q --allow-empty -m init; git branch -M main 2>/dev/null || true
printf '{"mainBranch":"main"}' > .shipgate.json   # opted in, no marker => baseline deny
GCFG_TEST="$(mktemp -u)"
disrun(){ printf '{"tool_input":{"command":"git push origin main"}}' | SHIPGATE_DISABLE="$1" SHIPGATE_GLOBAL_CONFIG="$GCFG_TEST" bash "$CP"; }
assert_eq       "$(disrun 1)"      "" "A1: SHIPGATE_DISABLE=1 => allow"
assert_eq       "$(disrun true)"   "" "A1: SHIPGATE_DISABLE=true => allow"
assert_eq       "$(disrun on)"     "" "A1: SHIPGATE_DISABLE=on => allow"
assert_contains "$(disrun 0)"      "deny" "A1: SHIPGATE_DISABLE=0 => gated"
assert_contains "$(disrun false)"  "deny" "A1: SHIPGATE_DISABLE=false => gated"
assert_contains "$(disrun '')"     "deny" "A1: SHIPGATE_DISABLE empty => gated"

# --- A2: global ~/.shipgate.json enabled:false = unconditional master kill ---
R=$(mktemp -d); cd "$R"; git init -q; git commit -q --allow-empty -m init; git branch -M main 2>/dev/null || true
printf '{"mainBranch":"main","enabled":true}' > .shipgate.json   # per-repo says ENABLED
GCFG_TEST="$(mktemp)"
mrun(){ printf '{"tool_input":{"command":"git push origin main"}}' | SHIPGATE_GLOBAL_CONFIG="$GCFG_TEST" bash "$CP"; }
printf '{"enabled":false}' > "$GCFG_TEST"
assert_eq       "$(mrun)" "" "A2: global enabled:false => allow EVEN WHEN per-repo enabled:true (master kill wins)"
printf '{"enabled":true}'  > "$GCFG_TEST"
assert_contains "$(mrun)" "deny" "A2: global enabled:true => not a kill => gated (per-repo enabled, no marker)"
printf '{"enabled":"false"}' > "$GCFG_TEST"   # STRING, malformed-ish value
assert_contains "$(mrun)" "deny" "A2: global enabled STRING false => not a real bool => kill does NOT fire => gated"
rm -f "$GCFG_TEST"

# --- A3: .git/shipgate/disabled sentinel (written by /ship off) => allow ---
R=$(mktemp -d); cd "$R"; git init -q; git commit -q --allow-empty -m init; git branch -M main 2>/dev/null || true
printf '{"mainBranch":"main"}' > .shipgate.json   # opted in, no marker => baseline deny
GCFG_TEST="$(mktemp -u)"
srun(){ printf '{"tool_input":{"command":"git push origin main"}}' | SHIPGATE_GLOBAL_CONFIG="$GCFG_TEST" bash "$CP"; }
assert_contains "$(srun)" "deny" "A3: no sentinel => gated"
mkdir -p "$(git rev-parse --git-common-dir)/shipgate"; : > "$(git rev-parse --git-common-dir)/shipgate/disabled"
assert_eq       "$(srun)" "" "A3: sentinel present => allow"
rm -f "$(git rev-parse --git-common-dir)/shipgate/disabled"

# --- A4: default-on for unconfigured repos when global defaultEnabled:true ---
R=$(mktemp -d); cd "$R"; git init -q; git commit -q --allow-empty -m init; git branch -M main 2>/dev/null || true
# NO per-repo .shipgate.json on purpose.
GCFG_TEST="$(mktemp)"
drun(){ printf '{"tool_input":{"command":"git push origin main"}}' | SHIPGATE_GLOBAL_CONFIG="$GCFG_TEST" bash "$CP"; }
printf '{"defaultEnabled":true}'  > "$GCFG_TEST"
assert_contains "$(drun)" "deny" "A4: no per-repo file + global defaultEnabled:true => GATED (default-on)"
printf '{"defaultEnabled":false}' > "$GCFG_TEST"
assert_eq       "$(drun)" "" "A4: defaultEnabled:false => opt-in => allow"
printf '{"defaultEnabled":"true"}' > "$GCFG_TEST"   # STRING, not a real bool
assert_eq       "$(drun)" "" "A4: defaultEnabled STRING 'true' => not real bool => opt-in => allow"
printf '{"mainBranch":"main"}'   > "$GCFG_TEST"      # valid global, no defaultEnabled key
assert_eq       "$(drun)" "" "A4: global without defaultEnabled => opt-in => allow"
rm -f "$GCFG_TEST"
# default-on must NOT override an explicit per-repo opt-out:
printf '{"enabled":false}' > "$R/.shipgate.json"; printf '{"defaultEnabled":true}' > "$GCFG_TEST"
assert_eq       "$(drun)" "" "A4: per-repo enabled:false beats global default-on => allow"
rm -f "$R/.shipgate.json" "$GCFG_TEST"

# --- A5: malformed ~/.shipgate.json => loud deny for unconfigured repos; env still escapes ---
R=$(mktemp -d); cd "$R"; git init -q; git commit -q --allow-empty -m init; git branch -M main 2>/dev/null || true
GCFG_TEST="$(mktemp)"; printf '{ this is not json' > "$GCFG_TEST"   # malformed
xrun(){ printf '{"tool_input":{"command":"git push origin main"}}' | SHIPGATE_GLOBAL_CONFIG="$GCFG_TEST" bash "$CP"; }
out=$(xrun)
assert_contains "$out" "deny" "A5: malformed global + unconfigured repo => DENY"
assert_contains "$out" "not valid JSON" "A5: deny message names the fix"
esc=$(printf '{"tool_input":{"command":"git push origin main"}}' | SHIPGATE_DISABLE=1 SHIPGATE_GLOBAL_CONFIG="$GCFG_TEST" bash "$CP")
assert_eq "$esc" "" "A5: SHIPGATE_DISABLE=1 still escapes a malformed global config"
rm -f "$GCFG_TEST"

# --- A6: non-push commands exit at the pre-filter (behavior-preserving) ---
R=$(mktemp -d); cd "$R"; git init -q; git commit -q --allow-empty -m init; git branch -M main 2>/dev/null || true
GCFG_TEST="$(mktemp)"; printf '{"defaultEnabled":true}' > "$GCFG_TEST"
nrun(){ printf '{"tool_input":{"command":"%s"}}' "$1" | SHIPGATE_GLOBAL_CONFIG="$GCFG_TEST" bash "$CP"; }
assert_eq "$(nrun 'git status')" "" "A6: git status (no push) => allow even under default-on"
assert_eq "$(nrun 'ls -la')"     "" "A6: ls (no push) => allow"
rm -f "$GCFG_TEST"

# --- A7 (review): non-object / unreadable / per-repo-shadowed global config + sentinel-from-subdir ---
R=$(mktemp -d); cd "$R"; git init -q; git commit -q --allow-empty -m init; git branch -M main 2>/dev/null || true
GCFG_TEST="$(mktemp)"
arun(){ printf '{"tool_input":{"command":"git push origin main"}}' | SHIPGATE_GLOBAL_CONFIG="$GCFG_TEST" bash "$CP"; }
for v in '[]' '"foo"' '42' 'true'; do
  printf '%s' "$v" > "$GCFG_TEST"; o=$(arun)
  assert_contains "$o" "deny" "A7: non-object global ($v) + unconfigured repo => DENY (no silent opt-in)"
  assert_contains "$o" "must be a JSON object" "A7: non-object global ($v) => message names the shape fix"
done
printf '{"defaultEnabled":true}' > "$GCFG_TEST"; chmod 000 "$GCFG_TEST"
if [ -r "$GCFG_TEST" ]; then echo "(A7: skip unreadable-global test: -r still true, likely root)"; else
  o=$(arun)
  assert_contains "$o" "deny" "A7: unreadable global + unconfigured repo => DENY"
  assert_contains "$o" "not readable" "A7: unreadable global => message names permissions (not 'invalid JSON')"
fi
chmod 644 "$GCFG_TEST" 2>/dev/null || true; rm -f "$GCFG_TEST"
# malformed/non-object global is IGNORED when a per-repo file is present (per-repo governs; locks §4.1)
R=$(mktemp -d); cd "$R"; git init -q; git commit -q --allow-empty -m init; git branch -M main 2>/dev/null || true
printf '{"mainBranch":"main"}' > .shipgate.json
GCFG_TEST="$(mktemp)"; printf '{ not json' > "$GCFG_TEST"
o2=$(printf '{"tool_input":{"command":"git push origin main"}}' | SHIPGATE_GLOBAL_CONFIG="$GCFG_TEST" bash "$CP")
assert_contains "$o2" "deny" "A7: malformed global + per-repo present => still gated"
assert_contains "$o2" "No ship-gate pass" "A7: deny is the per-repo no-marker path, NOT the global loud-deny"
rm -f "$GCFG_TEST"
# /ship off sentinel honored even when the hook CWD is a repo SUBDIR
R=$(mktemp -d); cd "$R"; git init -q; git commit -q --allow-empty -m init; git branch -M main 2>/dev/null || true
printf '{"mainBranch":"main"}' > .shipgate.json
mkdir -p "$R/sub"; mkdir -p "$(git rev-parse --git-common-dir)/shipgate"; : > "$(git rev-parse --git-common-dir)/shipgate/disabled"
sub_out=$(cd "$R/sub" && printf '{"tool_input":{"command":"git push origin main"}}' | SHIPGATE_GLOBAL_CONFIG="$(mktemp -u)" bash "$CP")
assert_eq "$sub_out" "" "A7: /ship off sentinel honored from a repo subdir (git-common-dir anchored to repo root)"
rm -f "$(git rev-parse --git-common-dir)/shipgate/disabled"

# --- B2: hook auto-detects the protected branch (origin/HEAD -> {main,master}) + literal match (P8-6) ---
UP=$(mktemp -d); git -C "$UP" init -q --bare
W=$(mktemp -d); git clone -q "$UP" "$W" 2>/dev/null
( cd "$W" && git config user.email t@t && git config user.name t && git checkout -q -b master && git commit -q --allow-empty -m i && git push -q -u origin master 2>/dev/null && git remote set-head origin master >/dev/null 2>&1 )
printf '{}' > "$W/.shipgate.json"   # opted in, no mainBranch => auto-detect; no marker => deny on protected
GCFG_NONE="$(mktemp -u)"
brun(){ printf '{"tool_input":{"command":"%s"}}' "$2" | ( cd "$1" && SHIPGATE_GLOBAL_CONFIG="$GCFG_NONE" bash "$CP" ); }
assert_contains "$(brun "$W" 'git push origin master')"   "deny" "B2: origin/HEAD=master => push master (no marker) => deny"
( cd "$W" && git checkout -q -b feature/x )
assert_eq       "$(brun "$W" 'git push origin feature/x')" ""    "B2: on feature/x, push feature/x => allow (backup)"
( cd "$W" && git checkout -q master )
assert_contains "$(brun "$W" 'git push origin feature/x')" "deny" "B2: on protected master, explicit non-protected push => conservatively GATED (safe over-gate)"
# {main,master} fallback (no remote)
R=$(mktemp -d); ( cd "$R" && git init -q && git commit -q --allow-empty -m i && git branch -M master 2>/dev/null )
printf '{}' > "$R/.shipgate.json"
assert_contains "$(brun "$R" 'git push origin master')" "deny" "B2: no remote => master in {main,master} fallback => deny"
assert_contains "$(brun "$R" 'git push origin main')"   "deny" "B2: no remote => main in {main,master} fallback => deny"
# P8-6: a protected branch name with an ERE metacharacter is matched LITERALLY
R2=$(mktemp -d); ( cd "$R2" && git init -q && git commit -q --allow-empty -m i && git branch -M main 2>/dev/null )
printf '{"mainBranch":"v1.0"}' > "$R2/.shipgate.json"
assert_contains "$(brun "$R2" 'git push origin v1.0')" "deny" "B2/P8-6: metachar branch v1.0 matched literally => deny"
assert_eq       "$(brun "$R2" 'git push origin v1X0')" ""    "B2/P8-6: v1X0 does NOT match v1.0 (dot literal) => allow"

# ============================================================
# CF — COMPOUND-COMMAND FOOTGUN (locks the 02f2073 guard, hardened)
# ============================================================
# A SINGLE command that both writes the pass marker AND pushes can NEVER pass on its OWN authority: this is a
# PreToolUse hook, so it reads the marker BEFORE the command runs => a same-command `write-marker` is still
# stale. The guard surfaces a specific, actionable fix INSTEAD of the generic deny — but only ON a marker
# failure: a command that already holds a VALID pass is allowed regardless of these tokens (no false-deny).
CF=$(mktemp -d); ( cd "$CF" && git init -q && git commit -q --allow-empty -m i && git branch -M main 2>/dev/null )
printf '{"mainBranch":"main"}' > "$CF/.shipgate.json"
GCFG_NONE2="$(mktemp -u)"
cfrun(){ printf '%s' "$1" | jq -Rsc '{tool_input:{command: .}}' | ( cd "$CF" && SHIPGATE_GLOBAL_CONFIG="$GCFG_NONE2" bash "$CP" ); }
# 1. The real shape: write-marker chained with the push in ONE command, NO prior marker => the SPECIFIC deny.
cf1=$(cfrun 'bash ~/.claude/skills/ship/ship-gate.sh write-marker ship --gate && git push origin main')
assert_contains "$cf1" "deny"              "CF: combined write-marker && push (no marker) => deny"
assert_contains "$cf1" "SEPARATE Bash"     "CF: combined form => the SPECIFIC actionable message (not the generic deny)"
# 2. No-false-fire: a real lone push (no marker) must hit the GENERIC deny, NOT the compound message.
cf2=$(cfrun 'git push origin main')
assert_contains "$cf2" "deny"              "CF: lone push (no marker) => deny"
assert_contains "$cf2" "No ship-gate pass" "CF: lone push => GENERIC deny path (compound message did NOT fire)"
# 3. HARDENED: a push that carries BOTH tokens in its text but already holds a VALID pass is ALLOWED — the
#    compound message is gated on a marker FAILURE, so a valid marker is never overridden (no false-deny).
mkdir -p "$CF/.git/shipgate"
printf '{"head":"%s","branch":"main","ts":%s,"hotfix":false}' "$(git -C "$CF" rev-parse HEAD)" "$(date +%s)" > "$CF/.git/shipgate/last-pass.json"
cf3=$(cfrun 'git push origin main # ship-gate write-marker note')
assert_eq "$cf3" ""                        "CF: valid marker + command carries both tokens => ALLOW (compound msg gated on marker failure)"
# 4. The compound message still wins over a GENERIC failure other than no-marker: a STALE marker (points at a
#    DIFFERENT commit) + the combined shape => the specific compound deny, not the bare 'different commit'.
printf '{"head":"%s","branch":"main","ts":%s,"hotfix":false}' "0000000000000000000000000000000000000000" "$(date +%s)" > "$CF/.git/shipgate/last-pass.json"
cf4=$(cfrun 'bash ship-gate.sh write-marker ship --gate && git push origin main')
assert_contains "$cf4" "SEPARATE Bash"     "CF: combined form + STALE marker (diff commit) => compound msg wins over generic 'different commit'"
# 5. ...and over an EXPIRED marker (the OTHER realistic combined-command failure: a day-old pass). Marker is
#    for the CORRECT commit but ts=1 (long expired) => fails the TTL check; the combined shape still surfaces
#    the compound message, not the bare 'expired' — locks the TTL failure path routes through _gate_fail too.
printf '{"head":"%s","branch":"main","ts":1,"hotfix":false}' "$(git -C "$CF" rev-parse HEAD)" > "$CF/.git/shipgate/last-pass.json"
cf5=$(cfrun 'bash ship-gate.sh write-marker ship --gate && git push origin main')
assert_contains "$cf5" "SEPARATE Bash"     "CF: combined form + EXPIRED marker => compound msg wins over generic 'expired'"

assert_summary
