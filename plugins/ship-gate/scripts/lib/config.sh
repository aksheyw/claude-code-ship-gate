#!/usr/bin/env bash
# Loads .shipgate.json merged over built-in defaults. Requires jq.
sg_defaults(){ cat <<'JSON'
{ "mainBranch": "main",
  "gates": { "tests": {"enabled":true,"command":null}, "lint": {"enabled":true,"command":null},
    "typecheck": {"enabled":true,"command":null}, "build": {"enabled":false,"command":null},
    "secretScan": {"enabled":true},
    "codeReview": {"enabled":true,"skill":"ship-review","upgrade":null},
    "security": {"enabled":true,"skill":"ship-security","upgrade":null},
    "uat": {"enabled":true,"skill":"verify","mode":"confidence"} },
  "heavyGates": { "audit": {"skill":"deep-review","upgrade":"audit","suggestWhen":{"filesChanged":15,"areasChanged":3,"riskyPaths":true}},
    "deep": {"skill":"deep-review","upgrade":"deep-review","suggestWhen":{"diffLines":400,"riskyPaths":true,"release":true}} },
  "regression": {"enabled":false,"skill":"ai-regression-testing","runWhen":"test-affecting"},
  "scoping": { "docs":["**/*.md","docs/**"], "ui":["src/components/**","src/pages/**","**/*.{tsx,jsx,vue,svelte}"],
    "security":["**/auth/**","**/*payment*","**/*.rules","**/migrations/**","**/.env*","api/**","package.json","requirements*.txt","go.mod","Cargo.toml","pubspec.yaml"] },
  "deploy": {"autoDetect":true,"warnOnPush":true},
  "hotfix": {"skipGates":["uat","regression","audit","deep"]},
  "markerTtlSeconds": 900 }
JSON
}
# sg_config_get <project-dir> <jq-filter>  — returns non-zero (fail CLOSED) on invalid config JSON.
sg_config_get(){ local dir="$1" filter="$2" cfg="$1/.shipgate.json"
  if [ -f "$cfg" ]; then
    jq empty "$cfg" 2>/dev/null || { echo "shipgate: invalid JSON in $cfg" >&2; return 2; }
    jq -n --argjson d "$(sg_defaults)" --argjson o "$(cat "$cfg")" '$d * $o' | jq -r "$filter"
  else sg_defaults | jq -r "$filter"; fi; }
# Phase 8: protected-branch resolution shared by runner + orchestrator. Mirrors the hook
# (check-push.sh) which replicates this inline (it must stay self-contained). Echoes one branch name
# PER LINE (matches the hook; safe for while-read and word-split consumers). Ladder (spec §5), first match wins:
#   per-repo .mainBranch -> global .mainBranch -> $SHIPGATE_MAIN_BRANCH -> origin/HEAD -> {main master}
# origin/HEAD uses symbolic-ref --quiet (robust: empty+exit1 when unset, so we fall through to the
# {main master} fallback rather than mis-resolving to the bogus branch "HEAD").
sg_protected_branches(){ local dir="$1" gcfg d m
  if [ -f "$dir/.shipgate.json" ]; then
    m=$(jq -r 'if (.mainBranch|type)=="string" and (.mainBranch|length)>0 then .mainBranch else empty end' "$dir/.shipgate.json" 2>/dev/null || true)
    [ -n "$m" ] && { printf '%s\n' "$m"; return 0; }
  fi
  gcfg="${SHIPGATE_GLOBAL_CONFIG:-${HOME:+$HOME/.shipgate.json}}"
  if [ -n "$gcfg" ] && [ -f "$gcfg" ]; then
    m=$(jq -r 'if (.mainBranch|type)=="string" and (.mainBranch|length)>0 then .mainBranch else empty end' "$gcfg" 2>/dev/null || true)
    [ -n "$m" ] && { printf '%s\n' "$m"; return 0; }
  fi
  [ -n "${SHIPGATE_MAIN_BRANCH:-}" ] && { printf '%s\n' "$SHIPGATE_MAIN_BRANCH"; return 0; }
  d=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo "")
  d="${d#origin/}"; [ -n "$d" ] && { printf '%s\n' "$d"; return 0; }
  printf 'main\nmaster\n'
}
# Worktree-safe git-dir helpers (raw rev-parse output; callers join to the repo dir as needed).
sg_git_dir(){ git -C "$1" rev-parse --git-dir 2>/dev/null || echo ".git"; }
sg_git_common_dir(){ git -C "$1" rev-parse --git-common-dir 2>/dev/null || echo ".git"; }
# Absolute path to the per-repo disable sentinel (/ship off writes it; the hook reads it). MUST resolve
# to the same path the hook computes (check-push.sh ladder step 4): anchor --git-common-dir to the repo
# ROOT (not the caller's CWD) so it is correct from a subdir, and join a relative result to the root so
# it is correct in a linked worktree (where it is the shared common dir). Echoes "" when not in a repo.
sg_disabled_sentinel(){ local dir="$1" root gcd
  root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "")
  [ -n "$root" ] || { echo ""; return 0; }
  gcd=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null || echo ".git")
  case "$gcd" in /*) : ;; *) gcd="$root/$gcd" ;; esac
  printf '%s/shipgate/disabled\n' "$gcd"; }
