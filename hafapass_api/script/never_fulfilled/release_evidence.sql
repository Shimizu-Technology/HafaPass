-- Read-only release evidence for A1-R1 and A1-R2
-- (docs/design/never-fulfilled-captures.md §10.5; runbook in
-- docs/NEVER_FULFILLED_RELEASE.md). It changes nothing: the whole script runs
-- in one READ ONLY transaction that ends with ROLLBACK.
--
-- psql:  psql "$READ_ONLY_DATABASE_URL" -v ON_ERROR_STOP=1 \
--          -v r1_sha=<40-hex R1 commit> -v r1_live_at='<ISO-8601 UTC time R1 went live>' \
--          -v bound_seconds=770 -f script/never_fulfilled/release_evidence.sql
-- rake:  bin/rails never_fulfilled:release_evidence R1_SHA=... R1_LIVE_AT=...
--        (same file, same read-only transaction; bound from the code).
-- Needs the A1-R1 schema. Before A1-R1, record baseline_before_r1.sql instead.
BEGIN TRANSACTION READ ONLY;

-- 1. Fence and integrity triggers installed (boundary item 1).
SELECT 'triggers' AS section, t.tgname, c.relname AS table_name, t.tgenabled
FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
WHERE NOT t.tgisinternal AND t.tgname IN (
  'payments_capture_recorded_at', 'never_fulfilled_captures_check', 'never_fulfilled_captures_mark_order',
  'never_fulfilled_captures_append_only', 'never_fulfilled_captures_no_truncate', 'orders_fulfillment_guard',
  'tickets_issuance_guard', 'refunds_success_recorded_at', 'disputes_recorded_at', 'buyer_return_postings_check',
  'buyer_return_postings_append_only', 'buyer_return_postings_no_truncate', 'repayment_operations_check',
  'repayment_operations_no_truncate', 'refunds_repayment_fence', 'payouts_repayment_fence')
ORDER BY t.tgname;

SELECT 'unvalidated_constraints' AS section, conrelid::regclass::text AS table_name, conname
FROM pg_constraint
WHERE NOT convalidated AND conrelid::regclass::text IN
  ('orders', 'payments', 'refunds', 'never_fulfilled_captures', 'buyer_return_postings', 'repayment_operations')
ORDER BY 2, 3;

SELECT 'cutovers' AS section, key, recorded_at FROM financial_cutovers ORDER BY recorded_at;

-- 2. Old processes gone (boundary item 3b). Every recently heartbeating
-- Solid Queue process and every claimed execution must carry the R1 SHA.
SELECT 'live_processes' AS section, kind, name, hostname, last_heartbeat_at,
  metadata::jsonb ->> 'application_revision' AS application_revision,
  (metadata::jsonb ->> 'application_revision') IS DISTINCT FROM :'r1_sha' AS other_revision
FROM solid_queue_processes
WHERE last_heartbeat_at > timezone('UTC', now()) - interval '90 seconds'
ORDER BY other_revision DESC, kind, name;

SELECT 'claimed_by_other_revision' AS section, count(*) AS claimed_executions
FROM solid_queue_claimed_executions ce JOIN solid_queue_processes p ON p.id = ce.process_id
WHERE (p.metadata::jsonb ->> 'application_revision') IS DISTINCT FROM :'r1_sha';

SELECT 'runtime_ticks' AS section, task_key, application_revision, last_succeeded_at
FROM runtime_executions ORDER BY task_key, application_revision;

-- 3. Durable job audit (boundary item 4): refund work enqueued before R1 went
-- live and not finished, by state.
SELECT 'refund_jobs_before_r1' AS section, j.class_name,
  CASE WHEN ce.id IS NOT NULL THEN 'claimed' WHEN se.id IS NOT NULL THEN 'scheduled' WHEN re.id IS NOT NULL THEN 'ready'
    WHEN fe.id IS NOT NULL THEN 'failed' ELSE 'other' END AS state,
  count(*) AS jobs
FROM solid_queue_jobs j
LEFT JOIN solid_queue_claimed_executions ce ON ce.job_id = j.id
LEFT JOIN solid_queue_scheduled_executions se ON se.job_id = j.id
LEFT JOIN solid_queue_ready_executions re ON re.job_id = j.id
LEFT JOIN solid_queue_failed_executions fe ON fe.job_id = j.id
WHERE j.finished_at IS NULL AND j.created_at < (:'r1_live_at')::timestamptz AT TIME ZONE 'UTC'
  AND j.class_name IN ('LateCaptureRefundJob', 'EventCancellationRefundJob', 'RefundReconciliationJob')
GROUP BY 2, 3 ORDER BY 2, 3;

