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
| A07 Admin presentation | Privacy wording, search/details and filter persistence usable at 375 and 1280 | Playwright with the repository's test auth and API mocks; live acceptance blocked as described below |

Agent executes the checks against isolated fixtures. Browser resizing covers web layouts, not physical devices or installed PWA behavior. Provider results are simulated in automated tests. The complete local gate also includes RSpec, RuboCop, Brakeman, Bundler Audit, ESLint, Vitest, production build, dependency audit, Playwright and repository hygiene/freeze checks.

## Database and deployment

Migration `20261024100000` adds nullable event, source, outcome and retry identity columns. Historical source/outcome values remain unknown. It creates indexes concurrently and validates small enum constraints separately. Concurrent indexing scans the audit table and consumes IO; measure duration on production-sized data and check for invalid indexes after an interrupted migration before retrying. Adding columns and creating the trigger still briefly require table locks. Run migrations through the configured direct Postgres/Neon migration connection, not the transaction pooler.

`hafapass_protect_audit_log()` and `audit_logs_append_only` block SQL updates and deletes. Only payload, IP and redaction-marker updates are accepted while `AuditLog.redact!` sets the transaction-local `hafapass.audit_redaction` flag. It restores the prior value before returning. Identity, action, time, tenant, event, actor, source, outcome and retry keys stay immutable even with that flag. A database owner can disable triggers; this protects normal application writes, not a malicious database administrator. Privacy anonymizes users while preserving their audit identity.

The schema dumper includes the function and trigger, so schema loads and CI test databases receive the same protection. Retention/privacy use the redaction API. Normal model callbacks remain append-only. The migration is deliberately irreversible; use a forward fix rather than deleting history.

The migration role needs permission to create the function and trigger. Old application workers cannot perform payload redaction once the trigger is installed; roll out the new redaction-capable workers promptly and retry any interrupted retention work. Do not disable the guard to run old code. Concurrent indexes and constraint validation scan the table; nullable column additions do not backfill identities or actors.

The global `platform.activity_logging_started` release marker records migration execution time with no invented actor or prior values. Historical entries are not backfilled. Deploy application and workers together and drain pre-release jobs before using this marker as the organization's complete-logging boundary. Take the displayed date from the persisted marker, not a hardcoded release date.

## Verification record

Implementation source: `efeddf0357c7ca39435b2183ac977a07d51cb16f`, verified 2026-10-23 UTC. The final full backend run passed all 2,543 examples. Earlier integration failures were retained in local test logs and corrected: fixture assertions now account for operational audit rows, and rerunning completed demo seeds keeps the existing fixture set and its audit history. Replacing demo fixtures requires an explicit database reset.

| Check | Result |
| --- | --- |
| RSpec: registry, scoped callbacks, atomicity, sanitization, trigger, retention/privacy and existing journeys | 2,543 examples passed; focused final refund/job/registry/logger/sanitizer suite also passed 109 examples |
| RuboCop | 916 files inspected, no offenses |
| Brakeman | No warnings |
| Bundler Audit | No vulnerabilities |
| ESLint | Passed |
| Vitest | 165 files, 1,809 tests passed; Clerk publishable key blank for repository test auth |
| Vite production build and production dependency audit | Passed; no production dependency vulnerabilities |
| Playwright | 112 tests passed, including admin audit at 375 and 1280 CSS pixels |
| Impeccable advisory scan | No findings for the changed admin page |
| Secret/debug hygiene; release/freeze contract; diff whitespace | Passed; freeze inactive |

Admin browser cases verify the redaction wording, opening details, displayed before/after values, submitting a search, preserving that query through reload, and no horizontal overflow. Generated screenshots were visually checked at both sizes. Browser tests use synthetic API rows and the repository's test auth. Physical-device and installed-PWA behavior were not tested.

The isolated API (3057), Vite (5227), and seeded `hafapass_audit_integrity` stack were prepared. T3 preview snapshot calls timed out twice, so Chrome was used. The configured Clerk test account required another verification step and no operator was available. Leon explicitly authorized mocked Vitest/Playwright verification instead. Live signed-in UI acceptance was **not performed**. The QA Chrome/preview tabs and both servers were closed; the temporary login fixture containing test credentials was deleted and never committed.

Two independent engineering review rounds found six material issues. All were fixed: audit validation errors now escape business validation handlers so mutations roll back; distinct reconciliation requests keep their actors; webhook and direct-recovery observations have distinct stable identities; consequential seating actions reach central history; and cancellation-refund retries preserve their actual initiator. Regression specs cover each case. CodeRabbit remains a separate required PR review; this document does not claim its approval.

Provider operations were simulated. No production deployment, real payment, refund, payout, email campaign, or production data repair was performed. The parallel team-permissions branch must be integrated with its own authorization/locking checks; changes here in its shared services are limited to audit context and records. `config/policies.yml` is unchanged.
