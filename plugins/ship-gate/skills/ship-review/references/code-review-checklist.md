# Code Review Checklist

Used by the `ship-review` gate as a secondary pass after `/code-review`.
Only flag findings you are **>80% confident** are real issues: do not flood with noise.

---

## Correctness

- Missing null/undefined guard on a value that can be absent → **Block**
- Off-by-one in array slice, loop bound, or pagination offset → **Block**
- `await` omitted on an async call whose result is used → **Block**
- Promise rejection left unhandled (no `.catch` / no `try/catch` around `await`) → **Block**
- Empty `catch` block that silently swallows errors → **Block**
- Logic branch that can never be reached (dead code introducing false confidence) → **Warn**
- TODO/FIXME without a linked issue in a new code path → **Warn**

---

## Security

- Hardcoded credential, API key, token, or connection string in source → **Block**
- SQL built via string concatenation instead of parameterized query → **Block**
- Unescaped user input rendered in HTML/JSX (XSS vector) → **Block**
- User-controlled file path used without sanitization (path traversal) → **Block**
- State-changing endpoint missing CSRF protection → **Block**
- Protected route missing authentication/authorization check → **Block**
- Sensitive data (token, password, PII) written to logs → **Block**
- Request body or query params used without schema validation → **Block**
- Missing rate limiting on a public-facing endpoint → **Warn**
- Internal error details sent to client (error message leakage) → **Warn**
- CORS policy absent or set to `*` on a credentialed API → **Warn**
- Insecure or outdated dependency introduced → **Warn**

---

## Immutability

*(Hard project rule: always create new objects, never mutate. `return {...obj, field}` not `obj.field = …; return obj`.)*

- Direct property assignment on an existing object (`obj.x = …`) → **Block**
- `Array.push` / `Array.splice` / `delete obj.key` on a shared reference → **Block**
- Sorting or reversing an array in-place without a prior `.slice()` copy → **Block**
- `Object.assign(target, …)` where `target` is not a freshly-created literal → **Warn**
- Accumulating into a mutable variable inside a loop where `reduce`/`map` would be pure → **Warn**

---

## Performance

- N+1 query: fetching related records in a loop rather than a JOIN/batch → **Block**
- Unbounded query (no `LIMIT`) on a user-facing endpoint → **Block**
- Synchronous/blocking I/O in an otherwise-async context → **Block**
- Missing `useEffect`/`useMemo`/`useCallback` dependency that causes an infinite render loop → **Block**
- Expensive computation inside a render function without memoization → **Warn**
- Importing an entire library when only one export is needed (bundle bloat) → **Warn**
- Unoptimized image asset (no compression / no lazy-loading attribute) → **Warn**
- External HTTP call without a timeout configured → **Warn**

---

## Maintainability

- Function body exceeds 50 lines → **Block**
- File exceeds 800 lines → **Block**
- Nesting depth exceeds 4 levels (use early returns or extract helpers) → **Block**
- `console.log` or debug print left in production code path → **Block**
- Single-letter or opaque variable name in non-trivial logic context → **Warn**
- Magic number with no named constant or inline comment → **Warn**
- Exported function with no JSDoc and a non-obvious signature → **Warn**
- Inconsistent style with the surrounding file (mixed quotes, missing semicolons) → **Warn**

---

## Verdict Rule

Apply the >80%-confidence filter before assigning severity. Consolidate similar findings (e.g., "3 functions > 50 lines" counts as one HIGH finding, not three).

| Highest-severity finding | Verdict |
|--------------------------|---------|
| Any **Block** item (CRITICAL or HIGH confidence) | **Block**: do not push; fix required |
| Only **Warn** items (MEDIUM/LOW, no Blocks) | **Warning**: proceed with caution; note findings |
| No findings above threshold | **Approve** |

A **Block** verdict from this checklist overrides a passing `/code-review` result. The orchestrator, not this skill, decides whether to halt the push.

---

Credit: distilled from the `code-reviewer` agent (`~/.claude/agents/code-reviewer.md`) and supplemented with OWASP Top-10 best practices.
