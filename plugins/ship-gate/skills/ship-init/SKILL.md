---
name: ship-init
description: Scaffold a .shipgate.json for this project by auto-detecting its test/lint/typecheck/build commands and deploy target.
user-invocable: true
---

# /ship-init

> **Runtime check (do this FIRST):** this skill requires the Ship Gate plugin runtime. If
> `${CLAUDE_PLUGIN_ROOT}` is empty or the file `"${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh"` does
> not exist, STOP and tell the user: this skill was installed as a bare skill (e.g. via skills.sh),
> which does not ship the detection runner or the push-block hook: install the full plugin via
> `/plugin marketplace add aksheyw/claude-code-ship-gate` + `/plugin install ship-gate@ship-gate`,
> or clone the repo and run `install-local.sh`.

You are the ship-gate setup helper. You run once in a new project to produce a `.shipgate.json`
scaffold that the user can tune before running `/ship`.

## Step 1: Run detection

Run the following command from the project root (the directory containing the user's code, NOT the plugin root):

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" detect
```

This prints a JSON object:

```json
{ "tests": "...", "lint": "...", "typecheck": "...", "build": "...", "deploy": "...", "ci": "..." }
```

An empty string `""` for a key means no command was detected for that gate. `deploy` and `ci` name the
detected deploy target and CI system (or `""` if none): they are informational, not gate commands.

## Step 1.5: Scan for uncovered suites (`doctor`)

Run the advisory scan from the project root:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" doctor
```

It prints `[WARN] uncovered suite: …` for every suite a single `tests.command` would silently skip, a
nested package with its own test script, an extra/named test-runner config, an e2e suite, or a `*.rules`
security-rules file, and a line for CI: `[PASS] CI detected: …` or `[WARN] no CI detected …`. (It always
exits 0; it never blocks. You can re-run it any time.)

**If it reports no CI** (`[WARN] no CI detected`), tell the user directly: with no CI, this gate is the only
automated check before production, so keeping every suite wired (above) and the gates enabled matters more.

**If it reports uncovered suites,** tell the user plainly: the default single `tests` command runs ONE suite,
so those other suites would not run on `/ship` and the gate would still report "tests PASS": the exact blind
spot this catches. Offer to wire each one as a **`when`-conditional suite** in `gates.tests.command` using the
array form (this replaces the single `"command": null|"…"` string). Example for a repo with a `functions/`
package and Firestore rules:

```json
"tests": {
  "enabled": true,
  "command": [
    { "command": "npm test" },
    { "command": "npm --prefix functions test", "when": ["functions"] },
    { "command": "npm run test:rules",           "when": ["*.rules"] }
  ]
}
```

Each entry is an object with a non-empty `command` string and an optional `when` array of **git pathspecs**;
the suite runs iff a changed file matches one (omitted/empty `when` = always run). Keep these shapes exact: 
the runner fail-closes on a malformed gate (a bare string in the array, an empty command, a non-array `when`).
Pathspec globbing: `*` spans `/` (so `*.rules` matches at any depth, `functions` matches everything under it);
brace globs like `{a,b}` are NOT supported: list entries separately (`"*.tsx"`, `"*.jsx"`). Let the user
confirm the exact command for each suite; only scaffold what they approve.

## Step 2: No-overwrite check

Before writing anything, check whether `.shipgate.json` already exists at the project root.

If it does: do NOT overwrite it. Instead, show the user the detected scaffold (filled per Step 3)
and ask: "A `.shipgate.json` already exists. Do you want to replace it with this scaffold?"
Proceed only on explicit confirmation.

## Step 3: Write `.shipgate.json`

Write the following scaffold to `.shipgate.json` at the project root. Fill in each
`gates.<g>.command` from the `detect` output where the detected value is non-empty; leave
`null` where detection found nothing: `null` means "auto-detect at runtime".

Special rules:
- `gates.build`: by default `enabled` stays `false` (build is opt-in; the user flips it when ready).
  **Exception: deploy-connected:** if Step 1's `detect` reported a non-empty `deploy` target (e.g. Vercel,
  Netlify, Firebase, Fly.io, Render), scaffold `gates.build.enabled: true` with the detected `command`, and
  tell the user why: a push to a deploy-connected branch builds in the cloud anyway, so a ~3-second local
  build pre-flight catches a broken build *before* it breaks the deploy mid-flight. This only changes what
  `/ship-init` scaffolds: the runtime default for configs that don't set `build.enabled` is unchanged
  (`false`), so existing configs behave exactly as before. Either way, still fill `gates.build.command`
  whenever a build command was detected.
