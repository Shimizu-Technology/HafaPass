# Fresh database initialization

W7 verified HafaPass's Rails database setup for developers and isolated Copa rush-test copies. The Copa round brief identifies `050b390c` as the production migration baseline. All migration files at that commit are treated as already applied in production.

## Reproduction on main

Tested `050b390c` on the Mac mini with Ruby 3.3.14 and PostgreSQL 16.16. Every Rails database command used a verified task-owned local URL. From `hafapass_api`, on a new database:

```sh
export RAILS_ENV=development DATABASE_URL=postgresql://localhost:5432/hafapass_w7_dev
test "$RAILS_ENV" = development && test "$DATABASE_URL" = postgresql://localhost:5432/hafapass_w7_dev &&
  printf '%s %s\n' "$RAILS_ENV" "$DATABASE_URL" &&
  bundle exec rails db:create db:migrate
```

That command exited zero with `Created database 'hafapass_w7_dev'` and 138 entries in `schema_migrations`. Rails 8.1 initializes an empty database from the committed schema during `db:migrate` when the dump is available.

After dropping that task database and confirming the override file did not exist, repeating the command with `SCHEMA` set to a missing path exercised historical replay:

```sh
export SCHEMA="$PWD/tmp/w7-absent-schema.rb"
test ! -e "$SCHEMA" &&
  test "$RAILS_ENV" = development && test "$DATABASE_URL" = postgresql://localhost:5432/hafapass_w7_dev &&
  printf '%s %s\n' "$RAILS_ENV" "$DATABASE_URL" &&
  bundle exec rails db:create db:migrate
unset SCHEMA
```

Exit 1, excerpt:

```text
== 20260720000002 AddCheckoutRecoveryAndTicketSecurity: migrating =============
StandardError: An error has occurred, this and all later migrations canceled: (StandardError)

Undeclared attribute type for enum 'fee_policy_snapshot' in Order. Enums must be backed by a database column or declared with an explicit type via `attribute`.
…/db/migrate/20260720000002_add_checkout_recovery_and_ticket_security.rb:13:in `up'
```

Line 13 calls `Order.find_each` for the reference backfill. Active Record initializes the current model's enums even on an empty table. The earlier schema lacks `orders.fee_policy_snapshot`, which migration `20260720230000` adds later. Replay stopped at the first failure.

## Supported setup and CI check

Load the committed schema on empty databases. Apply pending migrations to existing databases as usual. This preserves the release path and all migration files. A squashed baseline or a compatibility shim for the historical model would introduce another migration path to maintain. It could also hide later replay failures, which were beyond the first failure observed here.

CI now runs the following in the existing Backend / RSpec job, after PostgreSQL creates the empty test database:

```sh
bundle exec rails db:schema:load
bundle exec rails db:migrate db:schema:dump
git diff --exit-code -- db/schema.rb
```

The first round trip reported two equivalent PostgreSQL check constraint expressions with different cast placement. The patch records the PostgreSQL 16 dump form for those two constraints. On `RAILS_ENV=test` and `DATABASE_URL=postgresql://localhost:5432/hafapass_w7_test`, the commands then exited zero. No migrations ran, the schema diff was empty, and PostgreSQL reported `138|20261124160000` for the migration count and latest version. The check verifies the committed baseline. Apply each new migration to a database loaded from the preceding schema to verify its upgrade behavior.

## Setup and upgrade checks

- Fresh development setup passed with `bundle exec rails db:create db:schema:load db:seed` on a recreated `hafapass_w7_dev`. Output included `Created 10 events (9 published, 1 draft).` and `Created 73 orders with 188 tickets (0 checked in).`
- Forward upgrade passed on `hafapass_w7_upgrade_test`. Loaded the PR #232 schema (`git show debe3fb9:hafapass_api/db/schema.rb`) via a temporary `SCHEMA` file and ran `bundle exec rails db:migrate db:schema:dump`. Seven migrations ran, from `20261124140000 CreateEmailBase` through `20261124160000 PinEmailConsentIdentity`. `cmp db/schema.rb "$SCHEMA"` exited zero.

## Regression checks

Agent-executed on the Mac mini, with PostgreSQL 16.16, Ruby 3.3.14, and bundled Chromium via Node 22.23.5.

| Command | Result |
| --- | --- |
| `python3 ../scripts/ci_rspec.py` from `hafapass_api` | 4,170 examples, 0 failures. The two task-owned shards ran 1,948 and 2,222 examples. The helper verified every example ran exactly once. |
| `npm run lint` | Passed. |
| `npm run test:e2e -- --workers=2` | 233 passed on the first attempt. One Gate F evidence case timed out waiting for its submit button to enable, then passed on CI-mode retry. The targeted rerun with one worker and `--retries=0` passed. |
| `VITE_HAFAPASS_DEMO_DATA=0 npm run build` and `npx playwright test --config playwright.production.config.js` | Build passed. One flag-off checkout passed. |
| `CONTEXT=deploy-preview VITE_HAFAPASS_DEMO_DATA=1 npm run build` and `VITE_HAFAPASS_DEMO_DATA=1 npx playwright test --config playwright.demo.config.js --workers=2` | Build passed. All 27 demo-preview tests passed. |
| `npm run test:e2e:pwa` | Both deploy/offline tests passed. |

Browser commands ran under the shared lock. This change has no UI or new preview path. WebKit was outside the round's supported browser coverage on this host.
