-- Read-only consistency queries for the rush copy, for the Neon SQL editor.
-- Same checks as hafapass_api/script/rush_test/consistency_check.rb. Paste one block at a time.
-- RUN ONLY ON THE ISOLATED COPY'S DATABASE (hafapass_rush_staging). Every statement is a SELECT.
-- To limit to one run, replace  e.title LIKE '[LOAD TEST]%'  with  e.id IN (<ids from seed_fixture.rb>).

-- 1. Oversell. Every column named *_over must be 0 rows. (A database CHECK also forbids sold > available.)
SELECT e.id AS event_id, tt.id AS ticket_type_id, tt.name, tt.quantity_available, tt.quantity_sold,
       COALESCE((SELECT SUM(h.quantity) FROM inventory_holds h
                 WHERE h.ticket_type_id = tt.id AND h.status = 0 AND h.expires_at > now()), 0) AS live_hold_qty,
       (SELECT COUNT(*) FROM tickets t WHERE t.ticket_type_id = tt.id AND t.status <> 2) AS tickets_not_cancelled
FROM ticket_types tt JOIN events e ON e.id = tt.event_id
WHERE e.title LIKE '[LOAD TEST]%'
ORDER BY e.id, tt.id;
-- Pass when, for every row: quantity_sold + live_hold_qty <= quantity_available AND quantity_sold = tickets_not_cancelled.

-- 2. Event capacity: tickets + live holds must not exceed max_capacity.
SELECT e.id, e.title, e.max_capacity,
       (SELECT COUNT(*) FROM tickets t WHERE t.event_id = e.id AND t.status <> 2) AS tickets_not_cancelled,
       COALESCE((SELECT SUM(h.quantity) FROM inventory_holds h
                 WHERE h.event_id = e.id AND h.status = 0 AND h.expires_at > now()), 0) AS live_hold_qty
FROM events e WHERE e.title LIKE '[LOAD TEST]%' ORDER BY e.id;

-- 2b. Completed orders without tickets must be 0 (a counter and capacity can both look fine while this is wrong).
SELECT COUNT(*) AS completed_orders_without_tickets
FROM orders o JOIN events e ON e.id = o.event_id
WHERE e.title LIKE '[LOAD TEST]%' AND o.status = 1
  AND NOT EXISTS (SELECT 1 FROM tickets t WHERE t.order_id = o.id);

-- 3. Sell-out timing (server clock). Completion is empty while paid orders are still pending holds
--    (PAYMENT_MODE=test); use seconds_first_to_last_order_created then.
SELECT e.id AS event_id, COUNT(o.id) AS orders_total,
       COUNT(o.id) FILTER (WHERE o.status = 1) AS orders_completed,
       MIN(o.created_at) AS first_order_at, MAX(o.completed_at) AS last_completed_at,
       ROUND(EXTRACT(EPOCH FROM (MAX(o.completed_at) - MIN(o.created_at)))::numeric, 1) AS seconds_first_order_to_last_completion,
       MAX(o.created_at) AS last_order_created_at,
       ROUND(EXTRACT(EPOCH FROM (MAX(o.created_at) - MIN(o.created_at)))::numeric, 1) AS seconds_first_to_last_order_created
FROM events e LEFT JOIN orders o ON o.event_id = e.id
WHERE e.title LIKE '[LOAD TEST]%' GROUP BY e.id ORDER BY e.id;

-- 4. Holds by status. After the 10-minute hold TTL plus a minute, status 0 (active) with expires_at in the past must be 0 rows.
SELECT h.status, COUNT(*) AS hold_rows, COALESCE(SUM(h.quantity), 0) AS total_qty,
       COUNT(*) FILTER (WHERE h.status = 0 AND h.expires_at <= now()) AS overdue
FROM inventory_holds h JOIN events e ON e.id = h.event_id
WHERE e.title LIKE '[LOAD TEST]%' GROUP BY h.status ORDER BY h.status;

-- 5. Solid Queue health. failed and ready_backlog should both be 0 a minute after the load ends.
SELECT (SELECT COUNT(*) FROM solid_queue_failed_executions) AS failed,
       (SELECT COUNT(*) FROM solid_queue_ready_executions) AS ready_backlog,
       (SELECT COUNT(*) FROM solid_queue_claimed_executions) AS claimed,
       (SELECT COUNT(*) FROM reconciliation_exceptions WHERE resolved_at IS NULL) AS open_reconciliation_exceptions;

-- 6. Processes: expect exactly one Supervisor(async) row, and its Worker/Dispatcher/Scheduler rows all share the PID of ONE Puma worker.
SELECT kind, pid, hostname, COUNT(*) AS processes,
       MAX(EXTRACT(EPOCH FROM now() - last_heartbeat_at))::int AS seconds_since_heartbeat
FROM solid_queue_processes GROUP BY 1, 2, 3 ORDER BY 1, 2;

-- 7. No real email: nothing may be accepted by a real provider (status 1 = sent, 4 = delivered).
SELECT provider, status, COUNT(*) AS messages FROM message_deliveries GROUP BY 1, 2 ORDER BY 1, 2;

-- 8. Database connections right now (during the run this is the pooler's server-side view; compare with the Neon dashboard).
SELECT COUNT(*) AS total,
       COUNT(*) FILTER (WHERE state = 'active') AS active,
       COUNT(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_transaction,
       COUNT(*) FILTER (WHERE wait_event_type = 'Lock') AS lock_waiters
FROM pg_stat_activity
WHERE datname = current_database() AND backend_type = 'client backend';
SHOW max_connections;
