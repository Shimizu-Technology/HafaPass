#!/usr/bin/env bash
# A2 overlap rehearsal (design §8.10.11, §10.4 step 5, M-09): the merged A1
# release (a0b25ffe) and this release run as separate `bin/rails runner`
# processes against ONE task-owned localhost database, with Stripe and the
# payout gateway stubbed (two_process/stubs.rb). The database starts on A1's
# own schema with data A1 wrote (finalized versions, submitted, pending,
# held and paid payouts), and is upgraded by this branch's migrations (as
# bin/release-migrate does). A1 then acts during the overlap; captures and
# payout steps race across the two processes in both orders; this release
# settles the affected event; the authorized custody derivation runs; the
# R2-2 example gets a later live capture. Saved: calls.jsonl (every
# gateway submission by process), outcomes.jsonl, exports/<tag>/*.csv,
# preflight and custody outputs, comparisons and assertions.txt. Any FAIL
# exits nonzero.
#
#   REHEARSAL_DIR=<scratch dir> REHEARSAL_DB=hafapass_ncap_rehearsal_<name> \
#     script/never_fulfilled/rehearse_a2_overlap.sh
#
# The previous release is exported with `git archive` (no checkout). The
# database is dropped afterwards unless KEEP_DB=1. Never point it at a
# shared or remote database.
set -euo pipefail

OLD_SHA=${OLD_SHA:-a0b25ffea0795ffee98ae8a3360a75c21828561c}
: "${REHEARSAL_DIR:?set REHEARSAL_DIR to a scratch directory}"
: "${REHEARSAL_DB:?set REHEARSAL_DB (hafapass_ncap_rehearsal_*)}"
[[ $REHEARSAL_DB == hafapass_ncap_rehearsal_* ]] || { echo "REHEARSAL_DB must start with hafapass_ncap_rehearsal_" >&2; exit 2; }
url="postgres://${PGUSER:-agent}@localhost:5432/${REHEARSAL_DB}"

api_dir=$(cd "$(dirname "$0")/../.." && pwd)
repo_dir=$(git -C "$api_dir" rev-parse --show-toplevel)
step_rb="$api_dir/script/never_fulfilled/a2_overlap/step.rb"
old_root="$REHEARSAL_DIR/previous-release"
old_api="$old_root/hafapass_api"
if [[ ! -f "$old_api/Gemfile" ]]; then
  rm -rf "$old_root"
  mkdir -p "$old_root"
  git -C "$repo_dir" archive "$OLD_SHA" hafapass_api | tar -x -C "$old_root"
