#!/usr/bin/env bash
# install-local.sh — Mode A installer for ship-gate.
#
# Copies plugin skills and agents into ~/.claude/ as personal (bare-named) skills,
# rewrites ${CLAUDE_PLUGIN_ROOT} to an absolute path, strips the ship-gate: namespace,
# backs up any existing flat ship.md, and merges the push-block hook into
# ~/.claude/settings.json.
#
# Usage:
#   bash install-local.sh          # interactive (asks for confirmation)
#   bash install-local.sh --yes    # non-interactive (no prompt)
#
# SAFETY: NEVER run this without overriding HOME in a test context.
# It modifies $HOME/.claude/. The test suite always passes HOME=<fake-tmpdir>.
set -euo pipefail

# ---------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------
REPO="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT_ABS="$REPO/plugins/ship-gate"

SKILLS_SRC="$PLUGIN_ROOT_ABS/skills"
AGENTS_SRC="$PLUGIN_ROOT_ABS/agents"
RULE_SRC="$PLUGIN_ROOT_ABS/rules/shipgate-trigger.md"
CHECK_PUSH_ABS="$PLUGIN_ROOT_ABS/scripts/check-push.sh"

CLAUDE_DIR="$HOME/.claude"
SKILLS_DST="$CLAUDE_DIR/skills"
AGENTS_DST="$CLAUDE_DIR/agents"
RULES_DST="$CLAUDE_DIR/rules"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
GLOBAL_CFG="$HOME/.shipgate.json"   # default-on lives here (NOT in .claude/)

YES=false
NO_DEFAULT_ON=false
for arg in "$@"; do
  case "$arg" in
    --yes) YES=true ;;
    --no-default-on) NO_DEFAULT_ON=true ;;
  esac
done

# ---------------------------------------------------------------
# Pre-flight: confirm plugin source exists
# ---------------------------------------------------------------
if [ ! -d "$PLUGIN_ROOT_ABS" ]; then
  echo "ERROR: plugin source not found at: $PLUGIN_ROOT_ABS" >&2
  exit 1
fi
if [ ! -f "$CHECK_PUSH_ABS" ]; then
  echo "ERROR: check-push.sh not found at: $CHECK_PUSH_ABS" >&2
  exit 1
fi
# jq is a hard dependency (used for settings.json validation + the hook merge).
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but was not found on PATH. Install jq, then re-run." >&2
  exit 1
fi
# FIX 6: guard against missing/empty skills source (prevents empty-glob hazard)
if [ ! -d "$SKILLS_SRC/ship" ]; then
  echo "ERROR: expected skill source not found at: $SKILLS_SRC/ship" >&2
  exit 1
fi
# Phase E: the Layer-2 natural-language ship-trigger rule must exist to install.
if [ ! -f "$RULE_SRC" ]; then
  echo "ERROR: expected rule source not found at: $RULE_SRC" >&2
  exit 1
fi

# FIX 1 + FIX 4: validate settings.json in pre-flight, before copying any files.
# - Absent or whitespace-only -> treat as {} (safe start)
# - Non-empty -> MUST be a valid JSON object; abort otherwise (no data loss, no partial install)
if [ -f "$SETTINGS_FILE" ]; then
  if grep -q '[^[:space:]]' "$SETTINGS_FILE" 2>/dev/null; then
    # Non-empty: must be a valid JSON object.
    if ! jq -e 'type == "object"' "$SETTINGS_FILE" >/dev/null 2>&1; then
      echo "ERROR: $SETTINGS_FILE exists but is not a valid JSON object." >&2
      echo "Fix or remove it, then re-run. (Refusing to proceed: avoids data loss and a non-functional hook.)" >&2
      exit 1
    fi
    CURRENT=$(cat "$SETTINGS_FILE")
  else
    CURRENT='{}'   # empty / whitespace-only: safe to treat as {}
  fi
else
  CURRENT='{}'   # absent: start fresh
fi

# Phase E pre-flight: validate the default-on write target ~/.shipgate.json the SAME way as
# settings.json (absent/empty -> {}; non-empty -> MUST be a valid JSON object, else abort with no
# clobber). Done BEFORE any file copy so an invalid global config can never leave a partial install.
# Skipped entirely under --no-default-on (we won't touch ~/.shipgate.json then).
CURRENT_GCFG='{}'
if [ "$NO_DEFAULT_ON" = false ] && [ -f "$GLOBAL_CFG" ]; then
  if grep -q '[^[:space:]]' "$GLOBAL_CFG" 2>/dev/null; then
    if ! jq -e 'type == "object"' "$GLOBAL_CFG" >/dev/null 2>&1; then
      echo "ERROR: $GLOBAL_CFG exists but is not a valid JSON object." >&2
      echo "Fix or remove it, then re-run — or pass --no-default-on to skip enabling default-on." >&2
      exit 1
    fi
    CURRENT_GCFG=$(cat "$GLOBAL_CFG")
  fi
fi

