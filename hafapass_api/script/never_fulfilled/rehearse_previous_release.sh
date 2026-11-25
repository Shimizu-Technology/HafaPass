#!/usr/bin/env bash
# Two-version rehearsal M-01 (docs/design/never-fulfilled-captures.md §10.3,
# §10.4): the previous release's own code and specs against THIS schema.
#
#   REHEARSAL_DIR=/path/to/scratch REHEARSAL_DB=hafapass_ncap_rehearsal_<name> \
#     script/never_fulfilled/rehearse_previous_release.sh [spec paths...]
#
# Exports the previous release (OLD_SHA, default 7bcd97c2) with `git archive`
# into REHEARSAL_DIR (no checkout or worktree), loads this branch's
# db/schema.rb into a task-owned localhost database with the old app, runs the
# old specs that touch refunds, late captures and payouts, and classifies
# every failure. Expected: the only failures are the A1-R1 guards refusing an
# old outbound refund on a fenced payment, an old payout or finalization on
# an event with an open never-fulfilled item ("Repayment fence"), a sale
# effect from a payment that does not own the sale ("Sale ownership"), or a
# note closing an evidence hold ("Evidence hold"). Any other
# failure means the new schema breaks the overlap. The database is dropped
# afterwards unless KEEP_DB=1. Never point it at a shared or remote database.
set -euo pipefail

OLD_SHA=${OLD_SHA:-7bcd97c22e0514df21f3fb2c17ebe8845e708b59}
: "${REHEARSAL_DIR:?set REHEARSAL_DIR to a scratch directory}"
: "${REHEARSAL_DB:?set REHEARSAL_DB (hafapass_ncap_rehearsal_*)}"
[[ $REHEARSAL_DB == hafapass_ncap_rehearsal_* ]] || { echo "REHEARSAL_DB must start with hafapass_ncap_rehearsal_" >&2; exit 2; }
url="postgres://${PGUSER:-agent}@localhost:5432/${REHEARSAL_DB}"

api_dir=$(cd "$(dirname "$0")/../.." && pwd)
repo_dir=$(git -C "$api_dir" rev-parse --show-toplevel)
old_root="$REHEARSAL_DIR/previous-release"
rm -rf "$old_root"
mkdir -p "$old_root"
git -C "$repo_dir" archive "$OLD_SHA" hafapass_api | tar -x -C "$old_root"
old_api="$old_root/hafapass_api"
cp "$api_dir/db/schema.rb" "$old_api/db/schema.rb"

specs=("$@")
if [[ ${#specs[@]} -eq 0 ]]; then
  specs=(spec/jobs/late_capture_refund_job_spec.rb spec/requests/webhooks_spec.rb
    spec/requests/api/v1/refund_reconciliation_spec.rb spec/requests/api/v1/admin/reconciliation_exceptions_spec.rb
    spec/requests/api/v1/admin/order_refunds_spec.rb spec/requests/api/v1/admin/fraud_refunds_spec.rb
    spec/requests/api/v1/organizer/refunds_spec.rb spec/jobs/event_cancellation_refund_job_spec.rb
    spec/services/commerce/refund_creator_spec.rb spec/services/payout_reserves_spec.rb)
fi

cleanup() {
  if [[ ${KEEP_DB:-0} != 1 ]]; then
    (cd "$old_api" && DATABASE_URL="$url" RAILS_ENV=test bin/rails db:drop >/dev/null 2>&1) || true
  fi
}
trap cleanup EXIT

cd "$old_api"
export RAILS_ENV=test DATABASE_URL="$url" LANG=${LANG:-en_US.UTF-8} LC_ALL=${LC_ALL:-en_US.UTF-8}
echo "previous release ${OLD_SHA} on schema $(git -C "$repo_dir" rev-parse HEAD) (database ${REHEARSAL_DB})"
bin/rails db:create db:schema:load >/dev/null
psql "$url" -Atc "SELECT count(*) || ' fence triggers' FROM pg_trigger WHERE tgname IN ('refunds_repayment_fence', 'payouts_repayment_fence', 'repayment_operations_check')"
set +e
bundle exec rspec "${specs[@]}" --format progress --format json --out "$REHEARSAL_DIR/previous-release-rspec.json" >"$REHEARSAL_DIR/previous-release-rspec.log" 2>&1
set -e
ruby -rjson -e '
  data = JSON.parse(File.read(ARGV[0]))
  failed = data["examples"].select { |example| example["status"] == "failed" }
  guards = ["Repayment fence", "Sale ownership", "Evidence hold"]
  fence, other = failed.partition { |example| guards.any? { |guard| example.dig("exception", "message").to_s.include?(guard) } }
  puts data["summary_line"]
  puts "fence refusals: #{fence.size}"
  fence.each { |example| puts "  FENCE  #{example["id"]} #{example["full_description"]}" }
  puts "other failures: #{other.size}"
  other.each { |example| puts "  OTHER  #{example["id"]} #{example["full_description"]}\n         #{example.dig("exception", "message").to_s.lines.first(3).join("         ")}" }
  exit(other.empty? ? 0 : 1)
' "$REHEARSAL_DIR/previous-release-rspec.json"
