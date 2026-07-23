# Audit Checklist

Used by the `ship` orchestrator when `--audit` is passed (or suggested by the scenario matrix).
This is a broad systemic sweep of the **whole codebase**, not just the diff.
Only flag findings you are **>80% confident** are real issues: do not flood with noise.

---

## 1. Display Value Formatting

Raw database/API keys (snake_case, camelCase, SCREAMING_SNAKE, numeric codes) leaking into user-facing output.

- Every field rendered in UI passes through a centralized, null-safe formatter: not inline `replace(/_/g, ' ')` → **Block**
- Grep for `{item?.fieldName}` / `{{ obj.field }}` patterns in display contexts; none should expose raw enum values → **Block**
- Sibling fields of any known raw-value leak are checked codebase-wide (one leak implies many) → **Warn**
- All output channels audited (UI, email templates, push notifications, PDF exports, error messages) → **Warn**

---

## 2. API Contract Mismatch

Client and server disagree on request/response shape: headers, auth tokens, body field names.

- Every API endpoint has a response adapter; components never read raw response paths → **Block**
- Auth header injection is centralized in one API client module (not duplicated per-call) → **Block**
- After any auth/middleware change, ALL endpoints are verified (not just the changed one) → **Block**
- Error shapes on client match error shapes on server → **Warn**

---

## 3. Firestore Rules and Subcollections

Firestore rules are NOT transitive; subcollections silently denied; parent deletion orphans subcollection data.

- Every subcollection accessed in code has an explicit `match /{subcoll}/{docId}` entry in `firestore.rules` → **Block**
- Parent document deletion cascades to all subcollections (query → delete each → delete parent, ideally in a batch/transaction) → **Block**
- Account deletion purges ALL user data including subcollections (GDPR risk) → **Block**
- Fire-and-forget operations (`.catch(() => {})`) have at minimum error logging → **Warn**

---

## 4. CORS and Domain Configuration

CORS rules list dev domains but omit the production domain; new domain migrations miss one or more services.

- Production domain appears in ALL CORS configs: Firebase Storage `cors.json`, API proxy headers, n8n webhook origins, CSP headers → **Block**
- Dev-only domains (`localhost`, staging URLs) are absent from production CORS configs → **Block**
- Every external service (CDN, image optimization, analytics) has been audited for the production domain → **Warn**
- Adding a new serving domain triggers a full CORS sweep across all services → **Warn**

---

## 5. Consent and Analytics Gating

App features blocked by consent denial; or analytics/cookies firing despite consent being denied (GDPR violation).

- App is fully functional with analytics consent denied: no feature logic gated on `consentGranted` → **Block**
- Zero analytics cookies or tracking pixels set when consent is denied → **Block**
- All `trackEvent()` calls are no-ops (not thrown errors) when consent is denied → **Block**
- Consent state persists across sessions and is revocable after initial choice → **Warn**

---

## 6. Dynamic CSS Class Purging

Template-literal Tailwind classes (`bg-${color}-500`) work in dev but are purged in production builds.

- Zero template literal class names with dynamic color, size, or variant segments: use static class maps instead → **Block**
- All conditional classes use static ternaries or lookup objects with full class strings visible at parse time → **Block**
- Production build visually verified (not only dev server) → **Warn**

---

## 7. Security Hygiene

Multiple individually minor issues that compound: `window.open` without `noopener`, cleartext traffic, hardcoded secrets, missing minification.

- All `window.open('url', '_blank')` calls include `'noopener,noreferrer'` as the third argument → **Block**
- No API keys, passwords, or tokens in source code or git history (`git log --all -p | grep -i secret`) → **Block**
- Android: `usesCleartextTraffic="false"` in `AndroidManifest.xml`; `minifyEnabled true` in release build → **Block**
- CSP headers configured and URLs with user data (uid, tokens) do not go to third parties → **Warn**

---

## 8. Test and Mock Completeness

New module exports break all tests that mock that module: the mock omits the new export, causing `undefined is not a function` at test time.

- After any new export is added, ALL files that `vi.mock()` / `jest.mock()` the changed module are updated to include it → **Block**
- Full test suite passes: not just the changed file's tests → **Block**
- Mock behavior matches real implementation for edge cases (null, undefined, empty array) → **Warn**
- Changed function signatures are reflected in every mock that references them → **Warn**

---

## 9. Performance and Bundle Health

Silent bundle bloat; unnecessary re-renders; unoptimized images; sequential API calls that could be parallel.

- All route-level page components use `React.lazy()` / dynamic `import()` (no direct synchronous imports for pages) → **Block**
- No full library imports where tree-shakeable alternatives exist (e.g., `import _ from 'lodash'`) → **Block**
- No sequential API calls in a single async function that could be `Promise.all([…])` → **Warn**
- Images are compressed, responsive, and lazy-loaded below the fold; bundle size is baselined in project docs → **Warn**

---

## 10. Accessibility (a11y)

Interactive elements missing labels; keyboard navigation broken; screen readers unable to parse structure; contrast failures.

- All interactive elements are keyboard-navigable (Tab, Enter, Escape) and carry `role` + `aria-label` where needed → **Block**
- All `<img>` elements have meaningful `alt` text (or `alt=""` for decorative images) → **Block**
- All form inputs have an associated `<label>` or `aria-label`; modals trap focus and return it on close → **Block**
- Lighthouse accessibility score > 90; animations respect `prefers-reduced-motion` → **Warn**

---

## Verdict Rule

Apply the >80%-confidence filter before assigning severity. Consolidate related findings (e.g., "3 components with raw display values" counts as one HIGH finding, not three).

| Highest-severity finding | Verdict |
|--------------------------|---------|
| Any **Block** item (CRITICAL or HIGH confidence) | **Block**: do not push; fix required |
| Only **Warn** items (MEDIUM/LOW, no Blocks) | **Warning**: proceed with caution; note findings |
| No findings above threshold | **Approve** |

A **Block** verdict from this checklist overrides other passing gates. The orchestrator decides whether to halt the push.

---

Credit: distilled from the `audit` skill (`~/.claude/skills/audit/SKILL.md`), 10 systemic bug categories derived from production incidents in a production project.
