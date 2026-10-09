# Hosted backend deployment

Status: configuration prepared. Neither this document nor `render.yaml` creates services, database resources, credentials or approvals.

The existing API is `hafapass-api`, service `srv-d6bsuq0gjchc73fu35hg`, in Singapore, using Docker and the Starter/$7 tier. This inventory was checked on 2026-10-09; re-check its state and ownership before applying changes. The Blueprint keeps its name, region, runtime and root directory, and omits its plan so Render retains the existing tier. It adds a worker, clock and paid persistent queue. Those are additional billed services; the $7 API tier does not include them. Netlify, Neon and the existing S3 storage remain external to this Blueprint.

## Services and release ownership

| Service | Command and responsibility |
| --- | --- |
| `hafapass-api` | `bundle exec puma -C config/puma.rb`; web requests; sole migration owner through `bin/release-migrate`; platform health `/up` |
| `hafapass-worker` | `bundle exec sidekiq -C config/sidekiq.yml`; sole queue execution owner |
| `hafapass-commerce-clock` | `bundle exec rails runner script/commerce_clock.rb`; singleton scheduling protected by a renewable Redis lease |
| `hafapass-production-queue` | Dedicated `256mb` Key Value instance, `journal-snapshot` persistence, `noeviction`, no external IP access |

All application services use the backend Dockerfile and the same reviewed commit. `rootDir` is `hafapass_api`; Dockerfile/context paths are relative to it. Builds and application startup do not migrate. Start/pre-deploy commands set `GIT_SHA` from their actual `RENDER_GIT_COMMIT`. Automatic deployments and previews are off to allow a coordinated release; the Blueprint does not provide atomic deployment across services.

Initial capacity is one Puma process, three request threads, three worker threads and five database connections per process. Budget all three pools, release connections and overlapping deployments against Neon. The clock's expiry/fee jobs can keep database compute active; do not claim scale-to-zero savings while they run. Measure memory, checkout latency, connection use and queue latency before resizing.

## Adopt the existing API

Render attempts to configure an existing service with the same name. Inspect the sync preview before applying: it must target `srv-d6bsuq0gjchc73fu35hg`, retain Singapore and the current API tier, and create only the named worker, clock and queue. Stop if it proposes a duplicate API, wrong account, region change, unrelated mutation or deletion. Resuming a user-suspended service requires the authorized deployment decision. Confirm the complete incremental budget in the preview.

`sync: false` prompts apply only during initial Blueprint creation. Later syncs ignore them; missing values must be supplied privately on the existing service. Worker/clock `fromService` references update on Blueprint sync, not immediately on credential rotation. Rotate deliberately, resync, redeploy the aligned services and update `PROVIDER_CONFIGURATION_REVISION`. Do not expose configuration values in evidence or source.

## Configuration

The shared environment group contains non-secret runtime defaults. Supply private values to the API; worker/clock reference the same values. Only the API receives `DATABASE_MIGRATION_URL`.

| Group | Contract |
| --- | --- |
| Database | `DATABASE_URL`: Neon pooled URL with TLS. `DATABASE_MIGRATION_URL`: direct TLS URL copied from the same endpoint/database. The release wrapper checks host, normalized port and database path, permitting only Neon's matching `-pooler`/direct hostname difference. A dedicated migration role is allowed. Matching `neondb` names alone do not establish identity. |
| Redis | Dedicated private connection string, reviewed persistence/eviction/access, and internal authentication enabled before production. Resync connection references after enabling authentication. Any external connection needs TLS and restricted access. |
| Signing | Dedicated persistent `SECRET_KEY_BASE` and stable RSA `ADMISSION_MANIFEST_PRIVATE_KEY_PEM`, shared across aligned services; never regenerate on every boot. |
| Identity | Matching `CLERK_SECRET_KEY`, `CLERK_PUBLISHABLE_KEY`, `CLERK_ISSUER` and exact trusted HTTPS `CLERK_AUTHORIZED_PARTIES`. First-user bootstrap remains disabled. |
| Routing | Actual HTTPS `PUBLIC_API_URL` (prepared value `https://hafapass-api.onrender.com`), `FRONTEND_URL`, `PUBLIC_WEB_URL`, and exact `ALLOWED_ORIGINS`. Backend API origin has no `/api/v1`; frontend `VITE_API_URL` includes it. Change the API origin deliberately for a custom domain. |
| Administrators | Approved verified Clerk addresses in `ADMIN_EMAILS`; this grants an initial role only to new local users. Provision two approved administrators and explicitly verify existing users' roles and denial boundaries. |
| Monitoring | Backend `SENTRY_DSN` and separate frontend DSN/environment/release. Configure primary/backup routing, uptime, queue and commerce/delivery alerts; a nonempty DSN is not delivery proof. |
| Images | Authorized existing bucket and scoped `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_BUCKET`, `AWS_REGION`. The inspected image bucket is in `ap-southeast-2`; verify deployed configuration, lifecycle and actual upload/image-read behavior. |
| Email | Dedicated `RESEND_API_KEY`, verified `MAILER_FROM_EMAIL`, `RESEND_WEBHOOK_SECRET`, and `PROVIDER_CONFIGURATION_REVISION`; signed `/webhooks/resend` subscriptions and real delivery/bounce/suppression/resend evidence. Production delivery still requires current capability approval. |
| Stripe | Isolated rehearsal: `STRIPE_TEST_SECRET_KEY`, `STRIPE_TEST_PUBLISHABLE_KEY`, `STRIPE_TEST_PLATFORM_ACCOUNT_ID`, and its `STRIPE_WEBHOOK_SECRET`. Approved production: separate `STRIPE_LIVE_SECRET_KEY`, `STRIPE_LIVE_PUBLISHABLE_KEY`, `STRIPE_LIVE_PLATFORM_ACCOUNT_ID`, and that environment's webhook secret. Configure the applicable values privately on all three application services before enabling the corresponding mode. These optional keys are not initial Blueprint prompts. |

