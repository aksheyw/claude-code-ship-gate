#!/usr/bin/env bash
set -euo pipefail
INPUT=$(cat)
# Extract the command, NON-FATALLY. Under `set -e`, a failing `jq` (non-JSON stdin)
# would abort the hook with a non-zero exit BEFORE any decision — and Claude treats a
# hook *error* as non-blocking, so the gated command would proceed (FAIL-OPEN). So we
# swallow jq failure and treat unparseable/empty stdin as "no command" => allow below.
# Safe: the JSON envelope is harness-controlled and the command is an opaque value, so
# malformed stdin is a broken-harness case — it cannot smuggle a real push (no reachable
# bypass). Denying here would only break the user's session on a harness glitch.
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null) || CMD=""

# Phase 8: global config path. Env override is a hermetic-test seam + power-user knob, read from the
# hook's OWN environment (agent-proof: an agent cannot set/persist it mid-session). Default ~/.shipgate.json.
GCFG="${SHIPGATE_GLOBAL_CONFIG:-${HOME:+$HOME/.shipgate.json}}"

# --- O(n) cheap pre-filter (D2): a command with no `push` substring anywhere CANNOT be a
# git push, so bail before the jq config spawns AND before the O(n) tokenizer. bash glob
# `case` is a single O(n) scan with NO subprocess — it cannot be quadratic. This both closes
# the timeout-padding fail-open (a 100k command with no `push` exits here in microseconds)
# and avoids spawning jq for the overwhelmingly common non-push command. Placed FIRST (right
# after command extraction), before the repo check + enablement ladder + mainBranch/TTL config,
# so a non-push command does ZERO git/jq work.
#
# F1 (continuation-aware): a backslash-newline line continuation can split the word `push` itself
# (`git pu\<NL>sh` is `git push` to bash) — the RAW command then has NO literal `push` substring, so a
# naive *push* test would exit 0 (allow) BEFORE the awk gsub that folds continuations ever runs (fail-open).
#
# F-SG-2026-07-04 — this MUST stay O(n). The prior fix here folded continuations with a bash
# `${CMD//\<NL>/}` substitution, which is O(n^2) in bash 3.2 on the COUNT of `\<newline>` sequences: ~12k
# of them (~24KB) drove the WHOLE hook past its 15s timeout, which Claude treats as NON-BLOCKING = the very
# fail-open this pre-filter exists to close. So we do NOT fold here. Instead the fast-exit is refused for a
# command that could hide a split push: proceed if it literally contains `push`, OR contains a `\<newline>`
# continuation — in the latter case the O(n) C awk parser below folds correctly (its own gsub) and decides.
# A command with NEITHER cannot be a git push, so it exits. `case` glob is a single O(n) scan with no
# string-building and no subprocess — it cannot go quadratic (verified: 20k continuations in ~2ms vs ~85s
# for the old substitution). The awk stage re-derives its own buffer from $CMD, so this gate never alters
# downstream tokenization. (NL is a real newline via the $'\n' literal.)
_NL=$'\n'
case "$CMD" in
  *push*)       : ;;                      # literal push present => inspect (the awk parser decides precisely)
  *"\\${_NL}"*) : ;;                      # a line-continuation could hide `pu\<NL>sh` => cannot fast-exit
  *)            exit 0 ;;                  # neither => cannot be a git push => allow (backup)
esac

# --- Self-contained config resolution: read .shipgate.json directly.
# Precedence: .shipgate.json → env var → built-in default.
# If .shipgate.json is absent or invalid JSON, fall through to env/default without crashing.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
CFG="${REPO_ROOT:+$REPO_ROOT/.shipgate.json}"
cfg_get(){
  [ -n "$REPO_ROOT" ] || { echo ""; return 0; }
  [ -f "$CFG" ] || { echo ""; return 0; }
  jq empty "$CFG" 2>/dev/null || { echo ""; return 0; }
  jq -r "$1 // empty" "$CFG" 2>/dev/null || echo ""
}

