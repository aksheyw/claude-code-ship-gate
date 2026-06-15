---
name: ship-review
description: Ship Gate code-review gate — runs /code-review then applies the distilled checklist and emits Approve/Warning/Block.
user-invocable: true
---

# Ship Review

1. Invoke the `/code-review` skill on the current diff vs the main branch. If `/code-review` is unavailable, dispatch the bundled `ship-reviewer` agent (via the Task tool) instead.
2. Apply `references/code-review-checklist.md` to the diff for anything `/code-review` missed.
3. Emit a verdict: **Block** (any CRITICAL/HIGH), **Warning** (only LOW/MEDIUM), or **Approve**.
4. Return the verdict and the findings table. Do not push — the orchestrator decides.
