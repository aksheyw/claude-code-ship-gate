---
name: ship
description: Run the ship-gate quality gates and push to the protected branch (usually main). Invoke when the user expresses intent to ship, release, or push to the main/protected branch (e.g. "ship it", "go ahead and ship", "sync with GitHub"). On an imperative command, auto-push when all gates pass; on a question or a "not yet", run the gates and report without pushing.
argument-hint: "[off|on] [--hotfix] [--dry-run] [--audit] [--deep]"
allowed-tools: Bash Read Skill Task
---

# /ship

Arguments: $ARGUMENTS

You are the ship-gate orchestrator. You run a layered set of gates, then — when every required gate
passes and no gate needs the user's input — write the pass marker and push to the protected branch.
An imperative `/ship` (or a natural-language ship command like "ship it") is the authorization; you
still PAUSE for any gate that needs a decision (UAT, a feature-branch merge, a missing test command,
a detected deploy target, or an edge you surface), and a question or a "not yet" runs the gates and
reports WITHOUT pushing.

## Live state
- Branch: !`git rev-parse --abbrev-ref HEAD`
- Status: !`git status --short`
- Protected branch: !`bash "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" protected-branch . 2>/dev/null || echo main`
- Changed vs protected: !`B=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" protected-branch . 2>/dev/null || echo main); git diff "$B"...HEAD --name-only 2>/dev/null || git diff HEAD --name-only`
- Project config: !`cat .shipgate.json 2>/dev/null || echo "(none — using auto-detected defaults; suggest /ship-gate:ship-init)"`
- Ship-gate gating: !`bash "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" status . 2>/dev/null || echo on`

## Gate tiers (read before running)
- **Deterministic gates** (tests, lint, typecheck, build, secretScan) run via the bundled runner.
  They are non-negotiable: never skipped, never "degraded". A non-zero exit STOPS the ship.
- **Judgment gates** (codeReview, security, uat, regression) resolve in three tiers:
  **upgrade** (a configured external skill/agent, if installed) → **bundled default** (this plugin's
  own skill/agent) → **manual**. On a missing OPTIONAL upgrade, warn once **per gate** and fall back —
  never hard-block on a missing optional dependency. A **Block** verdict from a judgment gate STOPS the ship.

## Steps

0. **`off` / `on` (no gates run).** If `$ARGUMENTS` begins with `off`: disable ship-gate for this repo —
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" disable .` — then report "ship-gate disabled for this
   repo: Claude's pushes to the protected branch are no longer gated here. Re-enable with `/ship on`." and
   STOP. If `$ARGUMENTS` begins with `on`: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" enable .` —
   then report "ship-gate re-enabled for this repo." and STOP. Run NO gates in either case. (The runner
   writes/removes a per-repo, untracked sentinel under the repo's git common-dir, **anchored to the repo
   root** so it is correct from any subdirectory and in a linked worktree; the push-block hook reads the
   exact same path, so the change takes effect on the next push. Do NOT write the sentinel with a bare
   `git rev-parse --git-common-dir` — that is CWD-relative and misfires from a subdir.)

0.5. **Note if gating is OFF (normal `/ship`, no `off`/`on` arg).** If the "Ship-gate gating" line in Live
   state reads `off` — this repo was disabled via `/ship off` — tell the user up front: "Note: ship-gate is
   currently OFF for this repo, so the push-block hook will NOT block this push; run `/ship on` to re-enable
   enforcement." The gates below still run and report normally; only the hard hook backstop is paused. Continue.

1. **Parse flags** from `$ARGUMENTS`: `--hotfix`, `--dry-run`, `--audit`, `--deep`.

2. **Classify changed files** using `references/scenario-matrix.md` and the project's `scoping` globs
   (docs / ui / logic / security-sensitive / config-infra / test-affecting). If the change is
   **docs-only** (every changed path matches `**/*.md`), skip ALL judgment gates — only the
   deterministic gates and secretScan run, then proceed to the summary.

3. **Deterministic gates.** Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" run`. It prints a per-gate
   [PASS]/[FAIL] line and exits non-zero if any gate fails. On non-zero exit, STOP and report which gate failed
   (from its output). Do not continue, do not write a marker.
   **No silent pass on a missing command:** a clean exit code is NOT sufficient by itself. Scan the output for
   any `[WARN] <gate>: no command detected` line. If an *enabled* gate (especially `tests`) reports
   `[WARN] tests: no command detected` — or any other enabled gate has no command — do NOT treat that gate as
   passed. Per spec §16 ("do not silently pass; user decides"), surface it and require an explicit acknowledgment
   to proceed (or advise setting `gates.tests.command` in `.shipgate.json`). Disabled gates print `[SKIP] ...
   (disabled)` instead and are fine to skip.