The exact provider account, Guam/entity/charge-flow approval, direct organizer settlement and bank proof remain separate requirements. Do not place live credentials on staging or any backend secret in `VITE_` variables.

## Deploy the same candidate

1. Record service IDs, deployed revisions, database/queue identities, provider revision and encrypted backup reference. Verify protected-main checks and current reviewer coverage for the exact candidate.
2. Verify the sync preview, private configuration, pooled/direct endpoint identity, queue persistence/authentication and actual origins. Do not copy customer data or approvals into rehearsal.
3. Apply only reviewed configuration and the authorized sales/maintenance state. Deploy the API at the explicit reviewed commit; its pre-deploy task runs migrations. Record success and schema version. Use forward repairs where rollback would discard financial/upload/cash-sale history.
4. Deploy worker and clock at that identical commit. Verify one queue execution owner and one clock lease. A replacement clock can initially refuse the old owner's lease; let the old owner stop or the lease expire, then verify the new heartbeat. Never add another scheduler to bypass this.
5. Verify `/up`, `/api/v1/health` and redacted `/api/v1/readiness`, and compare all three actual deploy commits with the recorded SHA. Readiness does not compare worker/clock release identities. Pending provider/policy approvals may correctly return 503.
6. Deploy the matching frontend with the intended Clerk instance, API URL, canonical URL and release. Execute hosted organizer, guest, admin, S3, email, payment, refund and scanner scenarios; verify visible and persisted/provider outcomes.
7. Complete restore, rollback/redeploy, alerts, load and physical-device evidence. Complete applicable independent approvals before opening real inventory. New code revisions invalidate candidate-bound event approvals.

## Provider rehearsal

Use separate staging web/worker/clock, a dedicated Neon database whose name contains `staging`, dedicated Redis with an explicit nonzero database number, Clerk test identity, persistent staging secrets and a matching test frontend. Follow [Private testing runtime](PRIVATE_TESTING_STAGING.md); do not repoint the production Blueprint and call it production-ready.

Ordinary staging simulates money/email. Controlled rehearsal sets `HAFAPASS_PROVIDER_REHEARSAL=true`, selected `PROVIDER_REHEARSAL_SERVICES=stripe,resend`, and at most ten authorized tester addresses in `PROVIDER_REHEARSAL_EMAIL_RECIPIENTS`. Configure only selected providers. Stripe uses test keys and the exact test platform account; set the staging site setting to `test` only when Stripe rehearsal is selected. Resend recipients are restricted to the declared list. Live money and payouts remain prohibited; production boot rejects the rehearsal flag.

## Verification boundary

The prepared file passes [Render's official Blueprint JSON Schema](https://render.com/schema/render.yaml.json). Configuration semantics were checked against the [Blueprint reference](https://render.com/docs/blueprint-spec) and [root-directory documentation](https://render.com/docs/monorepo-support) on 2026-10-09. Schema validation does not prove a successful account sync or deployment.

Still required: confirmed service mapping/budget, private configuration, dedicated Neon resources, durable authenticated queue, same-SHA deployment, actual provider outcomes, hosted/physical acceptance, restore/alert drills and current approvals. None is claimed by committing this contract.
