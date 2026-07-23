---
name: ship-security
description: Ship Gate security gate, applies the distilled security checklist to the diff; optionally augments with /security-review.
user-invocable: true
---

# Ship Security

1. Apply `references/security-checklist.md` to the changed files (the checklist IS the gate).
2. If available, also invoke `/security-review` for an Anthropic-maintained diff pass and merge findings.
3. Go deeper on files matching the project's security scoping globs (auth, payments, rules, migrations, env, deps).
4. Emit **Block** (any CRITICAL/HIGH) / **Warning** / **Approve** + findings. Do not push.