4. **Judgment gates** — run each only when the scenario matrix says it applies; resolve every one
   upgrade → bundled default → manual (warn once on a missing optional upgrade, then fall back):
   - **codeReview** (any non-docs code file changed): if `gates.codeReview.upgrade` is set and that
     skill/agent is installed, use it; else invoke the bundled `ship-gate:ship-review` skill (it runs
     `/code-review` plus the distilled checklist); if even `/code-review` is unavailable, fall back to
     the bundled `ship-reviewer` agent via Task. STOP on a **Block** verdict; carry Warnings into the summary.
   - **security** (any code/config/dependency file changed; use the **deeper** checklist when a
     `scoping.security` path is touched): if `gates.security.upgrade` is installed, use it; else invoke
     the bundled `ship-gate:ship-security` skill (self-contained checklist; opportunistically also run
     `/security-review` if present). STOP on a **Block** verdict.
   - **uat** (per the confidence table in `references/scenario-matrix.md`: ui → required, hooks/contexts
     logic → recommended, lib/api → optional, analytics/docs → skip): when required or recommended,
     invoke `gates.uat.skill` (default `/verify`, plus `/run` to exercise the app) or ask for manual
     confirmation. The USER makes the final call on whether UAT is satisfied.
   - **regression** (only if `regression.enabled` AND the change is test-affecting): invoke the
     configured `regression.skill`. Off by default — skip silently when disabled.

5. **Heavy gates.**
   - If `--audit`: run `/deep-review` applying `references/audit-checklist.md` (or
     `heavyGates.audit.upgrade` if that skill is installed) — a whole-codebase systemic sweep.
   - If `--deep`: run `/deep-review` applying `references/deep-review-lenses.md` (or
     `heavyGates.deep.upgrade` if installed) — the iterative 14-lens pass over the diff.
   - **Fallback (never silently skip an explicitly requested heavy gate):** if a requested
     `--audit`/`--deep` cannot resolve `/deep-review` AND no matching `heavyGates.*.upgrade` is installed,
     warn once and apply the bundled checklist DIRECTLY — Read `references/audit-checklist.md` (for `--audit`)
     or `references/deep-review-lenses.md` (for `--deep`) and apply it to the diff yourself.
   - If neither flag is set but a `heavyGates.*.suggestWhen` heuristic fires (thresholds in
     `references/scenario-matrix.md` — e.g. filesChanged/areasChanged/riskyPaths for audit;
     diffLines/riskyPaths/release for deep), SUGGEST running it and let the user decide. Do not force it.

6. **`--hotfix`:** skip the gates in `hotfix.skipGates` (uat, regression, audit, deep); KEEP tests,
   codeReview, secretScan, **and security** (only uat/regression/audit/deep — the `hotfix.skipGates` set —
   are skipped). Note the skipped gates for the DECISIONS.md entry written in step 10.

7. **Gate Status Summary.** Print every gate with its outcome. Status tags are ASCII only:
   `[PASS]` pass / `[FAIL]` fail / `[SKIP]` skipped + why / `[USER]` user-decided / `[WARN]` warning carried
   forward. Then the branch and deploy target. Show `regression`'s real status (never hard-code `[SKIP]`), and
   keep `audit / deep` on their own opt-in line:
   ```
   ## Ship Gate Summary
   [PASS] tests — <result>
   [PASS] lint / typecheck / build — <result or "skipped (disabled)">
   [PASS] secretScan — clean
   [PASS] codeReview — <verdict> (resolved via: <upgrade|ship-review|manual>)
   [PASS] security — <verdict> (resolved via: <upgrade|ship-security|manual>)
   [USER] uat — <confidence>% UI impact — user decision: <required|skipped>
   <[PASS]|[FAIL]|[SKIP]> regression — <ran: result | skipped: disabled | skipped: not test-affecting>
   <[PASS]|[FAIL]|[SKIP]> audit / deep — <ran | not requested>
   Branch: <branch>   Target: origin/<protected-branch>
   ```
   If `--dry-run` — or a QUESTION/NEGATION invoked this ("should we ship?", "is this ready?", "don't ship yet") —
   STOP HERE: report the summary, do not write a marker, do not push.

