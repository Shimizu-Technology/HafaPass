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

Readiness returns the same 200/503 to everyone, but the public body is only `{"status": ..., "timestamp": ...}`. The full check detail needs an `X-Readiness-Token` header that matches the `READINESS_TOKEN` environment variable. With the variable unset, detail is unavailable and nothing else changes. Generate a long random value, store it in the password manager, and send it only from operator tools:

```bash
curl -s -H "X-Readiness-Token: $READINESS_TOKEN" https://hafapass-api.onrender.com/api/v1/readiness
```

The detail also reports the database `statement_timeout`, `idle_in_transaction_session_timeout` and Postgres major version (informational, never part of the verdict), and `request_ip_source`, which shows which header supplied the request IP (see "Client IP and rate limits").

In production, readiness requires:

- a working database connection;
- a working durable queue;
- current-release worker and scheduling actors;
- for SQL profiles, recent successful expiry/recovery/fee ticks and no overdue holds or jobs beyond the readiness bounds;
- for Sidekiq, a successful Redis ping, registered worker and singleton clock lease; and
- a complete redacted production configuration contract.

Provider checks return booleans only. They intentionally never return credentials. Production configuration and provider-policy controls are required readiness checks. Resend and the policy register need current approvals (one administrator may submit and approve); live payment mode additionally requires Stripe approval. Redacted configuration presence does not prove actual provider behavior. Staging requires its isolated safety configuration and the selected durable runtime. Simulation remains the default; controlled provider rehearsal requires its explicit allowlists and test-mode configuration.

## Required production configuration

Core runtime:

- `DATABASE_URL`
- `HAFAPASS_RUNTIME`, `RAILS_MAX_THREADS`, `DB_POOL`; `REDIS_URL` only for Sidekiq
- `CLERK_SECRET_KEY`, `CLERK_PUBLISHABLE_KEY`, and explicit production `CLERK_AUTHORIZED_PARTIES` matching the trusted HTTPS frontend origins (independent of CORS)
- `ALLOWED_ORIGINS`
- `FRONTEND_URL`
- `PUBLIC_WEB_URL`
- `PUBLIC_API_URL` (exact HTTPS API origin; application Host authorization)
- `SECRET_KEY_BASE` (persistent release-independent application secret)
- `DATABASE_MIGRATION_URL` (direct release-only connection; never the pooled host)
- `SENTRY_DSN`
- Render's authoritative `RENDER_GIT_COMMIT`, or `GIT_SHA`/`COMMIT_REF` on other platforms, containing the full commit digest for shared readiness, approval, job metadata and Sentry release correlation

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

`OperationalAlertJob` runs every 5 minutes (`config/recurring.yml`). A signal above zero sends one Sentry message, level error, with the fingerprint `operational-alert/<signal>`, so each signal stays one Sentry issue. It alerts when the count rose since the previous check, and otherwise repeats at most every 6 hours while the count stays above zero; a count that falls to zero and comes back alerts at once. The last count and alert time are kept per signal in the `runtime_alert_states` table, so deploys and restarts don't re-alert.

| Signal | Counts | First response |
|---|---|---|
| `exhausted_message_deliveries` | Failed deliveries with 5+ attempts that failed in the last 24 h | Check Resend status, then use **Resend failed messages** in the support console (below) |
| `failed_payment_webhooks` | Stripe webhook events in `failed` status | Admin → Operations; reconcile against Stripe before any replay |
| `open_reconciliation_exceptions` | Open reconciliation exceptions | Finance review; never close with a database edit |
| `failed_background_jobs` | Solid Queue failed executions in the last hour | Inspect the job class and error before retrying |

The same line is written to the log as `{"event":"operational_alert",...}`, so it is visible without Sentry.

After a Resend outage, the support console's **Resend failed messages** button (or `POST /api/v1/support/message_deliveries/bulk_resend` with `status=failed` and optional `failed_after`, `failed_before`, `event_id`) queues up to 500 failed messages per request, oldest first. It skips messages the provider already accepted, messages past the safe replay window, messages already queued for a replay in the last 15 minutes (`message_deliveries.replay_requested_at`, also set by a single **Retry delivery**), and addresses that bounced or complained, and reports how many it skipped for each reason. Each queued message writes a `message_delivery.replayed` audit entry. One request examines at most 2,000 candidates; `remaining` counts the eligible messages it did not reach. If the response says more remain, run it again: the next run takes the next batch, never the messages just queued. If the request times out or the response is lost, the outcome is unknown: check the delivery list and the `message_delivery.replayed` audit entries before running it again. A message whose replay failed again becomes eligible 15 minutes after it was queued.

### External alert and uptime setup

These live outside the code. Record the owner and date here once each is done.

