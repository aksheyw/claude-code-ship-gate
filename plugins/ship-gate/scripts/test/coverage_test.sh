#!/usr/bin/env bash
# File-coverage manifest (2026-07-23). THE GAP: the codeReview gate is a JUDGMENT gate — an LLM reads the
# diff and returns a verdict. On a large changeset (the real case: 20 commits, 44 files) a model quietly
# reviews a subset and still reports "looks good", and nothing in ship-gate ever asserted otherwise. The
# deterministic tier had no say in WHICH files got looked at.
#
# THE FIX, in this project's own idiom (deterministic engineering decides what must not be got wrong; the
# agent judges): `ship-gate.sh changed-files` emits the authoritative list of files in the shipped change,
# computed in bash from git — not from the model's reading of the diff. /ship then requires the reviewer to
# account for every path on that list before the gate can go green (SKILL.md step 4).
#
# Deliberately NOT a new deterministic gate: it produces a manifest, never a pass/fail. The runner keeps
# exit-code semantics for gates that actually EXECUTE something.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/assert.sh"; . "$DIR/../lib/config.sh"
SG="$DIR/../ship-gate.sh"

mk(){ local d; d=$(mktemp -d); git -C "$d" init -q
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$d" branch -M main
  printf '%s\n' "$d"; }
commit_on(){ git -C "$1" add -A >/dev/null 2>&1; git -C "$1" -c user.email=t@t -c user.name=t commit -qm "$2"; }

# --- committed changes on a feature branch are listed (the shipped range vs the protected branch) -------
A=$(mk); git -C "$A" checkout -qb feature
mkdir -p "$A/src"; : > "$A/src/one.js"; : > "$A/src/two.js"; commit_on "$A" work
outA=$(bash "$SG" changed-files "$A")
assert_contains "$outA" "src/one.js" "changed-files: committed file on a feature branch is listed"
assert_contains "$outA" "src/two.js" "changed-files: every committed file is listed, not just the first"

# --- staged, unstaged and untracked all count: /ship runs the gates BEFORE committing, so a file that is
# --- only staged (or not yet added) is still part of what is about to ship and must be reviewed ---------
B=$(mk); git -C "$B" checkout -qb feature
: > "$B/tracked.js"; commit_on "$B" base
printf 'x\n' > "$B/tracked.js"                                   # unstaged modification
: > "$B/staged.js"; git -C "$B" add staged.js                     # staged addition
: > "$B/untracked.js"                                             # untracked new file
outB=$(bash "$SG" changed-files "$B")
assert_contains "$outB" "tracked.js" "changed-files: unstaged modification counted"
assert_contains "$outB" "staged.js" "changed-files: staged addition counted"
assert_contains "$outB" "untracked.js" "changed-files: untracked new file counted (it ships too)"

# --- git-ignored files must NOT appear (they are not part of the change under review) -------------------
C=$(mk); git -C "$C" checkout -qb feature
printf 'secrets/\n' > "$C/.gitignore"; commit_on "$C" ignore
mkdir -p "$C/secrets"; : > "$C/secrets/key.txt"; : > "$C/real.js"
outC=$(bash "$SG" changed-files "$C")
assert_contains "$outC" "real.js" "changed-files: a real new file is listed"
case "$outC" in *secrets/key.txt*) assert_eq "listed-ignored" "excluded" "changed-files: git-ignored files must not be listed";; *) : ;; esac

# --- no duplicates: a file that is both committed in the range AND modified again must appear once ------
D=$(mk); git -C "$D" checkout -qb feature
: > "$D/dup.js"; commit_on "$D" add
printf 'more\n' > "$D/dup.js"                                     # now also unstaged
n=$(bash "$SG" changed-files "$D" | grep -c '^dup\.js$')
assert_eq "$n" "1" "changed-files: a path appears exactly once even when committed AND modified"

# --- a clean repo sitting on the protected branch with nothing pending yields an empty list, exit 0 -----
E=$(mk)
erc=0; oute=$(bash "$SG" changed-files "$E") || erc=$?
assert_eq "$erc" "0" "changed-files: clean repo exits 0"
assert_eq "$oute" "" "changed-files: clean repo lists nothing"

# --- outside a git repo: empty and exit 0, never a crash under set -e -----------------------------------
NR=$(mktemp -d)
nrc=0; outnr=$(bash "$SG" changed-files "$NR") || nrc=$?
assert_eq "$nrc" "0" "changed-files: non-git directory exits 0 (no set -e abort)"
assert_eq "$outnr" "" "changed-files: non-git directory lists nothing"

# --- paths with spaces and non-ASCII survive intact. git QUOTES non-ASCII paths by default, which would
# --- hand the reviewer a mangled path it cannot match against the diff; core.quotePath=false prevents it.
F=$(mk); git -C "$F" checkout -qb feature
mkdir -p "$F/a dir"; : > "$F/a dir/my file.js"; : > "$F/café_señor.js"
outF=$(bash "$SG" changed-files "$F")
assert_contains "$outF" "a dir/my file.js" "changed-files: a path containing spaces is listed intact"
assert_contains "$outF" "café_señor.js" "changed-files: a non-ASCII path is byte-exact, not octal-escaped"
case "$outF" in *'\3'*) assert_eq "escaped" "byte-exact" "changed-files: no git octal escaping in the manifest";; *) : ;; esac

# --- the manifest is one path per line, so a consumer can count it and diff it against what was reviewed
G=$(mk); git -C "$G" checkout -qb feature
mkdir -p "$G/p"; for i in 1 2 3 4 5; do : > "$G/p/f$i.js"; done; commit_on "$G" many
lines=$(bash "$SG" changed-files "$G" | wc -l | tr -d ' ')
assert_eq "$lines" "5" "changed-files: emits exactly one path per line (countable coverage denominator)"

# --- it is a MANIFEST, not a gate: it never fails the ship on its own, whatever the change looks like ---
H=$(mk); git -C "$H" checkout -qb feature
: > "$H/x.js"; commit_on "$H" x
hrc=0; bash "$SG" changed-files "$H" >/dev/null || hrc=$?
assert_eq "$hrc" "0" "changed-files: always exits 0 — it reports scope, it does not gate"

assert_summary