8. **Decide whether to push — auto-push on green; the imperative command IS the authorization.** A typed
   `/ship` (or a natural-language ship command) authorizes the push: there is NO separate final "Ready to
   push? y/n". Auto-push removes ONLY that rubber-stamp — it NEVER skips a question a gate genuinely needs.
   STOP or PAUSE here when any of these is outstanding:
   - `--dry-run`, OR a QUESTION/NEGATION invoked this ("should we ship?", "is this ready?", "don't ship yet") → report, never push.
   - **Any deterministic gate FAILED, or codeReview/security returned Block** → STOP, report, no push.
   - **UAT required/recommended and not yet satisfied** → PAUSE; the USER makes the final call.
   - **A missing/ambiguous test command** (a `[WARN] … no command detected` on an enabled gate) → PAUSE for an
     explicit acknowledgment (per step 3 — never silently pass).
   - **Merge guard** (feature branch, pending commits, gates not fully passed) → PAUSE for an explicit "yes".
   - **A heavy-gate `suggestWhen` heuristic fired** → suggest it and let the user decide.
   - **Any genuine edge you surface** that the configured gates do not formally cover → raise it and wait.
   When every REQUIRED gate passed and NO pause above is outstanding, proceed straight to step 9 — no separate
   confirmation. This SUPERSEDES the v1 "never push automatically; confirm first" rule: only code that passed
   every required gate can be pushed, and the push-block hook still backstops any ungated push, so the blast
   radius of a misread is bounded to already-gated code.

9. **Integrate + push (on green; auto-merge included), in this order so the marker matches the pushed commit.**
   Use the resolved **protected branch** (the `protected-branch` from Live state) everywhere below.
   - **If on a feature branch (auto-merge — P8-9):** run the **merge guard** — `git log <protected>..<branch> --oneline`.
     If there are pending commits AND not all gates passed, PAUSE EXPLICITLY:
     `[WARN] MERGE GUARD: N commits pending; gates not fully passed: [list]; pushing to <protected> may deploy to
     production. Approve? (yes/no)` — and wait for an explicit "yes". Never merge silently. Then
     `git checkout <protected> && git pull origin <protected> && git merge --no-ff <branch> -m "..."`. Merging is
     part of shipping (the imperative authorized it) — but **any git-operation failure HALTS and reports (P8-8):
     a merge conflict, a failed `git pull`, or a rejected / non-fast-forward push → STOP with the exact failure;
     never leave a conflicted or partial state, never `--force`.** HEAD is now the merge commit.
   - **Write the marker now** (every REQUIRED gate passed — the only way we reach here):
     `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" write-marker . <hotfix-bool>` (`true` under `--hotfix`, else
     `false`). It records the exact HEAD + the resolved branch, so the push-block hook allows this push. On
     `<protected>` directly HEAD is unchanged; on a feature branch it records the merge commit — either way the
     marker's HEAD equals the commit being pushed. **Always write the marker here** — even if this repo's
     ship-gate is OFF via `/ship off` (the hook would allow the push without a marker in that case, but writing
     it anyway keeps gating correct the moment `/ship on` is run). Never skip the marker.
   - **Deploy-target confirm (the one place auto-push still asks):** if a deploy target was detected
     (`deploy.warnOnPush`, or the runner's `detect` reports one), pushing to `<protected>` likely triggers a
     production deploy — a consequence the gates never evaluated. Print `[CONFIRM] deploy target detected —
     pushing <protected> may trigger a production deploy. Proceed? (yes/no)` and wait for "yes" before pushing.
   - `git push origin <protected>`. If the push is rejected (non-fast-forward), HALT and report — do not `--force`
     (P8-8). Then, if a feature branch was merged, offer to delete it.

10. **Post-ship.** Verify the push succeeded (`git status`, confirm HEAD is on the remote). On a
    `--hotfix`, append the entry below to `DECISIONS.md`. If the project keeps session handoff notes,
    update them. Report the final state.

## Hotfix DECISIONS.md entry
```
## [YYYY-MM-DD] Hotfix: <description>
**Context:** <what was broken>
**Decision:** Fast-shipped with reduced gates — skipped: uat, regression, audit, deep (kept: tests, code review, security, secret scan)
**Consequences:** Run full regression/UAT next session to verify no side effects
```
