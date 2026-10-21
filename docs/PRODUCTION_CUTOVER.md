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
| Payments | Simulation, or Stripe test mode only with provider rehearsal | Test or live, chosen by an admin in **Admin → Settings → Payment mode**. Live needs every live credential plus an approved `stripe_live` capability. Simulation is not offered; if the database still says simulate, paid sales are off until an admin picks test or live. |
| Provider rehearsal | `HAFAPASS_PROVIDER_REHEARSAL` turns on Stripe test / Resend allowlists | Ignored, and **boot fails** if it is true. |
| Email | Simulated, or Resend to rehearsal recipients | Real Resend email, but only after the `resend_production` capability is approved. Until then every email fails as "Production email is disabled". |
| Checkout | Open | Refused until the production policy register is approved (one click on the admin dashboard). |
| Selling | Verification required to publish | One gate: HåfaPass **verifies the organizer** (one admin action on the admin dashboard). Unverified organizers may publish, but tickets don't sell until verified. Organizers press **Request verification**; admins get an email and see the request on the dashboard. Setting the organizer to suspended ("Pause all sales") stops every event of theirs from selling; an admin can also pause a single event. Paid tickets also need test or live payments turned on and the organizer's payout details on file. Verification is not tied to deploys or event edits. |
| Launch-gate reviews (Gates E–J) | Optional | Still available as optional records in the admin pages; they never block publishing or sales. |
| Paid test-mode tickets | Valid for QA | Only platform admins can buy them (with Stripe test cards). They work at the door while payments stay in test mode, stop working after the switch to live, and are never counted in revenue, analytics, exports, settlements or payouts. |
| Ticket PDFs | "TEST TICKET - REHEARSAL ONLY" | "EVENT TICKET" |
| "Test" banner | Always shown | Shown only while payments are in test mode; hidden once live. |
| Clerk | Requires `pk_test_`/`sk_test_` | Accepts either. Use the Clerk **production** instance (`pk_live_`/`sk_live_`). `CLERK_AUTHORIZED_PARTIES` must be set explicitly (no fallback to `ALLOWED_ORIGINS`) and contain only HTTPS origins. |
| Sentry | Environment `staging` | Environment `production` (or `SENTRY_ENVIRONMENT`). |

Approvals no longer need two administrators. One admin may submit and approve
any review (provider capabilities, Gate B payment readiness, the optional
Gates E–J). The audit log records who submitted, who approved and when. A
two-person rule may return later as an optional setting.

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
- `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`, `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`: required before the production deploy, on the web service and any job service, even before any W-9 is collected; production refuses to boot without them. Generate each as a random 32-character value, keep them stable and backed up securely, never log them, and never replace them without a key-rotation plan. Staging can boot without them but cannot store tax information.

Keep as they are:

- `DATABASE_URL` (pooled), `DATABASE_MIGRATION_URL` (direct), `SECRET_KEY_BASE`, `PUBLIC_API_URL` (only this host is accepted; change it only if the API gets its own domain), `ADMIN_EMAILS`, `ENABLE_FIRST_USER_ADMIN_BOOTSTRAP=false`, `HAFAPASS_LAUNCH_SCOPE=general_admission`, `HAFAPASS_RUNTIME=embedded`, `RAILS_MAX_THREADS=3`, `DB_POOL=10`

Remove after the production deploy is healthy (unused in production):

- `STAGING_DATABASE_URL`, `STAGING_REDIS_URL`, `PROVIDER_REHEARSAL_SERVICES`, `PROVIDER_REHEARSAL_EMAIL_RECIPIENTS`
- `STRIPE_SECRET_KEY`, `STRIPE_PUBLISHABLE_KEY` (deprecated test-mode fallbacks; remove once the `STRIPE_TEST_*` pair is set)

