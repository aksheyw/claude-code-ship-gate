#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/config.sh"; . "$HERE/lib/detect.sh"; . "$HERE/lib/marker.sh"; . "$HERE/lib/log.sh"
cmd="${1:-help}"; dir="${2:-$PWD}"
# Fail CLOSED: if .shipgate.json exists but is invalid, abort — never run zero gates and report pass.
sg_guard_config(){ sg_config_get "$dir" '.mainBranch' >/dev/null || { sg_log fail "invalid .shipgate.json — aborting (fail closed)"; exit 2; }; }
resolve(){ local key="$1" detected="$2" c; c=$(sg_config_get "$dir" ".gates.${key}.command"); [ "$c" = "null" ] && printf '%s\n' "$detected" || printf '%s\n' "$c"; }
case "$cmd" in
  detect) sg_guard_config
    jq -n --arg t "$(resolve tests "$(sg_detect_test_cmd "$dir")")" \
          --arg l "$(resolve lint "$(sg_detect_lint_cmd "$dir")")" \
          --arg tc "$(resolve typecheck "$(sg_detect_typecheck_cmd "$dir")")" \
          --arg b "$(resolve build "$(sg_detect_build_cmd "$dir")")" \
          --arg d "$(sg_detect_deploy "$dir")" \
          '{tests:$t,lint:$l,typecheck:$tc,build:$b,deploy:$d}' ;;
  run) sg_guard_config
    fail=0
    run_gate(){ local name="$1" c="$2" en="$3"; [ "$en" = "true" ] || { sg_log skip "$name (disabled)"; return; }; [ -n "$c" ] || { sg_log warn "$name: no command detected"; return; }
      sg_log run "$name: $c"; if ( cd "$dir" && eval "$c" ); then sg_log pass "$name"; else sg_log fail "$name"; fail=1; fi; }
    run_gate tests "$(resolve tests "$(sg_detect_test_cmd "$dir")")" "$(sg_config_get "$dir" '.gates.tests.enabled')"
    [ "$fail" = 0 ] && run_gate lint "$(resolve lint "$(sg_detect_lint_cmd "$dir")")" "$(sg_config_get "$dir" '.gates.lint.enabled')"
    [ "$fail" = 0 ] && run_gate typecheck "$(resolve typecheck "$(sg_detect_typecheck_cmd "$dir")")" "$(sg_config_get "$dir" '.gates.typecheck.enabled')"
    [ "$fail" = 0 ] && run_gate build "$(resolve build "$(sg_detect_build_cmd "$dir")")" "$(sg_config_get "$dir" '.gates.build.enabled')"
    if [ "$fail" = 0 ] && [ "$(sg_config_get "$dir" '.gates.secretScan.enabled')" = "true" ]; then
      sg_log run "secretScan"; if ( cd "$dir" && bash "$HERE/secret-scan.sh" ); then sg_log pass secretScan; else sg_log fail secretScan; fail=1; fi; fi
    exit "$fail" ;;
  write-marker) sg_marker_write "$dir" "$(git -C "$dir" rev-parse --abbrev-ref HEAD)" "${3:-false}" ;;
  protected-branch) sg_protected_branches "$dir" | head -1 ;;
  # disable|enable|status: the per-repo /ship off|on sentinel. Resolved via sg_disabled_sentinel so the
  # path matches the hook's (anchored to the repo root; correct from a subdir and in a linked worktree).
  disable) s=$(sg_disabled_sentinel "$dir"); [ -n "$s" ] || { sg_log fail "not a git repo — cannot disable" >&2; exit 2; }
    mkdir -p "$(dirname "$s")"; : > "$s"; sg_log info "ship-gate disabled for this repo (pushes to the protected branch are no longer gated). Re-enable: /ship on" >&2 ;;
  enable) s=$(sg_disabled_sentinel "$dir"); [ -n "$s" ] || { sg_log fail "not a git repo — cannot enable" >&2; exit 2; }
    rm -f "$s"; sg_log info "ship-gate re-enabled for this repo." >&2 ;;
  status) s=$(sg_disabled_sentinel "$dir"); [ -n "$s" ] || { sg_log fail "not a git repo — no gating status" >&2; exit 2; }
    if [ -f "$s" ]; then echo off; else echo on; fi ;;
  *) echo "usage: ship-gate.sh {detect|run|write-marker|protected-branch|disable|enable|status} [dir]" ;;
esac
