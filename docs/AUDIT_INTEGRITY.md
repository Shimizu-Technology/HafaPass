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
| A03 Audit failure policy | Privileged configuration rolls back on audit failure; buyer-critical and provider-result mutations continue, report the gap and attempt a minimal marker | Service/request transaction and SQL-savepoint specs |
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

## Review fixes: failure and deletion policy

Review-fix baseline: PR #153 at `2deaa2b2`, 2026-10-24 Guam. The requested acceptance adds campaign enqueue failures, immutable foreign-key behavior and buyer fulfillment during an audit outage. Tests use a dedicated local Postgres database and simulated providers. No production data or real payment is involved.

### Audit failures

`AuditLogger` defaults to fail-closed. Organization/admin configuration, team roles and permissions, verification, payout settings, prices, staff refund reservations and provider-submission intent must commit with their audit. Unknown actions also default to fail-closed. Supplying a provider source alone does not exempt an unclassified action.

The explicit `BUYER_ACTIONS` allowlist covers order completion/agreement/cancellation/expiry, box-office cash-sale completion, admission and reversal, fulfillment/resends and guest-purchase recovery, catalog fulfillment creation/completion, and card-present payment outcomes. The provider allowlist covers observed refund/order-refund, dispute and payout outcomes. `Commerce::OrderLifecycle.complete!`, cash-sale creation, card-present processing, admission reconciliation, Stripe webhook processing, provider refund reconciliation/finalization and payout submission outcomes additionally scope fail-open behavior across their nested callbacks, ticket changes, seating and waitlist transitions. The scope restores on exit and is not propagated as blanket permission to other jobs. Staff manual cash/card refund recording remains fail-closed; a response from an already-executed provider refund is fail-open because rolling back local state cannot undo the provider's money movement.

Fail-open writes run inside a `requires_new` savepoint. A rejected SQL statement rolls back that savepoint before business writes continue. Each failure emits `audit_write_failed` to application monitoring and a generic exception to Sentry with action, subject type/ID, organization/event/actor IDs, source and exception class. Neither the exception message nor request/provider/snapshot payloads are sent by this reporting path. A separate savepoint attempts an `audit_write_failures` row with the same minimal identity. Monitoring/fallback failure is also best effort and must never roll back the buyer operation. These markers commit only if the business transaction commits.

`audit_write_failures` is an administrator repair backlog, not evidence that a complete audit succeeded. Inspect it after recovery, reconcile the action/IDs against authoritative order/payment/admission state, and append an explicitly identified gap/reconciliation record if needed. Do not fabricate missing before/after values or automatically replay a payment, refund, admission or campaign from a marker. The retention inventory classifies these minimal markers as retained audit records with no payload PII to redact. There is no automatic audit replay job in this change. If the entire database is unavailable, the business write itself still cannot succeed; fail-open isolates audit-storage failures, not a database outage.

### Campaign queueing

Campaign status changes no longer imply successful queueing. Sender commits the recipient outbox in `sending` and registers a dispatcher after all enclosing transactions commit, preserving the initiating audit context. Only the dispatcher writes `campaign.send_completed`, atomically with `sent`, after every `MessageDeliveryJob` reports an accepted enqueue outside a business transaction. This is queue acceptance, not provider delivery. A dispatcher or child-enqueue error records `campaign.send_failed` with a fixed failure code and exception class, clears `sent_at` and leaves `failed`. Partial sends reuse the same delivery IDs and provider idempotency keys; existing delivery leases/terminal guards tolerate repeated job enqueues. The worker retries five times; after exhaustion an authorized `send_now` request on the failed campaign retries the existing outbox without rebuilding recipients. Failed/sending campaigns remain non-editable so retry cannot change already-queued content. A process crash after outbox commit but before dispatcher enqueue can leave `sending`; operators may re-enqueue `CommunicationCampaignDispatchJob` for that campaign ID after inspecting the queue. The durable outbox is retained for this recovery.

### Foreign keys and deletion paths

Forward migration `20261024110000` drops the actor-user nullifying FK and creates the minimal failure-marker table. The only outgoing FK on `audit_logs` is `organization_id`, with `ON DELETE RESTRICT`. No table has an incoming FK targeting `audit_logs`. `actor_user_id`, `event_id` and polymorphic `auditable_type`/`auditable_id` are immutable historical references without cascading/nullifying FKs. They may refer to deleted rows; missing associations must not be interpreted as missing identity. The admin API exposes the immutable actor ID and the page labels a missing actor as “Deleted user #ID”, rather than “System”. `audit_write_failures` also keeps IDs without FKs.