`render.yaml` now declares `RAILS_ENV: production`,
`HAFAPASS_PROVIDER_REHEARSAL: 'false'` and the Stripe keys (`sync: false`), so a
Blueprint sync matches this checklist. It no longer lists `STAGING_DATABASE_URL`.

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
instance (step 2), so the admin's new user row exists. Run it before the approvals and the test-mode purchase below, so that only real data remains; rows sharing a kept
email are all kept. It empties every business table in one transaction and keeps
`schema_migrations`, `ar_internal_metadata`, `site_settings`, queue/runtime
tables and the listed users. It refuses, changing nothing, if any payment was
charged in live mode, any settlement or payout exists, no kept user is an
admin, payments are already live, or a purge already ran (set
`ALLOW_REPEAT_PURGE=YES` to run it again). IDs are not reset, and queued or
failed jobs are deleted while recurring task definitions stay. It prints before/after
counts and writes one `operations.synthetic_data_purged` audit entry. Uploaded
files in S3 and Clerk accounts of deleted users are not touched.

### 8. One-time setup on the admin dashboard

The admin dashboard shows a red banner for each item that still blocks
production, with an **Approve now** button (one admin, one click, audited):

1. **Production policy register**: checkout is off until approved. While the policies are still drafts, tick the acknowledgment ("I'm approving these draft policies for launch before legal review…"); it is recorded on the approval and in the audit log. Unfilled placeholders block approval. A new policy version needs a new approval.
2. **Production email (Resend)**: ticket and order emails are off until approved. The button stays disabled until the Resend variables are set.

These one-click approvals last a year. Thirty days before they expire, the
dashboard shows an amber banner and `/api/v1/readiness` reports
`expiring_soon`; approve again then.

**Stripe live payments** (`stripe_live`) keeps its evidence form in Admin →
Provider readiness. Submit and approve it yourself once every live Stripe
variable is set and the service runs as production.

### 9. Test-mode QA purchase (admin only)

1. **Admin → Settings → Payment mode** → **Switch to test mode**.
2. While in test mode only platform admins can buy paid tickets; everyone else sees "Paid ticket sales open soon". Free tickets work for everyone.
3. As the admin, buy a paid ticket with a Stripe test card (for example 4242 4242 4242 4242; real cards are declined in test mode) and scan it at the door. Test tickets are admitted while the platform stays in test mode.
4. Test-paid orders appear in order lists marked **Test** and are never counted in revenue, analytics, exports, settlements or payouts.

### 10. Switch to live payments

1. When the live checklist is all green (use **Check again** after changing Render settings), choose **Switch to live payments** and confirm. Every switch is audited with the admin, time and platform account.
2. From then on real cards are charged, and tickets bought with test cards stop working at the door.
3. **Door staff: refresh the scanner (re-download the event) after every mode switch.** The offline manifest records the payment mode, so a switch produces a new manifest version.
4. Orders keep the mode they were charged in. Refunds, fee lookups and webhooks for an old test order keep using test credentials, and the reverse.

### 11. Verify real organizers

1. Organizers can publish before they are verified (to preview and share); their events show "Visible but not on sale yet" and cannot sell. They press **Request verification**; admins get an email (sent once a day at most) and see them under **Organizers waiting for verification** on the admin dashboard, which is the source of truth (an organizer with no events yet appears there but is not emailed).
2. Press **Verify** (optional note). Their published events can sell right away; free events follow the same rule.
3. **Pause all sales** on a verified organizer stops every event of theirs from selling (events stay visible); they appear under **Sales paused** with **Resume sales**. Pause a single event from Admin → Events (**Pause sales** / **Resume sales**). Admin → Events also shows **Resume sales** for any event whose sales a bounded-pilot run paused.
4. Paid tickets also need payout details on file (Settings → Payouts).

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

## Note on earlier approvals

The `stripe_live` capability fingerprint now covers `STRIPE_LIVE_PLATFORM_ACCOUNT_ID` and `STRIPE_LIVE_WEBHOOK_SECRET`. Any `stripe_live` approval recorded before this release no longer matches and must be submitted and approved again. No deployed environment was in live mode when this changed.

## Legal/tax safeguards rollout

Apply `20261022000100_create_organizer_tax_informations` before serving the new
API. The new table is additive and does not populate or approve any organizer's
W-9. Existing organizers need completed tax information before payout readiness;
saving tax details invalidates all payout-method approval revisions.

The draft policy version stays `2026-10-launch-draft`, but its content and registry
digests change. Existing `policy_register` capability approvals no longer match.
Review Provider readiness and complete the applicable policy-register review
through the existing workflow before expecting paid-sale readiness. Engineering
drafts and product controls do not constitute counsel/accountant approval.
