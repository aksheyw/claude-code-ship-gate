# Changelog

All notable changes to ship-gate are documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [0.5.5] - 2026-07-23

### Fixed
- **Restored a docs pass that v0.5.4 reverted.** Commit `c543f8c` (em-dashes removed from the README and
  the `/ship` skill, a stale companion-repo skill count corrected, gate-output examples aligned with what
  the runner actually prints) was authored directly on the public repo and never existed in the
  development tree. Because a release rebuilds the published tree from that development tree, v0.5.4
  silently reverted all of it. The changes now live in the development repo, so they survive future
  releases. Same class of problem as `CASE-STUDY.md` in v0.5.0: anything edited only on the public side
  is lost at the next release unless it is brought back first.

---

## [0.5.4] - 2026-07-23

### Added
- **Config-drift detection — the other half of the "no silent pass" spec.** Until now, a `.shipgate.json`
  that disabled a gate ("docs-only repo, tests off") could go stale as the repo grew real capability, and
  every ship would report a clean `[SKIP]` while nothing ran. `run` now cheaply checks (no execution, just
  a filename scan) whether a disabled `tests`/`lint`/`typecheck`/`build` gate's capability is actually
  present in the repo. `[DRIFT]` (no reason recorded) pauses `/ship` for an explicit acknowledgment, the
  same weight as an enabled gate with no command; `[DRIFT-ACK]` (a `gates.<gate>.reason` + optional `.since`
  recorded) surfaces every run but does not pause — a dated, conscious decision doesn't need re-litigating
  on every push. A legitimately non-applicable gate stays a plain, silent `[SKIP]`.
- `ship-gate.sh doctor` now also audits an existing `.shipgate.json` against the same detection and
  proposes a concrete fix (the real auto-detected command, or an honest "inspect manually" placeholder).
- Schema: optional `reason`/`since` string properties on `gates.{tests,lint,typecheck,build}`.
- **File-coverage requirement on the codeReview gate.** `codeReview` is a judgment gate — a model reads
  the diff and returns a verdict — so on a large changeset it could review a subset and still report a
  pass, with nothing asserting otherwise. New `ship-gate.sh changed-files` emits the authoritative list of
  files in the shipped change, computed in bash from git rather than from the model's reading of the diff
  (committed range + staged + unstaged + untracked; ignored files excluded; non-ASCII paths byte-exact via
  `core.quotePath=false`). `/ship` now requires every path on that list to be either reviewed or explicitly
  classified as needing no review with a stated reason, reports coverage as `N/M files`, and treats an
  unaccounted path as an INCOMPLETE gate rather than a pass. It is a manifest, never a gate: it always
  exits 0 and never blocks a push on its own — the deterministic tier keeps exit-code semantics for gates
  that actually execute something.

### Fixed
- A `set -euo pipefail` footgun in the new detection code (a function's last-executed command being a
  false `&&` test propagates that exit status as the function's own return code, which aborts the script
  when the caller assigns via command substitution) — caught by the test suite before it shipped.
- **Fail-open: an enabled gate with an empty suite array reported a pass without running (found by an
  independent Codex review).** `"tests":{"enabled":true,"command":[]}` passed structural validation —
  jq's `all` is vacuously true over `[]` — after which the runner warned "empty suite list" and returned
  success, so an ENABLED deterministic gate exited 0 having executed nothing. An enabled gate with nothing
  to run is a config error and now fails closed, matching the rule already applied to every other
  malformed structure. **Behaviour change:** a config carrying `command: []` now aborts (exit 2) instead
  of warning. The schema gained `minItems: 1` to match.
- **An unknown subcommand exited 0.** `ship-gate.sh <typo>` printed usage and returned success, so a CI
  step or wrapper trusting the exit status read a clean pass while no gate had run. Unrecognised
  operations now exit 2; an explicit `help` still exits 0.