1. Sentry (backend project): an alert rule for new issues, and one for each `operational-alert/*` fingerprint above, routed to Leon and a backup contact.
2. Uptime monitor on `https://hafapass-api.onrender.com/api/v1/readiness`, every 1–5 minutes, alerting when the response lacks the keyword `"status":"ready"` twice in a row. The public body is enough; don't put the readiness token in a third-party monitor.
3. Uptime monitor on the frontend root, `https://hafapass.shimizu-technology.com/`.
4. Render: deploy-failed and service-health notifications for `hafapass-api`, to the same people.

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

## Refund recovery

- In **Refund issues**, retry a failed local refund only after checking the earlier provider attempt. A selected-ticket retry retains its selection: pending blocks those tickets, and success releases only their eligible inventory once. A provider timeout is an unknown result, not permission to submit a second return.
- **External refund needs verification** offers **Check Stripe status**. This retrieves operations using the payment's recorded account and environment; an aggregate returned amount alone never fabricates a refund. Historical failed/cancelled external observations reserve no money and do not appear as retryable local requests. Contradictory terminal outcomes, identity collisions, or incomplete provider evidence remain finance-review cases.
- A capture after order expiry/cancellation must not issue tickets or reclaim released capacity. Review the captured charge, return it through the authorized provider/refund process, and verify the recorded return and repeated callback handling. Do not close the exception with a direct database edit or compensate by issuing tickets.
- Keep the original operation identifiers, provider evidence, and independent finance holds until the ledger reconciles. A cleared refund queue alone does not prove that a check was issued, a provider returned money, or settlement is complete.

### Refunding a card order as an administrator

Use **Admin → Orders**, expand the order, then **Refund this order**. This is the path behind the "Contact HåfaPass support" message organizers see once an event has paid out, and behind the support link transfer recipients see after an event change.

- **Everything left** cancels every unscanned ticket, including transferred ones. **Selected tickets** refunds each ticket's value and cancels only those. **A set amount** leaves tickets valid.
- The money always goes to the original buyer's card, and only the buyer gets the refund email. If you refund a transferred ticket, tell its current holder yourself.
- A note is required and is stored in the audit log (`order.admin_refund_requested`).
- After a payout, HåfaPass's Stripe balance pays the refund. Any amount above the organizer's balance shows as a negative balance on their Finances page. The Organizer Agreement lets you deduct it from future payouts or invoice it. Nothing invoices automatically: if they have no upcoming event, send the invoice yourself.
- If a refund comes back unconfirmed, open it again and choose **Check this refund**. That replays the same request and can't refund twice. Don't refund the same order in the Stripe Dashboard while it's unconfirmed.
- Door-cash and other non-Stripe orders aren't refunded here. The organizer records those returns.

## Deploy order

The API deploys by hand, but Netlify auto-publishes `main` as soon as a merge lands. A frontend change that needs a new API must therefore never reach `main` while the old API is still live. Every merge waits for the gate and CI to pass.

To deploy the API: fast-forward `hafapass-staging` to the release commit (`git push origin <commit>:hafapass-staging`, fast-forward only), then deploy `hafapass-api` on Render. The pre-deploy command runs `bin/release-migrate`. The API is live once `GET /api/v1/health` reports the new `revision` and readiness returns 200.

- **API-only or frontend-only release:** merge, then deploy the API if it changed. Nothing waits on anything else.
- **Frontend depends on new API, option A (preferred): split the PRs.** Merge the API-only PR first, deploy the API, and confirm the health `revision`. Only then merge the frontend PR.
- **Frontend depends on new API, option B: one PR with the Netlify publish locked.** Before merging, open Netlify → Deploys → **Lock to stop auto publishing**. Merge, deploy the API, and confirm the health `revision`. Then publish the new deploy from Netlify and unlock auto publishing. Do not leave publishing locked after the release.

Make API changes expand-then-contract so either order is survivable: add new fields, endpoints and columns in one release and keep the old ones working; switch the frontend; remove the old ones in a later release. A migration must work with the code that is already running, because the old release keeps serving while the pre-deploy migration runs. `strong_migrations` checks every migration added after `20261024310000` and sets `lock_timeout` 10 s and `statement_timeout` 1 h for migrations.

## Rolling back a release

Roll back when an error spike, failed readiness or broken buyer or door flow lines up with a release. Write down the bad and last-good revisions first: `GET /api/v1/health` (`revision`) and `/release.json`.

