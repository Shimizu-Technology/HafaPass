# Audit integrity foundation

## Scope and acceptance

Baseline: `main` at `b4679ad0`, checked 2026-10-23 (Guam). HåfaPass sells event tickets and supports organizer teams, admission, refunds and settlement. Clerk authenticates users; organization memberships and event assignments authorize operations. Provider calls and queued deliveries can finish after the initiating request. Audit identity must survive those boundaries and event removal.

Sources: `docs/ROLES_AND_ROADMAP.md`, `docs/COMMERCE_LEDGER_OPERATIONS.md`, application models/controllers/services, `.github/workflows/ci.yml`. The Brain Dump's `work/shimizu-tech/company-positioning-and-project-review-2026-10-04.md` describes paid launch and pilot closeout as gated. No production or real-money verification is part of this change.

This PR supplies backend activity records and safe visibility definitions. It does not add an organization Activity endpoint or page. Owner can see all organization-visible actions; Manager and Finance receive only their registered operational or financial summaries. Unknown actions remain administrator-only.

Required acceptance:

| Case | Expected result | Verification |
| --- | --- | --- |
| A01 Registry | Every emitted action is registered; unknown keys are administrator-only | Registry completeness and audience specs |
| A02 Tenant context | Tenant actions carry organization and applicable event; mismatches fail | Logger and coverage specs |
| A03 Atomic writes | Audit failure rolls back mutation; mutation failure leaves no audit | Service/request transaction specs |
| A04 Async/provider | Actual initiator follows jobs; intent/outcome remain distinct; retries deduplicate | Context and provider specs |
| A05 Sensitive values | TINs, card numbers, secrets, search terms and verification URL queries are removed | Sanitizer and API specs |
| A06 Immutability | SQL updates/deletes fail; controlled privacy/retention redaction works | Postgres trigger and retention/privacy specs |
| A07 Admin presentation | Privacy wording, search/filter/details usable at 375 and 1280 | Local API 3057 / Vite 5227; browser evidence |

Agent executes the checks against isolated fixtures. Browser resizing covers web layouts, not physical devices or installed PWA behavior. Provider results are simulated in automated tests. The complete local gate also includes RSpec, RuboCop, Brakeman, Bundler Audit, ESLint, Vitest, production build, dependency audit, Playwright and repository hygiene/freeze checks.

## Database and deployment

Migration `20261024100000` adds nullable event, source, outcome and retry identity columns. Historical source/outcome values remain unknown. It creates indexes concurrently and validates small enum constraints separately. Concurrent indexing scans the audit table and consumes IO; measure duration on production-sized data and check for invalid indexes after an interrupted migration before retrying. Adding columns and creating the trigger still briefly require table locks. Run migrations through the configured direct Postgres/Neon migration connection, not the transaction pooler.

`hafapass_protect_audit_log()` and `audit_logs_append_only` block SQL updates and deletes. Only payload, IP and redaction-marker updates are accepted while `AuditLog.redact!` sets the transaction-local `hafapass.audit_redaction` flag. It restores the prior value before returning. Identity, action, time, tenant, event, actor, source, outcome and retry keys stay immutable even with that flag. A database owner can disable triggers; this protects normal application writes, not a malicious database administrator. Privacy anonymizes users while preserving their audit identity.

The schema dumper includes the function and trigger, so schema loads and CI test databases receive the same protection. Retention/privacy use the redaction API. Normal model callbacks remain append-only. The migration is deliberately irreversible; use a forward fix rather than deleting history.

The global `platform.activity_logging_started` release marker records migration execution time with no invented actor or prior values. Historical entries are not backfilled. Deploy application and workers together and drain pre-release jobs before using this marker as the organization's complete-logging boundary. Take the displayed date from the persisted marker, not a hardcoded release date.

## Verification record

Pending combined verification. Results and limits will be recorded here before handoff.
