# Hosted rush test results: Saturday Nov 28, 2026

Copy this file to `results-<run label>.md` (one per run) and fill it in. Every number needs a source in the right-hand column. Do not paste secrets, database URLs, buyer emails or card data. How to run each step: [runbook](../../SATURDAY_2026-11-28_RUNBOOK.md#saturday-run-order).

Pass and fail follow PR #232's targets. "Automated" rows come from `scripts/rush_test/collect_results.py`; paste its table into section 6 and still fill the manual rows.

## 1. Run identity

| Field | Value |
| --- | --- |
| Run label | |
| Date and time (Guam) / UTC | |
| Operator | |
| Copy URL (host only) | |
| Commit running on the copy (`/api/v1/health` revision) | |
| Commit on production at the time | |
| Runtime diff vs production empty? (command in the runbook) | yes / no |
| Render plan and instance count | Standard, 1 |
| Neon project, compute min/max, scale-to-zero off? | |
| `WEB_CONCURRENCY` / `RAILS_MAX_THREADS` / `DB_POOL` | 2 / 5 / 11 |
| `RACK_ATTACK_REQ_PER_IP_5M` / `..._ORDERS_PER_IP_1M` / `HAFAPASS_MAX_HELD_TICKETS_PER_IP` | |
| Payment mode (`simulate` or `test`) | |
| Scenario / profile | `paid_holds` / `burst` or `ramp` ... |
| Sizing (`PAID_VUS`, `FREE_VUS`, `RAMP_PEAK_RATE`, ...) | |
| Traffic origin (laptop network, other machines) and `SHARED_NAT` | |
| Fixture capacity (free / paid adult) | |
| k6 start and end (UTC), from `<label>.times.json` | |
| Anything unusual (other deploys, Render restarts, Neon scale events) | |

## 2. Neon round trip (Render shell, before the load)

Command: `HAFAPASS_RUSH_TARGET=<host> RUSH_OUT=/tmp/rtt.json bin/rails runner script/rush_test/neon_rtt.rb`

| Endpoint | `SELECT 1` p50 / p95 / p99 (ms) | New connection median (ms) | `max_connections` | Source |
| --- | --- | --- | --- | --- |
| Pooled (`DATABASE_URL`) | | | | `rtt.json` |
| Direct (`DATABASE_MIGRATION_URL`) | | | | `rtt.json` |

Estimated sell-out of 200 from the pooled p50 (script prints it): ______ to ______ s. PR #232's estimate: 8–18 s.

## 3. Sell-out and latency

| Measure | Result | Target | Pass / fail | Source |
| --- | --- | --- | --- | --- |
| Sell-out time (first order created to last order completed, per event) | | informational; compare with section 2 | | consistency check, `event_timing` |
| Orders accepted (201) / clean sold-out (422) | / | accepted = capacity | | k6 summary |
| Order p50 / p95 / p99 (ms), free or paid hold | / / | p95 ≤ 1,500 | | k6 summary |
| Listing p50 / p95 / p99 (ms) | / / | p95 ≤ 300 | | k6 summary (free runs only) |
| Event page p50 / p95 / p99 (ms) | / / | informational | | k6 summary |
| `payment_resume` p95 (ms), `PAYMENT_MODE=test` only | | informational | | k6 summary |
| Time from run start until listing p95 is back under 300 ms | | informational | | Render graphs |

## 4. Errors

| Measure | Count | Target | Pass / fail |
| --- | --- | --- | --- |
| `429` (throttled) | | 0 | |
| 5xx and network errors | | 0 | |
| Unexpected `422` | | 0 | |
| Stripe rate-limit errors in the API log (`PAYMENT_MODE=test`) | | 0 (a nonzero count is a test-mode limit; see runbook G8) | |
| k6 exit status | | 0 | |

Where did the first `429` or 5xx appear (time, endpoint)? _________________

## 5. Correctness (read-only; exit status of `consistency_check.rb`)

Run once after the load, and again 11+ minutes after a `PAYMENT_MODE=test` paid run.

| Check | Result | Target |
| --- | --- | --- |
| `quantity_sold` ≤ `quantity_available` (ticket types over) | | 0 |
| `quantity_sold` + live holds ≤ `quantity_available` (ticket types over) | | 0 |
| `quantity_sold` equals non-cancelled tickets (ticket types that differ) | | 0 |
| Tickets + live holds ≤ `max_capacity` (events over) | | 0 |
| Completed orders without tickets | | 0 |
| Overdue active holds (11+ min after the run) | | 0 |
| Solid Queue failed executions | | 0 |
| Solid Queue ready backlog one minute after the run | | 0 |
| Supervisor rows (one, in a single Puma worker's PID) | | 1 |
| Open reconciliation exceptions | | 0 |
| Emails accepted by a real provider | | 0 |
| Readiness (`/api/v1/readiness`) after the run | | 200 |

Oversell SQL for the Neon editor (read-only): `scripts/rush_test/consistency.sql`, block 1.

## 6. Resources

| Measure | Result | Source |
| --- | --- | --- |
| Peak database sessions (`pg_stat_activity`) | | `pg_sampler.rb` (`peak_total_connections`) |
| Peak active queries | | `pg_sampler.rb` |
| Peak lock waiters and share of busy samples (the event row lock) | / | `pg_sampler.rb` |
| Peak Neon connections (dashboard) and `max_connections` | / | Neon console |
| Neon compute: CPU, scale-up events | | Neon console |
| Peak CPU per process: master / worker 0 (supervisor) / worker 1 | / / | `proc_sampler.rb` summary |
| Peak RSS per process: master / worker 0 / worker 1 (MB) | / / | `proc_sampler.rb` summary |
| Container CPU (cores of 1) and memory (MB of 2,048) | / | `proc_sampler.rb` summary, Render graphs |
| Render request queue time, restarts, OOM | | Render metrics |
| Worker 0 vs worker 1 order latency difference visible? | | judgment, from Render logs |

Connection arithmetic to compare against: peak about 16, pool ceiling 22, 44 during a deploy.

## 7. Sentry after fork

| Check | Result |
| --- | --- |
| Probe run (`puma_sentry_probe.rb`): worker 0 `sending_allowed=true`, real `event_id` | |
| Probe run: worker 1 `sending_allowed=true`, real `event_id` | |
| Four events seen in Sentry (`probe:rush-sentry-fork`, environment `rush-copy`): boot and late, both workers | |
| Original Docker command restored and redeployed | |
| `SENTRY_ENVIRONMENT` and `SENTRY_ENABLED_ENVIRONMENTS` both set to `rush-copy` | |
| No production alert fired during the run | |
| Admin test alert (PR #238, if present) arrived | |
| An error raised during the load appeared in Sentry (optional) | |

## 8. Automated summary

Paste the output of `collect_results.py` here.

## 9. Verdict

| Question | Answer |
| --- | --- |
| Did every correctness check pass? | |
| Did order p95 meet 1,500 ms? | |
| Did listing p95 meet 300 ms? | |
| Any `429` or 5xx? | |
| Is the verdict **meets targets**, **misses latency targets only**, or **blocking**? | |
| Decision under D8 (admission control, waiting room, accept) | |
| Follow-ups | |
| Teardown done (Render, Neon, Clerk, Stripe test, Sentry)? | |
