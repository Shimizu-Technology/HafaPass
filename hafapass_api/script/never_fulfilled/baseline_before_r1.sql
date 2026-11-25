-- Read-only baseline before A1-R1 (docs/design/never-fulfilled-captures.md
-- §10.5, first row). Uses only tables that exist at 7bcd97c2. Changes
-- nothing: one READ ONLY transaction ending with ROLLBACK.
--
-- psql "$READ_ONLY_DATABASE_URL" -v ON_ERROR_STOP=1 -f script/never_fulfilled/baseline_before_r1.sql
BEGIN TRANSACTION READ ONLY;

SELECT 'late_capture_orders' AS section, re.code, re.status, count(DISTINCT re.order_id) AS orders,
  count(DISTINCT re.payment_id) AS payments
FROM reconciliation_exceptions re
WHERE re.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry',
  'pass_all_included_nights_cancelled')
GROUP BY re.code, re.status ORDER BY re.code, re.status;

SELECT 'finalized_settlements_on_late_capture_events' AS section, count(*) AS settlements
FROM settlements s WHERE s.status = 1 AND s.event_id IN (
  SELECT o.event_id FROM orders o JOIN reconciliation_exceptions re ON re.order_id = o.id
  WHERE re.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry',
    'pass_all_included_nights_cancelled'));

-- payouts.status: 0 pending, 1 processing, 5 held.
SELECT 'payouts_on_late_capture_events' AS section, py.status, count(*) AS payouts, sum(py.amount_cents) AS cents
FROM payouts py WHERE py.status IN (0, 1, 5) AND py.event_id IN (
  SELECT o.event_id FROM orders o JOIN reconciliation_exceptions re ON re.order_id = o.id
  WHERE re.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry',
    'pass_all_included_nights_cancelled'))
GROUP BY py.status ORDER BY py.status;

-- refunds.status 0 = pending.
SELECT 'refunds_provider_result_unknown' AS section, count(*) AS refunds,
  count(*) FILTER (WHERE idempotency_key LIKE 'late-capture:payment:%') AS late_capture_key
FROM refunds WHERE status = 0 AND failure_code = 'provider_result_unknown';

SELECT 'late_capture_refunds_by_status' AS section, status, count(*) AS refunds
FROM refunds WHERE idempotency_key LIKE 'late-capture:payment:%' GROUP BY status ORDER BY status;

ROLLBACK;
