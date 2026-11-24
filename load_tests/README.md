# HåfaPass Load Tests (k6)

This directory contains k6 load-rehearsal scripts for HåfaPass:

- `fd_championship_rush.js`: FD Alumni Championship rush rehearsal (cached public events browse + optional distribution link + free checkout saturation and/or paid hold creation + payment resume).
- `gate_f_onsale.js`: Gate F general-admission on-sale and assigned-seat contention harness (see `docs/GATE_F_VALIDATION_EVIDENCE.md`).

## Safety Rails

**Enforced by both `fd_championship_rush.js` and `gate_f_onsale.js`:**

1. **Explicit acknowledgement.** You must pass `ISOLATED_LOAD_TARGET_ACK=I_ACKNOWLEDGE_THIS_CREATES_TEST_ORDERS_IN_AN_ISOLATED_ENVIRONMENT`.
2. **`[LOAD TEST]` fixture guard.** Target event titles must start with `[LOAD TEST]`, be `published`, general admission (for GA checkout), and have no required registration questions or waivers.

**Enforced additionally by `fd_championship_rush.js`:**

1. **Production host denylist.** Hard-refuses production hostnames (`*.hafapass.com`, `hafapass-api.onrender.com`, after stripping any `userinfo@` prefix and trailing dot).
2. **Non-live payment mode check.** Queries `/api/v1/config` and hard-refuses any API reporting `payment_mode == "live"`.
3. **Strict `422` validation & non-zero success gates.** Only genuine inventory-exhaustion `422` responses count as clean sold-outs; all other `422` responses fail `rush_unexpected_422 == 0`, and enabled scenarios must create at least one order (`count > 0`).

---

## Running `fd_championship_rush.js`

### Prerequisites

