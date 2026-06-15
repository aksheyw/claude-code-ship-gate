# Scenario Matrix — when each gate runs

The `/ship` orchestrator uses this matrix to decide which gates are required, recommended,
or skipped for a given push. Changed files are classified via the project's `scoping` globs
into buckets before gates are evaluated.

---

Changed files are classified via the project's `scoping` globs into buckets: **docs**, **ui**, **logic** (everything else code), **security-sensitive**, **config/infra**, **test-affecting**.

| Gate | Runs when… | Scope of analysis |
|---|---|---|
| tests | always | full repo |
| lint | always (if present) | changed files |
| typecheck | always (if present) | full repo (type graph) |
| build | if `build.enabled` | full repo |
| secretScan | always | diff added lines |
| codeReview | any non-docs code file changed (skip docs-only pushes) | diff vs main |
| security | any code/config/dependency file changed; **deep checklist** when a `scoping.security` path is touched | diff vs main (+ touched files) |
| uat | confidence table: **ui→required**, logic (hooks/contexts)→recommended, lib/api→optional, analytics/docs→skip | running app |
| audit | opt-in `--audit`; **suggested** when filesChanged ≥ threshold, areasChanged ≥ threshold, riskyPaths, or release/tag | whole codebase |
| deep | opt-in `--deep`; **suggested** when diffLines ≥ threshold, riskyPaths, or release context | the diff/plan artifact, iterative |
| regression | enabled AND test-affecting changes | sandbox API tests |

Docs-only push (`**/*.md` only) ⇒ deterministic gates + secretScan run; all judgment gates skip; push proceeds. `--hotfix` skips uat/regression/audit/deep regardless. Thresholds come from `heavyGates.*.suggestWhen` and are config-tunable.

## Default suggestion thresholds (from config `heavyGates.*.suggestWhen`)
- **audit** suggested when: filesChanged ≥ 15, OR areasChanged ≥ 3, OR a risky path is touched, OR a release/tag.
- **deep** suggested when: diffLines ≥ 400, OR a risky path is touched, OR release context.
