# Ship Gate — a pre-push quality gate for Claude Code that an agent can't skip with a flag

[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE) [![CI](https://github.com/aksheyw/claude-code-ship-gate/actions/workflows/ci.yml/badge.svg)](https://github.com/aksheyw/claude-code-ship-gate/actions/workflows/ci.yml) [![release](https://img.shields.io/github/v/release/aksheyw/claude-code-ship-gate)](https://github.com/aksheyw/claude-code-ship-gate/releases) ![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-8A2BE2.svg)

> **Most quality checks die to one flag (`git push --no-verify`). Ship Gate runs *above* git, so that flag isn't there to reach for.**
> It's a guardrail against the accidental push and the fast-moving agent, not a sandbox against someone who is determined to get around it. That boundary is real and spelled out below; the gate doesn't pretend otherwise.

Ship Gate is a Claude Code plugin that sits between your AI and your protected branch like a bouncer who actually checks IDs. Before a push to that branch goes through, it runs the checks I'd otherwise have to remember at 1am: tests, lint, typecheck, build, a secret scan, a code-review pass, security, UAT. It won't let the push through until there's a fresh **gate-pass marker** for the exact commit being pushed. Pass the gates, say "ship it" (or run `/ship`), and it writes the marker and pushes for you. Fail one, and there's no "just push it anyway" button left to press.

The full story of how this gate was designed and hardened is in the product case study: [CASE-STUDY.md](CASE-STUDY.md).

## Quick install

Two ways to turn it on. Pick one mode and stick to it; running both installs duplicate commands. [Full install options below.](#install)

**Marketplace install** (opt-in per repo: it guards only repos that contain a `.shipgate.json`):

```
/plugin marketplace add aksheyw/claude-code-ship-gate
/plugin install ship-gate@ship-gate
```

**Personal install** (on by default for every repo, with a `--no-default-on` flag to keep it opt-in):

```sh
git clone https://github.com/aksheyw/claude-code-ship-gate.git
cd claude-code-ship-gate
bash install-local.sh
```

### Install just the review gates via skills.sh

`ship-review` (the code-review gate) and `ship-security` (the security gate) carry self-contained checklists and work as standalone skills:

```sh
npx skills add aksheyw/claude-code-ship-gate --skill ship-review --skill ship-security
```

Plainly: `/ship` and `/ship-init` need the full plugin runtime. The push-block hook and the deterministic scripts don't ship through a bare skills install, so a skills-only install gives you the two review checklists, not the gate. One more caveat: `ship-review` prefers a `/code-review` skill and falls back to the bundled `ship-reviewer` agent, which also only ships with the full plugin; without either, its distilled checklist still runs on its own.

## How it works

- A **`PreToolUse` hook sits above git**: it fires before the Bash tool runs the push command at all, and denies any push to the protected branch without a valid gate-pass marker. By the time git would consult its own hooks, Ship Gate has already allowed or denied the action.
- The **marker is bound to the exact commit** about to be pushed, on the right branch, within a TTL. It is written only when every required gate passes (that's what `/ship` does).
- **Fail-closed**: a malformed config or a missing, expired, or mismatched marker means deny, and no flag skips it. The one seam is a hook that fails to *execute* at all (Claude Code treats a hook execution error or timeout as non-blocking), so the hook is built to always run and answer fast: self-contained, quoted paths, O(n) parsing, all locked by regression tests.

The push-block hook went through a 14-lens deep review and three adversarial red-team passes that found and fixed seven different ways a cleverly-shaped command could sneak a push past it. The review methodology that found them is itself a companion repo, [claude-code-deep-review](https://github.com/aksheyw/claude-code-deep-review). It ships with working review defaults and needs no other plugins installed.

<details>
<summary><b>Contents</b></summary>

- [Quick install](#quick-install)
- [How it works](#how-it-works)
- [Product case study](CASE-STUDY.md)
- [Why I built this](#why-i-built-this)
- [What's in this repo](#whats-in-this-repo)
- [The part I actually care about: where the gate sits](#the-part-i-actually-care-about-where-the-gate-sits)
- [Example output](#example-output)
- [Install](#install)
- [Configuration](#configuration)
- [Saying "ship it", and turning the gate off](#saying-ship-it-and-turning-the-gate-off)
- [What runs when](#what-runs-when)
- [Gate skills & companions](#gate-skills--companions)
- [Verify it's working](#verify-its-working)
- [Troubleshooting](#troubleshooting)
- [Companion repos](#companion-repos)
- [Credits & acknowledgements](#credits--acknowledgements)
- [License](#license)

</details>

---

## Why I built this

I run the same ritual before every push to main: tests, a review pass, a security glance, a secret scan. For the longest time the only thing enforcing that ritual was *me* remembering to do it. And discipline is exactly what evaporates at 1am, or the moment an agent is moving fast on my behalf.

The obvious fix doesn't actually work. A git `pre-push` hook is one `git push --no-verify` away from being optional, and anything that wants the push to succeed will reach for that flag. I wanted a gate that sits *above* git, where an LLM in my terminal can't opt out of it.

My first version was dumb in an instructive way. I turned it on for every repo on my machine at once, and it immediately blocked a push in a hackathon repo that had never asked for it. Fair. So enforcement went strictly opt-in, per repo. And when I went to harden the part that decides *"is this command actually a `git push`?"*, my own [deep-review](https://github.com/aksheyw/claude-code-deep-review) methodology plus three red-team passes found seven different ways a cleverly-shaped command slipped a real push past the detector (`FOO=bar git push`, a commit message containing the words "git push", a 100k-character command that times the hook out, `$'...'` quoting that desyncs the parser, and more). Reimplementing bash's parser inside a hook is a leaky abstraction; only bash truly parses bash.

So I fixed all seven, and then I stopped on purpose. You can always hide a push inside `bash -c` or a `$(...)`, and chasing every one of those means rebuilding bash inside a hook, which just opens new holes. I'm not pretending this stops someone determined to get around it. It stops the version that actually bites you: the fast-moving agent, the 1am "ah, just push it." The marker and the `/ship` workflow do the real work; the hook just takes the one-keystroke escape off the table.

Then I walked back the opt-in decision, but only partly. The footgun was never that gating was on by default; it was that there was no easy way out, and the detector cried wolf on a commit message that happened to contain the words "git push". So default-on came back, but as a switch *I* turn on with the installer: four ways to step out (a session, one repo, the whole machine, or back to opt-in), and a detector that no longer trips over its own shadow. On for everything, trivial to turn off for anything. That's the version I actually wanted.

---

## What's in this repo

| Component | Kind | What it does |
|-----------|------|-------------|
| `ship` | Skill | **Orchestrator.** Runs every gate, prints a Gate Status Summary, then writes the pass-marker and pushes/merges to the protected branch once every required gate passes and nothing needs your input. A command (`/ship`, or "ship it") authorizes the push; a question ("is this ready?") or `--dry-run` reports without pushing. It still pauses for anything that needs a decision: UAT, a detected deploy target, or the merge guard when a feature branch has pending commits and the gates are not fully green. |
| `ship-init` | Skill | **Setup.** Auto-detects your test/lint/typecheck/build commands from `package.json` / `go.mod` / `Cargo.toml` / `pyproject.toml` / etc. and scaffolds `.shipgate.json`. |
| `ship-review` | Skill | **Code-review gate.** Invokes `/code-review` plus a distilled checklist; emits Approve / Warning / Block. |
| `ship-security` | Skill | **Security gate.** Applies a distilled security checklist to the diff; opportunistically augments with `/security-review`. |
| `ship-reviewer` | Agent | Fallback reviewer used when `/code-review` is unavailable; embeds all review dimensions inline. |
| Push-block hook | PreToolUse hook | `hooks/hooks.json` + `scripts/check-push.sh`. In every gated repo, denies `git push` to the protected branch without a valid marker. This is what takes the one-keystroke skip off the table. |
| Trigger rule | Rule | `rules/shipgate-trigger.md` — routes plain-language ship intent ("ship it") to `/ship`. Installed to `~/.claude/rules` by `install-local.sh`; marketplace users add a one-liner (see below). |
| Deterministic runner | Script | `scripts/ship-gate.sh detect\|run\|doctor\|write-marker\|protected-branch\|disable\|enable\|status` — runs the gates, flags uncovered test suites (`doctor`), resolves the protected branch, toggles per-repo gating; CI-reusable. |
| JSON Schema | Config | `schema/shipgate.schema.json` (Draft-07) for editor autocomplete on `.shipgate.json`. |

Everything deterministic lives in dependency-free **bash + jq + awk**; the skills hold prompt logic only. The full test suite is 364 assertions across `scripts/test/*_test.sh`, no framework required.

---

## The part I actually care about: where the gate sits

A normal git `pre-push` hook runs *inside* git, so `git push --no-verify` turns it off. Ship Gate's enforcement is a Claude Code **`PreToolUse` hook**: it fires *before* the `Bash` tool runs the push command at all. A `PreToolUse` hook has no bypass flag, so by the time git would consult its own hooks, Ship Gate has already allowed or denied the action.

Three things make me trust it in practice, and the third is the one that matters:

- **Fail-closed.** The hook is self-contained (no sourced libraries) and routes every failure mode it can evaluate (no repo root, missing/expired/mismatched marker, unparseable config, even a missing `awk`) to **deny**. The honest caveat: a hook that fails to *execute* is non-blocking in Claude Code, so "always executes, never times out" is itself an engineered property here: dependency-free with quoted paths, O(n) parsing, both locked by regression tests that reproduce the historical fail-open bugs.
- **On by default, with four ways out.** A personal install gates every repo; a marketplace install gates only repos with a `.shipgate.json`. Whichever you use, you can step out at four levels: a session bypass (`SHIPGATE_DISABLE=1`), a machine-wide off switch (`enabled:false` in `~/.shipgate.json`), a per-repo pause (`/ship off`), or `--no-default-on` at install time. A repo you've stepped out of is never gated, and in opt-in mode a repo that never adds `.shipgate.json` is never touched, so an install can't hijack a project you decided not to cover.
- **Marker-bound.** A push is allowed only when `.git/shipgate/last-pass.json` records the **exact commit** about to be pushed, on the right branch, within a configurable TTL (default 900s). Pass the gates via `/ship` and the marker is written for you; otherwise it isn't there.

**Scope boundary (deliberate):** the gate matches `git push` as a *simple command*, honoring env-assignment prefixes, git global options, and bash quoting/escaping. It does **not** chase a push hidden inside a wrapper (`bash -c`, `eval`, `$(...)`, `sudo`, `xargs`, …) or obscured by I/O redirection — closing those is unbounded shell-reimplementation that tends to introduce *new* holes. One seam remains different in kind (a bounded fix, tracked for a hardening release): the hook judges a push against the repo the session is standing in (a push aimed at a different repo via `git -C` is evaluated by the current repo's gating, not the target's). Two narrow denial-of-service edges are documented rather than closed, because triggering them needs a hand-crafted multi-hundred-kilobyte push command — which, given the only party who can feed this hook a command is you or your agent pushing your own code, is not a realistic threat: a push carrying a quoted or backslash-hidden refspec (`"feature:main"`, `feature:ma\in`) is not matched, and a command padded with hundreds of thousands of backslash-newline line-continuations can make the gate slow enough to time out. Ship Gate is a guardrail for the normal and the accidental, backed by the marker workflow, not a sandbox against a determined adversary. (The `src:dst` refspec-source hole that shipped in 0.5.0 **is** closed in 0.5.1 — a legitimate `feature:main` inside a valid pass window no longer certifies.)

---

## Example output

Here's what `/ship --dry-run` prints. The shape is exactly what the orchestrator emits (from the `ship` skill); the values are made up for a TypeScript project:

```
## Ship Gate Summary
[PASS] tests — 248 passed (npx vitest run)
[PASS] lint / typecheck — clean / clean
[SKIP] build — skipped (disabled)
[PASS] secretScan — clean
[PASS] codeReview — Warning carried forward (resolved via: ship-review → /code-review)
[PASS] security — Approve (resolved via: ship-security)
[USER] uat — 80% UI impact — user decision: required
[SKIP] regression — skipped: not test-affecting
[SKIP] audit / deep — not requested
Branch: feature/checkout-v2   Target: origin/main
```

`--dry-run` stops at the summary: it writes no marker and pushes nothing. Without `--dry-run`, an imperative `/ship` (or "ship it") pushes on its own once every required gate is green. Not in this example, though: UAT is `[USER]`-required and unsatisfied, so it pauses for your call first. Auto-push only ever proceeds on a clean run with no open decision; the imperative command is the authorization, and the push-block hook still backstops anything it misreads. And what the deterministic runner actually prints (here, run in this very repo, which has no test command configured) shows the **no-silent-pass** safety in action:

```
$ bash plugins/ship-gate/scripts/ship-gate.sh run
[WARN] tests: no command detected
[WARN] lint: no command detected
[WARN] typecheck: no command detected
[SKIP] build (disabled)
[RUN]  secretScan
[PASS] secretScan
```

An *enabled* gate with no command becomes a visible `[WARN]` the orchestrator must surface and you must acknowledge, never a silent green check.

---

## Install

**Requirements:** `git`, `bash`, `jq`, `awk`. `jq` (and on a minimal system `git`) may need installing; `bash` and `awk` are effectively everywhere. On Windows, use WSL or git-bash.

**Pick one mode and stick to it.** Running both installs duplicate commands.

### Mode A — Personal install (all your projects)

Installs bare-named personal skills (`/ship`, `/ship-init`, `/ship-review`, `/ship-security`), copies the `ship-reviewer` agent, and merges the push-block hook into `~/.claude/settings.json`. Any existing `~/.claude/skills/ship.md` is backed up to `ship.md.bak` first. It also installs the trigger rule to `~/.claude/rules/shipgate-trigger.md` (so "ship it" routes to the gate) and turns on default-on by adding `defaultEnabled:true` to `~/.shipgate.json`, merged without touching any other keys there.

```sh
bash install-local.sh                        # interactive; turns on default-on
bash install-local.sh --yes                  # non-interactive
bash install-local.sh --yes --no-default-on  # install, but keep Ship Gate opt-in per repo
```

> After a personal install, the hook gates **every** repo Claude pushes a protected branch on, not only ones with a `.shipgate.json`. That's the point of default-on, but it's a real behavior change. To go back to opt-in, set `defaultEnabled:false` in `~/.shipgate.json` (or remove the file); to pause one repo, run `/ship off`; for a single session, `export SHIPGATE_DISABLE=1` before launching Claude. Or install with `--no-default-on` and only repos with a `.shipgate.json` are gated.

> Installed skills reference this repo's scripts by absolute path. If you **move** this repo, re-run `install-local.sh`. The hook entry in `settings.json` is added once. If a ship-gate hook with an old path is already present, remove that entry before re-running so the new path takes effect.

### Mode B — Marketplace / OSS install

```
/plugin marketplace add aksheyw/claude-code-ship-gate
/plugin install ship-gate@ship-gate
```

Commands are namespaced: `/ship-gate:ship`, `/ship-gate:ship-init`, `/ship-gate:ship-review`, `/ship-gate:ship-security`. Hooks activate automatically on install. To test locally from a clone, use `/plugin marketplace add .` instead.

A marketplace install stays **opt-in per repo** (it gates only repos with a `.shipgate.json`) and does not include the natural-language trigger, because a plugin can't write to `~/.claude/rules`. Two optional add-ons:

- **Want "ship it" to trigger the gate?** Add one line to your own rules (e.g. `~/.claude/CLAUDE.md`): *"When I tell you to ship/release/push to main, run `/ship-gate:ship`, which runs the gates and pushes on green. When I ask whether to ship, run `/ship-gate:ship --dry-run` and never push."*
- **Want default-on everywhere?** Create `~/.shipgate.json` containing `{ "defaultEnabled": true }`. Revert by setting it `false` or removing the file.

---

## Configuration

Ship Gate is driven by a `.shipgate.json` at your project root.

> **Two files, two jobs.** A per-repo `.shipgate.json` (this section) configures the gates for one project. A global `~/.shipgate.json` holds machine-wide switches: `defaultEnabled` (gate every repo, no per-repo file needed) and `enabled:false` (a machine-wide off switch). To pause one repo while keeping its config, set its top-level `"enabled": false` or run `/ship off`.

**Scaffold one** (auto-detects your commands; asks before overwriting an existing file):

```
/ship-init          # or namespaced: /ship-gate:ship-init
```

**Example** (full version at `plugins/ship-gate/examples/example.shipgate.json`):

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

**Key knobs:**

| Key | Default | Purpose |
|-----|---------|---------|
| `mainBranch` | `"main"` | Protected branch that `/ship` targets and the hook guards. Also honored in the global `~/.shipgate.json` and via `SHIPGATE_MAIN_BRANCH`; otherwise auto-detected from `origin/HEAD`, falling back to `main`/`master`. |
| `enabled` (top-level) | `true` | Set `false` to pause enforcement for this repo while keeping its config. In the global `~/.shipgate.json`, `false` is a machine-wide off switch. |
| `defaultEnabled` (global only) | `false` | **In `~/.shipgate.json` only.** `true` gates every repo that has no per-repo `.shipgate.json` (default-on). Set by `install-local.sh`; ignored inside a per-repo file. |
| `gates.*.command` | `null` (auto-detect) | A string, `null` (auto-detect), or an **array** of `{command, when}` suites for multi-suite repos — see [Multi-suite test gates](#multi-suite-test-gates-monorepos). |
| `gates.build.enabled` | `false` | Build gate is opt-in; flip to `true` when ready. |
| `gates.*.upgrade` | `null` | External skill to prefer over the bundled default when installed. |
| `regression.enabled` | `false` | Advisory only: surfaces the `ai-regression-testing` strategy skill on test-affecting changes (guidance — it runs no command and never blocks). For regression *suites* you want actually executed, add them to a multi-suite `gates.tests.command`. |
| `hotfix.skipGates` | `["uat","regression","audit","deep"]` | Gates skipped on `--hotfix`. Tests, codeReview, secretScan, and security are always kept. |
| `markerTtlSeconds` | `900` | How long a gate-pass marker stays valid before it expires. |

A partial config is valid: anything you omit falls back to the bundled defaults (the runtime deep-merges your file over them). The schema (`schema/shipgate.schema.json`, Draft-07) gives editor autocomplete.

### Multi-suite test gates (monorepos)

A single `command` runs one suite. On a repo with more than one test suite, that silently leaves the others unrun while still reporting "tests PASS" — a false all-clear. So `tests` (and `lint`/`typecheck`/`build`) also accept an **array of suites**: each is an object with a `command` and an optional `when` (git pathspecs). A suite runs only if a changed file matches its `when`; omit `when` to always run it. **Any in-scope suite that fails, fails the gate.**

```json
"tests": { "enabled": true, "command": [
  { "command": "npx vitest run" },
  { "command": "npx vitest run -c functions/vitest.config.ts", "when": ["functions"] },
  { "command": "npm run test:rules", "when": ["*.rules"] }
] }
```

The root suite always runs; the `functions/` suite runs only when a file under `functions/` changed; the rules suite runs only when a `*.rules` file changed. A few things worth knowing:

- **`when` entries are git pathspecs.** `*` spans `/`, so `*.rules` matches at any depth and `functions` matches everything under `functions/`. Brace globs like `{tsx,jsx}` are not supported — list them separately (`*.tsx`, `*.jsx`).
- **Staged and untracked files count.** Gates run before the commit, so a brand-new suite's files (staged or untracked) put its suite in scope.
- **Scope is fail-safe.** If the shipped change-set can't be determined, every `when`-suite runs. It can over-run (slower), never silently skip.
- **A plain string still behaves exactly as before.** On older plugin versions, a `scripts/ship-tests.sh` wrapper that chains the suites by hand is the equivalent fallback.

To find suites you'd otherwise miss, run `ship-gate.sh doctor` (and `/ship-init` runs it for you): it flags a nested package with its own test script, an extra/named test-runner config, an e2e suite, or a `*.rules` file the single command wouldn't touch — and warns if no CI is configured. It's advisory and never blocks. A worked monorepo config is in [`examples/monorepo.shipgate.json`](plugins/ship-gate/examples/monorepo.shipgate.json).

---

## Saying "ship it", and turning the gate off

**Natural-language ship.** With the trigger rule installed (automatic in a personal install; a one-liner for marketplace installs, see Mode B), plain-language ship intent runs the gate:

- A **command** ("ship it", "go ahead and ship", "sync with GitHub") runs every gate and **pushes on green**, pausing only where a gate genuinely needs your decision.
- A **question** or a **"not yet"** ("is this ready?", "don't ship until tests pass") runs the gates and reports, and never pushes.

**Four ways to step out of the gate**, narrowest to broadest:

| Scope | How | Effect |
|-------|-----|--------|
| One session | `export SHIPGATE_DISABLE=1` before launching Claude | The hook allows every push for that session. |
| One repo | `/ship off` (re-enable with `/ship on`) | Pauses gating for that repo only. |
| This machine | `enabled:false` in `~/.shipgate.json` | Off everywhere, unconditionally. |
| Back to opt-in | `defaultEnabled:false` in `~/.shipgate.json`, or remove the file | Only repos with a `.shipgate.json` are gated again. |

There's no uninstall script: setting `defaultEnabled:false` (or removing `~/.shipgate.json`) and deleting the `~/.claude/rules/shipgate-trigger.md` line returns you to plain opt-in.

---

## What runs when

Changed files are classified into buckets (docs, ui, logic, security-sensitive, config/infra, test-affecting) using your `scoping` globs, and gates fire by bucket:

| Gate | When it runs |
|------|-------------|
| tests / secretScan | always when enabled (both on by default) |
| lint / typecheck | always (if a command is present) |
| build | only when `gates.build.enabled` is `true` |
| codeReview | any non-docs code file changed; skipped on docs-only pushes |
| security | any code/config/dependency file changed; deeper checklist when a `scoping.security` path is touched |
| uat | confidence-based: ui → required, logic → recommended, lib/api → optional, analytics/docs → skip |
| audit / deep | opt-in via `--audit` / `--deep`; suggested past size/risk thresholds |
| regression | advisory strategy pointer (guidance, not an executable check) — only when `regression.enabled` **and** the change is test-affecting |

**Docs-only push** (every changed path matches `**/*.md`): deterministic gates + secretScan run; all judgment gates skip. **`--hotfix`** skips uat/regression/audit/deep but keeps tests, codeReview, secretScan, and security. Full matrix: `plugins/ship-gate/skills/ship/references/scenario-matrix.md`.

---

## Gate skills & companions

Each judgment gate resolves in three tiers: a configured **external upgrade** (if installed) → the plugin's **bundled default** → a **manual** prompt. A missing optional upgrade never hard-blocks; it warns once and falls back.

| Gate | Bundled default | External (used when installed; falls back gracefully) |
|------|----------------|--------------------------------------|
| codeReview | `ship-review` skill + `ship-reviewer` agent fallback | `code-reviewer` agent; `coderabbit`; or any `gates.codeReview.upgrade` |
| security | `ship-security` skill | `vibe-security`, `/security-review`; or any `gates.security.upgrade` |
| uat | manual confirmation prompt | `/verify` + `/run` if your setup has them |
| regression | off by default; an advisory strategy pointer only — runs no command, never blocks | e.g. `ai-regression-testing` |
| audit / deep | bundled checklists (`references/audit-checklist.md` / `deep-review-lenses.md`) applied directly | `/deep-review` or `heavyGates.*.upgrade` skills if installed |

None of the external skills above ship with this plugin; every gate works with only what's in this repo, and an installed external simply upgrades it.

**Companion plugins** (install independently; Ship Gate does *not* call them, but they complement it): `security-guidance` (Anthropic edit/commit/push reminder hooks), `aikido` (SAST + secrets via MCP), `42crunch` (OpenAPI scanning), `sensitive-canary` (secret-scan hooks). All unversioned; see upstream.

---

## Verify it's working

```sh
# 1. Full deterministic test suite (expect TOTAL PASS=364 FAIL=0)
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

**The live check** that matters most (the hook itself): in a throwaway repo on its protected branch with no fresh marker, ask Claude to run `git push origin main`. It should be **denied** (with a personal/default-on install, in any repo; with a marketplace/opt-in install, in a repo that has a `.shipgate.json`). Then step out of the gate (`/ship off`, or for opt-in remove the `.shipgate.json`) and the same push is **allowed**. Judge by what actually reached the remote, not by Claude's narration.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| My push to main isn't blocked | After a personal install, default-on should gate it; check `defaultEnabled` is `true` in `~/.shipgate.json` and the repo isn't paused (`/ship on`). A marketplace install needs a `.shipgate.json` in the repo (opt-in), with top-level `enabled` not `false`. Hooks load at **session start**, so restart your Claude session after installing. Confirm `git`, `jq`, `awk` are on `PATH`, and that `SHIPGATE_DISABLE` isn't set. |
| A benign command got denied on the protected branch | The hook fail-closes by design. You're likely on the protected branch without a fresh marker, so run `/ship` to gate and generate one, or push from a feature branch. |
| Default-on is gating a repo I don't want gated | Run `/ship off` in that repo (pause it), or go back to opt-in entirely with `defaultEnabled:false` in `~/.shipgate.json`. Install with `--no-default-on` to avoid this from the start. |
| I moved the repo and the hook errors | Re-run `install-local.sh`; first remove the stale ship-gate hook entry from `~/.claude/settings.json` so the new absolute path takes effect. |
| Windows | Use WSL or git-bash; the hook and runner are bash. |

---

## Companion repos

Part of a small family of opinionated Claude Code tools:

- [**claude-code-deep-review**](https://github.com/aksheyw/claude-code-deep-review) — the 14-lens iterative deep-review methodology Ship Gate's `--deep` gate distills from. Found 14 production bugs (2 ship-stoppers) on its first use, and 7 fail-opens in *this* very plugin.
- [**claude-code-rules**](https://github.com/aksheyw/claude-code-rules) — opinionated global rules (honesty / earned-confidence, TDD, immutability, branch strategy) that shaped how these gates are wired.
- [**context-bridge**](https://github.com/aksheyw/context-bridge) — resume Claude Code sessions warm: a per-project wiki + generated handoff prompt to stop cross-session amnesia.
- [**claude-code-pm-agents**](https://github.com/aksheyw/claude-code-pm-agents) — seven subagents covering the product-builder lifecycle (PRDs, growth, brand, ASO, SEO, YouTube, comms).
- [**claude-code-learned-skills**](https://github.com/aksheyw/claude-code-learned-skills) — Docker / SSH / VPS skills captured from real debugging sessions.

---

## Credits & acknowledgements

The bundled reference files (`code-review-checklist.md`, `security-checklist.md`, `audit-checklist.md`, `deep-review-lenses.md`) **distill** best practices from the projects below. You do **not** need any of them installed; the checklists ship inside the plugin:

- **vibe-security** — security review skill
- **audit** — codebase audit skill
- **deep-review** — iterative 14-lens deep review methodology
- **code-reviewer** agent — embedded review dimensions
- [**gitleaks**](https://github.com/gitleaks/gitleaks) and [**OWASP**](https://owasp.org)

**Optional upgrades** Ship Gate invokes only when you configure them and they're installed: `vibe-security`, `code-reviewer` / `coderabbit`, `ai-regression-testing`, `audit` / `deep-review`. **Companion plugins** that run on their own: `security-guidance`, `aikido`, `42crunch`, `sensitive-canary`. All unversioned; see upstream.

> Ship Gate distills inputs from and orchestrates these projects but does not speak for their guarantees or support.

---

## License

MIT. See [LICENSE](LICENSE).
