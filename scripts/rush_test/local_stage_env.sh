#!/usr/bin/env bash
# LOCAL ONLY. Source this file to boot the API in production mode (RAILS_ENV=staging)
# on your own machine with throwaway secrets and the event-week Puma settings:
#
#   source scripts/rush_test/local_stage_env.sh [db_suffix]
#
# It never reads or prints a real secret: every value is generated here, in memory.
# It refuses to export anything unless Postgres is on localhost and the database name
# contains both "rush" and "staging" (the same two words the hosted guards require).
# Used for the local rehearsal described in docs/SATURDAY_2026-11-28_RUNBOOK.md.

_rush_db="${HAFAPASS_RUSH_LOCAL_DB:-hafapass_rush_local_staging}"
if [[ $# -gt 0 ]]; then _rush_db="$1"; fi
case "$_rush_db" in
  *rush*staging*) ;;
  *) echo "local_stage_env: database name must contain 'rush' and 'staging' (got '$_rush_db')" >&2; return 1 2>/dev/null || exit 1 ;;
esac
if [[ ! "$_rush_db" =~ ^[a-zA-Z0-9_]+$ ]]; then
  echo "local_stage_env: database name may only use letters, digits and underscores" >&2; return 1 2>/dev/null || exit 1
fi

export RAILS_ENV=staging
export DATABASE_URL="postgres://localhost:5432/${_rush_db}"
export STAGING_DATABASE_URL="$DATABASE_URL"
export PORT="${PORT:-3108}"

# Event-week topology under test (docs/SINGLE_SERVICE_RUNTIME.md).
export HAFAPASS_RUNTIME=embedded
export WEB_CONCURRENCY="${WEB_CONCURRENCY:-2}"
export RAILS_MAX_THREADS="${RAILS_MAX_THREADS:-5}"
export DB_POOL="${DB_POOL:-11}"
export HAFAPASS_MAX_HELD_TICKETS_PER_IP="${HAFAPASS_MAX_HELD_TICKETS_PER_IP:-250}"
export RACK_ATTACK_ORDERS_PER_IP_1M="${RACK_ATTACK_ORDERS_PER_IP_1M:-650}"
export RACK_ATTACK_REQ_PER_IP_5M="${RACK_ATTACK_REQ_PER_IP_5M:-3000}"
# macOS cluster mode needs these two (see load_tests/README.md).
export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES
export PGGSSENCMODE=disable

# Throwaway identity and keys. StageSafety wants pk_test_/sk_test_ Clerk keys whose
# encoded domain matches CLERK_ISSUER; none of these reach any real service.
_clerk_domain="clerk.rush-local.example.test"
export CLERK_PUBLISHABLE_KEY="pk_test_$(printf '%s$' "$_clerk_domain" | base64 | tr -d '=\n')"
export CLERK_SECRET_KEY="sk_test_localrushdummy0000"
export CLERK_ISSUER="https://${_clerk_domain}"
export PUBLIC_API_URL="https://localhost"
export FRONTEND_URL="https://localhost"
export PUBLIC_WEB_URL="https://localhost"
export ALLOWED_ORIGINS="https://localhost"
export ENABLE_FIRST_USER_ADMIN_BOOTSTRAP=false
export SECRET_KEY_BASE="$(openssl rand -hex 48)"
export ADMISSION_MANIFEST_PRIVATE_KEY_PEM="$(openssl genrsa 2048 2>/dev/null)"
export ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="$(openssl rand -hex 16)"
export ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="$(openssl rand -hex 16)"
export ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="$(openssl rand -hex 16)"
export RENDER_GIT_COMMIT="${RENDER_GIT_COMMIT:-$(git rev-parse HEAD 2>/dev/null || echo 0000000000000000000000000000000000000000)}"

# Safe by construction: no provider rehearsal, no Stripe keys, no mail transport.
unset HAFAPASS_PROVIDER_REHEARSAL PROVIDER_REHEARSAL_SERVICES
unset STRIPE_LIVE_SECRET_KEY STRIPE_LIVE_PUBLISHABLE_KEY STRIPE_SECRET_KEY STRIPE_TEST_SECRET_KEY \
  STRIPE_PUBLISHABLE_KEY STRIPE_TEST_PUBLISHABLE_KEY RESEND_API_KEY SENTRY_DSN

# What the rush scripts check before they act.
export HAFAPASS_RUSH_TARGET="localhost"
export ISOLATED_LOAD_TARGET_ACK="I_ACKNOWLEDGE_THIS_CREATES_TEST_ORDERS_IN_AN_ISOLATED_ENVIRONMENT"

echo "local_stage_env: RAILS_ENV=staging db=${_rush_db} port=${PORT} WEB_CONCURRENCY=${WEB_CONCURRENCY} RAILS_MAX_THREADS=${RAILS_MAX_THREADS} DB_POOL=${DB_POOL} (throwaway secrets, nothing printed)"
unset _rush_db _clerk_domain
