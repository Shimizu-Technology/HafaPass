# Saturday Nov 28, 2026: live-money test and hosted rush test

Prepared Nov 24 for Leon to run. Nothing here has been run against Render, Neon, Stripe or production. Everything marked **verified locally** was run on a local copy; everything else is a plan.

Times are Guam time (UTC+10). 11:30 AM Guam is 01:30 UTC.

Two parts:

1. [11:30 AM: $2 live-money test on production](#part-1-1130-am-2-live-money-test-on-production)
2. [Hosted rush test on an isolated copy](#part-2-hosted-rush-test-on-an-isolated-copy)

Companion files: [results sheet](qa/saturday-rush-2026-11-28/RESULTS_TEMPLATE.md), [helper scripts](../scripts/rush_test/README.md), [Gate H](GATE_H_LIVE_MONEY_PROOF.md), [load tests](../load_tests/README.md).

## Decisions only Leon can make

| # | Decision | Recommendation |
| --- | --- | --- |
| D1 | Live test path: **A** ordinary $2 event, or **B** Gate H proof candidate | **A.** B is enforced in code behind Gate E, F and G approvals (500-ticket manifest, three physical devices, accessibility and load evidence). See Part 1, gaps G1 and G2 |
| D2 | Leave production in live mode after the test, or switch back to test | Decide before you start; the switch is global and door staff must refresh scanners after it |
| D3 | Which organizer and which bank/entity the $2 test belongs to | Shimizu Technology's own organizer; Gate H needs it named |
| D4 | Rush copy: new Neon project at production's compute size (may cost money) or the free plan at a smaller size | Match production's compute, or the numbers say nothing about January |
| D5 | Rush copy: pay for Render Standard for a few hours (about $25/month prorated per second; see cost note) | Yes, one Standard instance for about 4 hours, deleted afterwards |
| D6 | Stripe test-mode run (`PAYMENT_MODE=test`) as well as simulate | Yes, it is the only way to measure the PaymentIntent call that holds a Puma thread |
| D7 | Clerk: real Clerk development instance (can sign in as admin) or formatted dummy keys (k6 only) | Dev instance, if you want the admin views or the test alert |
| D8 | Whether a miss on the order p95 target (1,500 ms) blocks January or triggers admission control (PR #232 option C) | Decide the rule before you see the numbers |
| D9 | Accept one-machine traffic as "shared NAT" only, or add a second and third machine for distinct IPs | Add at least one more network; see gap G9 |

## Accounts and settings you need (names only, never send the values)

- Production: Render dashboard (hafapass-api), Netlify (hafapass site), Stripe dashboard in live mode, an HåfaPass admin sign-in, Sentry, the restricted evidence folder, a card that can be charged $3.10 and refunded, a verified Shimizu organizer that is payout-ready.
- Rush copy: Render (a new web service), Neon (a new project), a Clerk development instance or formatted dummy keys, Sentry DSN (same project, separate environment), Stripe **test** keys and a test webhook endpoint (only for `PAYMENT_MODE=test`).
- Your laptop: k6 (`brew install k6`), `git`, `curl`, `python3`, Node 20 or newer (only for the offline self-check), and **Ruby from `hafapass_api/.ruby-version` with Bundler and the gems installed** (`cd hafapass_api && bundle install`) for `init_empty_db.sh`, which runs `rails db:schema:load`. `mise` is optional: the script uses it when present and plain `bundle exec` otherwise. The Neon direct URL needs network access from your laptop to Neon; nothing else in `init_empty_db.sh` touches the network.

---

# Part 1: 11:30 AM $2 live-money test on production

**What the buyer pays.** A $2.00 ticket plus the default buyer fee (5% plus $1.00) is $1.10, so the order total is **$3.10 (310 cents)**. Gate H's ceiling is 500 cents (`LiveMoneyProofAuthorization::MAX_AMOUNT_CENTS`), so it fits. The largest base price that fits is $3.80.

## Which path: read this first (D1)

The backend treats the two ways to run this test very differently. Checked against the code:

| | **Path A: ordinary $2 event** | **Path B: Gate H proof candidate** |
| --- | --- | --- |
| Gate E, F, G approvals | **Not enforced.** `Event#publish_checklist` has no gate item and says the reviews "never block publishing or sales" (`event.rb:748-750`); `OrderCreator` checks organizer verified, payout-ready, payments on (`order_creator.rb:451`) | **Enforced in code.** `LiveMoneyProofAuthorizations::Manager.request!` raises "A current Gate G rehearsal approval is required" (`manager.rb:23`), and `LiveMoneyProofAuthorization#current_bindings?` re-checks it on approval and at checkout (`live_money_proof_authorization.rb:51-61`) |
| Gate G needs | n/a | An active Gate F approval, which needs an active Gate E approval (`event_day_rehearsal.rb:4-6`, `pilot_validation.rb:4-6`), all bound to the event's digest **and the deployed commit** (`PilotReadiness.application_revision`). Gate G's own validations demand a signed manifest of at least 500 generated tickets, at least three physical devices and drills (`event_day_rehearsal_review.rb:110-123, 223`); Gate F demands accessibility, device and load evidence ([Gate F](GATE_F_VALIDATION_EVIDENCE.md)) |
| Visible to the public | Yes, while published and on sale | No: hidden from marketplace, sitemap, search; only an admin can buy (`events_controller.rb:96`, `order_creator.rb:456-467`) |
| Counts in revenue and settlements | Yes unless fully refunded | Same (live order) |
| Feasible by 11:30 AM Saturday | **Yes** | **Only if the E, F and G evidence bundles already exist.** Any deploy after approval, or any edit to the event, voids them |

**Recommendation.** Run **Path A** on Saturday: it proves the live charge, webhook, receipt, ledger, partial and final refund, which is what the morning needs. Treat the formal Gate H record (Path B) as a separate piece of work: Gate H is marked optional since Oct 21 ([Production cutover](PRODUCTION_CUTOVER.md)), and Path B's prerequisites are weeks of rehearsal evidence, not a morning's setup (gaps G1, G2). If Leon wants Path B on Saturday regardless, every prerequisite is listed in [Path B](#path-b-gate-h-proof-candidate-only-if-gates-e-g-are-approved).

**What this morning covers.** Charge, confirmation, receipt, partial refund and final refund. Settlement, payout and the bank receipt need the event to be complete (6 hours after its end, so a 12:30–1:00 PM event completes about 7:00 PM) and a bank transfer in 2–3 business days; plan them as a second session (gap G3).

## Pre-checks (10:45 AM)

| Check | How | Expected |
| --- | --- | --- |
| API release | `curl -s https://hafapass-api.onrender.com/api/v1/health` | `revision` is the 40-character commit you intend to test. Compare with the Render dashboard → hafapass-api → Events → latest deploy, and with `git ls-remote origin hafapass-staging main` |
| API ready | `curl -s -o /dev/null -w '%{http_code}\n' https://hafapass-api.onrender.com/api/v1/readiness` | `200` |
| Frontend release | `curl -s https://hafapass.shimizu-technology.com/release.json`; Netlify → Deploys | `revision` matches the published deploy; the deploy list shows **Auto publishing locked** until you decide otherwise |
| Environment | `curl -s https://hafapass-api.onrender.com/api/v1/config` | `"environment":"production"`; note `payment_mode` |
| Admin gates | Admin dashboard: no red banner. Admin → Provider readiness: Stripe live, policy register and production email (Resend) approved | All green. Without production email approval the buyer receipt fails; without the policy register approved checkout is refused |
| Stripe | Live mode toggle on. Developers → Webhooks: endpoint `https://hafapass-api.onrender.com/webhooks/stripe` enabled | Endpoint present and recent deliveries healthy |
| Sentry | Production project open on your phone | No open incident |
| Organizer | The test organizer is **verified** (Admin dashboard → Organizers waiting for verification → Verify) and payout-ready (connected account, certified tax information, approved readiness) | In production an unverified organizer's event does not sell; paid sales need `Organization#payout_ready?` |
| Evidence | Restricted folder open; stopwatch running | Never put card data, bank numbers or buyer PII in Git |

Write down both revisions (API and frontend) and the time. They go on the results sheet. **Do not deploy anything between now and the end of the test.**

## Path A: ordinary $2 event (recommended)

Menu names follow the cutover guide and the screens' code. If a label on screen differs, trust the screen and note it.

| # | Do | Verify | Capture |
| --- | --- | --- | --- |
| 1 | Admin → Settings → Payment mode: switch to **live** if it is not (D2) | Banner shows live; audit entry has your name and the platform account | Screenshot, time |
| 2 | As the Shimizu organizer, create the event: title `Live payment check - staff only`, starts today 12:30 PM and ends 1:00 PM Guam, one general-admission ticket type at $2.00, **Tickets available 1**, Tickets per order 1, Tickets per buyer 1, and a ticket sales window that ends about 30 minutes after you publish. Publish it | Publish checklist all green. The event is **public until you pause it** (step 5), so keep the window short | Event ID |
| 3 | Open the event page on the public site in a private window, sign in as an admin (a test-mode purchase is admin-only, a live one is open), buy the ticket. Check the event, quantity, total ($3.10), live banner and receipt email. Pay once. **Do not retry** if the result is ambiguous | Order completes; ticket PDF and QR present | Order ID, order reference |
| 4 | Admin → Events → **Pause sales** for the event, right after the payment | Event shows sales paused; no one else can buy | Screenshot |
| 5 | Order and ticket: Admin → Orders → open the order | Status completed, 1 ticket issued, total 310 | Screenshot |
| 6 | Email receipt: open the mailbox; Admin → Operations message deliveries | Confirmation delivered to the buyer address; delivery row `sent`/`delivered` | Screenshot, delivery ID |
| 7 | Stripe dashboard (live) → Payments | One charge of $3.10, succeeded; fee and net shown; copy the `pi_` and `ch_` IDs | Redacted IDs |
| 8 | Stripe → Developers → Webhooks → the endpoint → Events | `payment_intent.succeeded` (and `charge.succeeded`) delivered with 200 | Event IDs |
| 9 | Ledger rows (Render shell on **hafapass-api**, read-only): `bundle exec rails runner 'puts({orders: Order.count, itemized_orders: Order.joins(:order_items).distinct.count, open_reconciliation: ReconciliationException.open.count}.to_json)'` and `bundle exec rails runner 'puts Commerce::LedgerTotals.call(Order.where(status: [:completed, :partially_refunded, :refunded])).to_json'` | Gross, fees and proceeds agree with the order; `open_reconciliation` is 0 | Command output |
| 10 | Admin → Payouts and the organizer's event **Finances** view | Order appears once; Stripe processing fee evidence records after Stripe supplies it (can take minutes) | Screenshot |
| 11 | **Partial refund**: Admin → Orders → Refund → **A set amount** (for example $1.00) | Refund `pending` then `succeeded`; order `partially_refunded`; buyer notice sent; Stripe shows the refund | Refund ID, Stripe refund ID |
| 12 | Re-run the two ledger commands in step 9 | Totals reflect the refund; zero exceptions | Output |
| 13 | **Final refund**: refund everything left | Order `refunded`; second buyer notice; Stripe refunds sum to $3.10 | Refund ID |
| 14 | Stop for the day unless the event is complete | Statement, payout, bank receipt and the negative-balance settlement follow Gate H steps 3–5 after the event ends | Schedule in the evidence folder |

Note on step 13: Gate H wants the final refund **after** the payout, to prove the post-payout liability. Refunding fully on Saturday morning proves refunds but not that liability. For the full chronology, do step 11 now, stop, and run step 13 after the payout (gap G3).

## Path B: Gate H proof candidate (only if Gates E–G are approved)

Every requirement below is enforced by the backend, so a missing one fails at the step named. Steps follow the order the code needs.

1. **Event fields** (`Event#live_money_proof_candidate_configured?`, `event.rb:791-800`). The event must have: title starting `[LIVE MONEY TEST]`; **Event capacity 1**; exactly **one** ticket type; price 1–500 cents and price plus buyer fee at most 500 cents (a $2.00 ticket: 200 + 110 = 310); **Tickets available 1**; **Tickets per order 1**; **Tickets per buyer 1**; no pricing tiers, no add-ons or catalog items, no promo codes, no seating. All three limit fields are on the ticket type form (Tickets available, Tickets per order, Tickets per buyer). The publish checklist item "Live-money proof event is hidden, single-ticket, and capped at $5" blocks publishing until this holds.
2. **Flag it while still a draft.** Admin → Events → **Launch reviews** → **Mark as hidden proof candidate**. The flag can only change while the event is a draft and has no orders (`event.rb:885-892`). Then **publish** the event: authorization requests are refused unless it is published (`manager.rb:118`, and again in `current_bindings?`).
3. **Gate E.** Launch reviews → **Prepare pilot readiness**: restricted evidence reference and SHA-256, six named roles, twelve controls ([Gate E](GATE_E_PILOT_READINESS_EVIDENCE.md)). One admin may submit and approve.
4. **Gate F.** Launch reviews → **Prepare Gate F evidence**: device, accessibility, journey and load evidence bundle ([Gate F](GATE_F_VALIDATION_EVIDENCE.md)). Needs the active Gate E approval.
5. **Gate G.** Launch reviews → **Prepare Gate G rehearsal**: manifest of at least 500 generated tickets, three physical devices, drills ([Gate G](GATE_G_EVENT_DAY_REHEARSAL_EVIDENCE.md)). Needs the active Gate F approval and the same event digest.
6. **Freeze.** Each approval is bound to the event's material configuration and to the deployed commit. Editing the event, or any API deploy, after approval makes it inactive and the next step fails. Check readiness, then do not touch the event or deploy.
7. **Gate H authorization.** Launch reviews → **Prepare live-payment validation** → request: the finance operator's exact sign-in email, a ceiling of 310–500 cents, an expiry within two hours. An administrator (you may approve your own) approves. Requires a payout-ready connected account and live Stripe provider readiness (`manager.rb:18-20`).
8. **Charge** from the private proof checkout in the same dialog, then continue with Path A steps 5–14. Skip the Pause step; the event is already hidden.

If any of steps 3–5 cannot be completed with real evidence, do not approximate: use Path A.

## Evidence to keep (restricted folder)

Screenshots of every step; order, payment, refund (and authorization, for Path B) IDs; Stripe `pi_`, `ch_`, `re_` IDs and webhook event IDs; both revisions; the ledger command output; the buyer receipt and refund emails (redact names); the time of each step in UTC. Include SHA-256 digests of any bank or settlement document later.

## Rollback and cleanup

- Money: a failed or uncertain run needs finance review. For Path B it also needs a **new** authorization; never reuse one.
- Refund anything that was charged. Confirm Stripe shows the refund `succeeded` and the order `refunded`.
- Path A: after the refund, leave the event paused. Archive it only after its money is closed ([Settlement and payout operations](SETTLEMENT_AND_PAYOUT_OPERATIONS.md)); the archive guard will refuse earlier. Path B: the event is hidden; same archive rule.
- Path B only: revoke the Gate H authorization if it is unused and not yet expired.
- If you switched to live in step 1 and decided to go back (D2), switch to test and tell door staff to refresh the scanner.
- Do not delete database rows. Do not unlock Netlify publishing unless that was the plan.
- Never rotate or edit Stripe or encryption keys during the test.

## Gaps found in the existing docs

- **G1.** [Gate H](GATE_H_LIVE_MONEY_PROOF.md) says normal paid events "fail closed" without Gate H and that a candidate must complete Gates E, F and G first. The code agrees only for the candidate: ordinary events are never blocked by the gates (comment at `event.rb:748-750`; `LivePilot` "required" is a status flag, and a bounded pilot run is optional, `live_pilot.rb:102`). The Oct 21 cutover guide matches the code; Gate H's "normal paid events fail closed" sentence is stale.
- **G2.** The same doc's "Optional record" banner suggests the proof is optional, yet the proof-candidate path (the only way to get the hidden, admin-only checkout) hard-requires Gates E–G. The optional banner does not apply to Path B.
- **G3.** Gate H's chronology (charge, partial refund, settlement, payout, final refund, negative balance) cannot finish on one Saturday morning. The bank step alone is 2–3 business days.
- **G4.** Gate H does not say which ledger commands to run. Step 9 uses the ones from [Commerce ledger operations](COMMERCE_LEDGER_OPERATIONS.md).
- **G5.** The $3.10 total is not stated anywhere. Gate H gives 205 cents for a 100-cent ticket; the same rule gives 310 cents for $2.00.
- **G15.** The Gate H doc does not list the extra proof-candidate field limits (Tickets available 1, per order 1, per buyer 1) or that the event must be published before an authorization can be requested.

---

# Part 2: Hosted rush test on an isolated copy

## Goal and pass criteria

Learn whether the event-week settings survive a sales-open rush on hosted infrastructure, and measure how far the Neon round trip moves the numbers. PR #232's own numbers missed its targets locally, and it estimated a hosted sell-out of 8–18 s. The targets, from [PR #232](https://github.com/Shimizu-Technology/HafaPass/pull/232) and `load_tests/fd_championship_rush.js`:

| Criterion | Target |
| --- | --- |
| Order p95 (free and paid) | ≤ 1,500 ms |
| Listing p95 | ≤ 300 ms |
| Oversell | none (sold ≤ available; sold + live holds ≤ available) |
| 429, 5xx, unexpected 422 | 0 |
| Solid Queue | no failed jobs, backlog drains, one supervisor in worker 0 |
| Holds | none overdue 11+ minutes after the run |
| Sentry | both Puma workers deliver events after fork |

A miss on the p95 targets is expected on a zero-think-time burst (#232). The decision rule for a miss is D8.

## Why `WEB_CONCURRENCY=2 RAILS_MAX_THREADS=5 DB_POOL=11`

Checked against `config/runtime_configuration.rb`, `config/database.yml` and `config/puma.rb`:

- `WEB_CONCURRENCY=2` starts two Puma request workers from a preloaded master (`RuntimeConfiguration.web_processes`; 2 or more means cluster mode).
- `RAILS_MAX_THREADS=5` gives each worker five request threads, ten in total.
- **`DB_POOL` is a per-process setting, not a total.** `database.yml` passes it to every process as its Active Record pool size. Under `HAFAPASS_RUNTIME=embedded` the code refuses any value below `RAILS_MAX_THREADS + 6` (`RuntimeConfiguration.database_pool`), so 5 + 6 = **11** is the smallest value that boots. The six extra connections are for the embedded Solid Queue supervisor, which runs only in worker 0 (`config/puma.rb`, `before_worker_boot`): one job thread, dispatcher, scheduler, polling and heartbeats.
- Peak connections: 2 × 5 request threads + 6 supervisor = **about 16**. Pool ceiling: 2 × 11 = **22**. During a Render zero-downtime deploy the old and new instance overlap, so the ceiling doubles to **44**, plus one direct connection for `bin/release-migrate`. These match the table in [Single-service runtime](SINGLE_SERVICE_RUNTIME.md). A spec (`spec/scripts/rush_test_guard_spec.rb`) pins the arithmetic: 11 boots, 10 raises, and 16 / 22 / 44 are the results.
- The master holds no connections after forking (`before_fork` clears them).

**Mismatch flagged.** The brief's shorthand "2 processes × 5 threads + Solid Queue" suggests `DB_POOL` is a total. It is not: worker 1 never uses more than 5 and worker 0 never more than 11. Two other recipes in the repo do not apply here: `render.tournament.yaml` sets `DB_POOL=15` with a separate worker service (ceiling 2 × 15 + 10 = 40), and its `RAILS_MAX_THREADS=5` with `solid_queue` would only require 7. Use the embedded recipe, which is the one #232 tested.

**What "Neon connection count" means.** The app connects through Neon's pooled endpoint (PgBouncer in transaction mode). Its client connections (up to 22) are far below the pooler's client limit (a Neon FAQ reports 10,000; unverified). What reaches Postgres is the pooler's server-side connections, bounded by concurrent transactions, and direct connections (`DATABASE_MIGRATION_URL`, `psql`) are capped near 104 (also reported by that FAQ; verify in the Neon console with `SHOW max_connections`). Measure both: the Neon dashboard connection graph and `pg_sampler.rb` (`pg_stat_activity`). With transaction pooling, a checkout holding the event row lock holds a server connection for its whole transaction, so peak server-side connections track the number of concurrent checkout transactions, up to 10 request threads.

## Isolated copy: setup (Leon does this; nothing here was executed)

### Hard rules

- Never apply `render.yaml` or `render.tournament.yaml` as a Blueprint for the copy. Both name their service `hafapass-api`, the same as production. Create the service by hand with a different name (for example `hafapass-rush-copy`).
- Run the copy as **`RAILS_ENV=staging`**, not production. Staging boots through `StageSafety` (`app/services/stage_safety.rb`), which refuses live Stripe keys, requires `pk_test_`/`sk_test_` Clerk keys, a database whose name contains `staging`, no first-user admin bootstrap, and `simulate` payments (or `test` when Stripe rehearsal is configured). Email is simulated unless you name `resend` in `PROVIDER_REHEARSAL_SERVICES`; do not. No SMS integration exists in the API.
- The copy never gets production's database, keys or buyers. Do **not** branch Neon from production: that copies real buyer data and queued jobs, and the scripts refuse a database that has any (`RushTest::Guard.check_no_real_data!`).
- Use a **new empty Neon project** (D4) in Singapore (`aws-ap-southeast-1`), the same region as Render's Singapore service, with a database named `hafapass_rush_staging` (it must contain both `rush` and `staging`).

### Create the service

1. Render → New → Web Service → Docker, repo `Shimizu-Technology/HafaPass`, branch **`main`** (never `hafapass-staging`), root directory `hafapass_api`, Dockerfile `./Dockerfile`, region Singapore, plan **Standard** (1 CPU, 2 GB), auto-deploy **off**, health check `/up`, pre-deploy command `bin/release-migrate`, instances 1. Name: `hafapass-rush-copy`.
2. Render assigns `https://<name>.onrender.com`. Set `PUBLIC_API_URL`, `FRONTEND_URL`, `PUBLIC_WEB_URL` and `ALLOWED_ORIGINS` to that exact origin. Rails accepts only that host (`config/environments/staging.rb`).
3. Add the environment variables below, **before the first deploy**, then initialize the database (next section), then deploy a specific commit.

### Environment variables

| Variable | Value | Copied from production? |
| --- | --- | --- |
| `RAILS_ENV` | `staging` | No |
| `HAFAPASS_RUNTIME` | `embedded` | Same as production |
| `WEB_CONCURRENCY`, `RAILS_MAX_THREADS`, `DB_POOL` | `2`, `5`, `11` | New for event week |
| `DATABASE_URL`, `STAGING_DATABASE_URL` | The new Neon **pooled** URL, identical in both | **Never** production's |
| `DATABASE_MIGRATION_URL` | The new Neon **direct** URL, same database | **Never** production's |
| `SECRET_KEY_BASE` | A new random value of 65+ characters | **No** |
| `ADMISSION_MANIFEST_PRIVATE_KEY_PEM` | A new RSA key (2048+ bits) | **No** |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `..._DETERMINISTIC_KEY`, `..._KEY_DERIVATION_SALT` | New random values | **No** |
| `CLERK_PUBLISHABLE_KEY`, `CLERK_SECRET_KEY`, `CLERK_ISSUER`, `CLERK_AUTHORIZED_PARTIES` | Clerk **development** instance (`pk_test_`, `sk_test_`), or formatted dummies for k6 only (D7) | **No** |
| `ENABLE_FIRST_USER_ADMIN_BOOTSTRAP` | `false` | Same |
| `ADMIN_EMAILS` | Your email, only if you use a real Clerk dev instance | Optional |
| `HAFAPASS_LAUNCH_SCOPE` | `general_admission` | Same |
| `HAFAPASS_MAX_HELD_TICKETS_PER_IP` | `250` | Match the tournament group |
| `RACK_ATTACK_REQ_PER_IP_5M` `3000`, `RACK_ATTACK_ORDERS_PER_IP_1M` `500`, `RACK_ATTACK_MARKETPLACE_LANDING_PER_IP_1M` `600`, `..._MARKETPLACE_FUNNEL_PER_IP_1M` `600`, `..._USERS_SYNC_PER_IP_1M` `120`, `..._PAYMENT_RESUME_PER_IP_1M` `120` | As listed | Match `render.tournament.yaml`; production's real values may differ, copy what production uses |
| `SENTRY_DSN` | Same project as production, **or** a separate project (see below) | See below |
| `SENTRY_ENVIRONMENT` and `SENTRY_ENABLED_ENVIRONMENTS` | both `rush-copy` | No |
| `SENTRY_TRACES_SAMPLE_RATE` | leave unset (0.1, like production) | Same |
| `READINESS_TOKEN` | New random value | **No** |
| `HAFAPASS_PROVIDER_REHEARSAL` | unset for `simulate`; `true` only for the Stripe test run | No |
| `PROVIDER_REHEARSAL_SERVICES` | unset, or exactly `stripe`. **Never `resend`** | No |
| `STRIPE_TEST_SECRET_KEY`, `STRIPE_TEST_PUBLISHABLE_KEY`, `STRIPE_TEST_PLATFORM_ACCOUNT_ID`, `STRIPE_WEBHOOK_SECRET`, `PROVIDER_CONFIGURATION_REVISION` | Only for the Stripe test run, test-mode values | No |
| `STRIPE_LIVE_*` | **Never set.** Boot fails if present | Never |
| `RESEND_API_KEY`, `RESEND_WEBHOOK_SECRET`, `MAILER_FROM_EMAIL` | **Never set** | Never |
| `AWS_*`, `APPLE_*` | Leave unset | No |
| `RENDER_GIT_COMMIT` | Supplied by Render. Do not set | Automatic |

**Sentry decision.** Use the production project with its own environment so "Sentry after fork" can be checked without mixing data: `SENTRY_ENVIRONMENT=rush-copy` **and** `SENTRY_ENABLED_ENVIRONMENTS=rush-copy`. Gap G6: setting only `SENTRY_ENVIRONMENT` silently turns Sentry off, because the initializer's default allow-list is `production,staging` (verified locally: both workers logged `sending_allowed=false`). Before the run, check that no production alert rule lacks an environment filter, or the test will page your phone; if one does, create a separate Sentry project and use its DSN. Keep `SENTRY_TRACES_SAMPLE_RATE` at production's value so overhead matches.

### Initialize the empty database (no migration replay)

An empty database must be loaded from the committed schema, not by replaying migrations ([PR #235](https://github.com/Shimizu-Technology/HafaPass/pull/235), still open when this was written: replaying fails at `20260720000002`). `bin/release-migrate` is `rails db:migrate`; on a loaded schema it finds nothing to do.

1. Before the first deploy, from your laptop in a clone at the commit you will deploy, with the **copy's direct** Neon URL (never production's):
   ```sh
   RUSH_COPY_DIRECT_URL='<copy direct url>' scripts/rush_test/init_empty_db.sh
   ```
   It refuses unless the database name contains `rush` and `staging`, the host is a Neon host, and the database has no tables, then runs `db:schema:load` with throwaway values for every other setting. **Verified locally** on an empty local database, including all four refusals.
2. Deploy the exact commit (Manual Deploy → a specific commit). Watch the log for the pre-deploy command to finish and Puma to start with 2 workers.
3. Confirm: `curl -s https://<host>/api/v1/health` (revision), `/api/v1/config` (`environment: staging`, `payment_mode: simulate`), `/api/v1/readiness` returns 200.

Fidelity check. Deploy the commit that includes this PR; its only changes under `hafapass_api/` are inert files in `script/rush_test/` and a spec. Prove runtime is identical to production:
```sh
git diff --stat 050b390c..<copy commit> -- hafapass_api ':!hafapass_api/script/rush_test' ':!hafapass_api/spec'
```
The output must be empty (replace `050b390c` with production's actual revision from `/api/v1/health`).

### Seed fixtures

In the Render shell of the copy (working directory `/app`). `HAFAPASS_RUSH_TARGET` is typed, not stored: it is your confirmation of the target.
```sh
HAFAPASS_RUSH_TARGET=<host> RUSH_RUN_LABEL=burst-1 bin/rails runner script/rush_test/seed_fixture.rb
```
It prints the `k6_env` values and the `RUSH_EVENT_IDS` for the run. Each run label creates new events (free capacity 200 and paid capacity 200 by default; override with `FREE_CAPACITY`, `PAID_CAPACITY`), so every run starts from untouched inventory. For the Stripe test run add `PAYMENT_MODE=test` once rehearsal is configured. Seed one label per scenario.

### Teardown

1. Render: delete the web service. Billing stops at deletion.
2. Neon: delete the project (or leave it idle; check the plan).
3. Clerk dev instance, Sentry project or filters, Stripe test webhook endpoint: remove what you created.
4. Search the dashboards for anything named `rush`, `copy` or `staging` you do not recognize.
5. Keep `rush-results/` and the filled sheet.

### Cost note (verify on Saturday; Leon decides)

- Render Standard (1 CPU, 2 GB) is listed at about $25/month, billed by the second while the service exists ([Render pricing](https://render.com/pricing); some snapshots show other numbers, so check the page). A 4-hour test is well under $1 of compute, but a forgotten service keeps billing.
- Neon's free plan reportedly allows many small projects ([Neon pricing](https://neon.com/pricing); verify). A free project is a smaller compute than a paid production one, so latency and connection limits differ (D4).
- k6 from your laptop, Sentry events, Clerk dev instance and Stripe test mode are free.
- A paid Render plan, a bigger Neon compute and k6 Cloud (not needed) are the only paid items.

## Saturday run order

Set up the copy on Friday or early Saturday so this window is only measurement.

| When | Step |
| --- | --- |
| Before | Preflight (below), then **Sentry after fork** (below), then Neon RTT |
| Run 1 | `paid_holds` **burst** (simulate) |
| Run 2a | `paid_holds` **ramp**, sized to stay under the production throttles (simulate): `RAMP_PEAK_RATE=8 RAMP_UP=30s RAMP_HOLD=60s RAMP_DOWN=10s`, `PAID_CAPACITY=700` |
| Run 2b | `paid_holds` **ramp**, stress shape (simulate): raise the throttles on the copy only, then the defaults (below) |
| Run 3 | `free_saturation` burst (the original Copa-style shape; listing and event page numbers) |
| Run 4 | `paid_holds` burst with `PAYMENT_MODE=test` (Stripe PaymentIntent; optional, D6) |
| After each | Consistency check, collect results. Wait 6 minutes before the next run (gap G7) |
| After run 4 | Wait 11 minutes, run the consistency check again for overdue holds |

### 1. Preflight (your laptop)

```sh
export HAFAPASS_RUSH_TARGET=<host>            # bare host, no https://
export ISOLATED_LOAD_TARGET_ACK=I_ACKNOWLEDGE_THIS_CREATES_TEST_ORDERS_IN_AN_ISOLATED_ENVIRONMENT
export EVENT_SLUG=... PAID_EVENT_SLUG=...     # from the seed output
scripts/rush_test/preflight.sh
```
It refuses production hosts, a mismatch between target and URL, live payment mode and a non-staging environment, and checks revision, readiness, fixtures and k6. `node scripts/rush_test/check_k6_script.mjs` runs the offline self-check of the k6 script (also in CI).

### 2. Neon RTT (Render shell of the copy)

```sh
HAFAPASS_RUSH_TARGET=<host> RUSH_OUT=/tmp/rtt.json bin/rails runner script/rush_test/neon_rtt.rb
```
Reports `SELECT 1` p50/p95/p99 and new-connection time for the pooled and direct endpoints, then the sell-out time it implies for 200 tickets. Paste the JSON into the sheet. If the pooled p50 is above about 2 ms, expect the hosted sell-out to be slower than #232's estimate.

### 3. Sentry after fork (before load)

Needs the copy to run the probe config once. In Render, change the service's Docker command to `bundle exec puma -C script/rush_test/puma_sentry_probe.rb` and add the temporary environment variable `HAFAPASS_RUSH_TARGET=<host>`, then redeploy (isolated copy only). The probe config runs the same guard as the other scripts and refuses to boot unless the environment is staging, the target matches `PUBLIC_API_URL`, and the database is named `*rush*staging*`. The log shows, per worker, a boot line and another 20 seconds later:
```
rush_sentry_probe phase=boot worker=0 pid=... sentry_initialized=true sending_allowed=true environment=rush-copy event_id=...
```
Pass: both workers show `sending_allowed=true`, a real `event_id`, and **four** events appear in Sentry (filter `probe:rush-sentry-fork`, environment `rush-copy`), two per worker. Then put the original command back (`bundle exec puma -C config/puma.rb`), remove `HAFAPASS_RUSH_TARGET` and redeploy. A missing `event_id` or `sending_allowed=false` means that worker does not report errors (see G6).

**Verified locally** with a local fake Sentry endpoint (`scripts/rush_test/fake_sentry_sink.py`): a real two-worker Puma cluster (production settings, `RAILS_ENV=staging`) delivered events from **both** workers after fork, at boot and again 20 seconds later; with only `SENTRY_ENVIRONMENT` set, neither worker sent anything. Production's own workers are covered by the same initializer. I did not trace why the SDK survives the fork; the observation is what counts, so repeat it on Render (the SDK there has the same version).

If PR #238 is on the copy, Admin → Monitoring & alerts → **Send test alert** is a second check that an alert from some worker reaches Sentry. It cannot tell you which worker handled the request, so the probe config above is the per-worker proof.

### 4. A run

```sh
export SCENARIO=paid_holds PROFILE=burst RUN_LABEL=paid-burst-1
export ORG_SLUG=... PAID_EVENT_SLUG=... PAID_TICKET_TYPE_ID=... PAID_VUS=200
export SHARED_NAT=true
scripts/rush_test/run_k6.sh
```
Scenarios and profiles:

| Run | `SCENARIO` | `PROFILE` | Sizing |
| --- | --- | --- | --- |
| Burst, paid | `paid_holds` | `burst` | `PAID_VUS` (all start at once, one order each). Use 200 for capacity 200, 600 for Copa scale |
| Ramp, paid | `paid_holds` | `ramp` | `RAMP_PEAK_RATE` buyers per second (default 100), `RAMP_UP=30s`, `RAMP_HOLD=30s`, `RAMP_DOWN=10s`, `RAMP_MAX_VUS=600`. **Read the throttle note below before using the defaults** |
| Free burst | `free_saturation` | `burst` | `FREE_VUS` (default 150) |
| Both | `both` | either | Free runs first, paid starts 5 s later |

**Ramp and the per-IP throttles (one machine is one IP).** Two throttles apply to every request from one address (`config/initializers/rack_attack.rb`): `orders/ip`, every `POST /api/v1/orders`, limit `RACK_ATTACK_ORDERS_PER_IP_1M` (500 with the tournament values) per minute, about 8 orders per second; and `req/ip`, every API request, limit `RACK_ATTACK_REQ_PER_IP_5M` (3,000) per 5 minutes. The default ramp (peak 100 buyers per second, 70 seconds) sends about 5,000 orders, about 4,500 of them in its first minute, and 15,000 requests when it is the free funnel (listing, event page, order). From one IP it will mostly measure the throttle: expect thousands of `429`.

- **Run 2a, production throttles:** `RAMP_PEAK_RATE=8 RAMP_UP=30s RAMP_HOLD=60s RAMP_DOWN=10s`. That is about 640 buyers, 480 orders in the busiest minute (under 500) and at most 1,920 requests for the free funnel (about 640 for `paid_holds`), under 3,000 per 5 minutes. Seed with `PAID_CAPACITY=700` so the run does not sell out. A `429` here is a finding about the production limits.
- **Run 2b, stress shape:** on the copy only, set `RACK_ATTACK_ORDERS_PER_IP_1M=6000` and `RACK_ATTACK_REQ_PER_IP_5M=30000`, redeploy (an env change restarts the service), run the default ramp with `PAID_CAPACITY=1500`, then set them back. Never change them on production.
- Wait 6 minutes between runs from one address; the counters are shared.

`PROFILE` is new in this PR; the default (`burst`) is the old behaviour. Start the observers a few seconds before k6, in other Render shells of the copy:

```sh
# database sessions and lock waits (read-only)
HAFAPASS_RUSH_TARGET=<host> SAMPLE_SECONDS=240 RUSH_OUT=/tmp/pg.json bin/rails runner script/rush_test/pg_sampler.rb
# CPU and memory per Puma process and the container
SAMPLE_SECONDS=240 ruby script/rush_test/proc_sampler.rb
```
Also watch Render's CPU, memory and request queue graphs and Neon's connection graph; note the UTC times printed by `run_k6.sh`.

### 5. After each run (Render shell)

```sh
HAFAPASS_RUSH_TARGET=<host> RUSH_EVENT_IDS=<ids> RUSH_OUT=/tmp/consistency.json \
  bin/rails runner script/rush_test/consistency_check.rb
```
Read-only. Exit status 1 means a check failed. The same queries as plain SQL, for the Neon SQL editor, are in `scripts/rush_test/consistency.sql`. Then, on your laptop:
```sh
python3 scripts/rush_test/collect_results.py --k6 rush-results/paid-burst-1.summary.json \
  --times rush-results/paid-burst-1.times.json --consistency consistency.json --sampler pg.json --rtt rtt.json
```
It prints the filled rows and the verdict against the targets. Paste into the results sheet.

## Verified locally (Nov 24, Mac mini, `RAILS_ENV=staging`, `WEB_CONCURRENCY=2 RAILS_MAX_THREADS=5 DB_POOL=11`)

Local numbers are not hosted capacity. See `docs/qa/saturday-rush-2026-11-28/LOCAL_EVIDENCE.md` for the commands and results: both workers booted with the supervisor in worker 0; Sentry delivered from both workers; free burst (250 VUs, capacity 200): 200 sold, 50 clean sold-out, 0 errors; paid burst (60 VUs): 60 orders; mixed ramp: no 5xx and no oversell, but 132 requests hit the per-IP throttle because earlier runs were still inside the 5-minute window. No order or listing p95 target was met locally, consistent with #232.

## Gaps and risks found

- **G6.** `SENTRY_ENVIRONMENT` alone disables Sentry (default allow-list is `production,staging`). Set `SENTRY_ENABLED_ENVIRONMENTS` too. Verified locally.
- **G7.** Per-IP throttle counters live in PostgreSQL for 1 and 5 minutes. Back-to-back runs from one address share them; the local ramp saw 132 `429` for this reason. Wait 6 minutes between runs, or raise `RACK_ATTACK_REQ_PER_IP_5M` on the copy. It also raises a production question: 650 buyers behind one gym NAT, each making several API calls, can exceed `RACK_ATTACK_REQ_PER_IP_5M=3000`. Treat any `429` in the shared-NAT run as a finding, not noise. The same arithmetic applies to a single-minute burst: 650 buyers from one NAT is more than `RACK_ATTACK_ORDERS_PER_IP_1M=500` orders in a minute.
- **G8.** In `simulate` mode a paid order completes immediately and never creates a Stripe PaymentIntent (verified locally: `paid_hold_success` 60, 60 tickets, 0 `payment_resume`). Only `PAYMENT_MODE=test` measures the Stripe call that holds a Puma thread (#232). Stripe's test mode has lower request limits than live; expect rate-limit errors at high rates and read [Stripe's rate-limit page](https://docs.stripe.com/rate-limits) first. Those errors are a test-mode limit, not production's.
- **G9.** Distinct client IPs cannot be simulated from one machine through Render's proxy: it appends the real address, and the app uses the last untrusted `X-Forwarded-For` entry, so `DISTRIBUTED_IP_HEADERS=true` has no effect on Render. PR #232 asked for both shapes. Run k6 at the same time from two or three networks (laptop on home Wi-Fi, the Mac mini, a phone hotspot), each with its own `RUN_LABEL`, and split the VUs.
- **G10.** `load_tests/local_rush_fixture.rb` only seeds a local database and has no paid event. `script/rush_test/seed_fixture.rb` replaces it on the copy, including a payout-ready organizer so paid checkout works. It must live in `hafapass_api/` because Render's Docker context contains only that directory.
- **G11.** The k6 production host denylist did not include `hafapass.shimizu-technology.com`. Fixed in this PR (also `hafapass.netlify.app`, plus `HAFAPASS_PRODUCTION_HOSTS` for more).
- **G12.** `consistency_check` cannot show `quantity_sold > quantity_available`: a database check constraint (`ticket_types_sold_within_capacity`) blocks it. The meaningful oversell checks are sold + live holds against capacity, and the counter against actual tickets. Both ran locally, including a deliberate negative test.
- **G13.** `proc_sampler.rb` has a Linux path (reads `/proc` and the cgroup) that the Mac mini cannot exercise; only its macOS fallback ran locally. If it misbehaves on Render, use the Render CPU and memory graphs and `top` if available.
- **G14.** The Render shell image has no `psql`, so everything on the copy uses `bin/rails runner`.
