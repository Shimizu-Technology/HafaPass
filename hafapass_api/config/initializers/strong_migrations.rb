# frozen_string_literal: true

# Migrations newer than this version must pass strong_migrations' safety
# checks; every earlier one has already run in production and is not checked.
StrongMigrations.start_after = 20261024310000

# Release migrations (bin/release-migrate, direct Neon connection) give up
# rather than queue behind live traffic, and are not cut off by the
# application role's statement_timeout (docs/OPERATIONS_RUNBOOK.md).
StrongMigrations.lock_timeout = 10.seconds
StrongMigrations.statement_timeout = 1.hour

# Production Postgres major version, so local checks match Neon.
StrongMigrations.target_version = 16
