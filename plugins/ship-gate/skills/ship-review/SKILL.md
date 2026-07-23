---
name: ship-review
description: Ship Gate code-review gate, runs /code-review then applies the distilled checklist and emits Approve/Warning/Block.
user-invocable: true
---

# Ship Review

1. Invoke the `/code-review` skill on the current diff vs the protected branch (usually `main`; if the repo uses `master` or a configured trunk, diff against that: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ship-gate.sh" protected-branch .` resolves it when the full plugin is installed). If `/code-review` is unavailable, dispatch the bundled `ship-reviewer` agent (via the Task tool) instead. If that agent is also absent (a bare skills install ships only this file and its references), skip this step: step 2's checklist is the review.
2. Apply `references/code-review-checklist.md` to the diff for anything `/code-review` missed.
3. Emit a verdict: **Block** (any CRITICAL/HIGH), **Warning** (only LOW/MEDIUM), or **Approve**.
4. Return the verdict and the findings table. Do not push: the orchestrator decides.
