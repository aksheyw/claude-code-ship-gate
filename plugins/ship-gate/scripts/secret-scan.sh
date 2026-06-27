#!/usr/bin/env bash
set -euo pipefail
# Reads added diff lines (--stdin) or computes `git diff` added lines; exit 1 if a secret is found.
# Line-oriented: matches the "-----BEGIN ... PRIVATE KEY" header line, not the whole PEM block.
get_added(){ if [ "${1:-}" = "--stdin" ]; then grep '^+' || true
  else git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "secret-scan: not a git repo" >&2; exit 2; }
       { git diff --cached -U0; git diff -U0; } | grep '^+' || true; fi; }
# Case-SENSITIVE token patterns (AWS etc. are uppercase-anchored):
CS_PATTERNS=(
  '(A3T[A-Z0-9]|AKIA|ASIA|ABIA|ACCA)[A-Z2-7]{16}'
  'sk-or-v1-[A-Za-z0-9]{20,}'
  'sk-(proj|svcacct|admin)-[A-Za-z0-9_-]{20,}'
  'ey[A-Za-z0-9_-]{17,}\.ey[A-Za-z0-9_-]{17,}\.[A-Za-z0-9_-]{10,}'
  'ghp_[0-9A-Za-z]{36}'
  'xox[baprs]-[0-9A-Za-z-]{10,}'
  '(sk|rk)_(test|live)_[0-9A-Za-z]{10,}'
  'AIza[0-9A-Za-z_-]{35}'
  '-----BEGIN[ A-Z]*PRIVATE KEY'
)
# Case-INSENSITIVE keyword/value pattern:
CI_PATTERNS=(
  '(secret|api[_-]?key|password|access[_-]?token)["'"'"' ]*[:=][ ]*["'"'"'][A-Za-z0-9_+/=-]{20,}'
)
ADDED=$(get_added "${1:-}")
found=0
for p in "${CS_PATTERNS[@]}"; do if printf '%s' "$ADDED" | grep -qE -- "$p"; then echo "SECRET MATCH: /$p/"; found=1; fi; done
for p in "${CI_PATTERNS[@]}"; do if printf '%s' "$ADDED" | grep -qiE -- "$p"; then echo "SECRET MATCH: /$p/"; found=1; fi; done
exit "$found"