fi
# Both processes must share the test secret_key_base (HMAC payee identities
# in payout-method approvals); each app tree would otherwise generate its own.
(cd "$api_dir" && RAILS_ENV=test bin/rails runner 'Rails.application.secret_key_base' >/dev/null 2>&1)
mkdir -p "$old_api/tmp"
cp "$api_dir/tmp/local_secret.txt" "$old_api/tmp/local_secret.txt"
rm -rf "$REHEARSAL_DIR"/calls.jsonl "$REHEARSAL_DIR"/outcomes.jsonl "$REHEARSAL_DIR"/stripe_ledger.json \
  "$REHEARSAL_DIR"/state.json "$REHEARSAL_DIR"/*.reached "$REHEARSAL_DIR"/*.release "$REHEARSAL_DIR"/exports \
  "$REHEARSAL_DIR"/assertions.txt "$REHEARSAL_DIR"/compare_*.txt "$REHEARSAL_DIR"/preflight_*.txt
touch "$REHEARSAL_DIR/calls.jsonl" "$REHEARSAL_DIR/outcomes.jsonl"

export RAILS_ENV=test DATABASE_URL="$url" REHEARSAL_DIR LANG=${LANG:-en_US.UTF-8} LC_ALL=${LC_ALL:-en_US.UTF-8}
cleanup() {
  if [[ ${KEEP_DB:-0} != 1 ]]; then
    (cd "$api_dir" && bin/rails db:drop >/dev/null 2>&1) || true
  fi
}
trap cleanup EXIT

run() { # role step [env...]
  local role=$1 step=$2 dir
  shift 2
  dir=$([[ $role == old ]] && echo "$old_api" || echo "$api_dir")
  echo "== $role $step"
  (cd "$dir" && env REHEARSAL_ROLE="$role" "$@" bin/rails runner "$step_rb" "$step") >>"$REHEARSAL_DIR/runner.log" 2>&1
}
task() { # output rake-task [env...]
  local out=$1
  shift
  echo "== new rake $1"
  (cd "$api_dir" && env REHEARSAL_ROLE=new "${@:2}" bin/rails "$1") >"$REHEARSAL_DIR/$out" 2>>"$REHEARSAL_DIR/runner.log"
}
wait_for() {
  local file="$REHEARSAL_DIR/$1.reached" deadline=$((SECONDS + 120))
  until [[ -f $file ]]; do
    (( SECONDS < deadline )) || { echo "pause $1 never reached" >&2; exit 1; }
    sleep 0.2
  done
}
release() { touch "$REHEARSAL_DIR/$1.release"; }
reset_pause() { rm -f "$REHEARSAL_DIR/$1.reached" "$REHEARSAL_DIR/$1.release"; }

: >"$REHEARSAL_DIR/runner.log"
echo "A1 ${OLD_SHA} and candidate $(git -C "$repo_dir" rev-parse HEAD) on database ${REHEARSAL_DB}"
(cd "$old_api" && bin/rails db:drop db:create db:schema:load >/dev/null 2>&1)
run old u_a1_data
run old exports EXPORT_TAG=baseline
echo "== new db:migrate (upgrade from A1's schema; dump to the scratch directory)"
(cd "$api_dir" && SCHEMA="$REHEARSAL_DIR/upgraded_schema.rb" bin/rails db:migrate) >>"$REHEARSAL_DIR/runner.log" 2>&1
run new upgrade_state
run new exports EXPORT_TAG=upgraded
task preflight_before.txt never_fulfilled:a2_preflight

# Overlap: A1 acts on the migrated database.
run old o_a1_actions

# Capture first: A1's capture of B is paused inside its transaction; this
# release's paid recording waits on the event, then reads it.
run old x_old_capture REHEARSAL_KEY=race REHEARSAL_PAUSE=capture &
old_pid=$!
wait_for capture
run new x_new_paid_race_pre &
new_pid=$!
sleep 2
release capture
wait "$old_pid"
wait "$new_pid"
reset_pause capture
run new x_new_paid_race_gap
# Payout first: this release's submission is paused after its
# authorization; A1's capture of B waits for it.
run new x_new_submit_race2 REHEARSAL_PAUSE=submission_audit &
new_pid=$!
wait_for submission_audit
run old x_old_capture REHEARSAL_KEY=race2 &
old_pid=$!
sleep 2
release submission_audit
wait "$new_pid"
wait "$old_pid"
reset_pause submission_audit
run new x_state

# After drain: this release alone.
run new n_affected
run new n_p4_anchor
run old o_p4_episode
run new n_p4_paid
# A2 recheck finding 1: A1 reverses a paid transfer on an affected event,
# paused before its commit while this release asks for the released amount.
run new n_rev_paid
run old o_rev_a1_reverse REHEARSAL_PAUSE=reversal_audit &
old_pid=$!
wait_for reversal_audit
run new n_rev_reserve_race &
new_pid=$!
sleep 2
release reversal_audit
wait "$old_pid"
wait "$new_pid"
reset_pause reversal_audit
run new n_rev_after
run new n_plain
run new n_ordinary
run old o_a1_ordinary
task derive_dry_run.txt payout_custody:derive
run new n_derive
run new n_baseline
task derive_baseline.txt payout_custody:derive DRY_RUN=0 AUTHORIZED_BY="FIN-A2" \
  PUBLISHED_BASELINE="$REHEARSAL_DIR/published_baseline.csv"
task custody_verify.txt payout_custody:verify
run new exports EXPORT_TAG=before_r22_capture
run old exports EXPORT_TAG=a1_before_r22_capture
run new n_r22_capture
run new exports EXPORT_TAG=after_r22_capture
run old exports EXPORT_TAG=a1_after_r22_capture
task preflight_after.txt never_fulfilled:a2_preflight
run new assertions

compare() { # out baseline candidate
  ruby "$api_dir/script/never_fulfilled/compare_exports.rb" "$REHEARSAL_DIR/exports/$2" "$REHEARSAL_DIR/exports/$3" \
    >"$REHEARSAL_DIR/$1" 2>&1 || true
}
# The upgrade changes no export (CodeRabbit 4703321706): this comparison is
# a gate, so a difference in a pre-existing column stops the rehearsal before
# its summary. The r22 comparisons are expected to differ and stay reports.
ruby "$api_dir/script/never_fulfilled/compare_exports.rb" "$REHEARSAL_DIR/exports/baseline" \
  "$REHEARSAL_DIR/exports/upgraded" >"$REHEARSAL_DIR/compare_upgrade.txt" 2>&1 \
  || { cat "$REHEARSAL_DIR/compare_upgrade.txt"; echo "upgrade export comparison failed" >&2; exit 1; }
compare compare_r22_candidate.txt before_r22_capture after_r22_capture
compare compare_r22_a1.txt a1_before_r22_capture a1_after_r22_capture

ruby -rjson - "$REHEARSAL_DIR" <<'RUBY' | tee "$REHEARSAL_DIR/summary.txt"
dir = ARGV[0]
read = ->(name) { File.readlines(File.join(dir, name)).map { |line| JSON.parse(line) } }
puts "gateway submissions:"
read.call("calls.jsonl").select { |call| call["kind"] == "payout_submit" }.each { |call| puts "  #{call['role']} payout #{call['payout_id']} #{call['amount_cents']}" }
puts "outcomes:"
read.call("outcomes.jsonl").each { |row| puts "  #{row['role']} #{row['step']} #{row.reject { |k, _| %w[role step].include?(k) }.to_json}" }
%w[compare_upgrade.txt compare_r22_candidate.txt compare_r22_a1.txt preflight_before.txt preflight_after.txt derive_dry_run.txt derive_baseline.txt custody_verify.txt].each do |name|
  puts "#{name}:"
  File.readlines(File.join(dir, name)).each { |line| puts "  #{line}" }
end
puts "assertions:"
puts File.read(File.join(dir, "assertions.txt"))
RUBY
! grep -q '^FAIL' "$REHEARSAL_DIR/assertions.txt"
