#!/usr/bin/env bash
# The pass marker is a COMMIT-identity token: head = the SHA of the protected branch being shipped (the
# commit a `git push origin <branch>` will land), branch = that protected branch. It lives in the COMMON
# git-dir (shared across all linked worktrees), so a marker written from the primary checkout — or from a
# worktree on a feature branch that integrated into the protected branch — is visible to the push-block
# hook firing from any worktree of the same repo. Resolution is anchored to the repo ROOT and mirrors the
# disable sentinel (lib/config.sh sg_disabled_sentinel) + the hook (check-push.sh) byte-for-byte, so the
# writer and reader can never diverge (worktree marker branch-mismatch fix, proposal 2026-06-13 A+B).
sg_marker_path(){ local dir="$1" root gcd
  root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")
  gcd=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null || echo ".git")
  case "$gcd" in /*) : ;; *) gcd="$root/$gcd" ;; esac   # relative => anchor to repo root; worktree => absolute shared dir
  echo "$gcd/shipgate/last-pass.json"; }
sg_marker_write(){ local dir="$1" branch="$2" hotfix="${3:-false}" m; m="$(sg_marker_path "$dir")"; mkdir -p "$(dirname "$m")"
  jq -n --arg h "$(git -C "$dir" rev-parse "$branch")" --arg b "$branch" --argjson t "$(date +%s)" --argjson hf "$hotfix" \
    '{head:$h,branch:$b,ts:$t,hotfix:$hf}' > "$m"; }
sg_marker_valid(){ local dir="$1" branch="$2" ttl="$3" m; m="$(sg_marker_path "$dir")"; [ -f "$m" ] || return 1
  [ "$(jq -r .head "$m")" = "$(git -C "$dir" rev-parse "$branch")" ] || return 1
  [ "$(jq -r .branch "$m")" = "$branch" ] || return 1
  [ $(( $(date +%s) - $(jq -r .ts "$m") )) -le "$ttl" ] || return 1; return 0; }
