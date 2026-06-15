#!/usr/bin/env bash
sg_marker_path(){ local dir="$1" g
  g=$(git -C "$dir" rev-parse --git-dir 2>/dev/null || echo "$dir/.git")
  case "$g" in /*) : ;; *) g="$dir/$g" ;; esac   # normal repo: ".git" (relative to dir) => anchor to dir; worktree: absolute
  echo "$g/shipgate/last-pass.json"; }
sg_marker_write(){ local dir="$1" branch="$2" hotfix="${3:-false}" m; m="$(sg_marker_path "$dir")"; mkdir -p "$(dirname "$m")"
  jq -n --arg h "$(git -C "$dir" rev-parse HEAD)" --arg b "$branch" --argjson t "$(date +%s)" --argjson hf "$hotfix" \
    '{head:$h,branch:$b,ts:$t,hotfix:$hf}' > "$m"; }
sg_marker_valid(){ local dir="$1" branch="$2" ttl="$3" m; m="$(sg_marker_path "$dir")"; [ -f "$m" ] || return 1
  [ "$(jq -r .head "$m")" = "$(git -C "$dir" rev-parse HEAD)" ] || return 1
  [ "$(jq -r .branch "$m")" = "$branch" ] || return 1
  [ $(( $(date +%s) - $(jq -r .ts "$m") )) -le "$ttl" ] || return 1; return 0; }
