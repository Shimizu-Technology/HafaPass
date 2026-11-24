# Local evidence for the Saturday rush tooling (Nov 24, 2026)

Mac mini M4 (shared with other workers), k6 2.4.0, PostgreSQL 16.16 on localhost, commit `050b390c` plus this branch. `RAILS_ENV=staging` (production settings and `StageSafety`), simulated payments, plain HTTP with `FORWARDED_PROTO=https`, `HAFAPASS_RUNTIME=embedded`, `WEB_CONCURRENCY=2 RAILS_MAX_THREADS=5 DB_POOL=11`, throwaway secrets from `scripts/rush_test/local_stage_env.sh`. Everything ran against `localhost` and a task-owned database. **These are not hosted capacity numbers.** Nothing was run against Render, Neon, Stripe or production.

## Puma cluster boot and Sentry after fork

Booted with `bundle exec puma -C script/rush_test/puma_sentry_probe.rb` (the real `config/puma.rb` plus one per-worker probe), `SENTRY_DSN` pointing at `scripts/rush_test/fake_sentry_sink.py` on 127.0.0.1:

```
Puma starting in cluster mode ... Max threads: 5, Environment: staging, Workers: 2, Preloading application
rush_sentry_probe phase=boot worker=1 pid=59002 sentry_initialized=true sending_allowed=true environment=rush-copy event_id=924cacb5...
rush_sentry_probe phase=boot worker=0 pid=59001 sentry_initialized=true sending_allowed=true environment=rush-copy event_id=47b33ad0...
rush_sentry_probe phase=late worker=1 pid=59002 ... event_id=8548c3b4...      (20 s later)
rush_sentry_probe phase=late worker=0 pid=59001 ... event_id=413f6afd...
```

The sink received four labelled events (environment `rush-copy`, tags `worker_index` 0 and 1, the matching PIDs), then about 300 more events, mostly sampled transactions from the load runs (default 0.1 rate).

With only `SENTRY_ENVIRONMENT=rush-copy` set (no `SENTRY_ENABLED_ENVIRONMENTS`), both workers logged `sending_allowed=false event_id=NONE` and the sink received nothing. That is runbook gap G6.

`solid_queue_processes` showed one `Supervisor(async)`, its dispatcher, scheduler and two workers, all with worker 0's PID (59001) and none with the master's. Readiness returned `ready`. The existing `spec/config/puma_cluster_spec.rb` also passes (see below).

## Fixture, k6 and consistency check

Each run used a fresh fixture from `seed_fixture.rb` (free and paid event, capacity 200 each, payout-ready fictional organizer), run through `run_k6.sh` (preflight passed each time).

| Run | Counts | Latency p50 / p95 (ms) | Note |
| --- | --- | --- | --- |
| Free burst, 250 VUs | 200 sold, 50 clean sold-out, 0 unexpected 422, 0 429, 0 5xx | listing 2293 / 2994, event 527 / 1662, order 2410 / 4355 | Targets missed locally (listing p95 300, order p95 1500), as PR #232 found. Sold out in 6.9 s |
| Paid burst, 60 VUs | 60 orders, no errors | order 893 / 1802 | `simulate`: orders complete at once, no Stripe call, no `payment_resume` (runbook G8) |
| Both, ramp, peak 40 buyers/s each | 200 + 200 accepted, 250 clean sold-out, 0 unexpected 422, 0 5xx, **132 `429`** | order 477 / 2119 (free), 1181 / 2674 (paid) | The 429s come from the per-IP 5-minute counter shared with the two earlier runs (runbook G7) |

`consistency_check.rb` over those four events: all 12 checks passed (no oversell, counters equal tickets, no overdue holds, no failed jobs, backlog empty, one supervisor, no reconciliation exceptions, no email accepted by a real provider). Negative test: setting a counter to 1 with no tickets made the check fail with exit status 1. A database CHECK constraint forbids `quantity_sold > quantity_available`, so that case cannot be forced (runbook G12).

`neon_rtt.rb` against local Postgres: `SELECT 1` p50 0.05 ms (a real Neon round trip will be orders of magnitude larger, which is the point of running it on Render).

`proc_sampler.rb` ran on macOS (the `ps` fallback). Its Linux path reads `/proc` and cgroup files and was not exercised (runbook G13).

## Offline checks

| Command | Result |
| --- | --- |
| `K6_BIN=<k6> node scripts/rush_test/check_k6_script.mjs` | 20/20: burst and ramp shapes, 12 refusal cases (no acknowledgement, empty URL, five production hosts including userinfo and trailing-dot tricks, extra host list, target mismatch, bad `SCENARIO`/`PROFILE`), zero network calls before a guard, and `k6 inspect` for both profiles |
| `python3 -m unittest scripts/test_rush_test_helpers.py` | 13 tests pass |
| `init_empty_db.sh` on an empty local database | loads the schema; refuses a second run, a name without `rush`/`staging`, and a non-Neon host |
| `scripts/rush_test/consistency.sql` through `psql` | all 8 query blocks run without error |

## Fix round 1 (review of head ac921987)

| Change | Check |
| --- | --- |
| `init_empty_db.sh` falls back to `bundle exec` when `mise` is absent | Ran it with `mise` removed from `PATH` (`command -v mise` empty, plain Ruby 3.3.14): loaded the schema into an empty local database |
| `puma_sentry_probe.rb` runs the shared guard first | With `RAILS_ENV=production` and no target it exits with all three reasons; with the local staging environment it boots two workers and each logs its boot and late probe line (Sentry off there: no DSN, so `sending_allowed=false`, as expected) |
| First-to-last `created_at` sell-out span for pending holds | `consistency_check.rb` and `consistency.sql` run against a freshly seeded local database; `collect_results.py` has a unit test for the no-completed-orders case |
| Ramp sizing against the per-IP throttles | Arithmetic only, from `rack_attack.rb` (not run: no load runs this round) |
| Part 1 prerequisites | Each requirement was read in the cited file and line; nothing was run against production |

Checks this round: `ruby -c` on all `hafapass_api/script/rush_test/*.rb`, `bash -n` on the shell scripts, `node --check` on `check_k6_script.mjs` and `fd_championship_rush.js`, `python3 -m unittest scripts/test_rush_test_helpers.py` (14 tests), `rspec spec/scripts/rush_test_guard_spec.rb` (15 examples), RuboCop on the changed Ruby. No Vite build, browser run or load run.
