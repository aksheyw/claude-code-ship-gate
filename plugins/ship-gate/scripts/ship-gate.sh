#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/config.sh"; . "$HERE/lib/detect.sh"; . "$HERE/lib/marker.sh"; . "$HERE/lib/log.sh"
cmd="${1:-help}"; dir="${2:-$PWD}"
# sg_guard_json: fail CLOSED on invalid-JSON config (used by every entry point — you cannot reason about a
# config jq can't parse). sg_guard_config: ALSO enforce structural shape — the runtime enforcement of the
# (editor-only) schema, so a scalar gate / non-boolean enabled / non-(null|string|suite-array) command fails
# closed on the GATING path instead of becoming a silent green (deep-review 2026-06-20). Structural validation
# is ONLY for `run` (the push-gating path); `detect` is a read-only scaffold helper that NEVER gates a push, so
# it must TOLERATE an already-malformed config (that's exactly the config /ship-init exists to repair) — R3.
sg_guard_json(){ sg_config_get "$dir" '.mainBranch' >/dev/null || { sg_log fail "invalid .shipgate.json — aborting (fail closed)"; exit 2; }; }
sg_guard_config(){
  sg_guard_json
  sg_config_structure_ok "$dir" || { sg_log fail "malformed .shipgate.json structure — aborting (fail closed): gates must be objects; each enabled a boolean; each command null, a string, or a suite array of {command, when:[…]}."; exit 2; }
}
resolve(){ local key="$1" detected="$2" c t
  # P1: an ARRAY command (multi-suite) has no single string form — emit a placeholder so `detect` (used by
  # /ship-init) shows a sane one-liner instead of the raw multi-line JSON. The runner handles arrays via
  # run_cmd_gate and never routes them through resolve; string/null behavior is unchanged (back-compat).
  t=$(sg_config_get "$dir" ".gates.${key}.command | type")
  [ "$t" = "array" ] && { printf '<multi-suite: %s suites>\n' "$(sg_config_get "$dir" ".gates.${key}.command | length")"; return 0; }
  c=$(sg_config_get "$dir" ".gates.${key}.command"); [ "$c" = "null" ] && printf '%s\n' "$detected" || printf '%s\n' "$c"; }
