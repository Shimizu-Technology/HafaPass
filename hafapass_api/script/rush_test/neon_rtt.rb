# frozen_string_literal: true

# Measures database round-trip time (RTT) from the API host to Neon. Run it in the Render
# shell of the isolated copy, because that is where the checkout's ~80 statements under the
# event lock actually pay the RTT. Read-only: it only runs SELECT 1 and SHOW.
#
#   HAFAPASS_RUSH_TARGET=<api host> bin/rails runner script/rush_test/neon_rtt.rb
#
# It measures the pooled endpoint (DATABASE_URL, what the app uses) and, when set, the direct
# endpoint (DATABASE_MIGRATION_URL). Prints host and database name only, never the URL.
# Optional: RTT_SAMPLES (default 300). RUSH_OUT=path also writes JSON.
require "json"
require "pg"
require_relative "guard"

RushTest::Guard.check_environment!

samples = Integer(ENV.fetch("RTT_SAMPLES", "300"))
abort "RTT_SAMPLES must be 20..5000" unless samples.between?(20, 5000)

percentile = lambda do |sorted, fraction|
  sorted[[(sorted.size * fraction).ceil - 1, 0].max]
end
now_ms = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0 }

measure = lambda do |label, url|
  uri = URI.parse(url)
  connect_times = Array.new(5) do
    started = now_ms.call
    conn = PG.connect(url)
    conn.exec("SELECT 1")
    elapsed = now_ms.call - started
    conn.close
    elapsed
  end
  conn = PG.connect(url)
  10.times { conn.exec("SELECT 1") } # warm up the connection and the pooler
  times = Array.new(samples) do
    started = now_ms.call
    conn.exec("SELECT 1")
    now_ms.call - started
  end.sort
  txn_times = Array.new([samples / 3, 20].max) do
    started = now_ms.call
    conn.exec("BEGIN")
    conn.exec("SELECT 1")
    conn.exec("COMMIT")
    now_ms.call - started
  end.sort
  max_connections = conn.exec("SHOW max_connections").getvalue(0, 0)
  server_version = conn.exec("SHOW server_version").getvalue(0, 0)
  conn.close
  round = ->(value) { value.round(2) }
  {
    label: label, host: uri.host, database: uri.path.delete_prefix("/"), server_version: server_version, max_connections: max_connections.to_i,
    new_connection_ms: { median: round.call(connect_times.sort[connect_times.size / 2]), max: round.call(connect_times.max) },
    select_1_ms: { n: times.size, min: round.call(times.first), p50: round.call(percentile.call(times, 0.50)),
                   p95: round.call(percentile.call(times, 0.95)), p99: round.call(percentile.call(times, 0.99)), max: round.call(times.last) },
    begin_select_commit_ms: { n: txn_times.size, p50: round.call(percentile.call(txn_times, 0.50)), p95: round.call(percentile.call(txn_times, 0.95)) }
  }
end

report = { generated_at: Time.now.utc.iso8601, endpoints: [] }
report[:endpoints] << measure.call("pooled (DATABASE_URL, used by the app)", ENV.fetch("DATABASE_URL"))
direct = ENV["DATABASE_MIGRATION_URL"].to_s
report[:endpoints] << measure.call("direct (DATABASE_MIGRATION_URL)", direct) unless direct.empty?

p50 = report[:endpoints].first[:select_1_ms][:p50]
report[:estimate] = {
  note: "A winning checkout runs about 76-89 statements under the event lock (PR #232). Locked time per sale is roughly statements x pooled p50.",
  locked_ms_per_sale_low: (76 * p50).round, locked_ms_per_sale_high: (89 * p50).round,
  sell_out_seconds_for_200_low: (200 * 76 * p50 / 1000.0).round(1), sell_out_seconds_for_200_high: (200 * 89 * p50 / 1000.0).round(1)
}

puts JSON.pretty_generate(report)
File.write(ENV["RUSH_OUT"], JSON.pretty_generate(report)) if ENV["RUSH_OUT"].to_s != ""
