# frozen_string_literal: true

# Read-only post-run consistency check for the isolated copy: oversell, hold and ticket
# reconciliation, queue health, process layout and outbound email. It writes nothing
# (the whole run is one READ ONLY transaction).
#
#   cd hafapass_api            # on Render: the shell already starts in /app
#   HAFAPASS_RUSH_TARGET=<api host> RUSH_EVENT_IDS=12,13 bin/rails runner script/rush_test/consistency_check.rb
#
# RUSH_EVENT_IDS (from seed_fixture.rb) limits it to one run's events; default is every
# [LOAD TEST] event. RUSH_OUT=path also writes the JSON there (scripts/rush_test/collect_results.py reads it).
# Exit status 1 when any check fails. The same queries as plain SQL: scripts/rush_test/consistency.sql.
require "json"
require_relative "guard"

RushTest::Guard.check_environment!

conn = ActiveRecord::Base.connection
ids = ENV.fetch("RUSH_EVENT_IDS", "").split(",").map { |value| Integer(value.strip) }
scope = ids.empty? ? "e.title LIKE '[LOAD TEST]%'" : "e.id IN (#{ids.join(',')})"
rows = lambda do |sql|
  conn.select_all(sql).to_a
end
one = ->(sql) { conn.select_value(sql).to_i }

report = { generated_at: Time.now.utc.iso8601, rails_env: Rails.env, event_ids: ids, checks: [], tables: {} }
add = lambda do |name, value, ok, note = nil|
  report[:checks] << { name: name, value: value, pass: ok, note: note }.compact
end

