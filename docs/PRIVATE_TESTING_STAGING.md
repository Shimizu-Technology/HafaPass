# Private testing runtime

`RAILS_ENV=staging` runs production loading and logging, a separate Sidekiq worker and singleton commerce clock, HTTPS enforcement, and Clerk authentication. By default it supports free registrations and simulated payments against test data. The optional controlled provider rehearsal below permits Stripe test payments and real email to an explicit tester list. It defaults to general admission. `/api/v1/config` reports `environment: "staging"`, which the existing interface displays as a test environment.

This change defines the runtime contract. It does not provision a staging host, publish a frontend, create a Clerk instance, send real email, or establish payment-provider approval.

## Separate configuration and data

Use a dedicated staging database and Redis instance/database. Start with synthetic events, orders, identities and attendees. Do not copy production personal data, payment identifiers, approvals, or queues. Use a separate Clerk development instance and test accounts. Its secret key stays on the backend; only its matching publishable key is included in the frontend build.

Supply these variables from the deployment's secret/configuration store:

| Variable | Requirement |
| --- | --- |
| `RAILS_ENV` | `staging` |
| `DATABASE_URL`, `STAGING_DATABASE_URL` | Identical PostgreSQL URLs pointing to a dedicated database whose name contains `staging` |
| `DATABASE_MIGRATION_URL` | Direct connection to the same dedicated staging database, used only by the release command; never a transaction-pooled hostname |
| `RAILS_MAX_THREADS`, `SIDEKIQ_CONCURRENCY`, `DB_POOL` | Initially `3`, `3`, `5`; pool must cover both concurrency values |
| `REDIS_URL`, `STAGING_REDIS_URL` | Identical dedicated Redis URLs with an explicit nonzero database number; use TLS on remote infrastructure |
| `CLERK_SECRET_KEY`, `CLERK_PUBLISHABLE_KEY` | Matching valid `sk_test_` and `pk_test_` keys from the separate Clerk test instance |
| `CLERK_ISSUER` | HTTPS origin matching the host encoded in that publishable key |
| `CLERK_JWKS_URL` | Omit; if supplied, must be that issuer's `/.well-known/jwks.json` |
| `FRONTEND_URL`, `PUBLIC_WEB_URL` | Staging frontend HTTPS origins |
| `PUBLIC_API_URL` | Staging API HTTPS origin; its hostname is the allowed Rails host |
| `ALLOWED_ORIGINS` | Exact HTTPS frontend origins, comma separated; include `FRONTEND_URL` |
| `CLERK_AUTHORIZED_PARTIES` | Omit to use `ALLOWED_ORIGINS`, or supply a subset containing `FRONTEND_URL` |
| `ENABLE_FIRST_USER_ADMIN_BOOTSTRAP` | `false` |
| `ADMIN_EMAILS` | Approved testers' verified Clerk email addresses for initial administrator access |
| `HAFAPASS_LAUNCH_SCOPE` | Omit or set `general_admission` |
| `SECRET_KEY_BASE` | A separate random staging secret longer than 64 characters; retain it across restarts and deploys |
| `GIT_SHA` | Exact deployed commit |
| `ADMISSION_MANIFEST_PRIVATE_KEY_PEM` | A required RSA private staging signing key of at least 2048 bits; retain the same key across web/worker restarts and deploys |

Database naming and explicit URL matching catch common accidental reuse. Operators must also verify that the selected hosts, database and Redis credentials are separate from production. A name is not proof of isolation. A shared Redis database can mix queues and worker registration and invalidate readiness.

Do not supply Stripe live credentials. Boot rejects live keys in both the live slots and generic/test aliases. Staging disables production provider capabilities even if stale keys and approval records exist: production Resend delivery, Stripe live, Clover, Apple Wallet and Google Wallet. With provider rehearsal off, Stripe test API calls are blocked and `SiteSetting.payment_mode` must stay at `simulate`. With a valid Stripe rehearsal configuration, that setting must be `test` instead. Readiness checks the selected mode. Payout submission is disabled in both arrangements, including simulated marking of payouts as paid.