case "$cmd" in
  detect) sg_guard_json
    jq -n --arg t "$(resolve tests "$(sg_detect_test_cmd "$dir")")" \
          --arg l "$(resolve lint "$(sg_detect_lint_cmd "$dir")")" \
          --arg tc "$(resolve typecheck "$(sg_detect_typecheck_cmd "$dir")")" \
          --arg b "$(resolve build "$(sg_detect_build_cmd "$dir")")" \
          --arg d "$(sg_detect_deploy "$dir")" \
          --arg ci "$(sg_detect_ci "$dir")" \
          '{tests:$t,lint:$l,typecheck:$tc,build:$b,deploy:$d,ci:$ci}' ;;
  run) sg_guard_config
    fail=0
    run_gate(){ local name="$1" c="$2" en="$3"; [ "$en" = "true" ] || { sg_log skip "$name (disabled)"; return; }; [ -n "$c" ] || { sg_log warn "$name: no command detected"; return; }
      sg_log run "$name: $c"; if ( cd "$dir" && eval "$c" ); then sg_log pass "$name"; else sg_log fail "$name"; fail=1; fi; }
    # P1 (S149): a command-gate's `command` may be a string (today), null (auto-detect), or an ARRAY of
    # {command, when:[pathspec,...]} suites (multi-suite / monorepo). Dispatch on the JSON type. For the array
    # form, run each suite that is in scope (sg_suite_in_scope; omitted when => always; fail-safe RUN when the
    # change-set is indeterminate) and FAIL the gate if ANY in-scope suite is non-zero. Do NOT `local fail` —
    # fail=1 must mutate the enclosing run-case `fail` so a failing suite propagates to `exit "$fail"`.
    run_cmd_gate(){ local key="$1" detected="$2"
      [ "$(sg_config_get "$dir" ".gates.${key}.enabled")" = "true" ] || { sg_gate_skip_or_drift "$dir" "$key"; return 0; }
      local t; t=$(sg_config_get "$dir" ".gates.${key}.command | type")
      if [ "$t" = "array" ]; then
        local n base ran=0 i cmd
        n=$(sg_config_get "$dir" ".gates.${key}.command | length")
        [ "${n:-0}" -gt 0 ] || { sg_log warn "$key: empty suite list (nothing to run)"; return 0; }
        # DEFENSE-IN-DEPTH (a backstop, NOT the primary enforcement): validate that every suite entry is an
        # object with a non-empty string `command`. The PRIMARY fail-closed enforcement for malformed suite
        # arrays is sg_config_structure_ok (lib/config.sh), which sg_guard_config runs BEFORE this and is
        # strictly stronger (whitespace-stripped non-empty + the when-type check) — so on the normal `run`
        # path this guard is shadowed and won't fire. It is kept so run_cmd_gate still fails CLOSED if it is
        # ever reached without that validation (a future refactor / direct call). jq `and` short-circuits, so
        # `.command` is never indexed on a non-object element.
        if [ "$(sg_config_get "$dir" ".gates.${key}.command | map((type==\"object\") and has(\"command\") and (.command|type==\"string\") and (.command|length>0)) | all")" != "true" ]; then
          sg_log fail "$key: malformed suite array — each entry needs a non-empty \"command\" string"; fail=1; return 0
        fi
        base=$(sg_change_base "$dir")
        for ((i=0; i<n; i++)); do
          cmd=$(sg_config_get "$dir" ".gates.${key}.command[$i].command" 2>/dev/null || true)
          [ -n "$cmd" ] || { sg_log fail "$key[$i]: empty command"; fail=1; continue; }   # defense-in-depth backstop (validator already enforced this)
          if sg_suite_in_scope "$dir" "$key" "$i" "$base"; then
            sg_log run "$key[$i]: $cmd"
            if ( cd "$dir" && eval "$cmd" ); then sg_log pass "$key[$i]"; else sg_log fail "$key[$i]"; fail=1; fi
            ran=1
          else sg_log skip "$key[$i] (no changed files match its when)"; fi
        done
        [ "$ran" = 1 ] || sg_log warn "$key: all suites skipped (no matching changes)"
      else
        run_gate "$key" "$(resolve "$key" "$detected")" "true"   # string/null => existing single-command path
      fi; }
    run_cmd_gate tests "$(sg_detect_test_cmd "$dir")"
    [ "$fail" = 0 ] && run_cmd_gate lint "$(sg_detect_lint_cmd "$dir")"
    [ "$fail" = 0 ] && run_cmd_gate typecheck "$(sg_detect_typecheck_cmd "$dir")"
    [ "$fail" = 0 ] && run_cmd_gate build "$(sg_detect_build_cmd "$dir")"
    if [ "$fail" = 0 ] && [ "$(sg_config_get "$dir" '.gates.secretScan.enabled')" = "true" ]; then
      sg_log run "secretScan"; if ( cd "$dir" && bash "$HERE/secret-scan.sh" ); then sg_log pass secretScan; else sg_log fail secretScan; fail=1; fi; fi
    exit "$fail" ;;
  # Record the marker for the PROTECTED branch being shipped (resolved via the shared ladder), NOT the
  # checked-out branch — so a /ship from a linked worktree on a feature branch records the protected
  # branch + its tip (the commit that will land), matching the hook's push TARGET. sg_marker_write reads
  # that branch's local ref, so it works whether the protected branch is checked out here or in the primary.
  write-marker) sg_marker_write "$dir" "$(sg_protected_branches "$dir" | head -1)" "${3:-false}" ;;
  protected-branch) sg_protected_branches "$dir" | head -1 ;;
  # The deterministic file-coverage manifest for the shipped change (one path per line). /ship requires the
  # codeReview gate to account for every path here before it may go green, so a judgment gate can no longer
  # silently review a subset of a large changeset and still report a pass. Reports scope; never gates.
  changed-files) sg_guard_json; sg_changed_files "$dir" ;;
  # disable|enable|status: the per-repo /ship off|on sentinel. Resolved via sg_disabled_sentinel so the
  # path matches the hook's (anchored to the repo root; correct from a subdir and in a linked worktree).
  disable) s=$(sg_disabled_sentinel "$dir"); [ -n "$s" ] || { sg_log fail "not a git repo — cannot disable" >&2; exit 2; }
    mkdir -p "$(dirname "$s")"; : > "$s"; sg_log info "ship-gate disabled for this repo (pushes to the protected branch are no longer gated). Re-enable: /ship on" >&2 ;;
  enable) s=$(sg_disabled_sentinel "$dir"); [ -n "$s" ] || { sg_log fail "not a git repo — cannot enable" >&2; exit 2; }
    rm -f "$s"; sg_log info "ship-gate re-enabled for this repo." >&2 ;;
  status) s=$(sg_disabled_sentinel "$dir"); [ -n "$s" ] || { sg_log fail "not a git repo — no gating status" >&2; exit 2; }
    if [ -f "$s" ]; then echo off; else echo on; fi ;;
  # P2 (S149): ADVISORY scan for suites the single configured tests.command would silently SKIP (a nested
  # package with its own test script, an extra/named test config, an e2e suite, a *.rules security-rules file)
  # and (P4) for a missing CI backstop. Prints [WARN] lines and ALWAYS exits 0 — it never gates a push; it is a
  # setup aid surfaced by /ship-init and runnable any time. Reads only the filesystem (no .shipgate.json), so it
  # works on an un-configured or broken-config repo (exactly when it's most useful).
  doctor) found=0
    while IFS= read -r line; do [ -n "$line" ] && { sg_log warn "uncovered suite: $line"; found=1; }; done < <(sg_detect_uncovered "$dir")
    [ "$found" = 0 ] && sg_log pass "no uncovered suites detected"
    ci=$(sg_detect_ci "$dir")
    if [ -n "$ci" ]; then sg_log pass "CI detected: $ci"
    else sg_log warn "no CI detected — this gate is your only automated check before prod; keep suite coverage aggressive"; fi
    # Config-drift audit (2026-07-23): only meaningful against an actual .shipgate.json — an un-configured
    # repo has nothing to audit (it's already using the auto-detected defaults, so "disabled" isn't a
    # decision anyone made). For each of the four command gates that is disabled, check whether the repo
    # now has that capability (sg_detect_capability — same cheap, execution-free check `run` uses) and
    # propose the fix: the REAL auto-detected command when one resolves, an honest "inspect manually"
    # placeholder when it doesn't (never fabricate a command doctor can't actually detect).
    if [ -f "$dir/.shipgate.json" ]; then
      for g in tests lint typecheck build; do
        [ "$(sg_config_get "$dir" ".gates.${g}.enabled")" = "true" ] && continue
        cap=$(sg_detect_capability "$dir" "$g")
        [ -n "$cap" ] || continue
        reason=$(sg_config_get "$dir" ".gates.${g}.reason" 2>/dev/null || true); [ "$reason" = "null" ] && reason=""
        if [ -n "$reason" ]; then
          sg_log warn "config drift: $g disabled (reason: \"$reason\") but $cap — reconsider if stale"
        else
          case "$g" in
            tests) fixcmd=$(sg_detect_test_cmd "$dir") ;;
            lint) fixcmd=$(sg_detect_lint_cmd "$dir") ;;
            typecheck) fixcmd=$(sg_detect_typecheck_cmd "$dir") ;;
            build) fixcmd=$(sg_detect_build_cmd "$dir") ;;
          esac
          [ -n "$fixcmd" ] || fixcmd="<inspect repo and set manually — no root-level auto-detect matched>"
          sg_log warn "config drift: $g disabled but $cap — suggested fix: { \"gates\": { \"$g\": { \"enabled\": true, \"command\": \"$fixcmd\" } } }"
        fi
      done
    fi
    exit 0 ;;
  # `help` is a legitimate request and exits 0; any UNRECOGNISED operation exits 2. A typo'd subcommand
  # used to print usage and exit 0, so a CI step or wrapper running `ship-gate.sh rum` and trusting the
  # status read a clean pass while no gate had run (Codex review 2026-07-23).
  help) echo "usage: ship-gate.sh {detect|run|doctor|changed-files|write-marker|protected-branch|disable|enable|status} [dir]" ;;
  *) echo "usage: ship-gate.sh {detect|run|doctor|changed-files|write-marker|protected-branch|disable|enable|status} [dir]" >&2
     echo "shipgate: unknown operation '$cmd'" >&2; exit 2 ;;
esac
