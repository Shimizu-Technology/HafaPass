#!/usr/bin/env bash
# Loads the committed schema into a NEW, EMPTY database for the rush copy (no migration replay;
# see docs/SATURDAY_2026-11-28_RUNBOOK.md and PR #235). Run from your laptop in a clone at the
# commit you will deploy (Ruby from .ruby-version and `bundle install` in hafapass_api done),
# with the DIRECT Neon URL of the copy:
#
#   RUSH_COPY_DIRECT_URL='postgres://...' scripts/rush_test/init_empty_db.sh
#
# Refuses unless: the database name contains both "rush" and "staging", the host is a Neon host
# (or localhost), the host is not a production host, and the database has no tables. Other
# StageSafety values are throwaway ones from local_stage_env.sh; the only network use is the connection to that database.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
url="${RUSH_COPY_DIRECT_URL:?set RUSH_COPY_DIRECT_URL to the direct database URL of the rush copy}"
db="$(printf '%s' "$url" | sed -E 's#^[a-z]+://[^/]*/([^?]*).*#\1#')"
host="$(printf '%s' "$url" | sed -E 's#^[a-z]+://([^@/]*@)?([^/:?]+).*#\2#' | tr '[:upper:]' '[:lower:]')"
case "$db" in *rush*staging*) ;; *) echo "FAIL database name '$db' must contain 'rush' and 'staging'" >&2; exit 2 ;; esac
case "$host" in localhost|127.0.0.1|*.neon.tech) ;; *) echo "FAIL host '$host' is not a Neon or local host" >&2; exit 2 ;; esac
case "$host" in *hafapass*|*shimizu-technology*) echo "FAIL host '$host' looks like production" >&2; exit 2 ;; esac
echo "Target host: $host   database: $db"

cd "$here/../../hafapass_api"
# shellcheck disable=SC1091
source "$here/local_stage_env.sh" "hafapass_rush_init_staging" >/dev/null
export DATABASE_URL="$url" STAGING_DATABASE_URL="$url" DATABASE_MIGRATION_URL="$url"
run() {
  local out rc=0
  if command -v mise >/dev/null 2>&1; then
    out="$(mise exec -- bundle exec rails "$@" 2>&1)" || rc=$?
  else
    out="$(bundle exec rails "$@" 2>&1)" || rc=$?
  fi
  if [[ "$rc" -eq 0 ]]; then
    printf '%s\n' "$out" | grep -v 'Stripe' || true   # drop the harmless "No Stripe keys" banner on success only
  else
    printf '%s\n' "$out" >&2                          # on failure show everything, including lines that mention Stripe
  fi
  return "$rc"
}
run runner script/rush_test/empty_check.rb
run db:schema:load
run runner script/rush_test/loaded_check.rb