-- Outbound refunds on fenced payments that no repayment operation sent
-- (legacy rows, including an adopted operation 1), with when each may be
-- adjudicated: submission + in-flight bound. adjudicable = false means a
-- request that may still land; it is never treated as absent.
WITH fenced AS (
  SELECT p.id FROM payments p WHERE hafapass_fenced_payment(p.id)
), submitted AS (
  SELECT auditable_id AS refund_id, max(occurred_at) AS at FROM audit_logs
  WHERE action = 'refund.submission_requested' AND auditable_type = 'Refund' GROUP BY auditable_id
)
SELECT 'legacy_refunds_on_fenced_payments' AS section, r.id AS refund_id, r.payment_id, r.status, r.failure_code,
  r.idempotency_key, r.amount_cents, r.repayment_operation_id, COALESCE(s.at, r.updated_at) AS submitted_at,
  COALESCE(s.at, r.updated_at) + make_interval(secs => (:'bound_seconds')::int) AS adjudicable_after,
  r.failure_code IS NULL OR COALESCE(s.at, r.updated_at) + make_interval(secs => (:'bound_seconds')::int)
    < timezone('UTC', now()) AS adjudicable
FROM refunds r JOIN fenced f ON f.id = r.payment_id LEFT JOIN submitted s ON s.refund_id = r.id
WHERE r.status = 0 AND r.provider_refund_id IS NULL AND r.idempotency_key NOT LIKE 'provider:stripe:refund:%'
  AND (r.repayment_operation_id IS NULL OR EXISTS (
    SELECT 1 FROM repayment_operations o WHERE o.id = r.repayment_operation_id AND o.adopted))
ORDER BY r.id;

SELECT 'unknown_refunds_all' AS section, count(*) AS provider_result_unknown
FROM refunds WHERE status = 0 AND failure_code = 'provider_result_unknown';

SELECT 'repayment_operations' AS section, state, adopted, count(*) AS operations, COALESCE(sum(amount_cents), 0) AS cents
FROM repayment_operations GROUP BY state, adopted ORDER BY state, adopted;

-- Orphan provider evidence still waiting for replay or finance (§7.2).
SELECT 'orphan_evidence' AS section, re.code, (re.payment_id IS NULL) AS unbound, count(*) AS open_items
FROM reconciliation_exceptions re
WHERE re.status = 0 AND re.code IN ('refund_operation_not_found', 'refunded_payment_not_found',
  'disputed_payment_not_found', 'refund_aggregate_requires_reconciliation')
GROUP BY re.code, unbound ORDER BY re.code, unbound;

-- 4. Never-fulfilled items by code (§10.5 after A1-R1: Q and R are dispositioned).
SELECT 'never_fulfilled_items' AS section, code, status, count(*) AS items
FROM reconciliation_exceptions
WHERE code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry',
  'pass_all_included_nights_cancelled', 'unfulfilled_second_capture', 'never_fulfilled_ownership_ambiguous',
  'never_fulfilled_classification_quarantined', 'never_fulfilled_return_quarantined',
  'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement', 'never_fulfilled_repayment_reopened',
  'never_fulfilled_buyer_overpaid', 'provider_payment_cancel_failed')
GROUP BY code, status ORDER BY code, status;

SELECT 'classifications' AS section, capture_scope, provenance, count(*) AS captures, sum(captured_cents) AS cents
FROM never_fulfilled_captures GROUP BY capture_scope, provenance ORDER BY 2, 3;

-- 5. Fail-closed payouts (boundary item 5): events with an open blocking item,
-- their payouts by status, and any payout on them that changed since R1.
WITH blocked_events AS (
  SELECT DISTINCT o.event_id FROM reconciliation_exceptions re
  LEFT JOIN payments p ON p.id = re.payment_id
  JOIN orders o ON o.id = COALESCE(re.order_id, p.order_id)
  WHERE re.status = 0 AND re.code IN ('late_payment_success_after_inventory_release',
    'late_payment_success_after_hold_expiry', 'pass_all_included_nights_cancelled', 'unfulfilled_second_capture',
    'never_fulfilled_ownership_ambiguous', 'never_fulfilled_classification_quarantined',
    'never_fulfilled_return_quarantined', 'never_fulfilled_backfill_ambiguous', 'never_fulfilled_backfill_restatement',
    'never_fulfilled_repayment_reopened')
)
SELECT 'payouts_on_blocked_events' AS section, py.event_id, py.status, count(*) AS payouts, sum(py.amount_cents) AS cents,
  count(*) FILTER (WHERE py.updated_at > (:'r1_live_at')::timestamptz AT TIME ZONE 'UTC') AS changed_since_r1
FROM payouts py JOIN blocked_events b ON b.event_id = py.event_id
GROUP BY py.event_id, py.status ORDER BY py.event_id, py.status;

SELECT 'finalized_settlements_on_late_capture_events' AS section, count(*) AS settlements
FROM settlements s WHERE s.status = 1 AND s.event_id IN (
  SELECT o.event_id FROM orders o JOIN reconciliation_exceptions re ON re.order_id = o.id
  WHERE re.code IN ('late_payment_success_after_inventory_release', 'late_payment_success_after_hold_expiry',
    'pass_all_included_nights_cancelled'));

ROLLBACK;
