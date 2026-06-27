# Deep Review Lenses

Used by the `ship` orchestrator when `--deep` is passed (or suggested by the scenario matrix).
Applied to the diff/plan artifact using an **iterative lens methodology**: run all 14 lenses in
order; after completing a full round with zero new findings, the review is done. Earlier lenses
catch higher-severity issues. In practice: small codebases converge in 5–8 rounds; medium
codebases in 10–15 rounds. Never stop after finding a ship-stopper — they cluster.

---

| # | Lens | What it looks for | Severity |
|---|------|--------------------|----------|
| 1 | **File completeness** | Missing files, missing components, incomplete inventory — production files not covered by the artifact | HIGH |
| 2 | **Function-level audit** | Exported functions in existing test files that have zero individual test coverage (`grep "^export "` vs test file references) | HIGH |
| 3 | **Test type gaps** | Entire missing test categories: unit, hook, component, page, API/endpoint, E2E journeys, smoke, regression guards, performance, memory-leak, security-rules, config | HIGH |
| 4 | **Cleanup and performance** | `setTimeout`/`setInterval`/`addEventListener` without cleanup; `requestAnimationFrame` without `cancelAnimationFrame`; blob URLs without `revokeObjectURL`; O(n²) in hot paths | MEDIUM |
| 5 | **Client-server contract** | For every API endpoint: does the client send exactly what the server expects? Headers, auth tokens, body shape, field names — this is where ship-stoppers hide | CRITICAL |
| 6 | **Platform-specific paths** | Native vs web code paths (Capacitor, iOS, Android); verifies BOTH branches (true AND false) have coverage; primary platform must not have fewer tests than secondary | HIGH |
| 7 | **Network conditions** | Offline detection, rate-limit (429) handling, timeout UX — does the user see a meaningful message, or a generic/blank error? | MEDIUM |
| 8 | **Business logic flows** | Every state transition (free→premium, active→deleted, consent granted→revoked) and its reverse are represented in tests | HIGH |
| 9 | **UX details** | Back button in modals (hardware + browser), image load failure fallbacks, double-tap prevention on action buttons, form data loss on navigation, loading→data transitions, empty states for every list | MEDIUM |
| 10 | **Infrastructure and config** | Every config file in the repo (JSON, XML, `.properties`, `.rules`, `.gradle`): versions, security settings, stale references, service-worker SDK version vs app SDK version | MEDIUM |
| 11 | **Security and secrets** | Credentials in source or git history; `window.open` missing `noopener`; cleartext traffic flags; external links without `noreferrer`; CORS config for all serving domains | HIGH |
| 12 | **Data layer rules** | Security rules (Firestore, RLS, etc.) read cover-to-cover; every collection AND subcollection has explicit rules; CORS config covers all domains the app serves from | CRITICAL |
| 13 | **Existing test quality** | Tests that pass but test the wrong thing: tautological tests that never import/render the component they claim to test; time-dependent tests lacking fake timers; assertions using stale or wrong field names | HIGH |
| 14 | **Document consistency** | TOC matches all section headers; claimed totals match actual checkbox counts; file references point to real files; priority rankings reflect actual severity | LOW |

---

## Stop condition

Stop when a complete round through all remaining applicable lenses produces **zero new findings**.
Do not stop after finding a single ship-stopper — a second one is usually hiding at a contract
boundary or in the data layer rules.

---

Credit: distilled from the `deep-review` skill (`~/.claude/skills/deep-review.md`) and the iterative methodology documented in `~/.claude/docs/iterative-deep-review.md`. Methodology originated in a production project (2026-03-19): 28 rounds found 14 production bugs (2 ship-stoppers) missed by single-pass review.