S3 is optional for this release. Without its credentials, authenticated upload signing returns an unavailable response; the API can still boot. If image uploads are needed, use a separate staging bucket and scoped credentials. Do not invent credentials to satisfy readiness.

Configure a bucket lifecycle rule expiring the `pending/` prefix after one day and aborting incomplete multipart uploads. Completion deletes its pending source only after the immutable-copy receipt commits; denied or failed cleanup is logged and left for that lifecycle rule. Abandoned or invalid uploads also require lifecycle expiry. Keep final `uploads/` objects outside that rule. This document does not mutate AWS configuration. Completion tokens expire after 15 minutes; retries within that authorization window return the recorded URL and never allocate another destination, even after a copy timeout.

Production requires `CLERK_AUTHORIZED_PARTIES` explicitly, independently of CORS `ALLOWED_ORIGINS`. Supply the exact trusted HTTPS frontend origins before deploying this change or authentication fails closed. Staging may use the documented `ALLOWED_ORIGINS` fallback. An unrelated CORS expansion must not expand production token authority.

Attendee CSV downloads quote all fields and prepend a tab to formula-like values, including full-width variants. This follows [OWASP's Excel-resistant guidance](https://community.owasp.org/attacks/CSV_Injection); the protective tab remains in exported data. These exports are for viewing in spreadsheets. Source attendee records are unchanged. No CSV strategy is universal across every application and downstream transformation; retain protection when re-exporting and do not strip tabs from untrusted fields.

## Build and run

Select the reviewed commit in an isolated checkout and record that same SHA in `GIT_SHA`. Inject the staging configuration before these backend commands:

```sh
cd hafapass_api
bundle install
RAILS_ENV=staging bin/release-migrate
RAILS_ENV=staging bundle exec rails runner 'puts StageSafety.call(runtime: true).to_json'
RAILS_ENV=staging bundle exec puma -C config/puma.rb
```

Builds install dependencies only. Run `bin/release-migrate` once from the web service's release/pre-deploy command, using a direct `DATABASE_MIGRATION_URL` for the same dedicated staging database. The wrapper requires the same database path, endpoint host and port; for Neon, only its matching `-pooler`/direct hostname pair is accepted. A dedicated migration database role is permitted. It replaces both database aliases inside that release process. Keep the pooled application URL on web, worker and clock; no process start command migrates. Rails PostgreSQL advisory locking protects overlapping release tasks.

Set `RAILS_MAX_THREADS=3`, `SIDEKIQ_CONCURRENCY=3` and `DB_POOL=5` initially. The shared configuration rejects invalid capacity or a pool smaller than request/job concurrency. Measure the total database connection budget across all three services before increasing it.

Start the worker as a separate supervised process with the same environment and revision:

```sh
cd hafapass_api
RAILS_ENV=staging bundle exec sidekiq -C config/sidekiq.yml
```

Start the singleton clock as a third supervised process with the same environment and revision:

```sh
cd hafapass_api
RAILS_ENV=staging bundle exec rails runner script/commerce_clock.rb
```

Its renewable Redis lease prevents duplicate expiry authorities. Staging readiness fails when the clock is absent, so the hosted rehearsal tests inventory expiry as well as queued delivery.

Configure the TLS reverse proxy and trusted network path so Rails receives the correct HTTPS scheme. The API accepts only its configured hostname. Keep private testing access limited to the selected testers at the hosting layer; application authentication and organization permissions remain enforced.

Build the frontend with `VITE_CLERK_PUBLISHABLE_KEY` set to the matching test key and `VITE_API_URL` set to the staging API URL including `/api/v1` (for example, `https://api-staging.hafapass.example/api/v1`). Serve the production build at the configured frontend HTTPS origin. No live backend secret belongs in a `VITE_` variable.

Use the repository's development lifecycle helper to claim each local server or test browser tab when running QA. Stop only owned resources after each QA phase. Host services require an explicit operator deployment and supervision plan; none were started by this documentation.

## Acceptance and remaining proof

Check `/api/v1/readiness`: staging requires its safe configuration, connected database, connected Redis, the selected simulation/test payment mode, Sidekiq adapter, a registered worker and an active clock lease. It intentionally does not convert unavailable production approvals into success. Production capability readiness remains visible and disabled. Liveness alone does not confirm a usable release.

Complete the organizer → free/simulated checkout → confirmation → ticket download → admission journey with actual Clerk test accounts. Repeat it on desktop and mobile, and verify that users cannot read another organizer's records. Check missing storage, duplicate/canceled tickets, reload and outage recovery. Actual physical phones and venue connectivity remain separate proof.

Ordinary staging simulates email and its delivery history says so. An actual inbox/recovery-link test requires the controlled Resend rehearsal below. A simulated message is not email-delivery evidence.

## Controlled provider rehearsal

Keep the dedicated staging data, queue, Clerk test instance, signing keys and HTTPS origins described above. Use separate staging services; the production defaults in `render.yaml` do not configure this runtime.

Set `HAFAPASS_PROVIDER_REHEARSAL=true` and `PROVIDER_REHEARSAL_SERVICES` to `stripe`, `resend`, or `stripe,resend`. Supply every requirement for each selected provider; a partially configured selection fails boot validation. Production rejects the rehearsal flag.

| Selected provider | Required private/configuration values |
| --- | --- |
| Stripe | `STRIPE_TEST_SECRET_KEY` (`sk_test_` or `rk_test_`), matching `STRIPE_TEST_PUBLISHABLE_KEY` (`pk_test_`), exact `STRIPE_TEST_PLATFORM_ACCOUNT_ID`, `STRIPE_WEBHOOK_SECRET`, and `PROVIDER_CONFIGURATION_REVISION` |
| Resend | Domain-scoped sending `RESEND_API_KEY`, verified `MAILER_FROM_EMAIL`, `RESEND_WEBHOOK_SECRET`, `PROVIDER_CONFIGURATION_REVISION`, and `PROVIDER_REHEARSAL_EMAIL_RECIPIENTS` containing one to ten authorized tester email addresses |

Set the staging database's `SiteSetting.payment_mode` to `test` when Stripe is selected, or `simulate` otherwise. This database setting is separate from the environment variables: boot validation can pass while runtime readiness correctly fails on the wrong payment mode.

Stripe calls bind the original test platform account and accept only card payments; signed callbacks must describe test-mode objects. This exercises real Stripe test transport without real-money sales. Resend sends actual messages with a test subject marker. All frozen `to`, `cc` and `bcc` recipients must match the tester list; changing the list cannot redirect an existing message. Subscribe the staging provider endpoints to the required signed events and verify delivery through the durable worker, callback history and recipient inbox.

Record the exact deployed commit on web, worker, clock and frontend. Test decline/retry/reload, lost responses, duplicate callbacks, confirmation/recovery links, delivery failures and provider outcome reconciliation. This rehearsal grants no production capability approval, live payment permission or organizer payout eligibility.

AWS deployment, verified Resend delivery, production provider approval, authorized live charge/refund/settlement/bank receipt, backup restore, operational alerts, production load, and physical venue/device tests remain pending. Passing staging readiness permits the bounded simulation runtime; it does not declare paid public launch ready.


The unreleased `20261010080000` migration also installs keyed checkout attempts alongside the frozen email transport context. It must run before deploying checkout recovery. Each browser key is claimed before validation, bound to the complete request and authenticated identity using digests, and attached to the order in the inventory reservation transaction before provider calls. An interrupted owner can be replaced after its two-minute lease; a stale owner must pass the lease fence before reserving. Rejected keys are permanent tombstones and must not be purged or revived. No buyer payload or raw recovery key is stored in this journal.

A keyed checkout error includes `checkout_recovery_required: false` only after final rejection is committed and the old owner is fenced. In-progress, reserved, mismatched or unknown outcomes retain the original key and request; missing metadata also means retain them. An exact replay recovers the original order before requiring a new terms acceptance; current event, policy and payment confirmation gates still apply. Browser checks must cover an initial validation error followed by a corrected new checkout, lost responses, edited fields during recovery, and a delayed original request after rejection or lease takeover.