# --- OPT-IN GATE (Task 7.1): the hook guards a repo ONLY if it has opted in.
# A repo is gated iff .shipgate.json exists at the repo root AND its top-level
# "enabled" is not literally false. No repo root or no .shipgate.json => the repo
# has not adopted ship-gate => ALLOW (exit 0). "enabled":false => opted out => ALLOW
# (the file is kept for /ship's use; enforcement is paused).
#
# This is the ONE place where "allow" is the safe default: a repo that never adopted
# ship-gate must not be gated. Everything past this point is fail-CLOSED.
#
# CRITICAL: read .enabled WITHOUT jq's `//` operator. `//` treats BOTH false and null
# as "absent", so `.enabled // true` would yield "true" for {"enabled":false} — a
# fail-OPEN bug. Opt out ONLY for a real JSON boolean false. `jq -r .enabled` renders
# BOTH boolean false AND the STRING "false" as bare `false`, so a string "false" (a
# malformed config — schema says boolean) would silently un-gate; wrong direction for a
# security gate. The `if .enabled == false` test matches ONLY the boolean, so string
# "false", true, null, absent, and invalid JSON all yield "x" => gated (fail-closed).
[ -n "$REPO_ROOT" ] || exit 0
# Ladder step 2 (P8): session kill-switch, agent-proof (read from the hook's own env). Checked BEFORE
# any config-file read so it is the unbrickable escape even if a config file is malformed.
if printf '%s' "${SHIPGATE_DISABLE:-}" | grep -qiE '^(1|true|yes|on)$'; then exit 0; fi
# Ladder step 3 (P8): global ~/.shipgate.json enabled:false = unconditional machine-wide kill.
# Only a REAL JSON boolean false kills (string "false"/null/absent/malformed never silently disables).
if [ -n "$GCFG" ] && [ -f "$GCFG" ]; then
  _g_enabled=$(jq -r 'if .enabled == false then "false" else "x" end' "$GCFG" 2>/dev/null || echo x)
  [ "$_g_enabled" = "false" ] && exit 0