# ---------------------------------------------------------------
# Interactive confirmation
# ---------------------------------------------------------------
if [ "$YES" = false ]; then
  echo "This will install ship-gate skills and agents into:"
  echo "  $CLAUDE_DIR"
  echo ""
  echo "Skills: ship, ship-init, ship-review, ship-security"
  echo "Agents: ship-reviewer"
  echo "Rule:   shipgate-trigger.md -> ~/.claude/rules (natural-language 'ship it' trigger)"
  echo "Hook:   push-block will be merged into settings.json"
  if [ "$NO_DEFAULT_ON" = false ]; then
    echo "Default-on: defaultEnabled:true will be merged into ~/.shipgate.json"
    echo "            -> EVERY repo Claude pushes a protected branch on becomes gated"
    echo "            (re-run with --no-default-on to keep ship-gate opt-in)"
  else
    echo "Default-on: SKIPPED (--no-default-on) — ship-gate stays opt-in (only .shipgate.json repos)"
  fi
  echo ""
  printf "Proceed? (yes/no): "
  read -r REPLY
  case "$REPLY" in
    yes|y|YES|Y) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

# ---------------------------------------------------------------
# Ensure destination directories exist
# ---------------------------------------------------------------
mkdir -p "$SKILLS_DST"
mkdir -p "$AGENTS_DST"

