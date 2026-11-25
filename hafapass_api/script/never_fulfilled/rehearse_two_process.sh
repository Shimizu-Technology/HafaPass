#!/usr/bin/env bash
# Two-process rehearsal (A1-R1 review release gate): the pinned previous
# release (7bcd97c2) and this release run as separate `bin/rails runner`
# processes against ONE task-owned localhost database, with Stripe and the
# payout gateway stubbed (two_process/stubs.rb; a shared JSON ledger stands
# in for Stripe). The database starts on the previous release's own schema
# with data that release wrote, and is upgraded by this branch's migrations
# (as bin/release-migrate does). The old process is paused inside its
# stubbed calls (after its last refund gate, at its lookup before the gate,
# at the payout gateway) and while holding an order lock, while the new
# process acts. The assertions step checks the saved postconditions
# (assertions.txt); any FAIL makes the script exit nonzero.
#
#   REHEARSAL_DIR=<scratch dir> REHEARSAL_DB=hafapass_ncap_rehearsal_<name> \
#     script/never_fulfilled/rehearse_two_process.sh
#
# Writes calls.jsonl (every provider call, by process), outcomes.jsonl (every
# action and its result), exports_{old,new}.json (CPA and BPT rows) and
# summary.txt to REHEARSAL_DIR. The previous release is exported with
# `git archive` (no checkout or worktree). The database is dropped
# afterwards unless KEEP_DB=1. Never point it at a shared or remote database.
set -euo pipefail

OLD_SHA=${OLD_SHA:-7bcd97c22e0514df21f3fb2c17ebe8845e708b59}
: "${REHEARSAL_DIR:?set REHEARSAL_DIR to a scratch directory}"
: "${REHEARSAL_DB:?set REHEARSAL_DB (hafapass_ncap_rehearsal_*)}"
[[ $REHEARSAL_DB == hafapass_ncap_rehearsal_* ]] || { echo "REHEARSAL_DB must start with hafapass_ncap_rehearsal_" >&2; exit 2; }
url="postgres://${PGUSER:-agent}@localhost:5432/${REHEARSAL_DB}"

api_dir=$(cd "$(dirname "$0")/../.." && pwd)
repo_dir=$(git -C "$api_dir" rev-parse --show-toplevel)
step_rb="$api_dir/script/never_fulfilled/two_process/step.rb"
old_root="$REHEARSAL_DIR/previous-release"
old_api="$old_root/hafapass_api"
if [[ ! -f "$old_api/Gemfile" ]]; then
  rm -rf "$old_root"
  mkdir -p "$old_root"
  git -C "$repo_dir" archive "$OLD_SHA" hafapass_api | tar -x -C "$old_root"