- User hard deletion succeeds when other domain references permit it and preserves both actor and subject IDs. Privacy deletion normally anonymizes the local user and deletes the external Clerk identity; it redacts audit payloads through `AuditLog.redact!` while preserving all audit identity.
- Draft event deletion and eligible subject deletion preserve historical event/subject IDs. Existing domain guards still block events with operational/financial dependents; this change does not bypass them.
- Organizations with audit history cannot be deleted. `Organization#destroy` returns a clear dependent-audit error, and raw SQL deletion is restricted by the FK. Archive/anonymize as appropriate instead.
- Retention redacts audit payloads; `delete_pending_order!` only purges eligible orders without audit/financial evidence. Its child deletions and privacy's saved-record removals do not nullify central audit identities.
- `hafapass:purge_synthetic_data` is a separate, explicitly confirmed pre-launch reset. It verifies no live-money/settlement evidence, truncates all synthetic business history (including both audit tables) together without `CASCADE`, then deletes non-kept users and writes a fresh purge record. This intentional full reset is not a normal retention/deletion path. Never disable the append-only guard for ordinary cleanup.
- Demo seeds preserve a completed seed set; other existing audit history causes a clear refusal before fixture deletion. Only an explicit disposable-database reset replaces it.
- RSpec transaction rollback and schema reloads dispose of isolated fixtures; normal specs must not issue `AuditLog.delete_all` to clean append-only rows. The trigger continues to reject ordinary updates/deletes, including actor nullification under the redaction flag.

Regression coverage exercises hard user deletion, draft event destruction, organization model/SQL restriction, the complete outgoing/incoming audit FK inventory, privacy/retention, synthetic purge with an audit-failure marker, partial enqueue/retry and false enqueue returns, paid-order fulfillment after a real failing audit SQL statement, dual audit/fallback failure, sanitized monitoring, and fail-closed admin/team changes.

## Review-fix verification

Checked 2026-10-24 Guam against implementation `1d0c4f55f0f7bc7c0781525eab2c7443a0bf6023`. The following documentation commit changes no application or test code. Agent execution used isolated fixtures in `hafapass_audit_review_test`, Ruby 3.3.4, local Postgres 17, Node 22.22.3 and Chromium. CI uses Postgres 16. `origin/main` was already an ancestor; no merge or rebase was needed. Policies are unchanged.

| Required scenario | Result and evidence |
| --- | --- |
| R01 Campaign enqueue/outcome | Passed: committed outbox visible from another DB connection before dispatch; real adapter rejection, partial enqueue failure, false return, retry reuse and initiating actor covered. No success audit appears before accepted child enqueues. |
| R02 Historical deletion | Passed: user hard deletion and draft event destruction preserve audit IDs; organization destroy returns a dependent-audit error and SQL deletion is FK-restricted; FK inventory, privacy, retention and synthetic purge covered. |
| R03 Money and fulfillment during audit failure | Passed: real failing audit SQL does not roll back paid-order completion, inventory or ticket QR issuance. Monitoring and minimal marker verified; audit-plus-marker failure also leaves fulfillment intact. Cash sale, admission and observed refund outage cases pass. |
| R04 Privileged configuration | Passed: admin role/verification and organizer team role changes roll back on rejected audits; staff refund intent remains fail-closed. |
| R05 Administrator presentation | Passed: deleted actor ID remains visible, details/search/reload persistence and overflow checked at 375 and 1280 CSS pixels with test auth/API mocks; screenshots visually inspected. |

Full RSpec: **2,558 examples, zero failures**. RuboCop: **921 files, zero offenses**. Brakeman: zero warnings. Bundler Audit: no vulnerabilities. ESLint, Vite build, production dependency audit, hygiene, release/freeze and whitespace checks passed. Vitest: **165 files, 1,810 tests passed**. Playwright's CI-settings run passed all 112 cases, with one scanner case succeeding on retry (111 first-pass, one flaky). The eight event-day cases then passed with retries disabled, and both audit-page viewport cases also passed with retries disabled. Impeccable returned no findings for the changed audit page. The earlier missing marker-table retention classification is fixed and its 40-example suite and the full suite pass.

Provider outcomes remain simulated. Live Clerk sign-in, physical devices, installed PWA behavior and production deployment were not tested. The prior authorization to use repository mock authentication remains the UI acceptance boundary. All owned test/browser/server processes are finished; the dedicated test database was dropped. Shared services and the held worktree remain intact. GitHub Actions and a current CodeRabbit review remain separate remote gates for the lead; this record does not claim remote approval.

## Original implementation verification


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
