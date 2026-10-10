# HåfaPass Operations Runbook

This runbook covers the Phase 1 production foundation. It is an operational contract, not proof that paid-ticketing launch requirements in the [Ticketing Platform Blueprint](TICKETING_PLATFORM_BLUEPRINT.md) are complete.

## Service topology

The initial $7 Render service selects `HAFAPASS_RUNTIME=embedded`: one Puma process with three request threads, Solid Queue 1.7.0's native async supervisor, one job thread, dispatcher and scheduler. PostgreSQL owns durable jobs, recurring work, recovery journals and rate limits. Redis and separate worker/clock services are not required for this profile. Set `DB_POOL=10`; the shared pool must cover the web threads and queue management threads. See [Single-service runtime](SINGLE_SERVICE_RUNTIME.md) for recovery guarantees, measured limits and the later separate-worker cutover.

`HAFAPASS_RUNTIME=solid_queue` runs the same durable PostgreSQL queue with a separate `bundle exec bin/jobs` service. `HAFAPASS_RUNTIME=sidekiq` retains the existing separate Sidekiq, Redis and singleton commerce-clock services. Never run both scheduling authorities, and drain the old queue before changing queue adapters. The future Sidekiq manifest is not part of the initial hosting approval.

Use `bin/render-build.sh` to install dependencies and `bin/release-migrate` once as the web service release/pre-deploy command. Supply a direct `DATABASE_MIGRATION_URL` for Rails PostgreSQL migration advisory locks; application processes retain the pooled application URL. The release wrapper binds database path, endpoint host and port, allowing only Neon's matching `-pooler`/direct hostname difference. A dedicated migration role may differ from the application role. Builds and process startup do not migrate.

The Singapore deployment, secret references, release owner and acceptance sequence are in [Hosted backend deployment](RENDER_DEPLOYMENT_CONTRACT.md). Both runtime profiles expire holds every minute and recover pending Stripe fee evidence every five minutes. SQL profiles also recover eligible persisted domain work every minute. Production never falls back to an in-memory or inline queue.

## Probes and expected behavior

| Probe | Purpose | Healthy response | Load-balancer use |
|---|---|---|---|
| `GET /up` | Dependency-free boot liveness | HTTP 200 | Render platform health path |
| `GET /api/v1/health` | Application liveness | HTTP 200, `{"status":"ok"}` | Operator verification |
| `GET /api/v1/readiness` | Database, queue, worker, commerce clock, redacted configuration, provider, and operational state | HTTP 200 with `status: ready` | Separately monitored dependency diagnostics; never the frequent platform probe |

In production, readiness requires:

- a working database connection;
- a working durable queue;
- current-release worker and scheduling actors;
- for SQL profiles, recent successful expiry/recovery/fee ticks and no overdue holds or jobs beyond the readiness bounds;
- for Sidekiq, a successful Redis ping, registered worker and singleton clock lease; and
- a complete redacted production configuration contract.

Provider checks return booleans only. They intentionally never return credentials. Production configuration and provider-policy controls are required readiness checks. Resend and the policy register need current independent approvals; live payment mode additionally requires Stripe approval. Redacted configuration presence does not prove actual provider behavior. Staging requires its isolated safety configuration and the selected durable runtime. Simulation remains the default; controlled provider rehearsal requires its explicit allowlists and test-mode configuration.

## Required production configuration

Core runtime:

- `DATABASE_URL`
- `HAFAPASS_RUNTIME`, `RAILS_MAX_THREADS`, `DB_POOL`; `REDIS_URL` only for Sidekiq
- `CLERK_SECRET_KEY` and `CLERK_PUBLISHABLE_KEY`
- `ALLOWED_ORIGINS`
- `FRONTEND_URL`
- `PUBLIC_WEB_URL`
- `PUBLIC_API_URL` (exact HTTPS API origin; application Host authorization)
- `SECRET_KEY_BASE` (persistent release-independent application secret)
- `DATABASE_MIGRATION_URL` (direct release-only connection; never the pooled host)
- `SENTRY_DSN`
- `GIT_SHA` or an explicitly configured `COMMIT_REF` containing the full commit digest for release correlation

Provider-specific configuration remains documented in the root README. Put secrets in the deployment platform's encrypted environment store. Never put values in source, CI YAML, command output, screenshots, or support tickets. The exact Gate C contract and evidence procedure are in [Gate C Production Environment](GATE_C_PRODUCTION_ENVIRONMENT.md).

## Monitoring and alert rules

Backend and frontend errors are reported to Sentry when their DSNs are configured. The backend attaches environment, release, request ID, job ID/class/queue, and authenticated internal user ID. The frontend attaches environment, release, route context supplied by the SDK, and authenticated Clerk user ID. Neither side enables default PII or deliberately captures request bodies, payment data, email addresses, or tokens.

