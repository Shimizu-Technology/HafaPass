# frozen_string_literal: true

# Samples pg_stat_activity once per interval while a rush runs, and prints a summary:
# peak connections, peak active queries, and how often sessions waited on a lock (the
# event-row lock during checkout). Read-only.
#
#   HAFAPASS_RUSH_TARGET=<api host> SAMPLE_SECONDS=180 bin/rails runner script/rush_test/pg_sampler.rb
#
# Start it a few seconds before k6 and let it run past the end of the load. Ctrl-C prints
# the summary early. Optional: SAMPLE_INTERVAL (seconds, default 1), RUSH_OUT=path for JSON.
# Behind Neon's pooler (PgBouncer, transaction mode) pg_stat_activity shows the pooler's
# server-side connections, not the app's client connections: compare with the Neon dashboard.
require "json"
require_relative "guard"

RushTest::Guard.check_environment!

duration = Integer(ENV.fetch("SAMPLE_SECONDS", "120"))
interval = Float(ENV.fetch("SAMPLE_INTERVAL", "1"))
abort "SAMPLE_SECONDS must be 5..3600 and SAMPLE_INTERVAL 0.2..10" unless duration.between?(5, 3600) && interval.between?(0.2, 10)

conn = ActiveRecord::Base.connection
sql = <<~SQL
  SELECT COUNT(*)::int AS total,
         COUNT(*) FILTER (WHERE state = 'active')::int AS active,
         COUNT(*) FILTER (WHERE state = 'idle in transaction')::int AS idle_in_transaction,
         COUNT(*) FILTER (WHERE wait_event_type = 'Lock')::int AS lock_waiters,
         COUNT(*) FILTER (WHERE wait_event_type = 'Lock' AND query ILIKE '%FOR UPDATE%')::int AS row_lock_waiters
  FROM pg_stat_activity
  WHERE datname = current_database() AND pid <> pg_backend_pid() AND backend_type = 'client backend'
SQL

samples = []
stop = false
trap("INT") { stop = true }
trap("TERM") { stop = true }
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + duration
until stop || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
  row = conn.select_one(sql)
  samples << row.transform_values(&:to_i).merge("t" => Time.now.utc.iso8601(1))
  sleep interval
end

peak = ->(key) { samples.map { |sample| sample[key] }.max.to_i }
busy = samples.count { |sample| sample["active"].positive? }
waiting = samples.count { |sample| sample["lock_waiters"].positive? }
summary = {
  generated_at: Time.now.utc.iso8601, samples: samples.size, interval_seconds: interval,
  peak_total_connections: peak.call("total"), peak_active: peak.call("active"), peak_idle_in_transaction: peak.call("idle_in_transaction"),
  peak_lock_waiters: peak.call("lock_waiters"), peak_row_lock_waiters: peak.call("row_lock_waiters"),
  samples_with_any_active: busy, samples_with_lock_waiters: waiting,
  lock_wait_share_of_busy_samples: busy.zero? ? 0.0 : (waiting.to_f / busy).round(3)
}
puts JSON.pretty_generate(summary)
File.write(ENV["RUSH_OUT"], JSON.pretty_generate(summary.merge(series: samples))) if ENV["RUSH_OUT"].to_s != ""
