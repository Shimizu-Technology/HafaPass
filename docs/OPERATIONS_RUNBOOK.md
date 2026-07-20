# HåfaPass Operations Runbook

This runbook covers the Phase 1 production foundation. It is an operational contract, not proof that paid-ticketing launch requirements in the [Ticketing Platform Blueprint](TICKETING_PLATFORM_BLUEPRINT.md) are complete.

## Service topology

Production requires three independently supervised processes/services:

1. Rails web process: `bundle exec puma -C config/puma.rb`
2. Sidekiq worker process: `bundle exec sidekiq -C config/sidekiq.yml`
3. Redis service shared by Active Job, Sidekiq, and Rack::Attack

The backend `Procfile` declares the web and worker commands. The frontend is a separate static Vite deployment.

Production never falls back to an in-memory or inline queue. Rails boot fails when `REDIS_URL` is missing, making a broken worker topology visible during deployment instead of silently losing work.

## Probes and expected behavior

| Probe | Purpose | Healthy response | Load-balancer use |
|---|---|---|---|
| `GET /api/v1/health` | Web-process liveness | HTTP 200, `{"status":"ok"}` | Restart a wedged web process |
| `GET /api/v1/readiness` | Database, queue, worker, and provider state | HTTP 200 with `status: ready` | Stop routing traffic when required dependencies fail |

In production, readiness requires:

- a working database connection;
- a successful Redis ping through the configured queue adapter; and
- at least one Sidekiq process registered in Redis.

Provider checks return booleans only. They intentionally never return credentials. Provider configuration is advisory in Phase 1 because payment, storage, email, and monitoring may be enabled at different deployment stages; each later launch phase promotes its own provider to a hard release gate.

## Required production configuration

Core runtime:

- `DATABASE_URL`
- `REDIS_URL`
- `CLERK_SECRET_KEY` and `CLERK_PUBLISHABLE_KEY`
- `ALLOWED_ORIGINS`
- `FRONTEND_URL`
- `SENTRY_DSN`
- `GIT_SHA` or `COMMIT_REF` for release correlation

Provider-specific configuration remains documented in the root README. Put secrets in the deployment platform's encrypted environment store. Never put values in source, CI YAML, command output, screenshots, or support tickets.

## Monitoring and alert rules

Backend and frontend errors are reported to Sentry when their DSNs are configured. The backend attaches environment, release, request ID, job ID/class/queue, and authenticated internal user ID. The frontend attaches environment, release, route context supplied by the SDK, and authenticated Clerk user ID. Neither side enables default PII or deliberately captures request bodies, payment data, email addresses, or tokens.

Create these alerts in the production monitoring project before a pilot:

| Alert | Trigger | Initial response |
|---|---|---|
| Readiness unavailable | 2 consecutive 503 responses or 2 minutes unavailable | Check database, Redis, and Sidekiq in that order |
| Web error spike | 5 unhandled server errors in 5 minutes | Inspect release and request IDs; roll back if release-correlated |
| Worker exception | Any new background-job issue; page after 5 events in 10 minutes | Inspect job class/ID, dependency status, retries, and dead set |
| Worker missing | readiness reports `no_active_process` for 2 minutes | Restart worker and confirm registered process count |
| Payment/webhook error | Any new payment/webhook issue; page after 3 in 5 minutes | Stop risky deploys, preserve provider event IDs, reconcile before retrying |
| Frontend crash spike | 10 affected sessions in 10 minutes | Inspect browser/release pattern and activate recovery/private preview if needed |

Route routine alerts to the engineering operations channel. Route payment, webhook, and sustained checkout alerts to the on-call owner immediately. Phase 7 must record the actual owners and escalation contacts before pilot launch.

## Incident triage

1. Confirm scope with `/health` and `/readiness`; record timestamps, HTTP status, release, and request IDs.
2. Check the latest deploy and configuration change without printing secret values.
3. Check PostgreSQL connectivity and saturation.
4. Check Redis connectivity, memory, and eviction status.
5. Confirm a Sidekiq process is present and inspect retry/dead queues.
6. Check Sentry by release, request ID, job ID, or provider event ID.
7. For payment or webhook uncertainty, do not manually replay until current persisted state and provider state have been compared. Duplicate effects are more dangerous than a delayed reconciliation.
8. Roll back only the implicated release/configuration. Verify both probes and a representative user flow after recovery.
9. Write a short incident record with impact, timeline, cause, correction, and prevention.

## Worker recovery

After restoring Redis or restarting Sidekiq:

1. Confirm readiness shows `job_queue.status: connected`, `worker.status: active`, and a positive process count.
2. Review Sidekiq retry and dead sets before deleting or replaying anything.
3. Replay only jobs whose operation is known to be idempotent.
4. Reconcile email/payment side effects against their provider before retrying ambiguous jobs.
5. Watch the worker exception alert and queue latency until the backlog is cleared.

## Deployment verification

Every release must pass `./scripts/gate.sh` and CI before merge. After deployment:

1. Verify `/health` and `/readiness`.
2. Verify the reported release in Sentry.
3. Trigger a controlled non-sensitive test exception in the monitoring environment, then remove/disable the trigger.
4. Verify the Sidekiq process and perform one safe queued test job.
5. Verify the public marketplace and private-preview recovery behavior from a browser.

## Known Phase 1 boundaries

- Readiness proves dependency presence, not the full correctness of payments or ticket delivery.
- Job-level capture and retries do not make non-idempotent commerce operations safe by themselves.
- Monitoring alert policies must be created in the selected external Sentry account and deployment monitor.
- Backup restore drills, transaction reconciliation, payment state machines, immutable ledger behavior, and offline event-day admissions are delivered and validated in later phases.

## Event-day operations

Signed offline admissions, device reconciliation, emergency door lists, door inventory, cash sales, and the guarded BOH/Clover card-present path are operated through [Event-Day Operations](EVENT_DAY_OPERATIONS.md). Treat an unknown terminal result like an unknown webhook result: preserve provider identifiers and the original idempotency key, do not duplicate the side effect, and reconcile before issuing inventory.