- Install [k6](https://k6.io/docs/get-started/installation/) (`brew install k6`).
- Deploy the candidate revision to an isolated staging API with the tournament topology env vars (`RACK_ATTACK_*`, `HAFAPASS_MAX_HELD_TICKETS_PER_IP=250`, `HAFAPASS_RUNTIME=solid_queue` + worker if rehearsing peak topology).
- Seed `[LOAD TEST]` fixtures on staging:
  - A published free-ticket event (e.g., 100–150 ticket cap to exercise both `201` creates and clean `422` sold-out rejections).
  - Optionally, a published paid-ticket event (in `test` or `simulate` payment mode) for `paid_holds`.
  - Optionally, a public `EventSeries` membership and a `DistributionLink` code.

### Scenario 1: `free_saturation` (Default — 150–200 VUs, Guam CGNAT Shared NAT)

Simulates the full championship-rush funnel:
1. `GET /api/v1/events?organizer=<ORG_SLUG>&series=<SERIES_SLUG>&include_sold_out=true`
2. Optional `GET /api/v1/distribution_links/<DIST_CODE>` (when `DIST_CODE` is set)
3. `GET /api/v1/events/<EVENT_SLUG>`
4. `POST /api/v1/orders` (free pass / ticket; unique buyer email per VU)

```bash
ISOLATED_LOAD_TARGET_ACK=I_ACKNOWLEDGE_THIS_CREATES_TEST_ORDERS_IN_AN_ISOLATED_ENVIRONMENT \
SCENARIO=free_saturation \
BASE_URL=https://hafapass-staging-load.example.invalid \
ORG_SLUG=fd-alumni-staging \
SERIES_SLUG=fd-tourney-2026-load \
DIST_CODE=FDLOAD26 \
EVENT_SLUG=load-test-fd-championship-free \
TICKET_TYPE_ID=123 \
FREE_VUS=150 \
FREE_ITERATIONS=1 \
SHARED_NAT=true \
SUMMARY_OUT=fd-rush-free-summary.json \
k6 run load_tests/fd_championship_rush.js
```

To simulate distributed IPs against a staging environment configured to honor `X-Forwarded-For`:

```bash
SHARED_NAT=false DISTRIBUTED_IP_HEADERS=true k6 run load_tests/fd_championship_rush.js
```

### Scenario 2: `paid_holds` (30–50 VUs, Stripe `test` or `simulate` Mode)

Measures `InventoryHold` + `CheckoutAttempt` / test PaymentIntent creation and `POST /api/v1/orders/:id/payment_resume` latency before June 10:

```bash
ISOLATED_LOAD_TARGET_ACK=I_ACKNOWLEDGE_THIS_CREATES_TEST_ORDERS_IN_AN_ISOLATED_ENVIRONMENT \
SCENARIO=paid_holds \
BASE_URL=https://hafapass-staging-load.example.invalid \
PAID_EVENT_SLUG=load-test-fd-championship-paid \
PAID_TICKET_TYPE_ID=456 \
PAID_VUS=40 \
PAID_ITERATIONS=1 \
SHARED_NAT=true \
SUMMARY_OUT=fd-rush-paid-summary.json \
k6 run load_tests/fd_championship_rush.js
```

### Combined Run (`SCENARIO=both`)

Runs `free_saturation` and `paid_holds` together in one rehearsal (staggered by 5s):

```bash
ISOLATED_LOAD_TARGET_ACK=I_ACKNOWLEDGE_THIS_CREATES_TEST_ORDERS_IN_AN_ISOLATED_ENVIRONMENT \
SCENARIO=both \
BASE_URL=https://hafapass-staging-load.example.invalid \
ORG_SLUG=fd-alumni-staging \
SERIES_SLUG=fd-tourney-2026-load \
EVENT_SLUG=load-test-fd-championship-free \
TICKET_TYPE_ID=123 \
PAID_EVENT_SLUG=load-test-fd-championship-paid \
PAID_TICKET_TYPE_ID=456 \
FREE_VUS=150 \
PAID_VUS=40 \
k6 run load_tests/fd_championship_rush.js
```

### Pass/Fail Thresholds

- `http_req_failed`: `0%` (`422` on `POST /api/v1/orders` is inspected by body; only genuine inventory-exhaustion responses are accepted)
- `rush_unexpected_422`: `0` (any non-inventory `422` such as `price_changed`, `NETWORK_HOLD_LIMIT`, `NETWORK_FREE_LIMIT`, `ACTIVE_CHECKOUT_EXISTS`, or terms mismatch fails the run)
- `rush_free_order_success`: `> 0` (when `free_saturation` runs)
- `rush_paid_hold_success`: `> 0` (when `paid_holds` runs)
- `rush_throttled_429`: `0`
- `rush_server_errors_5xx`: `0`
- `rush_events_index_latency`: `p(95) <= 300ms`
- `rush_free_order_latency` / `rush_paid_hold_latency`: `p(95) <= 1500ms`

### Local production-mode benchmark (same machine, before/after comparisons)

Local numbers compare code revisions; they are not hosted capacity. Run the API with `RAILS_ENV=staging` (production settings, `StageSafety` checks) against a throwaway local database whose name contains `bench` or `load` and `staging` (for example `hafapass_rush_bench_staging`), with simulated payments:

1. `bin/rails db:create db:schema:load`, then `bin/rails runner ../load_tests/local_rush_fixture.rb`. It prints the `EVENT_SLUG`/`TICKET_TYPE_ID` pairs for a 200-ticket single event and a 200-pass two-night bundle. Recreate the database before every run: the PostgreSQL throttle counters and sold inventory persist.
2. Start Puma with the topology under test, for example `WEB_CONCURRENCY=2 RAILS_MAX_THREADS=5 DB_POOL=11 HAFAPASS_RUNTIME=embedded PORT=3101 bundle exec puma -C config/puma.rb`. On macOS, cluster mode also needs `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES PGGSSENCMODE=disable`. Raise `RACK_ATTACK_ORDERS_PER_IP_1M` (650 covers 600 buyers on one address).
3. Run plain HTTP with `FORWARDED_PROTO=https`, which marks requests the way Render's TLS proxy does (staging forces SSL):

```bash
ISOLATED_LOAD_TARGET_ACK=I_ACKNOWLEDGE_THIS_CREATES_TEST_ORDERS_IN_AN_ISOLATED_ENVIRONMENT \
SCENARIO=free_saturation BASE_URL=http://localhost:3101 FORWARDED_PROTO=https \
EVENT_SLUG=load-test-copa-rush-single TICKET_TYPE_ID=1 FREE_VUS=600 FREE_ITERATIONS=1 SHARED_NAT=true \
k6 run load_tests/fd_championship_rush.js
```

Each virtual buyer requests the listing, the event page and an order with no pause between them, so all 600 orders arrive within about a second. That is harsher than a real sales open.

---

## Telemetry Checks During & Immediately After the Run

### 1. Render Metrics (`hafapass-api` & `hafapass-worker`)
- Confirm zero OOM restarts, memory stays comfortably below container ceiling (2 GB on `standard` / 512 MB on `starter`).
- Confirm CPU and request queue time remain bounded during the burst.
- Check API logs for `[Rack::Attack] Throttled` (should be zero) and `checkout_network_cap_denied` (confirm `HAFAPASS_MAX_HELD_TICKETS_PER_IP` matched expected shared-NAT concurrency).

### 2. Neon PostgreSQL Metrics
- Peak active connections must stay below the configured connection limit (with `WEB_CONCURRENCY=2`, `DB_POOL=15` + worker `DB_POOL=10`, max pool footprint is 40).
- Check slow query logs / lock wait time on `events` row locks during `POST /api/v1/orders`.
- Verify zero oversells and clean hold reconciliation:

```sql
-- 1. Zero oversells: sold tickets must never exceed quantity_available
SELECT id, event_id, name, quantity_available, quantity_sold
FROM ticket_types
WHERE id IN (<FREE_TICKET_TYPE_ID>, <PAID_TICKET_TYPE_ID>);

-- 2. Reconcile active/expired inventory holds after the 10-minute hold TTL elapses
SELECT status, COUNT(*) AS hold_rows, COALESCE(SUM(quantity), 0) AS total_qty
FROM inventory_holds
WHERE event_id IN (<FREE_EVENT_ID>, <PAID_EVENT_ID>)
GROUP BY status;

-- 3. Verify Solid Queue job backlog drains to zero with no failed executions
SELECT COUNT(*) AS failed_jobs FROM solid_queue_failed_executions;
SELECT COUNT(*) AS ready_jobs FROM solid_queue_ready_executions;
```

---

## Cleanup After Staging Rehearsal

1. Wait 10+ minutes after `paid_holds` to verify `ExpireInventoryHoldsJob` expires all unpaid holds and releases inventory back to `available_quantity`.
2. Archive or purge the `[LOAD TEST]` fixtures and synthetic orders (`load-*@example.invalid`) in the isolated staging database using the approved staging purge process (never run synthetic purge against production).
3. Save the `SUMMARY_OUT` JSON artifact (contains only aggregate counts and latency percentiles — zero PII or credentials) for the pre-June-10 readiness review.