1. **Frontend (Netlify).** Deploys → open the last good published deploy → **Publish deploy**. Netlify then locks auto publishing. Confirm `/release.json` shows the old revision. After the fix merges, publish the new deploy and **unlock auto publishing**, or later merges silently won't go live.
2. **API (Render).** `hafapass-api` → Events → the last good deploy → **Rollback**, or start a deploy of a specific commit (Render API `POST /v1/services/<service id>/deploys` with `{"commitId": "<sha>"}`). Confirm the health `revision` and that readiness returns 200.
3. **Migrations are never reversed by a rollback.** Expand-then-contract keeps the old code compatible with the new schema. If a migration itself is the problem, take a Neon branch snapshot first, then run only its reviewed down step as a one-off job.
4. **Keep the branch honest.** After a Render rollback, `hafapass-staging` still points at the bad commit, and a casual "deploy latest commit" would ship it again. Fix forward on `main`, then fast-forward `hafapass-staging` to the fix and deploy.
5. **Reconcile the window.** Check Admin → Operations for failed or exhausted deliveries and reconciliation exceptions created while the bad release was live, and check Sentry for the release.

The daily `Scheduled checks` workflow (`.github/workflows/scheduled-checks.yml`) fails when the live API or frontend no longer matches `main`, or readiness isn't 200. A failure after a rollback is expected until the fix is deployed.

## Audit log TRUNCATE guard

Migration `20261102000000` adds the statement-level `audit_logs_no_truncate` trigger, which rejects `TRUNCATE audit_logs` unless the transaction has set `SET LOCAL hafapass.audit_truncate = 'on'` (details in [Audit integrity](AUDIT_INTEGRITY.md)). Consequences:

- Locally, `bin/rails db:truncate_all`, `db:seed:replant` and any tool that truncates every table fail on `audit_logs`. Use `db:reset` or `db:schema:load` (which drop and recreate tables) for a fresh local database instead.
- Rolling back past `20261102000000` drops the trigger and its function. Rolling back a later migration keeps the trigger in place.
- The synthetic-data purge (`hafapass:purge_synthetic_data`) is the only application path that opts in, inside its own transaction.

## Frontend asset caching

Netlify serves `/assets/*` with `Cache-Control: public, max-age=31536000, immutable`, because Vite fingerprints every file there. The rule matches by path, so a request for a missing hash (for example, an old tab asking for a chunk from a previous deploy) may also get the immutable header on its 404 or SPA fallback response, and a browser or CDN can cache that miss. We accept this: a missing hash never becomes valid later, because new builds use new names, and the app's chunk-load recovery reloads the page to pick up the current asset names.

## Deployment verification

Every release must pass `./scripts/gate.sh` and CI before merge. After deployment:

1. Verify `/up`, `/api/v1/health` (its `revision` should be the new commit) and `/api/v1/readiness`. Configure Render's platform health path as `/up`; it never probes dependencies. Production HTTPS/HSTS and exact API Host authorization apply to application paths. Only `/up` bypasses SSL redirect and Host enforcement for the platform probe.
2. Verify the reported release in Sentry.
3. Trigger a controlled non-sensitive test exception in the monitoring environment, then remove/disable the trigger.
4. Verify actual selected-runtime progress and perform one safe queued test job.
5. Verify the public marketplace and private-preview recovery behavior from a browser.

## Client IP and rate limits

Rack::Attack keys its IP throttles on Rack's `req.ip`. Render's proxy reaches the app from a private address, so Rack skips it and uses the last untrusted `X-Forwarded-For` entry. If a CDN edge sits in that chain, `req.ip` would be the edge rather than the visitor, and one busy edge would share a single throttle bucket. Each process logs one `rack_attack_client_ip_source` line after boot with the source (`x_forwarded_for` or `remote_addr`), the number of forwarded hops, and whether `CF-Connecting-IP` and `True-Client-IP` match `req.ip`. It never logs an address. The token-protected readiness detail shows the same fields for your own request. If either header reports `differs`, the throttles are keyed on an edge address: fix the trusted-proxy setup before relying on per-IP limits.

Provider webhook deliveries (`POST /webhooks/stripe`, `POST /webhooks/resend`) don't use the 300-per-5-minute visitor budget; they have 600 per minute per address. Other methods on those paths count as ordinary visitor traffic. Ticket pages (`GET /api/v1/tickets/:credential`) are limited to 60 per minute per ticket under a 600-per-minute address ceiling, so a door crowd on one venue Wi-Fi can open passes.

## Database settings, backups and restore drill

Set these on the Neon application role once (Neon SQL editor, connected to the production database as the owner). Don't put them in `database.yml`: the pooler runs in transaction mode.

```sql
ALTER ROLE <application_role> SET statement_timeout = '30s';
ALTER ROLE <application_role> SET idle_in_transaction_session_timeout = '60s';
```

New connections pick them up; confirm with the readiness detail (`checks.database.statement_timeout`). Release migrations use their own connection settings from strong_migrations, so they aren't cut off at 30 s.

Backups: confirm the Neon project is on a paid plan with point-in-time restore of at least 7 days. Run the restore drill before the first event and then quarterly:

