# Security Checklist

Used by the `ship-security` gate as the primary (self-contained) pass over the diff.
Only flag findings you are **>80% confident** are real issues — do not flood with noise.

---

## Secrets

- Hardcoded API key, token, password, or connection string in source → **Block**
- Secret accessible via client-side env var prefix (`NEXT_PUBLIC_`, `VITE_`, `EXPO_PUBLIC_`, `REACT_APP_`) — not a publishable/anon key → **Block**
- Supabase `service_role` key or Stripe `sk_live_*`/`sk_test_*` key anywhere in client-side code → **Block**
- JWT signing secret or OAuth client secret in a client bundle → **Block**
- `.env`, `.env.local`, or `*.pem` file committed to the repo (not in `.gitignore`) → **Block**
- `.env.example` or `.env.sample` contains real key values rather than placeholders → **Warn**
- Git history contains secret patterns (`sk_live_`, `sk-or-v1-`, `AKIA`, `ghp_`, `glpat-`, `Bearer `) — run `gitleaks detect` → **Warn**

---

## Access Control

- Supabase table with RLS disabled AND the absence is not documented as an intentional decision (e.g., single-user service_role model) → **Block**
- Supabase RLS policy using `USING (true)` or `USING (auth.uid() IS NOT NULL)` on SELECT/UPDATE/DELETE (grants full table access to any authed user) → **Block**
- Supabase INSERT or UPDATE policy missing `WITH CHECK` (lets user reassign row ownership) → **Block**
- Firebase Security Rules deploy with `allow read, write: if true` or `allow read, write: if request.auth != null` → **Block**
- Firebase subcollection with no explicit rules (parent rules do not cascade) → **Block**
- Supabase `SECURITY DEFINER` function in the `public` schema (callable via REST by anyone) → **Block**
- Supabase storage bucket with no access policies → **Block**
- Convex public `query`/`mutation` that does not call `ctx.auth.getUserIdentity()` → **Block**
- Junction table, audit log, or metadata table missing RLS while parent table has it → **Warn**
- Firebase rules checking ownership via a Firestore users document rather than `request.auth.token` claims (requires extra read, tamper-prone) → **Warn**

---

## Auth

- `jwt.decode()` used instead of `jwt.verify()` — signature never validated → **Block**
- JWT library not explicitly rejecting `"alg": "none"` → **Block**
- Auth token stored in `localStorage` instead of `HttpOnly + Secure + SameSite` cookie → **Block**
- Next.js middleware is the sole auth layer (no re-check in Server Action or Route Handler) — CVE-2025-29927 bypass vector → **Block**
- Server Action or API route handler missing auth/authorization check at the top → **Block**
- Server Action or API route handler missing input validation (Zod/schema) at the top → **Block**
- Entire database object passed to a Client Component (may contain passwords, admin flags, internal IDs) → **Block**
- JWT issuer, audience, or expiration not validated → **Warn**
- `import 'server-only'` absent from data access module (allows accidental client import) → **Warn**

---

## Rate Limiting

- Auth endpoint (login, register, password reset, OTP, magic link) with no rate limiting → **Block**
- AI/LLM API endpoint with no rate limiting (full budget drain risk) → **Block**
- Rate limit counters stored in a Supabase public table (user can reset via REST API) → **Block**
- Email/SMS-sending endpoint with no rate limiting (spam relay risk) → **Warn**
- File-upload or CPU-intensive endpoint with no rate limiting (DoS risk) → **Warn**
- Per-user usage quota absent for AI API calls (no hard cap alongside provider-level limits) → **Warn**

---

## Payments

- Price taken from the client request body instead of looked up server-side → **Block**
- Stripe webhook handler not verifying the `stripe-signature` with `stripe.webhooks.constructEvent` → **Block**
- Stripe webhook handler using `request.json()` (destroys raw body needed for signature) instead of `request.text()` → **Block**
- Checkout session metadata (user ID, plan) accepted from the client rather than set server-side → **Block**
- Subscription status checked from a cached session value or JWT claim rather than the database (kept in sync via webhooks) → **Warn**

---

## Input / Injection

- SQL built via string concatenation rather than parameterized query or ORM method → **Block**
- `prisma.$queryRawUnsafe` or `$executeRawUnsafe` with user-supplied input → **Block**
- Unvalidated object from request body passed directly to Prisma `findFirst`/`where` (operator injection) → **Block**
- User input spread directly into a database `update`/`create` (mass assignment) → **Block**
- Unescaped user input rendered as HTML/JSX (XSS vector) → **Block**
- User-controlled URL passed to a server-side fetch without allowlist check (SSRF) → **Block**
- User-controlled file path used without sanitization (path traversal) → **Block**
- TypeScript types used as the only runtime validation boundary (no Zod/schema at API/action entry point) → **Block**

---

## Mobile

- Third-party API key present in the React Native / Expo JS bundle (use backend proxy instead) → **Block**
- Auth token stored in `AsyncStorage` (unencrypted plaintext on disk) instead of `expo-secure-store` / `react-native-keychain` → **Block**
- `EXPO_PUBLIC_` or `react-native-config` variable containing a secret key (baked into bundle at build time) → **Block**
- Deep link parameters used without validation or sanitization → **Warn**
- Biometric auth result checked as a boolean flag rather than using cryptographic challenge/response → **Warn**
- Sensitive data (tokens, PII) written to device logs → **Warn**

---

## LLM

- AI API key (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, etc.) present in client-side code or mobile bundle → **Block**
- Raw user input concatenated directly into a system prompt string (prompt injection) → **Block**
- LLM output rendered as raw HTML without sanitization (XSS via model response) → **Block**
- LLM allowed to construct raw SQL or shell commands from user-supplied content → **Block**
- LLM tool/function-call parameters not validated against a schema before execution → **Block**
- No per-user token/usage cap in the application (provider-level caps alone have lag) → **Warn**
- LLM tool access not restricted to a least-privilege allowlist → **Warn**
- Tool invocations not logged for audit → **Warn**

---

## Deploy

- `CORS: Access-Control-Allow-Origin: *` on an endpoint that uses credentials or serves private data → **Block**
- `.git` directory publicly accessible at the deploy URL (exposes full source and history) → **Block**
- Debug mode or verbose logging enabled in production (leaks stack traces and env vars) → **Block**
- Preview deployment uses production API keys, DB credentials, or payment keys → **Block**
- Source maps deployed to production (exposes full source code via DevTools) → **Warn**
- Security headers missing or incomplete (`HSTS`, `X-Frame-Options`, `X-Content-Type-Options`, `CSP`) → **Warn**
- Error responses send internal error details or stack traces to the client → **Warn**

---

## Verdict Rule

Apply the >80%-confidence filter before assigning severity. Consolidate related findings (e.g., "3 tables missing RLS" counts as one HIGH finding, not three).

| Highest-severity finding | Verdict |
|--------------------------|---------|
| Any **Block** item (CRITICAL or HIGH confidence) | **Block** — do not push; fix required |
| Only **Warn** items (MEDIUM/LOW, no Blocks) | **Warning** — proceed with caution; note findings |
| No findings above threshold | **Approve** |

A **Block** verdict from this checklist overrides a passing `/security-review` result. The orchestrator, not this skill, decides whether to halt the push.

---

Credit: distilled from `vibe-security` skill (Chris Raroque, MIT), OWASP Top-10 (A01–A10), and gitleaks secret-detection patterns.