- `mainBranch`: use the repo's actual default branch if it isn't `main`
  (check with `git symbolic-ref refs/remotes/origin/HEAD` or `git remote show origin`).
- Do NOT add a `$schema` key. The schema lives at the plugin's `schema/shipgate.schema.json`
  but has no stable path from a user's project, so omitting the pointer avoids a dangling reference.

```json
{
  "mainBranch": "main",
  "gates": {
    "tests":      { "enabled": true,  "command": null },
    "lint":       { "enabled": true,  "command": null },
    "typecheck":  { "enabled": true,  "command": null },
    "build":      { "enabled": false, "command": null },
    "secretScan": { "enabled": true },
    "codeReview": { "enabled": true, "skill": "ship-review",   "upgrade": null },
    "security":   { "enabled": true, "skill": "ship-security", "upgrade": null },
    "uat":        { "enabled": true, "skill": "verify", "mode": "confidence" }
  },
  "heavyGates": {
    "audit": { "skill": "deep-review", "upgrade": "audit",       "suggestWhen": { "filesChanged": 15, "areasChanged": 3, "riskyPaths": true } },
    "deep":  { "skill": "deep-review", "upgrade": "deep-review", "suggestWhen": { "diffLines": 400, "riskyPaths": true, "release": true } }
  },
  "regression": { "enabled": false, "skill": "ai-regression-testing", "runWhen": "test-affecting" },
  "scoping": {
    "docs":     ["**/*.md", "docs/**"],
    "ui":       ["src/components/**", "src/pages/**", "**/*.{tsx,jsx,vue,svelte}"],
    "security": ["**/auth/**", "**/*payment*", "**/*.rules", "**/migrations/**", "**/.env*", "api/**", "package.json", "requirements*.txt", "go.mod", "Cargo.toml", "pubspec.yaml"]
  },
  "deploy":  { "autoDetect": true, "warnOnPush": true },
  "hotfix":  { "skipGates": ["uat", "regression", "audit", "deep"] },
  "markerTtlSeconds": 900
}
```

When writing the file, replace each `null` command value with the detected string if non-empty.
For example, if detection returned `"tests": "pnpm test"`, write `"command": "pnpm test"` for
`gates.tests.command`. If detection returned `""`, keep `"command": null`.

## Step 4: Explain configuration

After writing the file, give a brief explanation (roughly 8–12 lines):

- **Gate tiers**: The judgment gates run in a tiered order, first an external upgrade skill
  if configured (e.g. `vibe-security`, `code-reviewer`), then the plugin's bundled skill where one
  exists (codeReview and security have one; UAT's shipped fallback is a manual confirmation), then
  a manual prompt. Enabled deterministic gates (tests, lint, typecheck, build, secretScan) are
  non-negotiable; a gate disabled in config is skipped and reported as such.
- **Changed-file awareness**: `/ship` only fires gates relevant to the diff. Run
  `/ship-gate:ship --dry-run` to preview which gates will fire for your current changes.
- **CI backstop**: if `doctor` reported no CI, this gate is the only automated check before production, 
  prefer enabling more gates and wiring every suite over leaving coverage gaps.
- **Tuning handles**:
  - Set `gates.*.upgrade` to plug in external skills (e.g. `"upgrade": "vibe-security"` for the
    security gate, `"upgrade": "code-reviewer"` for code review).
  - Set `heavyGates.audit`/`heavyGates.deep` thresholds to control when `--audit`/`--deep` are
    suggested.
  - Set `regression.enabled: true` to surface the `ai-regression-testing` strategy skill on test-affecting
    changes. This is **advisory guidance**: it runs no command and never blocks the ship. For regression
    *suites* you want actually executed, wire them into `gates.tests.command` as `when`-conditional entries
    (see Step 1.5) rather than relying on this pointer.
  - Flip `gates.build.enabled: true` when you want the build gate to run on every ship. (If a deploy target
    was detected, `/ship-init` already turned it on: a deploy-connected push builds anyway, so a local
    pre-flight beats a mid-deploy break.)
  - `deploy.autoDetect: true` makes the ship gate warn before pushing if it detects a deploy target
    (e.g. `vercel.json`, `netlify.toml`) that would auto-deploy on push.