conn.transaction do
  conn.execute("SET TRANSACTION READ ONLY")

  ticket_types = rows.call(<<~SQL)
    SELECT e.id AS event_id, e.title, tt.id AS ticket_type_id, tt.name, tt.price_cents,
           tt.quantity_available, tt.quantity_sold,
           COALESCE((SELECT SUM(h.quantity) FROM inventory_holds h
                     WHERE h.ticket_type_id = tt.id AND h.status = 0 AND h.expires_at > now()), 0)::int AS active_hold_qty,
           (SELECT COUNT(*) FROM tickets t WHERE t.ticket_type_id = tt.id AND t.status <> 2)::int AS tickets_not_cancelled
    FROM ticket_types tt JOIN events e ON e.id = tt.event_id
    WHERE #{scope} ORDER BY e.id, tt.id
  SQL
  report[:tables][:ticket_types] = ticket_types

  oversold = ticket_types.select { |row| row["quantity_sold"].to_i > row["quantity_available"].to_i }
  add.call("oversell: quantity_sold <= quantity_available (ticket types over)", oversold.size, oversold.empty?,
    oversold.map { |row| "type #{row['ticket_type_id']}: sold #{row['quantity_sold']} > #{row['quantity_available']}" }.join("; ").presence)
  over_with_holds = ticket_types.select { |row| row["quantity_sold"].to_i + row["active_hold_qty"].to_i > row["quantity_available"].to_i }
  add.call("oversell: sold + live holds <= quantity_available (ticket types over)", over_with_holds.size, over_with_holds.empty?)
  drift = ticket_types.select { |row| row["quantity_sold"].to_i != row["tickets_not_cancelled"].to_i }
  add.call("counter agrees with tickets: quantity_sold == non-cancelled tickets (ticket types that differ)", drift.size, drift.empty?,
    drift.map { |row| "type #{row['ticket_type_id']}: counter #{row['quantity_sold']}, tickets #{row['tickets_not_cancelled']}" }.join("; ").presence)

  events = rows.call(<<~SQL)
    SELECT e.id AS event_id, e.title, e.max_capacity,
           (SELECT COUNT(*) FROM tickets t WHERE t.event_id = e.id AND t.status <> 2)::int AS tickets_not_cancelled,
           COALESCE((SELECT SUM(h.quantity) FROM inventory_holds h WHERE h.event_id = e.id AND h.status = 0 AND h.expires_at > now()), 0)::int AS active_hold_qty
    FROM events e WHERE #{scope} ORDER BY e.id
  SQL
  report[:tables][:events] = events
  over_capacity = events.select { |row| row["max_capacity"] && row["tickets_not_cancelled"].to_i + row["active_hold_qty"].to_i > row["max_capacity"].to_i }
  add.call("event capacity: tickets + live holds <= max_capacity (events over)", over_capacity.size, over_capacity.empty?)

  # Sell-out time: first order created until the last ticket issued (server clock, seconds).
  timing = rows.call(<<~SQL)
    SELECT e.id AS event_id, e.title,
           COUNT(o.id)::int AS orders_total,
           COUNT(o.id) FILTER (WHERE o.status = 1)::int AS orders_completed,
           MIN(o.created_at) AS first_order_at,
           MAX(o.completed_at) AS last_completed_at,
           ROUND(EXTRACT(EPOCH FROM (MAX(o.completed_at) - MIN(o.created_at)))::numeric, 1) AS first_order_to_last_completion_seconds
    FROM events e LEFT JOIN orders o ON o.event_id = e.id
    WHERE #{scope} GROUP BY e.id, e.title ORDER BY e.id
  SQL
  report[:tables][:event_timing] = timing

  orders = rows.call(<<~SQL)
    SELECT o.event_id, o.status, COUNT(*)::int AS orders, COALESCE(SUM(o.total_cents), 0)::bigint AS total_cents
    FROM orders o JOIN events e ON e.id = o.event_id WHERE #{scope} GROUP BY 1, 2 ORDER BY 1, 2
  SQL
  report[:tables][:orders_by_status] = orders
  no_tickets = one.call(<<~SQL)
    SELECT COUNT(*) FROM orders o JOIN events e ON e.id = o.event_id
    WHERE #{scope} AND o.status = 1 AND NOT EXISTS (SELECT 1 FROM tickets t WHERE t.order_id = o.id)
  SQL
  add.call("every completed order has at least one ticket (completed orders without tickets)", no_tickets, no_tickets.zero?)

  holds = rows.call(<<~SQL)
    SELECT h.status, COUNT(*)::int AS hold_rows, COALESCE(SUM(h.quantity), 0)::int AS total_qty
    FROM inventory_holds h JOIN events e ON e.id = h.event_id WHERE #{scope} GROUP BY 1 ORDER BY 1
  SQL
  report[:tables][:inventory_holds_by_status] = holds.map { |row| row.merge("status_name" => %w[active consumed released expired][row["status"].to_i]) }
  overdue = one.call("SELECT COUNT(*) FROM inventory_holds h JOIN events e ON e.id = h.event_id WHERE #{scope} AND h.status = 0 AND h.expires_at <= now()")
  add.call("no overdue active holds (run again 11+ minutes after paid_holds; expiry job runs every minute)", overdue, overdue.zero?)

  failed = one.call("SELECT COUNT(*) FROM solid_queue_failed_executions")
  ready = one.call("SELECT COUNT(*) FROM solid_queue_ready_executions")
  claimed = one.call("SELECT COUNT(*) FROM solid_queue_claimed_executions")
  oldest_ready = conn.select_value("SELECT COALESCE(EXTRACT(EPOCH FROM now() - MIN(created_at)), 0)::int FROM solid_queue_ready_executions").to_i
  add.call("Solid Queue failed executions", failed, failed.zero?)
  add.call("Solid Queue ready backlog drained (jobs waiting)", ready, ready.zero?, "oldest ready job #{oldest_ready}s old; claimed now: #{claimed}")

  processes = rows.call(<<~SQL)
    SELECT kind, pid, hostname, COUNT(*)::int AS processes,
           MAX(EXTRACT(EPOCH FROM now() - last_heartbeat_at))::int AS seconds_since_heartbeat
    FROM solid_queue_processes GROUP BY 1, 2, 3 ORDER BY 1, 2
  SQL
  report[:tables][:solid_queue_processes] = processes
  stale = processes.select { |row| row["seconds_since_heartbeat"].to_i > 90 }
  add.call("Solid Queue processes all heartbeating within 90s (stale rows)", stale.size, stale.empty?)
  supervisors = processes.select { |row| row["kind"].to_s.start_with?("Supervisor") }
  workers = processes.select { |row| row["kind"] == "Worker" }
  add.call("one embedded supervisor, in Puma worker 0 (supervisor rows; expected exactly 1 while the API is up)", supervisors.size, supervisors.size == 1,
    "worker PIDs: #{workers.map { |row| row['pid'] }.uniq.join(',')}")

  open_exceptions = one.call("SELECT COUNT(*) FROM reconciliation_exceptions WHERE resolved_at IS NULL")
  add.call("open reconciliation exceptions", open_exceptions, open_exceptions.zero?)

  deliveries = rows.call("SELECT provider, status, COUNT(*)::int AS messages FROM message_deliveries GROUP BY 1, 2 ORDER BY 1, 2")
  report[:tables][:message_deliveries] = deliveries
  real_sent = one.call("SELECT COUNT(*) FROM message_deliveries WHERE provider ILIKE '%resend%' AND status IN (1, 4)")
  add.call("no email accepted by a real provider (resend, status sent/delivered)", real_sent, real_sent.zero?)

  report[:tables][:public_cache_generation] = rows.call("SELECT name, value FROM public_cache_generations")
end

report[:pass] = report[:checks].all? { |check| check[:pass] }
puts "== Rush consistency check (#{report[:generated_at]}) =="
report[:checks].each do |check|
  puts format("%-5s %s = %s%s", check[:pass] ? "PASS" : "FAIL", check[:name], check[:value], check[:note] ? "  (#{check[:note]})" : "")
end
puts "\nTickets per type:"
report[:tables][:ticket_types].each do |row|
  puts format("  event %-4s type %-4s %-10s sold %5s / %-5s live holds %-4s tickets %s", row["event_id"], row["ticket_type_id"],
    row["name"], row["quantity_sold"], row["quantity_available"], row["active_hold_qty"], row["tickets_not_cancelled"])
end
puts "\nSell-out timing (first order created -> last order completed):"
report[:tables][:event_timing].each do |row|
  puts format("  event %-4s orders %-5s completed %-5s %s s", row["event_id"], row["orders_total"], row["orders_completed"],
    row["first_order_to_last_completion_seconds"] || "n/a")
end
puts "\nOverall: #{report[:pass] ? 'PASS' : 'FAIL'}"
puts "JSON: " + JSON.generate(report)
File.write(ENV["RUSH_OUT"], JSON.pretty_generate(report)) if ENV["RUSH_OUT"].present?
exit(report[:pass] ? 0 : 1)