- Capability discovery now respects git's view of the repo (`git ls-files -z --cached --others
  --exclude-standard`) instead of scanning the raw filesystem, and prunes `vendor/`. Without this, a
  git-ignored linked worktree, a vendored dependency, or build output inflated the count and could name an
  untracked copy as the example. Five further edges found by an adversarial review pass and fixed with
  tests: non-ASCII paths (git quotes them without `-z`, making such files invisible to detection),
  tracked-but-deleted files being counted, a trailing slash on the target dir silently dropping a root
  `Makefile`, and a directory inside a parent repo's ignored path reporting no capability at all.

---

## [0.5.3] - 2026-07-18

A docs release: the README demo GIF is now much faster to watch.

### Changed
- **Demo GIF sped up ~4x (roughly 90s → 21s).** Same real `/ship` run, trimmed of the dead air where
  the model was thinking, so the arc (bypass ask → refusal → `ship it` → gates pass → push) reads in a
  third the time. Same file at `assets/demo.gif`.

---

## [0.5.2] - 2026-07-18

A docs release: the README now leads with a recorded demo of the gate in action.

### Added
- **Demo GIF (`assets/demo.gif`), embedded near the top of the README.** Every frame is a real `/ship`
  run: asked to "just push to main and skip the gates," Claude declines to bypass and points to `/ship`,
  which runs the gates, writes the pass marker, and pushes. Recorded with [vhs](https://github.com/charmbracelet/vhs);
  the tape and its throwaway-repo setup live in `docs/` (maintainer-only, outside the public export).

### Changed
- `tools/publish.sh` now includes a top-level `assets/` directory in the export allowlist, and
  `tools/publish_test.sh` asserts the demo GIF ships and the README reference resolves.

---

## [0.5.1] - 2026-07-17

A security patch for the push-block hook, closing the refspec-source fail-open reported against 0.5.0.

### Fixed
- **Refspec-source bypass of the pass marker (F-SG-2026-07-01, HIGH).** Within a valid pass window, a
  `git push origin feature:main` (or any explicit `src:dst` to the protected branch) certified against the
  destination's local tip instead of the commit it actually landed, letting ungated commits reach the
  protected branch. The hook now resolves the refspec **source** and compares that to the marker, covering
  every git branch-destination spelling (`main`, `heads/main`, `refs/heads/main`). Empty-source deletions
  (`:main`) and multi-refspec pushes landing two commits are denied. The legitimate `HEAD:main` publish
  flow still passes.
- **O(n²) continuation fold in the pre-filter (F-SG-2026-07-04).** A `git push` padded with ~12k
  backslash-newline line-continuations could make the hook exceed its 15s timeout (treated as
  non-blocking = a bypass). The fold is now O(n); a 15k-continuation command classifies in ~120 ms
  (was ~37 s). The refspec-source resolution is likewise bounded by count and size caps so no
  command length can time the hook out.

### Known boundary (documented, not fixed)
- The push-detection parser is O(n²) on backslash-newline continuations (pre-existing since before 0.5.0);
  a hand-crafted ~700 KB command can still make the gate slow. Documented in the README scope boundary —
  ship-gate is a guardrail against accidental and fast-agent pushes of your own code, not a sandbox against
  a determined adversary crafting oversized commands.

## [0.5.0] - 2026-07-17

The flagship-credibility release: the quality-gate tool now has CI on its own repo, a README you can
act on in 15 seconds, and honest positioning for bare-skill installs.

### Added

- **CI on this repo.** `.github/workflows/ci.yml` runs the full 364-assertion bash suite on
  ubuntu + macos and validates all four manifests with jq, on pushes to main and on every pull request. The README's
  hardcoded test-count badge is replaced by the live CI badge (the hardcoded-count class silently went
  stale twice; a live badge can't).
- **skills.sh runtime guards.** `ship` and `ship-init` now open with a runtime check: if
  `CLAUDE_PLUGIN_ROOT` is empty (a bare skills.sh install), they stop and point to the full plugin
  install instead of running without the deterministic runner and the push-block hook. `ship-review`
  and `ship-security` carry self-contained checklists and need no guard (`ship-review`'s optional
  fallback reviewer agent ships only with the full plugin).

### Changed

- **README restructured for the 15-second rule.** Quick install (marketplace + personal) and a
  3-bullet How-it-works now sit above the fold; a skills.sh subsection says plainly what a bare skills
  install does and does not deliver; release + CI badges added; the case study (`CASE-STUDY.md`) is
  now linked. Existing prose largely kept and pushed down; the wording fixes below are the exceptions.
- **Honest fail-closed wording.** The README no longer claims "a broken hook blocks the push":
  a hook that fails to execute (or times out) is non-blocking in Claude Code. Both fail-closed
  passages now state that seam plainly and explain how the hook engineers around it (self-contained,
  quoted paths, O(n) parsing, regression-locked).
- **`/ship` honors `gates.<gate>.enabled: false` for judgment gates.** The schema always defined
  the flag; the orchestrator prompt never consulted it for codeReview/security/uat. A disabled
  judgment gate is now reported `[SKIP] (disabled)` instead of running anyway.
- **Test suite made CI-portable.** Tests no longer depend on the runner's git identity
  (hermetic env identity in the shared assert harness) and the perf timer no longer requires
  GNU `date +%s%N` (portable fallback). No deterministic gating logic touched.

### Notes

- The push-block hook, the locked awk push-detection parser, the marker, and the deterministic
  runner scripts are **byte-untouched** in this release. Plugin suite stays 364/0.

---

## [0.4.0] - 2026-06-26

Multi-suite / area-conditional deterministic gates — so a repo with more than one test suite can't get a
false "tests PASS" by running only the first one — plus config-time tooling to find the suites you'd miss.

### Added

- **Multi-suite test gates.** `gates.tests.command` (and `lint` / `typecheck` / `build`) now accept an
  **array of `{ command, when }` suites** in addition to a string. Each suite runs only if a changed file
  matches its `when` git-pathspecs (omit `when` to always run it), and **any in-scope suite that fails,
  fails the gate.** A repo with a root suite, a `functions/` suite, and a Firestore-rules suite now runs
  every relevant one instead of silently skipping all but the first.
  - `when` entries are git pathspecs: `*` spans `/` (so `*.rules` matches at any depth, `functions`
    matches everything under `functions/`); brace globs like `{a,b}` aren't supported — list separately.
  - Scope is **fail-safe**: if the shipped change-set can't be determined, every `when`-suite runs (it can
    over-run, never silently skip). **Staged and untracked** new files count, since gates run before commit.
  - **Malformed config fails closed; unevaluable scope fails safe.** A bare-string array, or a suite with an
    empty/missing `command`, fails the gate (never a silent pass). An unsupported or invalid `when` pathspec
    (a brace glob like `*.{a,b}`, or bad pathspec magic) is treated as indeterminate scope, so the suite
    runs — never silently skipped.
  - **Runtime structural validation** (the schema is editor-only). The runner now rejects, fail-closed, any
    config shape that would otherwise silently disable or skip a gate: a non-object `gates` or gate, a
    non-boolean `enabled`, a `command` that is not null/string/suite-array, or a non-string-array `when`.
    `when` pathspecs are matched relative to the repo root (so a `.shipgate.json` in a subdir scopes
    correctly), not the directory `/ship` was run from.
- **`doctor` — uncovered-suite detection.** New `ship-gate.sh doctor` (which `/ship-init` runs and you can
  run any time) flags suites a single `tests.command` would silently skip — a nested package with its own
  test script, an extra/named test-runner config (e.g. `vitest.config.functions.ts`), an e2e suite, a
  `*.rules` security-rules file — and offers to wire each as a `when`-conditional suite. Advisory: it prints
  `[WARN]` lines and always exits 0; it never blocks a push.
- **CI-awareness.** `detect` now reports a `ci` field; `doctor`, `/ship-init`, and `/ship` warn when no CI is
  configured — "this gate is your only automated check before prod, keep suite coverage aggressive."
- **Deploy-connected build pre-flight.** When a deploy target is detected (Vercel / Netlify / Firebase /
  Fly.io / Render), `/ship-init` now scaffolds `gates.build.enabled: true` so a broken build is caught
  locally before it breaks the deploy. The runtime default stays `false` (existing configs are unchanged).
- **Monorepo example.** New `examples/monorepo.shipgate.json` — a self-contained multi-suite showcase (root
  app + `functions/` package + Firestore rules, per-area `when`-conditional suites, deploy-connected build).

### Changed

- A plain-string `command` behaves exactly as before — full back-compat. `ship-gate.sh detect` now reports
  a `<multi-suite: N suites>` placeholder for an array command instead of raw JSON.
- **`regression` relabeled as an advisory strategy pointer.** It was never an executable check — the runner
  never ran a command for it. Enabling it surfaces the `ai-regression-testing` strategy skill for guidance
  on test-affecting changes; it never runs a command and never blocks. For regression *suites* you want
  executed, add them to a multi-suite `gates.tests.command`. Schema + docs only; no behavior change.

### Fixed

- **Actionable error for the compound-command footgun.** If the pass-marker write and the `git push` are
  chained in a *single* command (`… write-marker … && git push …`), the push can never pass on its own
  authority: the push-block is a PreToolUse hook, so it reads the marker *before* the command runs and the
  same-command write hasn't taken effect yet — producing a baffling generic "pass is for a different commit"
  deny. The hook now detects this shape (an already-confirmed protected-branch push whose text also carries
  both the `write-marker` and `ship-gate` tokens) and, **on a marker-validation failure**, surfaces a
  specific fix — run them as two separate commands — which `/ship` already does. The message is gated on the
  failure path, so a push that *already* holds a valid pass is allowed regardless of those tokens (no
  false-deny). The new HARD RULE is documented in step 9 of the `ship` skill.

### Notes

- The multi-suite work is entirely in the deterministic runner's gate-execution path. The locked `awk`
  push-detection parser and the pass-marker are untouched; the push-block hook gained only the one additive,
  fail-closed guard above, which runs *after* the parser has already confirmed a protected-branch push.

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

- **Bundled reference checklists** (each under its skill's `references/` dir):
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
