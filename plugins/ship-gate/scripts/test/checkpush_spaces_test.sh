#!/usr/bin/env bash
# Regression guard for the Gate-B ship-stopper (2026-05-29): the plugin's hook command must
# survive a ${CLAUDE_PLUGIN_ROOT} that contains spaces (e.g. ".../Claude Code/..."). If the
# hooks.json command path is unquoted, /bin/sh splits it, check-push.sh never runs, and Claude
# treats the hook *execution error* as non-blocking -> the push proceeds = FAIL-OPEN.
# This test runs the ACTUAL command string from hooks.json the same way Claude Code does
# (sh -c with CLAUDE_PLUGIN_ROOT exported), against a plugin copy living under a spaced path.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/assert.sh"
PLUGIN_DIR="$(cd "$DIR/../.." && pwd)"          # .../plugins/ship-gate
HOOKS="$PLUGIN_DIR/hooks/hooks.json"

# The real hook command, e.g.  bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-push.sh"
CMD=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$HOOKS")

# D9: the inner hook must NOT carry a gating `if`. An `if: "Bash(git push *)"` is an
# anchored-prefix matcher that skips the hook for any command not literally starting with
# "git push " (FOO=bar git push, git -C path push, ...) => fail-open above the script.
# No `if` => matcher:"Bash" fires check-push.sh on every Bash command (the script is the
# sole, complete gate; its `case *push*` fast-path keeps non-push overhead negligible).
HOOK_IF=$(jq -r '.hooks.PreToolUse[0].hooks[0].if // ""' "$HOOKS")
assert_eq "$HOOK_IF" "" "plugin hooks.json inner hook has NO gating 'if' (D9: script is sole gate)"

# Stage a copy of the (self-contained) hook script under a path WITH A SPACE.
BASE=$(mktemp -d); ROOT="$BASE/with space/plug"; mkdir -p "$ROOT/scripts"
cp "$PLUGIN_DIR/scripts/check-push.sh" "$ROOT/scripts/"

# A no-marker git repo to act as cwd (push to main must be denied).
# It must have a .shipgate.json so the opt-in gate engages (no file => the hook allows).
R=$(mktemp -d); ( cd "$R" && git init -q -b main && git -c user.email=t@e.com -c user.name=t commit -q --allow-empty -m init && printf '{"mainBranch":"main"}' > .shipgate.json )

GCFG_TEST="$(mktemp -u)"
HJ='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
OUT=$(cd "$R" && printf '%s' "$HJ" | CLAUDE_PLUGIN_ROOT="$ROOT" SHIPGATE_GLOBAL_CONFIG="$GCFG_TEST" sh -c "$CMD" 2>&1)

assert_contains "$OUT" "deny"                 "spaced-path hook command still DENIES (no marker)"
assert_contains "$OUT" "No ship-gate pass"    "deny reason surfaces on a spaced plugin path"
case "$OUT" in
  *"No such file"*|*"not found"*) assert_eq "path-split-error" "none" "hook command must NOT break on the space (regression: unquoted path)";;
  *)                              assert_eq "none" "none"             "no path-split error on spaced plugin root";;
esac

rm -rf "$BASE" "$R"
assert_summary
