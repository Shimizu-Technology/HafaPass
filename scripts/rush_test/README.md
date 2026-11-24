# Rush test helpers

Tools for the hosted rush test in [docs/SATURDAY_2026-11-28_RUNBOOK.md](../../docs/SATURDAY_2026-11-28_RUNBOOK.md). All of them are made for an **isolated copy** of the API (or a local throwaway database) and refuse anything else. None of them can be switched off with a flag.

The guard (`hafapass_api/script/rush_test/guard.rb`, and the same rules in `preflight.sh` and `load_tests/fd_championship_rush.js`) requires:

- `RAILS_ENV=staging`, so `StageSafety` has already refused live Stripe keys and required test identity;
- `HAFAPASS_RUSH_TARGET`, typed by you, equal to the exact host of `PUBLIC_API_URL`;
- a target and database host that are not production (`hafapass-api.onrender.com`, `*.hafapass.com`, `*.shimizu-technology.com`, `hafapass.netlify.app`, plus `HAFAPASS_PRODUCTION_HOSTS`);
- a database whose name contains both `rush` and `staging`, with `DATABASE_URL` equal to `STAGING_DATABASE_URL`;
- for seeding: no real buyer, no event that is not titled `[LOAD TEST]`, no live payment.

## Where things live

The Render image contains only `hafapass_api/`, so anything that runs on the copy sits under `hafapass_api/script/rush_test/`. Tools that run on your laptop sit here.

| File | Runs on | What it does |
| --- | --- | --- |
| `init_empty_db.sh` | laptop | Loads the committed schema into a new empty Neon database (`db:schema:load`); refuses non-empty databases |
| `preflight.sh` | laptop | Read-only checks of the copy before load (revision, config, readiness, fixtures, k6) |
| `run_k6.sh` | laptop | Preflight, then k6 with `SCENARIO` and `PROFILE`; writes summary and start/end times |
| `check_k6_script.mjs` | anywhere | Offline self-check of the k6 script (burst/ramp shapes, host guards). Needs Node, uses `k6 inspect` too if k6 is on `PATH` or `K6_BIN` |
| `collect_results.py` | laptop | Fills the automated rows of the results sheet from the files above |
| `consistency.sql` | Neon SQL editor | Read-only oversell, hold, queue and connection queries |
| `local_stage_env.sh` | local only | Exports a production-mode local environment with throwaway secrets (never real ones) |
| `fake_sentry_sink.py` | local only | Local stand-in for Sentry's ingest endpoint, to prove which workers report |
| `hafapass_api/script/rush_test/seed_fixture.rb` | Render shell | Seeds a free and a paid `[LOAD TEST]` event per run label |
| `.../consistency_check.rb` | Render shell | Read-only checks; exit 1 on failure; writes JSON |
| `.../neon_rtt.rb` | Render shell | Round-trip time to Neon (pooled and direct) |
| `.../pg_sampler.rb` | Render shell | Samples `pg_stat_activity` during the run |
| `.../proc_sampler.rb` | Render shell | CPU and memory per Puma process and cgroup |
| `.../puma_sentry_probe.rb` | Render (Docker command, once) | Sends one labelled Sentry message from every Puma worker after fork |

## Local rehearsal

```sh
export PATH=$HOME/.pixi/bin:$PATH        # Mac mini: psql, createdb
createdb -h localhost hafapass_<you>_rush_staging
cd hafapass_api
source ../scripts/rush_test/local_stage_env.sh hafapass_<you>_rush_staging
bundle exec rails db:schema:load
RUSH_RUN_LABEL=local1 bundle exec rails runner script/rush_test/seed_fixture.rb
bundle exec puma -C script/rush_test/puma_sentry_probe.rb &   # or -C config/puma.rb; wait for "Listening"
cd ..
# Use the slugs and ids the seed script printed (the example values are for RUSH_RUN_LABEL=local1 on a fresh database).
BASE_URL=http://localhost:3108 FORWARDED_PROTO=https SCENARIO=free_saturation PROFILE=burst FREE_VUS=250 \
  ORG_SLUG=rush-test-org EVENT_SLUG=load-test-copa-rush-free-local1 TICKET_TYPE_ID=1 \
  RUN_LABEL=local-free-burst scripts/rush_test/run_k6.sh
```

Local numbers compare code revisions. They are not hosted capacity.

## Tests

`python3 -m unittest scripts/test_rush_test_helpers.py` (preflight refusals, result evaluation, k6 self-check) and `bundle exec rspec spec/scripts/rush_test_guard_spec.rb` (guard rules and the `DB_POOL` arithmetic).
