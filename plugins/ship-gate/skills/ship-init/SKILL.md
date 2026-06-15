---
name: ship-init
description: Scaffold a .shipgate.json for this project by auto-detecting its test/lint/typecheck/build commands and deploy target.
user-invocable: true
---

# /ship-init

You are the ship-gate setup helper. You run once in a new project to produce a `.shipgate.json`
scaffold that the user can tune before running `/ship`.

## Step 1 — Run detection

Run the following command from the project root (the directory containing the user's code, NOT the plugin root):

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" detect
```

This prints a JSON object:

```json
{ "tests": "...", "lint": "...", "typecheck": "...", "build": "...", "deploy": "..." }
```

An empty string `""` for a key means no command was detected for that gate.

## Step 2 — No-overwrite check

Before writing anything, check whether `.shipgate.json` already exists at the project root.

If it does: do NOT overwrite it. Instead, show the user the detected scaffold (filled per Step 3)
and ask: "A `.shipgate.json` already exists. Do you want to replace it with this scaffold?"
Proceed only on explicit confirmation.

## Step 3 — Write `.shipgate.json`

Write the following scaffold to `.shipgate.json` at the project root. Fill in each
`gates.<g>.command` from the `detect` output where the detected value is non-empty; leave
`null` where detection found nothing — `null` means "auto-detect at runtime".

Special rules:
- `gates.build.enabled` stays `false` even if a build command was detected (build is opt-in;
  the user flips it to `true` when ready). Still fill `gates.build.command` if detected.
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

## Step 4 — Explain configuration

After writing the file, give a brief explanation (roughly 8–12 lines):

- **Gate tiers**: The three judgment gates run in a tiered order — first an external upgrade skill
  if configured (e.g. `vibe-security`, `code-reviewer`), then the plugin's own bundled skill, then
  a manual prompt. Deterministic gates (tests, lint, typecheck, build, secretScan) are non-negotiable
  and always run regardless of tier.
- **Changed-file awareness**: `/ship` only fires gates relevant to the diff. Run
  `/ship-gate:ship --dry-run` to preview which gates will fire for your current changes.
- **Tuning handles**:
  - Set `gates.*.upgrade` to plug in external skills (e.g. `"upgrade": "vibe-security"` for the
    security gate, `"upgrade": "code-reviewer"` for code review).
  - Set `heavyGates.audit`/`heavyGates.deep` thresholds to control when `--audit`/`--deep` are
    suggested.
  - Set `regression.enabled: true` and pick a `runWhen` policy to activate regression testing.
  - Flip `gates.build.enabled: true` when you want the build gate to run on every ship.
  - `deploy.autoDetect: true` makes the ship gate warn before pushing if it detects a deploy target
    (e.g. `vercel.json`, `netlify.toml`) that would auto-deploy on push.
