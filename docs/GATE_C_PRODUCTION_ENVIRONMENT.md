# Gate C Production Environment

Status: application controls implemented; production provisioning and independent drill evidence remain pending.

## Purpose

Gate C proves that the production candidate runs in a dedicated, observable, recoverable environment. Passing unit tests or possessing credentials is not evidence that this gate is complete. The exit requires a real deployment, named primary and backup responders, a redacted readiness capture, alert acknowledgements, and an isolated backup/restore and application-rollback drill.

Never paste environment values, database URLs, signing keys, provider payloads, customer data, or backup contents into Git, screenshots, chat, or the evidence register. Record only deployment identifiers, redacted outputs, timestamps, actors, digests, and restricted-system references.

## Required topology

Provision and supervise these independently:

1. Rails web process;
2. Sidekiq worker process;
3. singleton commerce-clock process;
4. PostgreSQL with encrypted automated backups;
5. Redis with authentication, encryption, persistence policy, and eviction policy reviewed for queues/rate limits;
6. static frontend/CDN with DNS and TLS;
7. private object-storage bucket;
8. Sentry plus an external uptime monitor; and
9. Resend domain and signed webhook path.

The commerce clock now owns a renewable Redis lease. A second clock exits instead of becoming another inventory-expiry authority. `/api/v1/readiness` fails in production if the lease heartbeat is absent, the worker is absent, Redis or PostgreSQL is unavailable, or the redacted production configuration is incomplete.

## Runtime configuration contract

The readiness configuration check requires the following groups without returning their values:

- database: `DATABASE_URL`;
- queue/lease: `REDIS_URL`;
- authentication: `CLERK_SECRET_KEY`, `CLERK_PUBLISHABLE_KEY`;
- public routing: HTTPS `FRONTEND_URL`, HTTPS `PUBLIC_WEB_URL`, and HTTPS-only `ALLOWED_ORIGINS` containing the frontend origin;
- release correlation: `GIT_SHA` or an explicitly configured `COMMIT_REF` containing the full 40- or 64-hex commit digest—not a branch name;
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

1. confirm protected-main CI and the source PR, including Greptile, are green;
2. confirm web, worker, and clock are separate supervised services using the same release;
3. capture redacted `/api/v1/health` and `/api/v1/readiness` responses;
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
6. Re-deploy the candidate and reverify readiness, worker/clock heartbeats, queue processing, and provider disablement.
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