Create these alerts in the production monitoring project before a pilot:

| Alert | Trigger | Initial response |
|---|---|---|
| Readiness unavailable | 2 consecutive 503 responses or 2 minutes unavailable | Check database, selected queue actors, successful ticks and oldest due jobs |
| Web error spike | 5 unhandled server errors in 5 minutes | Inspect release and request IDs; roll back if release-correlated |
| Worker exception | Any new background-job issue; page after 5 events in 10 minutes | Inspect job class/ID, dependency status, retries, and dead set |
| Worker missing | readiness reports `no_active_process` for 2 minutes | Restart the owning service and confirm current-release actors and progress |
| Payment/webhook error | Any new payment/webhook issue; page after 3 in 5 minutes | Stop risky deploys, preserve provider event IDs, reconcile before retrying |
| Frontend crash spike | 10 affected sessions in 10 minutes | Inspect browser/release pattern and activate recovery/private preview if needed |

Route routine alerts to the engineering operations channel. Route payment, webhook, and sustained checkout alerts to the on-call owner immediately. Phase 7 must record the actual owners and escalation contacts before pilot launch.

## Incident triage

1. Confirm scope with `/up`, `/api/v1/health` and `/api/v1/readiness`; record timestamps, HTTP status, release, and request IDs.
2. Check the latest deploy and configuration change without printing secret values.
3. Check PostgreSQL connectivity and saturation.
4. For SQL profiles inspect queue failures, oldest due/claimed work and runtime progress. For Sidekiq check Redis connectivity, memory and eviction.
5. Confirm the selected worker and scheduler are current and inspect failed work before replay.
6. Check Sentry by release, request ID, job ID, or provider event ID.
7. For payment or webhook uncertainty, do not manually replay until current persisted state and provider state have been compared. Duplicate effects are more dangerous than a delayed reconciliation.
8. Roll back only the implicated release/configuration. Verify both probes and a representative user flow after recovery.
9. Write a short incident record with impact, timeline, cause, correction, and prevention.

## Worker recovery

After restoring the database/queue or restarting its owning service:

1. Confirm readiness shows `job_queue.status: connected`, `worker.status: active`, and a positive process count.
2. Review persisted failures and provider uncertainty before deleting or replaying anything. SQL recovery retries only its explicit safe interrupted-job allowlist; exhausted or ambiguous financial work needs operator reconciliation.
3. Replay only jobs whose operation is known to be idempotent.
4. Reconcile email/payment side effects against their provider before retrying ambiguous jobs.
5. Watch the worker exception alert and queue latency until the backlog is cleared.

## Deployment verification

Every release must pass `./scripts/gate.sh` and CI before merge. After deployment:

1. Verify `/up`, `/api/v1/health` and `/api/v1/readiness`. Configure Render's platform health path as `/up`; it never probes dependencies. Production HTTPS/HSTS and exact API Host authorization apply to application paths. Only `/up` bypasses SSL redirect and Host enforcement for the platform probe.
2. Verify the reported release in Sentry.
3. Trigger a controlled non-sensitive test exception in the monitoring environment, then remove/disable the trigger.
4. Verify actual selected-runtime progress and perform one safe queued test job.
5. Verify the public marketplace and private-preview recovery behavior from a browser.

## Known Phase 1 boundaries

- SQL readiness proves bounded runtime progress; it does not prove the full correctness of payments or ticket delivery.
- Job-level capture and retries do not make non-idempotent commerce operations safe by themselves.
- Monitoring alert policies must be created in the selected external Sentry account and deployment monitor.
- Backup restore drills, transaction reconciliation, payment state machines, immutable ledger behavior, and offline event-day admissions are delivered and validated in later phases.

## Event-day operations

Signed offline admissions, device reconciliation, emergency door lists, door inventory, cash sales, and the guarded BOH/Clover card-present path are operated through [Event-Day Operations](EVENT_DAY_OPERATIONS.md). Treat an unknown terminal result like an unknown webhook result: preserve provider identifiers and the original idempotency key, do not duplicate the side effect, and reconcile before issuing inventory.

## Pilot readiness

Communications, support, provider outage, incident, weather, refund, rollback, backup/restore, alert, accessibility, and device/browser pilot procedures are in [Pilot Readiness and Incident Runbook](PILOT_READINESS_RUNBOOK.md). Draft legal artifacts and their required professional approvals are tracked in [Policy and Professional Review Register](POLICY_REVIEW_REGISTER.md). Pending external evidence is a hard release gate, not an engineering test failure to waive.

Durable email attempts bind their payload and idempotency key to a nonsecret fingerprint of the effective Resend credential, endpoint, and provider configuration revision. Reconcile uncertain sends before changing those settings. Changed contexts and legacy attempted rows with no saved context fail closed; approving a new provider configuration does not authorize replaying old uncertain sends.
