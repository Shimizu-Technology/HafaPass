# Production cutover: one Render service, one Neon database

Status: written 2026-10-21 for the move of the existing Render API service
(`hafapass-api`, currently `RAILS_ENV=staging`) and Neon database
(`hafapass_staging`) to production. The Netlify site moves from
`https://hafapass.netlify.app` to `https://hafapass.shimizu-technology.com`.

This is an ordered checklist. It lists environment variable **names** only.
Put values in the Render and Netlify encrypted environment stores, never in
source, chat or screenshots.

Related: [Changing the public domain](DOMAIN_CUTOVER.md),
[Operations runbook](OPERATIONS_RUNBOOK.md),
[Gate C production environment](GATE_C_PRODUCTION_ENVIRONMENT.md).

## What changes when the service runs as production

| Area | Staging today | Production |
|---|---|---|
| Boot checks | `StageSafety.validate!` (staging DB name, Clerk `pk_test_`, no live Stripe keys, rehearsal allowlists) | `StageSafety` no longer runs. Boot fails only on the items in [Boot failures](#boot-failures). |
| Database config | `STAGING_DATABASE_URL` | `DATABASE_URL`. The Neon database can keep the name `hafapass_staging`; production does not check the name. |
| Payments | Simulation, or Stripe test mode only with provider rehearsal | Test or live, chosen by an admin in **Admin → Settings → Payment mode**. Live needs every live credential plus an approved `stripe_live` capability. Paid checkout in simulation mode is refused. |
| Provider rehearsal | `HAFAPASS_PROVIDER_REHEARSAL` turns on Stripe test / Resend allowlists | Ignored, and **boot fails** if it is true. |
| Email | Simulated, or Resend to rehearsal recipients | Real Resend email, but only after the `resend_production` capability is approved. Until then every email fails as "Production email is disabled". |
| Checkout | Open | Refused until the `policy_register` capability is approved. |
| Event release gates | Not enforced | Each event needs current Gate E (pilot readiness), F (validation), G (event-day rehearsal), H (live money, paid events only) and I (bounded live pilot) approvals, plus a started Gate I run, before it can be published or sold. One admin may submit and approve each. |
| Paid test-mode tickets | Valid for QA | Orders complete, but tickets paid in Stripe test mode are not admissible at the door (production admission requires a live Stripe payment). Free tickets work. |
| Ticket PDFs | "TEST TICKET - REHEARSAL ONLY" | "EVENT TICKET" |
| "Test" banner | Always shown | Shown only while payments are in test mode; hidden once live. |
| Clerk | Requires `pk_test_`/`sk_test_` | Accepts either. Use the Clerk **production** instance (`pk_live_`/`sk_live_`). `CLERK_AUTHORIZED_PARTIES` must be set explicitly (no fallback to `ALLOWED_ORIGINS`) and contain only HTTPS origins. |
| Sentry | Environment `staging` | Environment `production` (or `SENTRY_ENVIRONMENT`). |

Approvals no longer need two administrators. One admin may submit and approve
any review (provider capabilities, Gate B payment readiness, Gates E–J). The
audit log records who submitted, who approved and when. A two-person rule may
return later as an optional setting.

## Do not do these while the service is still staging

`StageSafety` refuses to boot a staging deploy when:

- `STRIPE_LIVE_SECRET_KEY` or `STRIPE_LIVE_PUBLISHABLE_KEY` is set, or any
  Stripe key variable holds a `sk_live_`/`rk_live_`/`pk_live_` value;
- `CLERK_PUBLISHABLE_KEY`/`CLERK_SECRET_KEY` are Clerk live keys.

Adding those while `RAILS_ENV=staging` makes the next deploy fail (Render keeps
the previous instance running). Add them in the same batch as
`RAILS_ENV=production` (step 4). `STRIPE_LIVE_PLATFORM_ACCOUNT_ID` and
`STRIPE_LIVE_WEBHOOK_SECRET` are safe to add early.

## Checklist

### 1. Before anything else

1. Merge and deploy the release that contains this document while still on staging. Confirm `/up` and `/api/v1/health` respond.
2. Create a Neon backup branch of the current database (needed before the purge in step 7).
3. Confirm `DATABASE_URL` is the Neon **pooled** host (`…-pooler…neon.tech`) and `DATABASE_MIGRATION_URL` is the **direct** host for the same database. `bin/release-migrate` refuses a pooled migration URL. Prepared statements are now off for deployed connections (`config/database.yml`), which fixes `PG::FeatureNotSupported: cached plan must not change result type` after migrations.

### 2. Clerk production instance

1. Create the Clerk production instance for `hafapass.shimizu-technology.com` (Clerk production needs a domain you control, not `netlify.app`).
2. Add the frontend origin to allowed origins and redirect URLs.
3. Note the new publishable key, secret key and issuer (`https://clerk.<domain>` style).
4. Users are matched by Clerk user ID, not email. The production instance issues new IDs, so each person's first production sign-in creates a new user row. `ADMIN_EMAILS` (checked against Clerk-verified addresses) makes the admin's new row an administrator. The old development-instance rows stay but can no longer sign in.

### 3. Stripe

1. In live mode, create a webhook endpoint `https://<PUBLIC_API_URL host>/webhooks/stripe` with: `payment_intent.succeeded`, `payment_intent.processing`, `payment_intent.payment_failed`, `payment_intent.canceled`, `charge.updated`, `charge.refunded`, `charge.refund.updated`, `refund.created`, `refund.updated`, `refund.failed`, `charge.dispute.created`, `charge.dispute.updated`, `charge.dispute.closed`. Keep the existing test-mode endpoint.
2. Its signing secret becomes `STRIPE_LIVE_WEBHOOK_SECRET`. The test endpoint's secret stays in `STRIPE_WEBHOOK_SECRET`. The API checks a signed event's `livemode` and verifies it with the matching secret, so both endpoints can share one URL.
3. Note the live platform account ID (`acct_…`, Shimizu Technology's account) for `STRIPE_LIVE_PLATFORM_ACCOUNT_ID`. The switch to live confirms the live secret key really belongs to that account.

### 4. Render environment (one batch, then deploy)

Change:

- `RAILS_ENV` → `production` (in the `hafapass-staging-runtime` group or on the service)
- `HAFAPASS_PROVIDER_REHEARSAL` → `false`, or delete it (**boot fails if true in production**)
- `CLERK_PUBLISHABLE_KEY`, `CLERK_SECRET_KEY` → Clerk production keys
- `CLERK_ISSUER` → the production issuer, or delete it (derived from the publishable key). Delete `CLERK_JWKS_URL` if set, or point it at the production issuer.
- `CLERK_AUTHORIZED_PARTIES` → `https://hafapass.shimizu-technology.com` (plus `https://hafapass.netlify.app` during the move). Required in production.
- `ALLOWED_ORIGINS` → the same origins
- `FRONTEND_URL`, `PUBLIC_WEB_URL` → `https://hafapass.shimizu-technology.com`
- `PROVIDER_CONFIGURATION_REVISION` → a new value (increase it whenever provider settings change; approvals are bound to it)

Add (if not already present):

- `STRIPE_TEST_SECRET_KEY`, `STRIPE_TEST_PUBLISHABLE_KEY`, `STRIPE_TEST_PLATFORM_ACCOUNT_ID`, `STRIPE_WEBHOOK_SECRET`
- `STRIPE_LIVE_SECRET_KEY`, `STRIPE_LIVE_PUBLISHABLE_KEY`, `STRIPE_LIVE_PLATFORM_ACCOUNT_ID`, `STRIPE_LIVE_WEBHOOK_SECRET`
- `RESEND_API_KEY`, `RESEND_WEBHOOK_SECRET`, `MAILER_FROM_EMAIL` (verified Resend domain); optional `MAILER_REPLY_TO`
- `SENTRY_DSN`; optional `SENTRY_ENVIRONMENT`
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_BUCKET`, `AWS_REGION`
- `ADMISSION_MANIFEST_PRIVATE_KEY_PEM` (RSA ≥ 2048-bit)

Keep as they are:

- `DATABASE_URL` (pooled), `DATABASE_MIGRATION_URL` (direct), `SECRET_KEY_BASE`, `PUBLIC_API_URL` (only this host is accepted; change it only if the API gets its own domain), `ADMIN_EMAILS`, `ENABLE_FIRST_USER_ADMIN_BOOTSTRAP=false`, `HAFAPASS_LAUNCH_SCOPE=general_admission`, `HAFAPASS_RUNTIME=embedded`, `RAILS_MAX_THREADS=3`, `DB_POOL=10`

Remove after the production deploy is healthy (unused in production):

- `STAGING_DATABASE_URL`, `STAGING_REDIS_URL`, `PROVIDER_REHEARSAL_SERVICES`, `PROVIDER_REHEARSAL_EMAIL_RECIPIENTS`
- `STRIPE_SECRET_KEY`, `STRIPE_PUBLISHABLE_KEY` (deprecated test-mode fallbacks; remove once the `STRIPE_TEST_*` pair is set)

If the service is managed by the `render.yaml` Blueprint, a Blueprint sync would
put `RAILS_ENV=staging` back. Update `render.yaml` (`RAILS_ENV: production`,
`HAFAPASS_PROVIDER_REHEARSAL: 'false'`, the new keys as `sync: false`) in the
same change, or confirm the service is not Blueprint-synced.

### 5. Netlify (then trigger a fresh build; `VITE_` values are baked in)

- `VITE_CLERK_PUBLISHABLE_KEY` → Clerk production publishable key (must match the API's `CLERK_PUBLISHABLE_KEY`)
- `VITE_API_URL` → `https://<PUBLIC_API_URL host>/api/v1`
- `VITE_PUBLIC_WEB_URL` → `https://hafapass.shimizu-technology.com`
- `VITE_SENTRY_ENVIRONMENT` → `production`; `VITE_SENTRY_DSN` if frontend Sentry is used
- `HAFAPASS_API_ORIGIN` (edge functions) → `https://<PUBLIC_API_URL host>`
- optional `VITE_SUPPORT_EMAIL`

The Stripe publishable key is not a Netlify variable. The browser gets the key
for the current payment mode from `/api/v1/config`.

### 6. Deploy and check

1. Deploy. Render's health check is `/up` (boot only).
2. `/api/v1/health` returns the deployed commit.
3. `/api/v1/readiness` reports what is still missing. It stays `503` until the approvals in step 8 exist; that does not block traffic.
4. `/api/v1/config` returns `"environment":"production"`.

### 7. Remove the synthetic test data

After the Neon backup branch exists, run once as a Render job:

```
CONFIRM=PURGE_SYNTHETIC_DATA KEEP_USER_EMAILS=shimizutechnology@gmail.com bin/rails hafapass:purge_synthetic_data
```

Run it after the admin has signed in once through the production Clerk
instance (step 2), so the admin's new user row exists; rows sharing a kept
email are all kept. It empties every business table in one transaction and keeps
`schema_migrations`, `ar_internal_metadata`, `site_settings`, queue/runtime
tables and the listed users. It refuses, changing nothing, if any payment was
charged in live mode or any settlement or payout exists. It prints before/after
counts and writes one `operations.synthetic_data_purged` audit entry. Uploaded
files in S3 and Clerk accounts of deleted users are not touched.

### 8. Approvals (Admin → Provider readiness; one admin may submit and approve)

1. **Production policy register** (`policy_register`): checkout is refused until approved.
2. **Resend production email** (`resend_production`): all email fails until approved.
3. **Stripe live payments** (`stripe_live`): needed before switching to live. It can only be submitted once every live Stripe variable is set and the service runs as production.
4. Organizer payout readiness (Gate B) for each paid organizer.
5. Per event: Gates E, F, G, H (paid events), I, then start the Gate I run.

### 9. Payment mode

1. **Admin → Settings → Payment mode** shows the current mode and a checklist for each other mode.
2. Switch to **test mode** first and run a test purchase (remember: paid test tickets are not admissible in production).
3. When the live checklist is all green, choose **Switch to live payments** and confirm. Every switch is audited with the admin, time and platform account.
4. Orders keep the mode they were charged in. Refunds, fee lookups and webhooks for an old test order keep using test credentials after the switch, and the reverse.

## Boot failures

A production boot stops on:

- `HAFAPASS_PROVIDER_REHEARSAL` true (`config/environments/production.rb`)
- `PUBLIC_API_URL` missing or not an exact HTTPS origin (host authorization)
- `ALLOWED_ORIGINS` empty (CORS)
- `FRONTEND_URL` or `PUBLIC_WEB_URL` missing or not HTTPS (`PublicSiteUrl.validate!`)
- unknown `HAFAPASS_LAUNCH_SCOPE` or `HAFAPASS_LAUNCH_CAPABILITIES` values
- `DB_POOL` smaller than the request/job threads, or an unknown `HAFAPASS_RUNTIME`
- `REDIS_URL` missing when `HAFAPASS_RUNTIME` is `sidekiq` (not the case with `embedded`)
- `SECRET_KEY_BASE` missing

Everything else (Clerk, Sentry, Resend, Stripe, S3, admission signing) is a
readiness check: the service boots, `/api/v1/readiness` names the gap, and the
dependent feature refuses to run.