fi
rm -f "$REHEARSAL_DIR"/calls.jsonl "$REHEARSAL_DIR"/outcomes.jsonl "$REHEARSAL_DIR"/stripe_ledger.json \
  "$REHEARSAL_DIR"/state.json "$REHEARSAL_DIR"/*.reached "$REHEARSAL_DIR"/*.release "$REHEARSAL_DIR"/exports_*.json \
  "$REHEARSAL_DIR"/assertions.txt

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
echo "previous release ${OLD_SHA} and $(git -C "$repo_dir" rev-parse HEAD) on database ${REHEARSAL_DB}"
# A leftover rehearsal database of this exact name (KEEP_DB=1) is replaced.
# Upgrade path: the previous release's schema and its own data first.
(cd "$old_api" && bin/rails db:drop db:create db:schema:load >/dev/null 2>&1)
run old u_existing_data
run old exports EXPORT_TAG=baseline
echo "== new db:migrate (upgrade from the previous release's schema)"
# The schema dump after the migration goes to the scratch directory, never
# over the committed db/schema.rb.
(cd "$api_dir" && SCHEMA="$REHEARSAL_DIR/upgraded_schema.rb" bin/rails db:migrate) >>"$REHEARSAL_DIR/runner.log" 2>&1
run new exports EXPORT_TAG=upgraded
run new u_upgrade_checks
run old u_old_redact_orphan

run new setup
run new u_after_redaction
run old r1_old_reserve
run old r2_old_pre_fence_reservation

# The old worker passes its last gate for a row already marked unknown and
# is paused inside its POST; the new release adjudicates meanwhile.
run old r3_old_retry_past_gate REHEARSAL_PAUSE=post &
old_pid=$!
wait_for post
run new r3_new_adjudicate
release post
wait "$old_pid" || true
reset_pause post
run new r3_new_adjudicate_after

# The old worker replays an unsent reservation and is paused at its lookup,
# before its last gate; the new release adjudicates meanwhile.
run old r4_old_replay_unsent REHEARSAL_PAUSE=lookup &
old_pid=$!
wait_for lookup
run new r4_new_adjudicate
release lookup
wait "$old_pid" || true
reset_pause lookup

# Old inbound writers first, then the same signed notices in this release
# (Stripe redelivers a notice whose processing failed).
run old r5_inbound_refund_on_isolated_b
run new r5_inbound_refund_on_isolated_b
run old r6_dispute_on_pending_b
run new r6_dispute_on_pending_b
run new r6_new_capture_b
run old r7_inbound_refund_on_legacy_a
run new r7_inbound_refund_on_legacy_a

# Payouts: two pending payouts reserved before the hold. The old process
# submits one, is paused at the gateway after its authorization while the
# hold opens, then records the outcome. Then both releases try to submit the
# other, reserve, finalize and record paid after the hold.
run new r8_reserve REHEARSAL_KEY=first REHEARSAL_AMOUNT=4000
run new r8_reserve REHEARSAL_KEY=second
run old r8_submit REHEARSAL_PAUSE=payout_gateway REHEARSAL_KEY=first &
old_pid=$!
wait_for payout_gateway
run new r8_open_block
release payout_gateway
wait "$old_pid" || true
reset_pause payout_gateway
run old r8_submit REHEARSAL_KEY=second
run new r8_submit REHEARSAL_KEY=second
run new r8_reserve REHEARSAL_KEY=after_hold
run old r8_finalize
# Paid recording: a post-hold and a pre-hold transfer time in each release.
run old r8_record_paid
run new r8_record_paid
# Held release in both releases.
run new r8_hold_second
run old r8_release_held
run new r8_release_held

# Blocker 1: A's $13.60 sale, classified B refunded $7.00, then Stripe's
# $6.60 refund on A to the old release first, then to this one (twice).
run new r10_state
run old r10_refund_a
run new r10_refund_a

# Blocker 3: the old release acknowledges B's capture after A fulfilled
# (two orders); it redacts one receipt; this release sees the hold and
# verify, then recovers one by redelivery and one by the scheduled job.
run old r12_old_capture_b REHEARSAL_KEY=x
run old r12_old_capture_b REHEARSAL_KEY=y
run old r12_old_redact_receipt REHEARSAL_KEY=y
run new r12_check_held
run new verify_task
run old r12_old_finalize
run new r12_new_redeliver
run new r12_new_reconcile
# A return written after classification: refused for B by the old release
# and recorded by this one; written by the old release on an order-scope
# capture and posted by reconcile.
run old r12_refund_b
run new r12_refund_b
run old r12_old_late_return
run new r12_new_post_late_return

# Upgrade data: the old release acknowledges a second capture on the sale
# it fulfilled before the upgrade, and holds that order's lock while this
# release discovers it (lock contention).
run old u_old_capture_on_legacy_sale
run old r13_hold_order_lock REHEARSAL_PAUSE=order_lock &
old_pid=$!
wait_for order_lock
run new u_new_discover_legacy_sale &
new_pid=$!
sleep 1
release order_lock
wait "$old_pid" || true
wait "$new_pid"
reset_pause order_lock
run new verify_task

# Readers on a fully returned never-fulfilled order in an ordinary event.
run old r9_readers
run new r9_readers

run old exports
run new exports
run new payout_history
run new assertions
(cd "$api_dir" && REHEARSAL_ROLE=new bin/rails never_fulfilled:release_evidence R1_SHA="$(git -C "$repo_dir" rev-parse HEAD)" \
  R1_LIVE_AT="$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
  >"$REHEARSAL_DIR/release_evidence.txt" 2>>"$REHEARSAL_DIR/runner.log") || echo "release evidence failed (see runner.log)"

ruby -rjson -rdigest - "$REHEARSAL_DIR" <<'RUBY' | tee "$REHEARSAL_DIR/summary.txt"
dir = ARGV[0]
read = ->(name) { File.exist?(File.join(dir, name)) ? File.readlines(File.join(dir, name)).map { |line| JSON.parse(line) } : [] }
puts "provider calls:"
read.call("calls.jsonl").each { |call| puts "  #{call['role']} #{call.reject { |k, _| %w[role at].include?(k) }.to_json}" }
puts "outcomes:"
read.call("outcomes.jsonl").each { |row| puts "  #{row['role']} #{row['step']} #{row.reject { |k, _| %w[role step].include?(k) }.to_json}" }
old, new = %w[old new].map { |role| JSON.parse(File.read(File.join(dir, "exports_#{role}.json"))) }
# CPA: like-format comparison by column name (A2 may add columns), plus
# whole-export hashes. BPT: rows compared by event.
puts "cpa: old sha256=#{Digest::SHA256.hexdigest(JSON.generate(old['cpa']))} new sha256=#{Digest::SHA256.hexdigest(JSON.generate(new['cpa']))}"
puts "  header old=#{old['cpa_header'].length} new=#{new['cpa_header'].length} columns, #{old['cpa_header'] == new['cpa_header'] ? 'same' : 'different'}"
shared = old["cpa_header"] & new["cpa_header"]
key = ->(header, row) { [row[header.index("row_type") || 0], row[header.index("organization_id") || 2], row[header.index("event_id") || 4]] }
old["cpa"].each do |row|
  match = new["cpa"].find { |other| key.call(new["cpa_header"], other) == key.call(old["cpa_header"], row) }
  diffs = shared.reject { |column| match && row[old["cpa_header"].index(column)] == match[new["cpa_header"].index(column)] }
  next if match && diffs.empty?

  puts "  #{key.call(old['cpa_header'], row).join('/')} differs: " +
    diffs.map { |column| "#{column} #{row[old['cpa_header'].index(column)].inspect}->#{match && match[new['cpa_header'].index(column)].inspect}" }.join("; ")
end
puts "bpt: old sha256=#{Digest::SHA256.hexdigest(JSON.generate(old['bpt']))} new sha256=#{Digest::SHA256.hexdigest(JSON.generate(new['bpt']))}"
puts "  rows old=#{old['bpt'].length} new=#{new['bpt'].length} #{old['bpt'] == new['bpt'] ? 'identical' : 'differ'}"
baseline, upgraded = %w[baseline upgraded].map { |tag| JSON.parse(File.read(File.join(dir, "exports_#{tag}.json"))) }
%w[cpa bpt].each do |kind|
  puts "upgrade #{kind}: before migration sha256=#{Digest::SHA256.hexdigest(JSON.generate(baseline[kind]))} " \
    "after sha256=#{Digest::SHA256.hexdigest(JSON.generate(upgraded[kind]))} rows=#{baseline[kind].length}/#{upgraded[kind].length}"
end
puts "assertions:"
puts File.read(File.join(dir, "assertions.txt"))
RUBY
! grep -q '^FAIL' "$REHEARSAL_DIR/assertions.txt"