fi
# Ladder step 4 (P8): persistent per-repo opt-out via /ship off. Use --git-common-dir so it works in
# linked worktrees (where $REPO_ROOT/.git is a FILE, not a dir).
# Resolve via -C "$REPO_ROOT" so a relative result (".git") is relative to the repo root, not the hook
# CWD. From a repo SUBDIR a bare `git rev-parse --git-common-dir` returns "../.git"; joining that to the
# absolute $REPO_ROOT gave "$REPO_ROOT/../.git" (the PARENT dir) and the sentinel was missed (verified).
_GCDIR=$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo "")
if [ -n "$_GCDIR" ]; then
  case "$_GCDIR" in /*) : ;; *) _GCDIR="$REPO_ROOT/$_GCDIR" ;; esac   # relative => anchor to repo root
  [ -f "$_GCDIR/shipgate/disabled" ] && exit 0
fi
# Ladder steps 5+6 (P8). Per-repo file present: enabled:false => allow, else GATED (incl. malformed
# => fail-closed). Per-repo file ABSENT: consult the global defaultEnabled (only a real boolean true
# turns on default-on); absent/false/non-bool => opt-in => allow. Malformed GLOBAL handled in A5.
if [ -f "$CFG" ]; then
  _enabled=$(jq -r 'if .enabled == false then "false" else "x" end' "$CFG" 2>/dev/null || echo x)
  [ "$_enabled" = "false" ] && exit 0
  # present and not opted out => GATED (fall through)
else
  if [ -n "$GCFG" ] && [ -f "$GCFG" ]; then
    # An unreadable / non-JSON / non-object global config is a LOUD, escapable failure — never a silent
    # opt-in (which would silently drop default-on protection). Each case gets an ACCURATE fix message;
    # SHIPGATE_DISABLE (checked above) escapes all of them.
    if [ ! -r "$GCFG" ]; then
      jq -n --arg r "ship-gate: ${GCFG} is not readable (check file permissions), or set SHIPGATE_DISABLE=1 to bypass." \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
      exit 0
    fi
    if ! jq empty "$GCFG" 2>/dev/null; then
      jq -n --arg r "ship-gate: ${GCFG} is not valid JSON. Fix it, or set SHIPGATE_DISABLE=1 to bypass." \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
      exit 0
    fi
    if ! jq -e 'type == "object"' "$GCFG" >/dev/null 2>&1; then
      jq -n --arg r "ship-gate: ${GCFG} must be a JSON object (e.g. {\"defaultEnabled\":true}). Fix it, or set SHIPGATE_DISABLE=1 to bypass." \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
      exit 0
    fi
    _default=$(jq -r 'if .defaultEnabled == true then "true" else "x" end' "$GCFG" 2>/dev/null || echo x)
    [ "$_default" = "true" ] || exit 0
  else
    exit 0
  fi
fi

# Protected-branch SET resolution (mirrors the runner's sg_protected_branches in lib/config; the hook is
# self-contained so the logic is replicated inline). Ladder, first match wins: per-repo .mainBranch ->
# global .mainBranch -> $SHIPGATE_MAIN_BRANCH -> origin/HEAD (symbolic-ref, robust when unset) ->
# {main master}. Emits one branch per line.
_resolve_protected(){
  local m="" d
  # Only a NON-EMPTY STRING mainBranch is honored. null / number / array / bool / "" / a malformed file
  # all yield empty => fall through to the next rung (fail-closed: gate the real branch, never a fictional
  # one). The `|| true` keeps a malformed-file jq failure from aborting the hook under set -e (=fail-open).
  [ -f "$CFG" ] && m=$(jq -r 'if (.mainBranch|type)=="string" and (.mainBranch|length)>0 then .mainBranch else empty end' "$CFG" 2>/dev/null || true)
  if [ -z "$m" ] && [ -n "$GCFG" ] && [ -f "$GCFG" ]; then
    m=$(jq -r 'if (.mainBranch|type)=="string" and (.mainBranch|length)>0 then .mainBranch else empty end' "$GCFG" 2>/dev/null || true)
  fi
  [ -z "$m" ] && m="${SHIPGATE_MAIN_BRANCH:-}"
  if [ -n "$m" ]; then printf '%s\n' "$m"; return; fi
  d=$(git -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo ""); d="${d#origin/}"
  [ -n "$d" ] && { printf '%s\n' "$d"; return; }
  printf 'main\nmaster\n'
}
# ERE-escape a literal branch name so it is matched as a fixed token in the refspec grep (P8-6: git
# allows . | ( ) + { } in branch names; unescaped they are regex metacharacters => mis-match or grep error).
# (] } - are intentionally NOT escaped: outside a bracket expression they are ERE literals, and esc is
# interpolated between a closed [..] class and a (..) group here, so they never gain metachar status — verified on BSD+GNU grep.)
_ere_escape(){ printf '%s' "$1" | sed 's/[.[\(*^$+?{|)]/\\&/g'; }
_t=$(cfg_get '.markerTtlSeconds')

# Validate TTL is a positive integer; fall back to 900 if not.
if printf '%s' "${_t:-}" | grep -qE '^[1-9][0-9]*$'; then
  TTL="${_t}"
else
  TTL="${SHIPGATE_TTL:-900}"
fi
# Ensure SHIPGATE_TTL env override is also validated if _t was absent
if [ -z "${_t:-}" ] && [ -n "${SHIPGATE_TTL:-}" ]; then
  if printf '%s' "$SHIPGATE_TTL" | grep -qE '^[1-9][0-9]*$'; then
    TTL="$SHIPGATE_TTL"
  else
    TTL="900"
  fi
fi

deny(){ jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }

# --- Command-position-aware "is this a git push?" detection (O(n)).
# The old check grepped the WHOLE command for "git push", which (a) false-POSITIVES on
# the substring inside a quoted string (a commit message, an echo) and (b) false-NEGATIVES
# on "git -C <path> push" (no adjacent "git push"). Both are fixed here.
#
# A command is a git push when, in SOME command segment, the first word is `git`, then
# zero or more git GLOBAL options, then `push` as the next word. We split the command into
# segments and tokenize each, honoring single/double quotes so a separator or the word
# `push` INSIDE quotes never counts.
#
# WHY AWK: the previous bash implementation walked the string with ${s:i:1} inside a for
# loop. Indexed substring extraction in a loop is O(n^2) in bash — a 100k-char command took
# ~100s. The hook times out at 15s and Claude treats a hook TIMEOUT as NON-BLOCKING, so a
# padded command would evade the gate (FAIL-OPEN). awk processes input in C in a single
# O(n) pass. We pass $CMD on STDIN (not -v, which has backslash-escaping pitfalls) and set
# RS to a NUL-free control sentinel so awk reads the WHOLE input as ONE record — our state
# machine handles embedded newlines itself (an UNQUOTED newline is a segment separator; a
# QUOTED newline stays in the token). awk is POSIX-ubiquitous (macOS/Linux/WSL/git-bash).
# PORTABILITY: escapes use OCTAL (\001 sentinel, \047 single-quote) — \xNN hex escapes are a
# gawk/BWK extension that historical mawk (Debian/Ubuntu /usr/bin/awk) does NOT honor; octal
# is POSIX and works on gawk, mawk, and BWK awk alike.
#
# DEPENDENCY/FAIL-CLOSED: if awk is missing or errors, we DO NOT silently treat the command
# as "not a push" (that would be fail-OPEN). The pre-filter above already guarantees $CMD
# contains "push", so on awk failure we fall through to the (fail-CLOSED) downstream marker
# logic rather than allowing — i.e. "contains push, parse uncertain" => proceed to gate.

# _awk_is_push: O(n) single-pass tokenizer/segmenter. Reads $CMD on stdin (one record).
# Exit 0 if some segment is `git [globals...] push`; exit 1 otherwise.
# Semantics mirror the old bash code exactly:
#   - segment separators (UNQUOTED): ; & | newline  (& and | are the intentional safe
#     superset of && and ||).
#   - token separators (UNQUOTED): space and tab.
#   - quote chars (' ") are RETAINED in the token; inside a quote, separators/whitespace
#     and the word `push` do not split or terminate.
#   - QUOTE FLAVORS (parity must match bash so a quoted mention cannot leak as a real push):
#       * plain '...'  : backslash is LITERAL; the string ends at the next '.
#       * "..."        : backslash escapes the next char; \" does NOT close (quote stays open).
#       * $'...'       : bash ANSI-C quoting — backslash ESCAPES inside, so \' is a literal
#                        apostrophe that does NOT close; the string ends at the next UNescaped
#                        '. An odd number of \' flips quote parity in bash, so the machine must
#                        model it or a `commit -m $'it\'s'` + push leaks as ALLOW (fail-open).
#                        Modeled via the sqesc flag in the single-quote branch below.
#       * $"..."       : locale double-quote — behaves like "..."; handled by the "-branch
#                        (the bare $ is an ordinary in-token char; the following " opens it).
#   - token0 must be literally `git` (quoted "git" keeps quotes and won't match).
#   - skip globals: -C / -c / --git-dir / --work-tree / --namespace each consume the
#     FOLLOWING token (space-separated value form); any other -… token (incl. --foo=bar
#     and the =-forms like --git-dir=/p) skips itself only.
#   - the next token after the globals must be literally `push`.
_AWK_PROG='
# Tokens are stored as (start,len) indices into the char array ch[] — NEVER as accumulated
# strings. Accumulating a token via "tok = tok c" in the char loop is O(n^2) in BWK awk
# (each concat re-copies the growing string); a single giant filler token would reopen the
# timeout-padding fail-open. (start,len) bookkeeping is O(1) per char.
function reset_seg() { ntok = 0; ts = 0; tl = 0; started = 0 }
function end_tok() { if (started) { ntok++; tstart[ntok] = ts; tlen[ntok] = tl; started = 0 } }
# tokval(k): materialize token k from ch[]. ONLY call after length-gating (k is short),
# so we never build a huge string. O(len of token k).
function tokval(k,   s, p, e) { s = ""; p = tstart[k]; e = p + tlen[k] - 1; for (; p <= e; p++) s = s ch[p]; return s }
# tokeq(k, want): true iff token k equals literal `want`. Length-gate first (O(1)) so a
# giant token short-circuits without materialization.
function tokeq(k, want) { if (tlen[k] != length(want)) return 0; return tokval(k) == want }
# is_assign(k): true iff token k is a shell env-assignment prefix: a valid shell NAME
# (^[A-Za-z_][A-Za-z0-9_]*) immediately followed by the = sign. Scans ch[] directly from
# the token start — O(token length), no materialization of a huge token. A token with no =
# (e.g. a long filler) bails at the first non-name char, so the scan stays O(n) overall.
# NOTE: comments here avoid a literal single-quote on purpose — _AWK_PROG is a bash
# single-quoted string, so a stray apostrophe would terminate it and corrupt the program.
function is_assign(k,   p, e, first, ci, c2) {
  p = tstart[k]; e = p + tlen[k] - 1
  if (p > e) return 0                 # empty token cannot be an assignment
  for (ci = p; ci <= e; ci++) {
    c2 = ch[ci]
    if (c2 == "=") return (ci > p)    # = ends the name; assignment iff the name was non-empty
    first = (ci == p)
    if (first) {                      # first char: [A-Za-z_]
      if (!((c2 >= "A" && c2 <= "Z") || (c2 >= "a" && c2 <= "z") || c2 == "_")) return 0
    } else {                          # subsequent: [A-Za-z0-9_]
      if (!((c2 >= "A" && c2 <= "Z") || (c2 >= "a" && c2 <= "z") || (c2 >= "0" && c2 <= "9") || c2 == "_")) return 0
    }
  }
  return 0                            # reached end of token without an = sign => not an assignment
}
function seg_is_push(   j, cw) {
  # Skip leading env-assignment tokens (VAR=value ...). Each is a SINGLE token; do NOT
  # consume a following token. The first non-assignment token is the command word.
  cw = 1
  while (cw <= ntok && is_assign(cw)) cw++
  if (cw > ntok) return 0             # nothing but assignments => not a command
  if (!tokeq(cw, "git")) return 0     # command word must be literally git
  j = cw + 1
  while (j <= ntok) {
    # value-taking globals (space-separated value form): skip the option AND its value.
    if (tokeq(j, "-C") || tokeq(j, "-c") || tokeq(j, "--git-dir") || tokeq(j, "--work-tree") || tokeq(j, "--namespace")) { j += 2; continue }
    # any other option token (incl. --foo=bar and =-forms like --git-dir=/p): skip itself.
    # Only need the FIRST char — O(1), no materialization of a long flag value.
    if (tlen[j] >= 1 && ch[tstart[j]] == "-") { j += 1; continue }
    break
  }
  if (j <= ntok && tokeq(j, "push")) return 1
  return 0
}
# scan(s): O(n) single-pass tokenizer/segmenter over the WHOLE reconstructed command buffer
# s. Sets the global `found` to 1 if some segment is `git [globals...] push`. Returns early
# once found. Pulled into a function (was inline in the main rule) because F3 moves the scan
# to END over a reconstructed buffer rather than over a single RS-delimited record.
#
# PERF: split the buffer into a per-character array ONCE (split is O(n)), then index the
# array (O(1) per access). We must NOT call substr(s,i,1) inside the loop — in BWK awk
# (macOS /usr/bin/awk) substr re-walks from the start each call, which is O(n^2). split is
# linear, and we track token boundaries (not strings) so the whole pass is O(n).
function scan(s,   q, esc, sqesc, n, i, c) {
  q = ""          # current open quote char ("" = none; "\047" = single; "\"" = double)
  esc = 0         # escaped flag: previous char was an active backslash escape
  sqesc = 0       # 1 iff the open single-quote was opened via dollar+\047 (bash ANSI-C
                  # quoting, which HONORS backslash escapes); 0 for a PLAIN single-quote
                  # (backslash literal). NOTE: comments here must NOT contain a literal
                  # single-quote char — _AWK_PROG is a bash single-quoted string; a stray
                  # one would terminate it. Use the word or \047 instead.
  reset_seg()
  n = split(s, ch, "")
  for (i = 1; i <= n; i++) {
    c = ch[i]
    # Backslash-escape parity (mirror bash). When set, THIS char is an ordinary in-token
    # char with NO special role (not quote/separator/whitespace); clear the flag. The
    # backslash that set it was itself an in-token char (handled below where esc is SET),
    # so the token is already started — just extend it.
    if (esc) {
      tl++                         # token already started by the backslash; extend it
      esc = 0
    } else if (q == "\047") {      # \047 = single quote (octal, POSIX).
      # PLAIN single-quote (sqesc==0): backslash is LITERAL; only \047 closes.
      # ANSI-C dollar+\047 (sqesc==1): backslash ESCAPES the next char (so a \047 right after
      #   a backslash does NOT close, mirroring bash); an UNescaped \047 closes and clears
      #   sqesc. (No literal single-quote in these comments on purpose — see note above.)
      tl++
      if (sqesc && c == "\\") esc = 1             # ANSI-C: backslash escapes next; \\047 stays in-token
      else if (c == "\047") { q = ""; sqesc = 0 } # unescaped \047 closes (both plain and ANSI-C)
    } else if (q == "\"") {        # double quote: backslash escapes next; " closes; else in-token
      tl++
      if (c == "\\") esc = 1       # \\ literal, \" does NOT close — keeps quote parity
      else if (c == "\"") q = ""
    } else if (c == "\\") {        # unquoted backslash: escapes next char (\;, \ , \" are literal)
      if (!started) { ts = i; tl = 0; started = 1 }
      tl++
      esc = 1
    } else if (c == "$" && i < n && ch[i+1] == "\047") {  # unquoted dollar+\047 : ANSI-C string.
      # O(1) lookahead (ch[i+1], guarded by i<n so no out-of-bounds; an out-of-range index
      # would just read empty and not match). Consume BOTH the dollar and the opening \047 as
      # in-token chars, then enter single-quote state with escapes HONORED (sqesc=1). i++ steps
      # past the \047. dollar+doublequote (locale string) is NOT matched here: a bare dollar
      # falls through to the ordinary-in-token case and the following doublequote opens a
      # normal double-quote via the branch above — so dollar+doublequote stays correct.
      if (!started) { ts = i; tl = 0; started = 1 }
      tl++          # the dollar
      tl++          # the opening \047 (we consume i+1 here)
      i++           # advance past the \047 so the loop does not re-read it
      q = "\047"
      sqesc = 1
    } else if (c == "\047" || c == "\"") {   # unquoted quote: open quote, char is in-token
      q = c
      if (!started) { ts = i; tl = 0; started = 1 }
      tl++
    } else if (c == ";" || c == "&" || c == "|" || c == "\n" || c == "(" || c == ")") {
      # unquoted segment separator. ( and ) are shell metacharacters that ALWAYS separate
      # commands (subshell grouping), so `(git push)` / `(cd x && git push)` end a segment at
      # the paren — without this, `push` glued to `)` (token `push)` != `push`) and the gate
      # missed (fail-open). A QUOTED paren never reaches here (it is consumed by the quote
      # branches above), so `echo "(git push)"` stays a single echo segment (no false positive).
      end_tok()
      if (seg_is_push()) { found = 1; return }
      reset_seg()
    } else if (c == " " || c == "\t") {       # unquoted token separator
      end_tok()
    } else {                       # ordinary in-token char (incl. any control byte such as
      if (!started) { ts = i; tl = 0; started = 1 }   # 0x01 SOH — see F3 below; it does not
      tl++                                            # split, it is just token data)
    }
  }
  # A trailing backslash at end-of-input leaves esc=1 with no next char: the backslash was
  # already counted as an in-token char above, so the token simply ends below. No crash.
  end_tok()
  if (seg_is_push()) found = 1
}
{
  # F3 FIX — read the ENTIRE stdin as ONE buffer regardless of content. The old code set
  # RS="\001" assuming 0x01 never appears in a command; false — a SOH can ride through the JSON
  # envelope as a literal byte and SPLIT the single record into many, resetting quote state
  # mid-string (parity scramble => fail-open). Here RS is the DEFAULT (newline): each input
  # line is a record, and we reconstruct the original command by re-joining records with "\n"
  # (NR>1 ? "\n" : "" puts the separators back exactly). Any control byte (incl. 0x01) is now
  # ordinary record DATA and reaches the state machine as an in-token char; real embedded
  # newlines are restored and the state machine still treats an UNQUOTED one as a separator.
  buf = buf (NR > 1 ? "\n" : "") $0
}
END {
  # F1 FIX — remove backslash-newline LINE CONTINUATIONS before tokenizing. In bash a
  # backslash immediately followed by a newline is removed and the surrounding text joined
  # (`git \<NL>push` == `git push`; `gi\<NL>t push` == `git push`). Doing this string-level on
  # the whole buffer mirrors bash and is the single place the join can happen. SAFE inside
  # single-quotes (where bash keeps \<NL> literal): removal only SHORTENS inert quoted DATA —
  # the single-quote bytes (0x27) are never a backslash or newline, so quote boundaries are
  # untouched; it cannot forge or hide an unquoted push. O(n): one linear gsub pass.
  gsub(/\\\n/, "", buf)
  scan(buf)
  exit (found ? 0 : 1)
}
'

# is_git_push -> exit 0 if $CMD contains a git push in any command segment.
# Fail-closed on awk error/absence: $CMD is already known to contain "push" (pre-filter),
# so an uncertain parse must NOT allow — return 0 ("treat as push") to reach the downstream
# fail-closed marker check rather than skipping the gate.
is_git_push(){
  local rc
  # DEFAULT RS (newline): each input line is a record; _AWK_PROG's main rule re-joins records
  # with "\n" into one buffer and the END block runs the F1 gsub + scan over it. (Was
  # RS="\001" — removed in the F3 fix: a SOH byte could appear in the command and split the
  # record, scrambling quote parity = fail-open. See _AWK_PROG main-rule/END comments.)
  printf '%s' "$CMD" | awk "$_AWK_PROG"
  rc=$?
  case "$rc" in
    0) return 0 ;;   # awk found a push segment
    1) return 1 ;;   # awk ran cleanly and found none
    *) return 0 ;;   # awk missing/errored (rc 127/2/…): parse uncertain => fail-closed (gate it)
  esac
}

# Only act on git push
is_git_push || exit 0

# Resolve the push TARGET against the protected SET. A push is GATED iff its destination is a protected
# branch: (1) the refspec explicitly names one (literal match, preceded by space/ / + :, ended at a token
# boundary — catches "origin master", "origin/master", "+master", "HEAD:master", "-u origin master",
# "origin<TAB>master"), which takes PRECEDENCE; else (2) it is a bare push and the CURRENT branch is itself
# protected. An explicit push of a NON-protected branch while checked out on a protected branch is
# conservatively gated via the CUR fallback — the safe over-gate direction (a backup push is best done
# from the branch itself, or via an escape hatch). Branch names are ERE-escaped so metachars match literally.
CUR=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
TARGET=""; _cur_protected=""
while IFS= read -r B; do
  [ -n "$B" ] || continue
  [ "$CUR" = "$B" ] && _cur_protected="$B"
  esc=$(_ere_escape "$B")
  if printf '%s' "$CMD" | grep -qE "[[:space:]/+:]${esc}([[:space:]]|$)"; then TARGET="$B"; fi
done <<EOF
$(_resolve_protected)
EOF
[ -n "$TARGET" ] || TARGET="$_cur_protected"   # explicit refspec destination wins; else bare-push from a protected CUR
[ -n "$TARGET" ] || exit 0                      # not pushing a protected branch => allow (backup)
MAIN="$TARGET"

# Compound-command footgun (actionable error): a SINGLE command that both writes the pass marker AND pushes
# can NEVER pass on its OWN authority — this is a PreToolUse hook, so it reads the marker BEFORE the command
# runs; a same-command `write-marker` has not executed yet, leaving the marker as whatever a PRIOR /ship left
# (missing, or for a different commit) => one of the generic, baffling marker-validation denies below. We
# DETECT this shape here (an already-confirmed protected-branch push whose text also carries both the
# `write-marker` and `ship-gate` tokens) but only set a FLAG — the specific message is emitted by _gate_fail()
# ONLY on a marker-validation FAILURE. So a command that already holds a VALID pass is allowed (exit 0)
# regardless of these tokens (no false-deny), and a real lone `git push` never sets the flag.
COMPOUND=0
if printf '%s' "$CMD" | grep -q 'write-marker' && printf '%s' "$CMD" | grep -q 'ship-gate'; then COMPOUND=1; fi

# _gate_fail MSG: deny on a marker-validation failure. When the command is the compound write-marker+push
# shape, the ROOT CAUSE of the failure is that same-command stale marker, so surface the specific, actionable
# fix (run them as two separate commands — which /ship already does) instead of the generic reason.
_gate_fail() {
  if [ "$COMPOUND" = "1" ]; then
    deny "ship-gate: run 'write-marker' and 'git push' as SEPARATE Bash commands — do NOT combine them in one (e.g. NOT '… ship-gate.sh write-marker … && git push …'). This push-block hook checks the pass marker BEFORE your command runs, so a marker written in the SAME command has not taken effect yet, and the push is rejected. /ship already runs them as two separate steps."
  fi
  deny "$1"
}

# Resolve the marker via the COMMON git-dir (shared across all linked worktrees of the repo), anchored to
# $REPO_ROOT — the SAME path the disable sentinel uses (_GCDIR above) and the runner writes (lib/marker.sh
# sg_marker_path). This makes a marker written from the primary checkout, or from a worktree on a feature
# branch that integrated into the protected branch, visible to a hook firing from any worktree of the repo
# (worktree marker branch-mismatch fix). NOT --git-dir (per-worktree => invisible across worktrees) and NOT
# $REPO_ROOT/.git (a FILE in a linked worktree).
_MDIR=$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo "$REPO_ROOT/.git")
case "$_MDIR" in /*) : ;; *) _MDIR="$REPO_ROOT/$_MDIR" ;; esac
MARKER="$_MDIR/shipgate/last-pass.json"
[ -f "$MARKER" ] || _gate_fail "No ship-gate pass. Run /ship before pushing to ${MAIN}."

M_HEAD=$(jq -r '.head // empty' "$MARKER")
M_TS=$(jq -r '.ts // empty' "$MARKER")

# Guard: empty HEAD in marker is corrupt
[ -n "$M_HEAD" ] || _gate_fail "ship-gate marker is corrupt. Re-run /ship."

# Commit-identity check: the marker records the SHA of the protected branch that /ship verified. Compare it
# to the commit THIS push will actually LAND on the protected branch — NOT the session's checked-out HEAD
# (from a linked worktree on a feature branch the session HEAD is the feature tip, not the protected commit
# being pushed). All refs are resolved anchored to $REPO_ROOT so they are correct from a subdir / worktree.
#
# The landing commit depends on the refspec form:
#   * bare (`git push origin main`, `-u origin main`, `--all`): the local tip of $TARGET is what git sends.
#   * explicit `src:dst` (`feature:main`, `HEAD:main`, `+feature:main`): the SOURCE is what lands — $TARGET's
#     own ref is NOT sent and is irrelevant.
#
# F-SG-2026-07-01 — this used to resolve $TARGET unconditionally, which FAIL-OPENED on the explicit form:
# `git push origin feature:main` leaves local `main` untouched, so a valid marker for `main` still matched
# while UNGATED feature commits landed on the protected branch. (The old comment here claimed such a push
# "can never fail OPEN" — that only ever held for the mismatch direction.) So: when the command carries an
# explicit refspec aimed at $TARGET, resolve the SOURCE and compare THAT to the marker.
_ESC_T=$(_ere_escape "$TARGET")
# Split the command into whitespace-separated tokens (one per line) and keep those of the form
# [+]<src>:<dst> whose dst names $TARGET. git DWIM-resolves a push destination through exactly three
# branch spellings — bare `main`, `heads/main`, and fully-qualified `refs/heads/main` — so the dst
# alternation covers all three (NOT a leaky whitelist: these are the only prefixes git accepts for a
# branch ref; verified against a real bare remote). Token-anchored (^…$) so a dst that merely CONTAINS
# the branch name cannot match. Scans the RAW command ($CMD): a QUOTED refspec (`"feature:main"`) is a
# DOCUMENTED boundary (see the README scope paragraph + F-SG-2026-07-03) — the earlier quote-strip
# attempt was reverted because `${CMD//"/}` is super-quadratic in bash 3.2 (the platform floor) and
# reintroduced the very timeout fail-open the awk parser closed. TARGET detection above already scans
# $CMD the same way, so a refspec it flagged is visible here too.
_SRC_TOKENS=$(printf '%s' "$CMD" | tr ' \t\n' '\n\n\n' | grep -E "^\+?[^:]*:(refs/heads/|heads/)?${_ESC_T}$" || true)
if [ -n "$_SRC_TOKENS" ]; then
  # BOUND THE WORK BEFORE THE LOOP (fail-closed). The loop below spawns one `git rev-parse` per matched
  # token. A command padded with many refspec-looking tokens — even ones bash never sends to git (e.g.
  # hidden after a `#` comment) — would otherwise fan out into thousands of subprocesses and push the hook
  # past its 15s timeout, which Claude treats as NON-BLOCKING (= fail-open). That is the exact timeout
  # class the awk parser exists to close; the loop must not reopen it. A legitimate push names at most a
  # couple of refspecs to the protected branch, so any command with more than a small cap is rejected here
  # WITHOUT resolving a single ref. Counting is one O(n) grep pass (C), no per-token fork.
  # Two independent bounds, both fail-closed, both O(1)/O(n)-cheap — together they cap the loop's total work
  # so NO attacker-controlled command length can push the hook past its 15s timeout:
  #   (1) COUNT — one huge command can match thousands of short `…:main` tokens; each would cost a
  #       `git rev-parse`. >8 refspecs to the protected branch is never a real push, so reject before the loop.
  #   (2) SIZE — a SINGLE oversized token (e.g. `<1MB of a>:main`, count=1, so the count cap passes) would
  #       hit bash 3.2's O(n^2) `${_tok%%:*}` / `${_src#+}` pattern-strips below (~7.5s each at 1MB). A real
  #       refspec source is a ref name or a 40-char SHA; 4096 bytes is vast headroom. `${#var}` is not O(n^2).
  # This is the third guard against the SAME class in this file (after the reverted quote-strip and the
  # count cap): any work over the command text must be O(n) with no per-token subprocess, or fail-closed
  # bounded. A too-long refspec source cannot resolve anyway (git rejects it), so failing closed loses nothing.
  _NTOK=$(printf '%s\n' "$_SRC_TOKENS" | grep -c . 2>/dev/null || echo 0)
  [ "$_NTOK" -le 8 ] || _gate_fail "ship-gate: this push names too many refspecs to '${TARGET}' (${_NTOK}). Push one refspec at a time, then re-run /ship."
  [ "${#_SRC_TOKENS}" -le 4096 ] || _gate_fail "ship-gate: refspec to '${TARGET}' is unreasonably long. Re-run /ship, or push one normal refspec at a time."
  # Every matched refspec must resolve, and to the SAME commit — an exotic multi-refspec push landing two
  # different commits on one branch cannot be covered by a single-SHA marker, so it fails closed.
  _LANDING=""
  while IFS= read -r _tok; do
    [ -n "$_tok" ] || continue
    _src="${_tok%%:*}"                     # everything before the first colon is the source
    _src="${_src#+}"                       # drop a leading force marker (+feature:main)
    # An EMPTY source is `git push origin :main` — a DELETION of the protected branch. A pass marker
    # attests to a verified COMMIT; it can never authorize deleting the branch. Always fail closed.
    [ -n "$_src" ] || _gate_fail "ship-gate: refusing to delete the protected branch '${TARGET}' (empty refspec source). A ship-gate pass cannot authorize a branch deletion."
    _sha=$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${_src}^{commit}" 2>/dev/null || echo "")
    [ -n "$_sha" ] || _gate_fail "ship-gate: unable to resolve '${_src}', the source of the push to ${TARGET}. Re-run /ship."
    if [ -z "$_LANDING" ]; then _LANDING="$_sha"
    elif [ "$_LANDING" != "$_sha" ]; then
      _gate_fail "ship-gate: this push sends more than one commit to '${TARGET}'. Push one refspec at a time, then re-run /ship."
    fi
  done <<EOF
$_SRC_TOKENS
EOF
  PUSHED_SHA="$_LANDING"
else
  PUSHED_SHA=$(git -C "$REPO_ROOT" rev-parse "$TARGET" 2>/dev/null || echo "")
fi
[ -n "$PUSHED_SHA" ] || _gate_fail "ship-gate: unable to resolve the commit being pushed to ${TARGET}. Re-run /ship."

[ "$M_HEAD" = "$PUSHED_SHA" ] || _gate_fail "ship-gate pass is for a different commit. Re-run /ship."

# Guard: M_TS must be a non-empty non-negative integer to avoid arithmetic crash
if [ -z "$M_TS" ] || ! printf '%s' "$M_TS" | grep -qE '^[0-9]+$'; then
  _gate_fail "ship-gate marker is corrupt. Re-run /ship."
fi

NOW=$(date +%s)
[ $((NOW - M_TS)) -le "$TTL" ] || _gate_fail "ship-gate pass expired (>${TTL}s). Re-run /ship."

# --- Validate marker.branch matches push target ---
M_BRANCH=$(jq -r '.branch // empty' "$MARKER")
[ "$M_BRANCH" = "$TARGET" ] || _gate_fail "ship-gate pass is for branch '${M_BRANCH}', not '${TARGET}'. Re-run /ship."

exit 0