1. In Neon, create a branch from production at a timestamp a few minutes in the past.
2. Connect to the branch (never to production) and check row counts and the newest `orders`, `payments` and `audit_logs` rows against what you expect for that time.
3. Note how long the restore took and anything that surprised you.
4. Delete the branch.
5. Record the result here.

| Date | Restore point | Duration | Checked | Result | By |
|---|---|---|---|---|---|
| _not yet run_ | | | | | |

## TIN encryption key custody

`ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` and `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` encrypt organizer W-9/TIN data. Production refuses to boot without them, and losing them makes the stored TINs unreadable, including in any restored backup.

- Primary copy: Render environment for `hafapass-api`.
- Escrow copy: _password manager item: (location to be recorded)_.
- Second custodian: _(name to be recorded)_.

Never write the values in a repository, ticket, chat, screenshot or this document. Don't rotate them by editing the Render values; rotation needs a planned re-encryption release.

## Production names that still say "staging"

Production went live on infrastructure first created for staging, and the names were kept to avoid a risky migration:

- Render deploys the branch `hafapass-staging` (fast-forwarded from `main`).
- The Neon database is named `hafapass_staging`.
- The Render environment group is `hafapass-staging-runtime`.
- The S3 bucket is `hafapass-staging-assets-20261010-01a11d81`.

All of these are production. `RAILS_ENV` is `production`. Don't rename them as cleanup; a rename needs its own planned change.

## Known Phase 1 boundaries

- SQL readiness proves bounded runtime progress; it does not prove the full correctness of payments or ticket delivery.
- Job-level capture and retries do not make non-idempotent commerce operations safe by themselves.
- Monitoring alert policies must be created in the selected external Sentry account and deployment monitor.
- Backup restore drills, transaction reconciliation, payment state machines, immutable ledger behavior, and offline event-day admissions are delivered and validated in later phases.

## Event-day operations

Signed offline admissions, device reconciliation, emergency door lists, door inventory, cash sales, and the guarded BOH/Clover card-present path are operated through [Event-Day Operations](EVENT_DAY_OPERATIONS.md). Treat an unknown terminal result like an unknown webhook result: preserve provider identifiers and the original idempotency key, do not duplicate the side effect, and reconcile before issuing inventory.

## Pilot readiness

Communications, support, provider outage, incident, weather, refund, rollback, backup/restore, alert, accessibility, and device/browser pilot procedures are in [Pilot Readiness and Incident Runbook](PILOT_READINESS_RUNBOOK.md). The operative policies and later professional-review items are tracked in [Policy and Professional Review Register](POLICY_REVIEW_REGISTER.md). Other pending external payment and provider evidence remains a release gate, not an engineering test failure to waive.

Durable email attempts bind their payload and idempotency key to a nonsecret fingerprint of the effective Resend credential, endpoint, and provider configuration revision. Reconcile uncertain sends before changing those settings. Changed contexts and legacy attempted rows with no saved context fail closed; approving a new provider configuration does not authorize replaying old uncertain sends.

## Checkout network caps and client IP

Public checkout limits how many tickets one network can hold or take free per event. Guam carrier NAT and venue Wi-Fi put many real buyers behind one address, so both caps start loose or off and every denial is logged for tuning.

- **Client address.** `ClientIp` reads `CF-Connecting-IP`, then `True-Client-IP`, then Rails `remote_ip`, ignoring malformed values. Rack::Attack IP throttles and the checkout caps both use it. IPv6 clients are grouped by their /64 prefix. Orders store only an HMAC of the network (`orders.checkout_ip_digest`), never the address.
- **`HAFAPASS_MAX_HELD_TICKETS_PER_IP`** (default `60`): the most tickets one network may hold in live, unexpired checkouts for one event. Expired or released holds do not count. Set `0` to turn it off.
- **`HAFAPASS_MAX_FREE_TICKETS_PER_IP`** (default `0`, off): when set to a positive number, the most free tickets one network may receive for one event in a rolling one-hour window.
- **Tuning.** A denial writes a `checkout_network_cap_denied` warning log line with the cap name, limit, current count, requested quantity, event ID and a digest prefix. Sentry gets a "Checkout network cap denied a buyer" warning at most once per cap and event every 10 minutes per process. Review those before lowering a cap. Invalid or negative values fall back to the default. Changing either variable needs a redeploy or restart.
- One buyer (email, or signed-in account) may have only one live unpaid checkout per event, whatever the network.

Hold expiry (`ExpireInventoryHoldsJob`, every minute) checks Stripe before releasing an order with a payment, with a 5-second limit per check. After 45 seconds of work in one run it leaves the remaining orders for the next run and logs `order_expiry_budget_exhausted`. Holds stop counting against inventory when they expire whether or not the job has reached them yet.
