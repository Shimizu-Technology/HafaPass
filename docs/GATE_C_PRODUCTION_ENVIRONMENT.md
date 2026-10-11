# Gate C Production Environment

Status: application controls implemented; production provisioning and independent drill evidence remain pending.

## Purpose

Gate C proves that the production candidate runs in a dedicated, observable, recoverable environment. Passing unit tests or possessing credentials is not evidence that this gate is complete. The exit requires a real deployment, named primary and backup responders, a redacted readiness capture, alert acknowledgements, and an isolated backup/restore and application-rollback drill.

Never paste environment values, database URLs, signing keys, provider payloads, customer data, or backup contents into Git, screenshots, chat, or the evidence register. Record only deployment identifiers, redacted outputs, timestamps, actors, digests, and restricted-system references.

## Required topology

Select and supervise one supported runtime profile. The initial `embedded` profile runs one Rails/Puma service with Solid Queue's native async worker, dispatcher and scheduler; PostgreSQL persists the queue and rate limits. The later `solid_queue` profile adds a separate SQL worker using the same queue. The legacy `sidekiq` profile requires separate web, Sidekiq, singleton commerce-clock and persistent Redis services. Do not combine queue or scheduler authorities. See [Single-service runtime](SINGLE_SERVICE_RUNTIME.md).

All profiles require isolated PostgreSQL with encrypted automated backups, static frontend/CDN with DNS and TLS, private object storage, Sentry plus an external uptime monitor, and the configured Resend domain and signed webhook path. Readiness fails on unavailable dependencies or missing actors. SQL readiness additionally requires recent successful critical ticks and bounded due/claimed work; these checks fail closed when the one job thread stalls.

## Runtime configuration contract

Configure the following groups without exposing their values in diagnostics. Runtime readiness checks the application/provider configuration; the direct migration connection is required only by the release command:

- database: `DATABASE_URL`;
- runtime: explicit `HAFAPASS_RUNTIME`; `REDIS_URL` for the Sidekiq queue/lease only;
- release migrations: direct `DATABASE_MIGRATION_URL`, run once through `bin/release-migrate` from the web release/pre-deploy hook;
- capacity: embedded uses one Puma process, `RAILS_MAX_THREADS=3`, one job thread and `DB_POOL=10`; account for dispatcher, polling and heartbeat threads as well as requests/jobs. Separate SQL and Sidekiq profiles must meet their own enforced pool budgets;
- persistent application signing: dedicated `SECRET_KEY_BASE`;
- authentication: `CLERK_SECRET_KEY`, `CLERK_PUBLISHABLE_KEY`, explicit production `CLERK_AUTHORIZED_PARTIES` containing the exact trusted HTTPS frontend origins; the issuer/JWKS must match the selected Clerk instance;
- public routing: HTTPS `FRONTEND_URL`, HTTPS `PUBLIC_WEB_URL`, exact HTTPS `PUBLIC_API_URL`, and HTTPS-only `ALLOWED_ORIGINS` containing the frontend origin;
- release correlation: Render's authoritative `RENDER_GIT_COMMIT`, or `GIT_SHA`/`COMMIT_REF` on other platforms, containing the full 40- or 64-hex commit digest—not a branch name; a present invalid Render value blocks readiness instead of using a fallback;
- monitoring: `SENTRY_DSN`;
- mail: `RESEND_API_KEY`, `RESEND_WEBHOOK_SECRET`, `MAILER_FROM_EMAIL`;
- provider evidence binding: non-secret `PROVIDER_CONFIGURATION_REVISION`, incremented for every provider-side configuration change;
- private storage: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_BUCKET`, `AWS_REGION`;
- offline-admission signing: `ADMISSION_MANIFEST_PRIVATE_KEY_PEM`; and
- bootstrap safety: `ENABLE_FIRST_USER_ADMIN_BOOTSTRAP` absent or false.

Production CORS has no localhost fallback. Missing `ALLOWED_ORIGINS` prevents boot; HTTP, wildcard, genuine subpath, credential-bearing, query-bearing, and fragment-bearing origins make readiness fail. A conventional single trailing root slash is normalized.

Payment, wallet, and card-present credentials remain feature-specific gates. Do not add a credential merely to turn a boolean green. Every enabled production provider still needs the applicable Gate B/D/H approval and evidence.

## Deployment verification

For the exact candidate commit:

1. confirm protected-main CI and the source PR, including completed current-head review provenance under [the release review contract](INDEPENDENT_REVIEW_EVIDENCE.md), are green;
2. confirm the selected runtime topology, a single scheduling authority and the exact same release across its services;
3. confirm `/up` succeeds without querying dependencies and capture redacted `/api/v1/health` and `/api/v1/readiness` responses;
4. confirm readiness reports database connected, queue connected, worker active, commerce clock active, and configuration configured;
5. confirm TLS, HSTS/cache behavior, allowed origins, private-route cache headers, webhook signature rejection, and rate limits;
6. trigger controlled non-PII web and job exceptions and acknowledge both primary and backup routes;
7. verify queue-depth, payment/webhook/reconciliation, delivery, hold-expiry, scanner-sync, and seating-contention alert policies; and
8. record deployment, monitor, alert, and verifier identifiers in restricted evidence storage.

## Backup, restore, and rollback drill

1. Create an encrypted backup and record its provider backup ID, source release, schema version, start/end time, and retention.
2. Restore into a new isolated environment. Disable outbound mail, payments, payouts, wallet issuance, card-present calls, and production webhooks before application access.
3. Verify schema version, table/row-count manifest, sampled referential integrity, orders, tickets, immutable ledger entries, audits, admissions, delivery events, and policy snapshots.
4. Run safe application smoke tests against the restored environment.
5. Deploy the current candidate, then roll application code back to the reviewed compatible release. Do not reverse destructive migrations after real records exist.
6. Re-deploy the candidate and reverify readiness, selected-runtime actors and successful critical ticks, queue processing, and provider disablement.
7. Record RPO, RTO, discrepancies, independent verifier, and secure destruction date for the isolated environment.

## Exit evidence

Gate C remains pending until restricted evidence contains:

- production project/service identifiers and the exact release SHA;
- dedicated-credential and rotation/revocation attestations;
- redacted health/readiness captures;
- named alert destinations with primary and backup acknowledgement IDs;
- encrypted backup and isolated restore identifiers;
- integrity results, measured RPO/RTO, and verifier sign-off;
- application rollback/redeploy result; and
- confirmation that no borrowed credential or unintended production-provider path remains.
