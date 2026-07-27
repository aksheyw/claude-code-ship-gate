# Ship Gate: full configuration reference

Everything the [README](../README.md) points at but doesn't need to carry. Read that first for what
Ship Gate is and why it sits where it does.

**Contents:** [Two config files](#two-config-files) · [Every key](#every-key) ·
[Multi-suite test gates](#multi-suite-test-gates-monorepos) · [What runs when](#what-runs-when) ·
[Turning the gate off](#saying-ship-it-and-turning-the-gate-off) ·
[Swapping in external reviewers](#gate-skills-and-companions) ·
[Verify it's working](#verify-its-working) · [Troubleshooting](#troubleshooting)

---

## Two config files

**Two files, two jobs.** A per-repo `.shipgate.json` configures the gates for one project. A global
`~/.shipgate.json` holds machine-wide switches: `defaultEnabled` (gate every repo, no per-repo file
needed) and `enabled:false` (a machine-wide off switch). To pause one repo while keeping its config,
set its top-level `"enabled": false` or run `/ship off`.

**Scaffold one** (auto-detects your commands; asks before overwriting an existing file):

```
/ship-init          # or namespaced: /ship-gate:ship-init
```

**Full example** (also at [`plugins/ship-gate/examples/example.shipgate.json`](../plugins/ship-gate/examples/example.shipgate.json)):

```json
{
  "mainBranch": "main",
  "gates": {
    "tests":      { "enabled": true,  "command": "npx vitest run" },
    "lint":       { "enabled": true,  "command": null },
    "typecheck":  { "enabled": true,  "command": null },
    "build":      { "enabled": false, "command": null },
    "secretScan": { "enabled": true },
    "codeReview": { "enabled": true, "skill": "ship-review",   "upgrade": "code-reviewer" },
    "security":   { "enabled": true, "skill": "ship-security", "upgrade": "vibe-security" },
    "uat":        { "enabled": true, "skill": "verify", "mode": "confidence" }
  },
  "regression": { "enabled": true, "skill": "ai-regression-testing", "runWhen": "test-affecting" },
  "deploy":  { "autoDetect": true, "warnOnPush": true },
  "hotfix":  { "skipGates": ["uat", "regression", "audit", "deep"] },
  "markerTtlSeconds": 900
}
```

A partial config is valid: anything you omit falls back to the bundled defaults (the runtime
deep-merges your file over them). The schema
([`plugins/ship-gate/schema/shipgate.schema.json`](../plugins/ship-gate/schema/shipgate.schema.json),
Draft-07) gives editor autocomplete.

## Every key

| Key | Default | Purpose |
|-----|---------|---------|
| `mainBranch` | `"main"` | Protected branch that `/ship` targets and the hook guards. Also honored in the global `~/.shipgate.json` and via `SHIPGATE_MAIN_BRANCH`; otherwise auto-detected from `origin/HEAD`, falling back to `main`/`master`. |
| `enabled` (top-level) | `true` | Set `false` to pause enforcement for this repo while keeping its config. In the global `~/.shipgate.json`, `false` is a machine-wide off switch. |
| `defaultEnabled` (global only) | `false` | **In `~/.shipgate.json` only.** `true` gates every repo that has no per-repo `.shipgate.json` (default-on). Set by `install-local.sh`; ignored inside a per-repo file. |
| `gates.*.command` | `null` (auto-detect) | A string, `null` (auto-detect), or an **array** of `{command, when}` suites for multi-suite repos (see below). |
| `gates.build.enabled` | `false` | Build gate is opt-in; flip to `true` when ready. |
| `gates.*.upgrade` | `null` | External skill to prefer over the bundled default when installed. |
| `gates.{tests,lint,typecheck,build}.reason` / `.since` | (unset) | Why a command gate is disabled, and when that was recorded, so the premise is auditable at ship time. When set, a config-drift signal becomes an informational `[DRIFT-ACK]` instead of a pausing `[DRIFT]`. |
| `regression.enabled` | `false` | Advisory only: surfaces the `ai-regression-testing` strategy skill on test-affecting changes (guidance: it runs no command and never blocks). For regression *suites* you want actually executed, add them to a multi-suite `gates.tests.command`. |
| `hotfix.skipGates` | `["uat","regression","audit","deep"]` | Gates skipped on `--hotfix`. Tests, codeReview, secretScan, and security are always kept. |
| `markerTtlSeconds` | `900` | How long a gate-pass marker stays valid before it expires. |

## Multi-suite test gates (monorepos)

A single `command` runs one suite. On a repo with more than one test suite, that silently leaves the
others unrun while still reporting "tests PASS", a false all-clear. So `tests` (and
`lint`/`typecheck`/`build`) also accept an **array of suites**: each is an object with a `command` and
an optional `when` (git pathspecs). A suite runs only if a changed file matches its `when`; omit `when`
to always run it. **Any in-scope suite that fails, fails the gate.**

```json
"tests": { "enabled": true, "command": [
  { "command": "npx vitest run" },
  { "command": "npx vitest run -c functions/vitest.config.ts", "when": ["functions"] },
  { "command": "npm run test:rules", "when": ["*.rules"] }
] }
```

The root suite always runs; the `functions/` suite runs only when a file under `functions/` changed;
the rules suite runs only when a `*.rules` file changed. A few things worth knowing:

- **`when` entries are git pathspecs.** `*` spans `/`, so `*.rules` matches at any depth and
  `functions` matches everything under `functions/`. Brace globs like `{tsx,jsx}` are not supported,
  so list them separately (`*.tsx`, `*.jsx`).
- **Staged and untracked files count.** Gates run before the commit, so a brand-new suite's files
  (staged or untracked) put its suite in scope.
- **Scope is fail-safe.** If the shipped change-set can't be determined, every `when`-suite runs. It
  can over-run (slower), never silently skip.
- **A plain string still behaves exactly as before.** On older plugin versions, a
  `scripts/ship-tests.sh` wrapper that chains the suites by hand is the equivalent fallback.

To find suites you'd otherwise miss, run `ship-gate.sh doctor` (and `/ship-init` runs it for you): it
flags a nested package with its own test script, an extra/named test-runner config, an e2e suite, or a
`*.rules` file the single command wouldn't touch, warns if no CI is configured, and (against an
existing `.shipgate.json`) flags config drift, a disabled gate the repo has since grown real capability
for, proposing the concrete fix. It's advisory and never blocks. A worked monorepo config is in
[`examples/monorepo.shipgate.json`](../plugins/ship-gate/examples/monorepo.shipgate.json).

## What runs when

Changed files are classified into buckets (docs, ui, logic, security-sensitive, config/infra,
test-affecting) using your `scoping` globs, and gates fire by bucket:

| Gate | When it runs |
|------|-------------|
| tests / secretScan | always when enabled (both on by default) |
| lint / typecheck | always (if a command is present) |
| build | only when `gates.build.enabled` is `true` |
| codeReview | any non-docs code file changed; skipped on docs-only pushes |
| security | any code/config/dependency file changed; deeper checklist when a `scoping.security` path is touched |
| uat | confidence-based: ui → required, logic → recommended, lib/api → optional, analytics/docs → skip |
| audit / deep | opt-in via `--audit` / `--deep`; suggested past size/risk thresholds |
| regression | advisory strategy pointer (guidance, not an executable check), only when `regression.enabled` **and** the change is test-affecting |

**Docs-only push** (every changed path matches `**/*.md`): deterministic gates + secretScan run; all
judgment gates skip. **`--hotfix`** skips uat/regression/audit/deep but keeps tests, codeReview,
secretScan, and security. Full matrix:
[`scenario-matrix.md`](../plugins/ship-gate/skills/ship/references/scenario-matrix.md).

## Saying "ship it", and turning the gate off

**Natural-language ship.** With the trigger rule installed (automatic in a personal install; a
one-liner for marketplace installs), plain-language ship intent runs the gate:

- A **command** ("ship it", "go ahead and ship", "sync with GitHub") runs every gate and **pushes on
  green**, pausing only where a gate genuinely needs your decision.
- A **question** or a **"not yet"** ("is this ready?", "don't ship until tests pass") runs the gates
  and reports, and never pushes.

**Four ways to step out of the gate**, narrowest to broadest:

| Scope | How | Effect |
|-------|-----|--------|
| One session | `export SHIPGATE_DISABLE=1` before launching Claude | The hook allows every push for that session. |
| One repo | `/ship off` (re-enable with `/ship on`) | Pauses gating for that repo only. |
| This machine | `enabled:false` in `~/.shipgate.json` | Off everywhere, unconditionally. |
| Back to opt-in | `defaultEnabled:false` in `~/.shipgate.json`, or remove the file | Only repos with a `.shipgate.json` are gated again. |

There's no uninstall script: setting `defaultEnabled:false` (or removing `~/.shipgate.json`) and
deleting the `~/.claude/rules/shipgate-trigger.md` line returns you to plain opt-in.

## Gate skills and companions

Each judgment gate resolves in three tiers: a configured **external upgrade** (if installed) → the
plugin's **bundled default** → a **manual** prompt. A missing optional upgrade never hard-blocks; it
warns once and falls back.

| Gate | Bundled default | External (used when installed; falls back gracefully) |
|------|----------------|--------------------------------------|
| codeReview | `ship-review` skill + `ship-reviewer` agent fallback | `code-reviewer` agent; `coderabbit`; or any `gates.codeReview.upgrade` |
| security | `ship-security` skill | `vibe-security`, `/security-review`; or any `gates.security.upgrade` |
| uat | manual confirmation prompt | `/verify` + `/run` if your setup has them |
| regression | off by default; an advisory strategy pointer only: runs no command, never blocks | e.g. `ai-regression-testing` |
| audit / deep | bundled checklists (`references/audit-checklist.md` / `deep-review-lenses.md`) applied directly | `/deep-review` or `heavyGates.*.upgrade` skills if installed |

None of the external skills above ship with this plugin; every gate works with only what's in this
repo, and an installed external simply upgrades it.

**Companion plugins** (install independently; Ship Gate does *not* call them, but they complement it):
`security-guidance` (Anthropic edit/commit/push reminder hooks), `aikido` (static analysis, known as
SAST, plus secret scanning), `42crunch` (OpenAPI scanning), `sensitive-canary` (secret-scan hooks).
All unversioned; see upstream.

## Verify it's working

From the root of a clone of this repo:

```sh
# 1. Full deterministic test suite (expect TOTAL PASS=447 FAIL=0)
tp=0; tf=0
for t in plugins/ship-gate/scripts/test/*_test.sh; do
  s=$(bash "$t" | tail -1)
  case "$s" in PASS=*FAIL=*) ;; *) echo "NO SUMMARY: $t (aborted?)"; exit 1;; esac
  p=${s#PASS=}; p=${p%% *}; f=${s##*FAIL=}
  tp=$((tp+p)); tf=$((tf+f))
done; echo "TOTAL PASS=$tp FAIL=$tf"; [ "$tf" = "0" ]

# 2. Both manifests validate
claude plugin validate ./plugins/ship-gate
claude plugin validate .
```

**The live check that matters most** (the hook itself): in a throwaway repo on its protected branch
with no fresh marker, ask Claude to run `git push origin main`. It should be **denied** (with a
personal/default-on install, in any repo; with a marketplace/opt-in install, in a repo that has a
`.shipgate.json`). Then step out of the gate (`/ship off`, or for opt-in remove the `.shipgate.json`)
and the same push is **allowed**. Judge by what actually reached the remote, not by Claude's narration.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| My push to main isn't blocked | After a personal install, default-on should gate it; check `defaultEnabled` is `true` in `~/.shipgate.json` and the repo isn't paused (`/ship on`). A marketplace install needs a `.shipgate.json` in the repo (opt-in), with top-level `enabled` not `false`. Hooks load at **session start**, so restart your Claude session after installing. Confirm `git`, `jq`, `awk` are on `PATH`, and that `SHIPGATE_DISABLE` isn't set. |
| A benign command got denied on the protected branch | The hook fail-closes by design. You're likely on the protected branch without a fresh marker, so run `/ship` to gate and generate one, or push from a feature branch. |
| Default-on is gating a repo I don't want gated | Run `/ship off` in that repo (pause it), or go back to opt-in entirely with `defaultEnabled:false` in `~/.shipgate.json`. Install with `--no-default-on` to avoid this from the start. |
| I moved the repo and the hook errors | Re-run `install-local.sh`; first remove the stale ship-gate hook entry from `~/.claude/settings.json` so the new absolute path takes effect. |
| I combined `write-marker` and `git push` in one command and it was denied | Run them as two separate commands. The push-block hook reads the marker *before* your command runs, so a marker written in the same command hasn't taken effect yet. `/ship` already runs them as two steps. |
| Windows | Use WSL or git-bash; the hook and runner are bash. |
