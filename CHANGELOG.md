# Changelog

All notable changes to ship-gate are documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [0.3.0] - 2026-06-15

Optional default-on, and a natural-language ship trigger.

### Added

- **Say "ship it".** With the trigger rule installed, plain-language ship intent runs the
  gate: a command ("ship it", "go ahead and ship", "sync with GitHub") runs every gate and
  pushes on green; a question ("is this ready?") or a "not yet" runs the gates and reports
  without pushing. `install-local.sh` installs the rule to `~/.claude/rules/`; marketplace
  users add a one-line rule themselves (see the README).
- **On by default for a personal install.** `install-local.sh` now gates every repo, via a
  global `~/.shipgate.json` with `defaultEnabled: true`. Pass `--no-default-on` to keep it
  opt-in. A marketplace install is unchanged: still opt-in, gating only repos that contain a
  `.shipgate.json`.
- **Four ways to step out of the gate**, narrowest to broadest: one session
  (`SHIPGATE_DISABLE=1`), one repo (`/ship off`, undo with `/ship on`), the whole machine
  (`enabled: false` in `~/.shipgate.json`), or back to opt-in (`defaultEnabled: false`).
- **Per-repo on/off on the runner.** `ship-gate.sh disable | enable | status` backs `/ship
  off` and `/ship on`, and resolves correctly from a subdirectory or a linked worktree.

### Changed

- **`/ship` pushes on green when you command it.** It is now model-invocable. Run as a
  command, it writes the marker and pushes once every required gate passes and nothing needs
  your decision; run as a question, or with `--dry-run`, it reports and never pushes. This
  replaces the previous "always stop and ask" behavior. Any gate that needs your input still
  pauses.
- **The protected branch is resolved, not hardcoded.** The hook, the runner, and `/ship`
  share one resolution order (per-repo config, then global config, then `SHIPGATE_MAIN_BRANCH`,
  then `origin/HEAD`, then `main`/`master`), so they always target the same branch. Repos
  whose trunk is `master`, or anything else, work without extra config.

### Fixed

- Fail-open and edge cases found while building default-on: a non-string `mainBranch` no
  longer gates a branch that does not exist; `/ship off` disables correctly from a repo
  subdirectory and a linked worktree; and the hook and runner are held to one branch
  resolution by a 20-assertion contract test.

### Notes

- Default-on is a switch on the personal installer, not a marketplace default. The published
  plugin stays opt-in for everyone who installs it; only your own `install-local.sh` turns
  gating on everywhere, and `--no-default-on` opts out even then.

---

## [0.2.0] - 2026-05-30

Production-readiness hardening of the push-block hook.

### Changed

- **Opt-in per repo.** The push-block hook is now a no-op unless the repo contains a
  `.shipgate.json` (gated iff the file is present AND top-level `enabled != false`). A
  personal or global install no longer gates repos that never adopted ship-gate.
- **Command-position-aware push detection.** Replaced the whole-command `git push` grep with
  an O(n) `awk` shell-aware parser that honors env-assignment prefixes, git global options,
  and single / double / ANSI-C (`$'...'`) quoting plus backslash-newline continuation. Removed
  the `if:"Bash(git push *)"` matcher so `check-push.sh` is the single gate.

### Fixed

- Seven fail-open classes in push detection, found by a 14-lens deep review + 3 adversarial
  red-teams: O(n²) timeout-padding, env-assignment prefix, double-quote & `$'...'`
  escaped-quote parity, backslash-newline continuation, control-byte record split, the
  `if`-matcher under-match, and space-form value-globals / tab-refspec / subshell.
- `awk` is now a dependency (POSIX-ubiquitous; the hook fails **closed** if it is missing).

### Notes

- Scope boundary (documented, by design): a guardrail against accidental and normal un-gated
  pushes, **not** a sandbox — git invoked via a wrapper (`bash -c`, `eval`, `sudo`, …) or
  obscured by I/O redirection is out of scope.

---

## [0.1.0] - 2026-05-29

Initial release.

### Added

- **Deterministic runner** (`scripts/ship-gate.sh`) with `detect`, `run`, and
  `write-marker` subcommands. Auto-detects test, lint, typecheck, build, and deploy
  commands from project files (`package.json`, `Cargo.toml`, `pyproject.toml`,
  `go.mod`, etc.). Runs gates in sequence; exits non-zero on first failure.
  Never silently passes a gate with no command: surfaces `[WARN] <gate>: no command
  detected` and requires user acknowledgment.

- **Secret-scan gate** (`scripts/secret-scan.sh`). Scans diff added lines for
  credential patterns; non-zero exit blocks the ship.