# ---------------------------------------------------------------
# Rewrite helper: apply both rewrites to a file in-place.
# (a) ${CLAUDE_PLUGIN_ROOT} -> absolute plugin root path
# (b) ship-gate:            -> empty string (strip namespace)
# FIX 5: uses bash parameter expansion instead of sed so that special
# characters in the path (&, |, \) are never misinterpreted by sed.
# Trailing newlines are preserved via the append-x / strip-x pattern.
# ---------------------------------------------------------------
rewrite_file() {
  local f="$1" content
  # Read preserving trailing newline(s): append x, then strip it.
  content=$(cat "$f"; printf 'x'); content=${content%x}
  # (a) Replace the literal ${CLAUDE_PLUGIN_ROOT} token with the absolute path.
  # Single-quotes around the pattern make it a literal match (no variable expansion).
  content=${content//'${CLAUDE_PLUGIN_ROOT}'/$PLUGIN_ROOT_ABS}
  # (b) Strip the plugin command namespace (safe: 'ship-gate:' has a colon; paths use 'ship-gate/').
  content=${content//ship-gate:/}
  printf '%s' "$content" > "$f"
}

# ---------------------------------------------------------------
# Back up existing flat ship.md (if present)
# ---------------------------------------------------------------
FLAT_SHIP="$SKILLS_DST/ship.md"
if [ -f "$FLAT_SHIP" ]; then
  BAK="$SKILLS_DST/ship.md.bak"
  if [ -f "$BAK" ]; then
    EPOCH=$(date +%s)
    BAK="$SKILLS_DST/ship.md.bak.$EPOCH"
    echo "NOTE: ship.md.bak already exists; backing up to: $BAK"
  fi
  mv "$FLAT_SHIP" "$BAK"
  echo "Backed up $FLAT_SHIP -> $BAK"
fi

# ---------------------------------------------------------------
# Install all skills (copy whole directory, then rewrite each .md)
# ---------------------------------------------------------------
for SKILL_DIR in "$SKILLS_SRC"/*/; do
  SKILL_NAME="$(basename "$SKILL_DIR")"
  DST_SKILL="$SKILLS_DST/$SKILL_NAME"

  # Remove any prior install so we don't accumulate stale files.
  rm -rf "$DST_SKILL"
  cp -r "$SKILL_DIR" "$DST_SKILL"

  # Rewrite every .md file in the copied skill tree.
  find "$DST_SKILL" -name '*.md' -type f | while IFS= read -r mdfile; do
    rewrite_file "$mdfile"
  done

  echo "Installed skill: $SKILL_NAME -> $DST_SKILL"
done

# ---------------------------------------------------------------
# Install agents (copy .md files, then rewrite)
# ---------------------------------------------------------------
for AGENT_SRC in "$AGENTS_SRC"/*.md; do
  [ -f "$AGENT_SRC" ] || continue
  AGENT_NAME="$(basename "$AGENT_SRC")"
  DST_AGENT="$AGENTS_DST/$AGENT_NAME"
  cp "$AGENT_SRC" "$DST_AGENT"
  rewrite_file "$DST_AGENT"
  echo "Installed agent: $AGENT_NAME -> $DST_AGENT"
done

# ---------------------------------------------------------------
# Install the Layer-2 natural-language ship-trigger rule (always-loaded global rule).
# Installed regardless of --no-default-on: the rule routes ship intent to /ship; default-on is a
# separate switch. rewrite_file is a no-op on the rule today (no ${CLAUDE_PLUGIN_ROOT}/namespace),
# applied for consistency + future-proofing.
# ---------------------------------------------------------------
mkdir -p "$RULES_DST"
cp "$RULE_SRC" "$RULES_DST/shipgate-trigger.md"
rewrite_file "$RULES_DST/shipgate-trigger.md"
echo "Installed rule: shipgate-trigger.md -> $RULES_DST/shipgate-trigger.md"

# ---------------------------------------------------------------
# Merge push-block hook into settings.json
# ---------------------------------------------------------------
# Build JSON entry for the hook. The command is:
#   bash "<abs>/scripts/check-push.sh"
# The inner double-quotes are literal characters in the string value,
# encoded as \" inside the JSON. We pass the command to jq via --arg
# to let jq handle escaping correctly.
HOOK_COMMAND="bash \"${CHECK_PUSH_ABS}\""

# $CURRENT was validated and set in pre-flight above (FIX 1 + FIX 4).
# No re-read here; the pre-flight value is authoritative.

# FIX 2: Idempotency guard + merge using jq.
# Guard scoped to the actual hook-command location (.hooks.PreToolUse[].hooks[].command)
# NOT [.. | strings] which would over-match unrelated contexts (e.g. permissions rules).
# The ? operators make it null-safe when .hooks / .PreToolUse are absent.
NEW_JSON=$(printf '%s' "$CURRENT" | jq \
  --arg cmd "$HOOK_COMMAND" \
  '
  # Build the entry object
  ($cmd | {
    "type": "command",
    # D9: NO `if` matcher. An anchored "Bash(git push *)" rule SKIPS the hook for any
    # command not literally starting with "git push " (FOO=bar git push, git -C path push,
    # GIT_SSH_COMMAND=x git push) => those proceed ALLOWED = fail-open ABOVE check-push.sh.
    # matcher:"Bash" runs check-push.sh on EVERY Bash command; the script is the sole gate.
    "command": .,
    "timeout": 15
  }) as $hook_entry |

  {
    "matcher": "Bash",
    "hooks": [$hook_entry]
  } as $entry |

  # Idempotency: check only .hooks.PreToolUse[].hooks[].command — not every string
  if ([.hooks.PreToolUse[]? | .hooks[]? | .command] | any(test("check-push\\.sh")))
  then .
  else
    .hooks.PreToolUse += [$entry]
  end
  ')

# Write back atomically (temp file + mv on the same filesystem).
printf '%s\n' "$NEW_JSON" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
echo "Merged push-block hook into: $SETTINGS_FILE"

# FIX 3: Post-merge verification — confirm hook is actually present before claiming success.
# This makes a silent fail-open structurally impossible: the success message can only
# print when the hook verifiably exists in settings.json.
if ! jq -e '[.hooks.PreToolUse[]? | .hooks[]? | .command] | any(test("check-push\\.sh"))' "$SETTINGS_FILE" >/dev/null 2>&1; then
  echo "ERROR: post-install verification failed - push-block hook is NOT present in $SETTINGS_FILE." >&2
  echo "Push protection is NOT active. Resolve before relying on it." >&2
  exit 1
fi

# ---------------------------------------------------------------
# Enable default-on (global ~/.shipgate.json), unless --no-default-on
# ---------------------------------------------------------------
# Non-clobbering recursive merge: every existing key is preserved; only defaultEnabled is set true.
# $CURRENT_GCFG was validated in pre-flight (valid object, or {} when absent/empty). Atomic write +
# post-verify, mirroring the settings.json merge so a silent failure is structurally impossible.
if [ "$NO_DEFAULT_ON" = false ]; then
  NEW_GCFG=$(printf '%s' "$CURRENT_GCFG" | jq '. * {"defaultEnabled": true}')
  printf '%s\n' "$NEW_GCFG" > "$GLOBAL_CFG.tmp" && mv "$GLOBAL_CFG.tmp" "$GLOBAL_CFG"
  if ! jq -e '.defaultEnabled == true' "$GLOBAL_CFG" >/dev/null 2>&1; then
    echo "ERROR: failed to enable default-on in $GLOBAL_CFG." >&2
    exit 1
  fi
  echo "Enabled default-on: defaultEnabled:true -> $GLOBAL_CFG"
else
  echo "Skipped default-on (--no-default-on): ship-gate stays opt-in (only repos with a .shipgate.json are gated)."
fi

# ---------------------------------------------------------------
# Final report
# ---------------------------------------------------------------
echo ""
echo "ship-gate (Mode A) installed. Personal skills now available:"
echo "  /ship          -- run the full ship gate and push to main"
echo "  /ship-init     -- scaffold .shipgate.json for a project"
echo "  /ship-review   -- code-review judgment gate"
echo "  /ship-security -- security judgment gate"
echo ""
echo "The push-block hook (check-push.sh) is active in:"
echo "  $SETTINGS_FILE"
echo "It will deny 'git push' to a protected branch unless a fresh /ship marker exists."
echo ""
echo "Natural-language trigger rule installed:"
echo "  $RULES_DST/shipgate-trigger.md  ('ship it' runs the gates and pushes on green)"
if [ "$NO_DEFAULT_ON" = false ]; then
  echo ""
  echo "Default-on is ON ($GLOBAL_CFG has defaultEnabled:true):"
  echo "  every repo Claude pushes a protected branch on is now gated, even without a .shipgate.json."
  echo "  To revert to opt-in: set defaultEnabled:false in $GLOBAL_CFG, or remove that file."
  echo "  To pause one repo: /ship off (re-enable with /ship on)."
  echo "  To bypass for a session: export SHIPGATE_DISABLE=1 before launching Claude."
fi