- **Push-block PreToolUse hook** (`hooks/hooks.json` + `scripts/check-push.sh`).
  Intercepts `git push` to the main branch before the tool executes.
  Denies the push unless a valid gate-pass marker exists for the exact HEAD commit,
  on the correct branch, within the configured TTL. Because this is a PreToolUse
  hook, `--no-verify` cannot bypass it. Reads `.shipgate.json` directly for
  `mainBranch` and `markerTtlSeconds`; falls back to env vars and built-in defaults.

- **`/ship` orchestrator** (`skills/ship/SKILL.md`). Manual-only gate runner:
  - Parses `--hotfix`, `--dry-run`, `--audit`, `--deep` flags.
  - Classifies changed files into buckets (docs, ui, logic, security-sensitive,
    config/infra, test-affecting) using project `scoping` globs.
  - Docs-only pushes skip all judgment gates.
  - Runs deterministic gates via the bundled runner.
  - Runs judgment gates (codeReview, security, uat, regression) via 3-tier
    resolution: upgrade skill -> bundled default -> manual fallback.
  - Supports heavy gates (`--audit` / `--deep`) with fallback to bundled checklists
    when `/deep-review` is unavailable.
  - Suggests `--audit` / `--deep` automatically when configurable thresholds fire
    (files changed, areas changed, diff lines, risky paths, release context).
  - Prints a Gate Status Summary with ASCII-only status tags before asking for
    confirmation.
  - Writes the pass-marker only after explicit user confirmation ("yes"), then
    pushes/merges to main. Includes merge guard for feature branches.
  - `--hotfix` fast path skips uat/regression/audit/deep; keeps tests, codeReview,
    secretScan, security; appends a `DECISIONS.md` entry.
  - `--dry-run` stops after the summary without writing a marker or pushing.

- **Scenario matrix** (`skills/ship/references/scenario-matrix.md`). Documents
  which gates run under which change-type conditions and the default suggestion
  thresholds for heavy gates.

- **`/ship-init`** (`skills/ship-init/SKILL.md`). One-shot setup helper. Runs
  `ship-gate.sh detect`, writes a populated `.shipgate.json` scaffold, and
  explains the config knobs. No-overwrite guard: asks before replacing an
  existing file.

- **`/ship-review`** (`skills/ship-review/SKILL.md`). Bundled code-review
  judgment gate. Invokes `/code-review` on the diff, applies the distilled
  `code-review-checklist.md`, emits Approve/Warning/Block. Falls back to the
  `ship-reviewer` agent when `/code-review` is unavailable.

- **`/ship-security`** (`skills/ship-security/SKILL.md`). Bundled security
  judgment gate. Applies `security-checklist.md` to changed files; goes deeper
  on files matching `scoping.security` globs. Optionally augments with
  `/security-review` when available.

- **`ship-reviewer` agent** (`agents/ship-reviewer.md`). Self-contained fallback
  code-reviewer. Embeds five review dimensions (correctness, security, immutability,
  performance, maintainability) inline; no external skill required at runtime.
  Also usable directly via `codeReview.upgrade: "ship-reviewer"`.

- **Bundled reference checklists** (`skills/ship/references/`):
  - `code-review-checklist.md` - distilled from vibe-security, code-reviewer, OWASP
  - `security-checklist.md` - distilled from vibe-security, OWASP, gitleaks
  - `audit-checklist.md` - whole-codebase systemic sweep
  - `deep-review-lenses.md` - iterative 14-lens methodology

- **`.shipgate.json` configuration** with JSON Schema (Draft-07,
  `schema/shipgate.schema.json`). Per-project config covers: `mainBranch`,
  `gates` (tests/lint/typecheck/build/secretScan/codeReview/security/uat),
  `heavyGates` (audit/deep with `suggestWhen` thresholds), `regression`,
  `scoping` globs, `deploy` auto-detection, `hotfix.skipGates`,
  `markerTtlSeconds`. Runtime deep-merges over built-in defaults; any subset
  of keys is valid.

- **Example config** (`examples/example.shipgate.json`). Real-world
  project config showing all sections.

- **Mode A installer** (`install-local.sh`). Copies skills and agent into
  `~/.claude/`, rewrites `${CLAUDE_PLUGIN_ROOT}` to an absolute path, strips the
  `ship-gate:` namespace, backs up any existing `~/.claude/skills/ship.md`, and
  merges the push-block hook into `~/.claude/settings.json` idempotently.
  Accepts `--yes` for non-interactive use.

- **Mode B marketplace install** via `/plugin marketplace add` +
  `/plugin install ship-gate@ship-gate`. Commands namespaced as
  `/ship-gate:ship`, `/ship-gate:ship-init`, etc. Hooks auto-activate.

- **Test suite** (`scripts/test/`). Covers the bash runner, marker logic,
  push-block hook (including spaced-path variants), secret-scan, config
  resolution, detection, and the Mode A installer. All tests pass at `FAIL=0`.
