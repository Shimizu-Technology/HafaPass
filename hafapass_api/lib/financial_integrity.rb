# frozen_string_literal: true

require "English"

# Database guarantees for never-fulfilled capture classification
# (docs/design/never-fulfilled-captures.md §4.2). Like AuditLogIntegrity, the
# DDL is appended to the schema dump so db:schema:load/test:prepare installs
# the same triggers as a migrated production database.
#
# Lock contract (docs/LOCKING.md rank 3): classification takes the order
# FOR UPDATE, then the payment; a ticket insert takes the order FOR KEY SHARE
# (the lock its order_id foreign key already takes); a ticket reactivation or
# reassignment takes it NOWAIT, so no path waits for an order while holding a
# ticket. Each trigger locks in one statement and reads in the next: in READ
# COMMITTED every PL/pgSQL statement takes a fresh snapshot, so the read after
# a lock wait sees the other transaction's commit.
module FinancialIntegrity
  CAPTURED_PAYMENT_STATUSES = "1, 4, 5" # succeeded, partially_refunded, refunded
  CANCELLED_TICKET_STATUS = 2
  SENTINEL_TRIGGER = %w[tickets_issuance_guard tickets].freeze
  # Rails stores UTC in `timestamp without time zone` columns; database stamps match.
  NOW_UTC = "timezone('UTC', clock_timestamp())"

  CAPTURE_RECORDED_AT_SQL = <<~SQL.freeze
    CREATE OR REPLACE FUNCTION hafapass_payment_capture_recorded_at() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      captured boolean := NEW.status IN (#{CAPTURED_PAYMENT_STATUSES});
    BEGIN
      IF TG_OP = 'UPDATE' AND OLD.capture_recorded_at IS NOT NULL THEN
        IF NEW.capture_recorded_at IS DISTINCT FROM OLD.capture_recorded_at THEN
          RAISE EXCEPTION 'A payment''s capture recording time is set once' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;
      IF captured AND (TG_OP = 'INSERT' OR OLD.status NOT IN (#{CAPTURED_PAYMENT_STATUSES})) THEN
        NEW.capture_recorded_at := COALESCE(NEW.capture_recorded_at, #{NOW_UTC});
      ELSIF NEW.capture_recorded_at IS NOT NULL THEN
        RAISE EXCEPTION 'A capture recording time is written only when the payment is first captured'
          USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS payments_capture_recorded_at ON payments;
    CREATE TRIGGER payments_capture_recorded_at BEFORE INSERT OR UPDATE OF status, capture_recorded_at ON payments
      FOR EACH ROW EXECUTE FUNCTION hafapass_payment_capture_recorded_at();
  SQL

  APPEND_ONLY_SQL = <<~SQL.freeze
    CREATE OR REPLACE FUNCTION hafapass_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION '% rows are append-only', TG_TABLE_NAME USING ERRCODE = '23514';
    END;
    $$;
    -- Only the confirmed synthetic-data purge may empty these tables, with the
    -- same transaction-scoped opt-in it sets for audit_logs.
    CREATE OR REPLACE FUNCTION hafapass_append_only_truncate() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF current_setting('hafapass.audit_truncate', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION '% cannot be truncated', TG_TABLE_NAME USING ERRCODE = '23514';
      END IF;
      RETURN NULL;
    END;
    $$;
    DROP TRIGGER IF EXISTS never_fulfilled_captures_append_only ON never_fulfilled_captures;
    CREATE TRIGGER never_fulfilled_captures_append_only BEFORE UPDATE OR DELETE ON never_fulfilled_captures
      FOR EACH ROW EXECUTE FUNCTION hafapass_append_only();
    CREATE OR REPLACE TRIGGER never_fulfilled_captures_no_truncate BEFORE TRUNCATE ON never_fulfilled_captures
      FOR EACH STATEMENT EXECUTE FUNCTION hafapass_append_only_truncate();
    DROP TRIGGER IF EXISTS financial_cutovers_append_only ON financial_cutovers;
    CREATE TRIGGER financial_cutovers_append_only BEFORE UPDATE OR DELETE ON financial_cutovers
      FOR EACH ROW EXECUTE FUNCTION hafapass_append_only();
    CREATE OR REPLACE TRIGGER financial_cutovers_no_truncate BEFORE TRUNCATE ON financial_cutovers
      FOR EACH STATEMENT EXECUTE FUNCTION hafapass_append_only_truncate();
  SQL

  CLASSIFICATION_SQL = <<~SQL.freeze
    CREATE OR REPLACE FUNCTION hafapass_check_never_fulfilled_capture() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      ord orders%ROWTYPE;
      pay payments%ROWTYPE;
      cutover timestamp;
    BEGIN
      SELECT * INTO ord FROM orders WHERE id = NEW.order_id FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Classified order does not exist' USING ERRCODE = '23503';
      END IF;
      SELECT * INTO pay FROM payments WHERE id = NEW.payment_id FOR SHARE;
      IF NOT FOUND OR pay.order_id <> NEW.order_id THEN
        RAISE EXCEPTION 'A classified payment must belong to the classified order' USING ERRCODE = '23503';
      END IF;
      IF pay.status NOT IN (#{CAPTURED_PAYMENT_STATUSES}) THEN
        RAISE EXCEPTION 'Only a captured payment can be classified' USING ERRCODE = '23514';
      END IF;
      IF pay.amount_cents <> NEW.captured_cents OR lower(pay.currency) <> lower(NEW.currency) THEN
        RAISE EXCEPTION 'A classification must match its payment''s amount and currency' USING ERRCODE = '23514';
      END IF;

      IF pay.capture_recorded_at IS NOT NULL THEN
        NEW.capture_recorded_at := COALESCE(NEW.capture_recorded_at, pay.capture_recorded_at);
        IF NEW.capture_recorded_at <> pay.capture_recorded_at THEN
          RAISE EXCEPTION 'A classification must use its payment''s recorded capture time' USING ERRCODE = '23514';
        END IF;
      ELSE
        SELECT recorded_at INTO cutover FROM financial_cutovers WHERE key = 'a1_capture_recording';
        IF NEW.provenance <> 'backfill' OR NEW.capture_recorded_at IS NULL OR cutover IS NULL
            OR NEW.capture_recorded_at > cutover THEN
          RAISE EXCEPTION 'A capture recorded before A1 needs a backfilled time with evidence, no later than the cutover'
            USING ERRCODE = '23514';
        END IF;
      END IF;

      IF NEW.capture_scope = 'order' THEN
        IF ord.completed_at IS NOT NULL OR ord.status IN (0, 1) OR ord.fulfilled_by_payment_id IS NOT NULL
            OR EXISTS (SELECT 1 FROM audit_logs WHERE action = 'order.completed'
              AND deduplication_key = 'order:' || ord.id || ':completed') THEN
          RAISE EXCEPTION 'A pending or fulfilled order cannot be classified as never fulfilled' USING ERRCODE = '23514';
        END IF;
        IF EXISTS (SELECT 1 FROM tickets WHERE order_id = NEW.order_id AND status <> #{CANCELLED_TICKET_STATUS}) THEN
          RAISE EXCEPTION 'An order with active tickets cannot be classified as never fulfilled' USING ERRCODE = '23514';
        END IF;
      ELSE
        IF ord.fulfilled_by_payment_id IS NULL THEN
          RAISE EXCEPTION 'A second capture needs the order''s verified fulfilling payment' USING ERRCODE = '23514';
        END IF;
        IF ord.fulfilled_by_payment_id = NEW.payment_id THEN
          RAISE EXCEPTION 'The fulfilling payment cannot be classified as never fulfilled' USING ERRCODE = '23514';
        END IF;
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS never_fulfilled_captures_check ON never_fulfilled_captures;
    CREATE TRIGGER never_fulfilled_captures_check BEFORE INSERT ON never_fulfilled_captures
      FOR EACH ROW EXECUTE FUNCTION hafapass_check_never_fulfilled_capture();

    -- The order marker is derived from its first order-scope row, never written directly.
    CREATE OR REPLACE FUNCTION hafapass_mark_never_fulfilled_order() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.capture_scope = 'order' THEN
        UPDATE orders SET never_fulfilled_at = NEW.created_at WHERE id = NEW.order_id AND never_fulfilled_at IS NULL;
      END IF;
      RETURN NULL;
    END;
    $$;
    DROP TRIGGER IF EXISTS never_fulfilled_captures_mark_order ON never_fulfilled_captures;
    CREATE TRIGGER never_fulfilled_captures_mark_order AFTER INSERT ON never_fulfilled_captures
      FOR EACH ROW EXECUTE FUNCTION hafapass_mark_never_fulfilled_order();
  SQL

  ORDER_GUARD_SQL = <<~SQL.freeze
    CREATE OR REPLACE FUNCTION hafapass_guard_order_fulfillment() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      payment_status integer;
    BEGIN
      IF TG_OP = 'INSERT' THEN
        IF NEW.never_fulfilled_at IS NOT NULL OR NEW.fulfilled_by_payment_id IS NOT NULL THEN
          RAISE EXCEPTION 'An order''s fulfilment is recorded by its lifecycle, not at creation' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;

      IF NEW.never_fulfilled_at IS DISTINCT FROM OLD.never_fulfilled_at THEN
        IF OLD.never_fulfilled_at IS NOT NULL THEN
          RAISE EXCEPTION 'An order''s never-fulfilled marker is set once' USING ERRCODE = '23514';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM never_fulfilled_captures WHERE order_id = NEW.id AND capture_scope = 'order'
            AND created_at = NEW.never_fulfilled_at) THEN
          RAISE EXCEPTION 'The never-fulfilled marker comes only from an order-scope classification' USING ERRCODE = '23514';
        END IF;
      END IF;

      IF NEW.fulfilled_by_payment_id IS DISTINCT FROM OLD.fulfilled_by_payment_id THEN
        IF OLD.fulfilled_by_payment_id IS NOT NULL THEN
          RAISE EXCEPTION 'An order''s fulfilling payment is set once' USING ERRCODE = '23514';
        END IF;
        IF NEW.status NOT IN (1, 2, 4) THEN
          RAISE EXCEPTION 'Only a fulfilled order records its fulfilling payment' USING ERRCODE = '23514';
        END IF;
        SELECT status INTO payment_status FROM payments
          WHERE id = NEW.fulfilled_by_payment_id AND order_id = NEW.id FOR KEY SHARE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'The fulfilling payment must belong to this order' USING ERRCODE = '23503';
        END IF;
        IF payment_status NOT IN (#{CAPTURED_PAYMENT_STATUSES}) THEN
          RAISE EXCEPTION 'The fulfilling payment must be captured' USING ERRCODE = '23514';
        END IF;
        IF EXISTS (SELECT 1 FROM never_fulfilled_captures WHERE payment_id = NEW.fulfilled_by_payment_id
            OR (order_id = NEW.id AND capture_scope = 'order')) THEN
          RAISE EXCEPTION 'A never-fulfilled payment or order cannot record a fulfilling payment' USING ERRCODE = '23514';
        END IF;
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS orders_fulfillment_guard ON orders;
    CREATE TRIGGER orders_fulfillment_guard BEFORE INSERT OR UPDATE OF never_fulfilled_at, fulfilled_by_payment_id ON orders
      FOR EACH ROW EXECUTE FUNCTION hafapass_guard_order_fulfillment();
  SQL

  TICKET_GUARD_SQL = <<~SQL.freeze
    CREATE OR REPLACE FUNCTION hafapass_guard_ticket_issuance() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.status = #{CANCELLED_TICKET_STATUS} THEN
        RETURN NEW;
      END IF;
      IF TG_OP = 'UPDATE' AND OLD.status <> #{CANCELLED_TICKET_STATUS} AND OLD.order_id = NEW.order_id THEN
        RETURN NEW;
      END IF;
      IF TG_OP = 'INSERT' THEN
        PERFORM 1 FROM orders WHERE id = NEW.order_id FOR KEY SHARE;
      ELSE
        BEGIN
          PERFORM 1 FROM orders WHERE id = NEW.order_id FOR KEY SHARE NOWAIT;
        EXCEPTION WHEN lock_not_available THEN
          RAISE EXCEPTION 'Lock the order before reactivating or reassigning a ticket' USING ERRCODE = '55P03';
        END;
      END IF;
      IF EXISTS (SELECT 1 FROM orders WHERE id = NEW.order_id AND never_fulfilled_at IS NOT NULL)
          OR EXISTS (SELECT 1 FROM never_fulfilled_captures WHERE order_id = NEW.order_id AND capture_scope = 'order') THEN
        RAISE EXCEPTION 'Tickets cannot be issued on a never-fulfilled order' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS tickets_issuance_guard ON tickets;
    CREATE TRIGGER tickets_issuance_guard BEFORE INSERT OR UPDATE OF order_id, status ON tickets
      FOR EACH ROW EXECUTE FUNCTION hafapass_guard_ticket_issuance();
  SQL

  # Tranche 1 (migration 20261126100300). Frozen: that migration replays it.
  FOUNDATION_SQL = (CAPTURE_RECORDED_AT_SQL + APPEND_ONLY_SQL + CLASSIFICATION_SQL + ORDER_GUARD_SQL + TICKET_GUARD_SQL).freeze

  REFUND_STATUS_SUCCEEDED = 1
  DISPUTE_STATUS_LOST = 2

  # Durable movement recording times (design §5.2). Like the capture time, the
  # database stamps each one in the statement that first records the fact and
  # never accepts an application value, so a backdated business field
  # (refunds.succeeded_at, disputes.closed_at) is never recording evidence.
  # Rows that reached the state before A1 keep NULL; their time comes once from
  # bounded evidence (financial_cutovers a1_return_recording) on the posting.
  RETURN_RECORDED_AT_SQL = <<~SQL.freeze
    CREATE OR REPLACE FUNCTION hafapass_refund_success_recorded_at() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'UPDATE' AND OLD.success_recorded_at IS NOT NULL THEN
        IF NEW.success_recorded_at IS DISTINCT FROM OLD.success_recorded_at THEN
          RAISE EXCEPTION 'A refund''s success recording time is set once' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;
      IF NEW.success_recorded_at IS NOT NULL THEN
        RAISE EXCEPTION 'A refund''s success recording time is written by the database' USING ERRCODE = '23514';
      END IF;
      IF NEW.status = #{REFUND_STATUS_SUCCEEDED} AND (TG_OP = 'INSERT' OR OLD.status <> #{REFUND_STATUS_SUCCEEDED}) THEN
        NEW.success_recorded_at := #{NOW_UTC};
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS refunds_success_recorded_at ON refunds;
    CREATE TRIGGER refunds_success_recorded_at BEFORE INSERT OR UPDATE OF status, success_recorded_at ON refunds
      FOR EACH ROW EXECUTE FUNCTION hafapass_refund_success_recorded_at();

    -- loss_reversed_at: the application asks for it by writing any value on a
    -- lost dispute; the database replaces it with its own time, once.
    CREATE OR REPLACE FUNCTION hafapass_dispute_recorded_at() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'UPDATE' AND OLD.loss_recorded_at IS NOT NULL THEN
        IF NEW.loss_recorded_at IS DISTINCT FROM OLD.loss_recorded_at THEN
          RAISE EXCEPTION 'A dispute''s loss recording time is set once' USING ERRCODE = '23514';
        END IF;
      ELSIF NEW.loss_recorded_at IS NOT NULL THEN
        RAISE EXCEPTION 'A dispute''s loss recording time is written by the database' USING ERRCODE = '23514';
      ELSIF NEW.status = #{DISPUTE_STATUS_LOST} AND (TG_OP = 'INSERT' OR OLD.status <> #{DISPUTE_STATUS_LOST}) THEN
        NEW.loss_recorded_at := #{NOW_UTC};
      END IF;

      IF TG_OP = 'INSERT' THEN
        IF NEW.loss_reversed_at IS NOT NULL THEN
          RAISE EXCEPTION 'A dispute loss is reversed only after it was recorded' USING ERRCODE = '23514';
        END IF;
      ELSIF OLD.loss_reversed_at IS NOT NULL THEN
        IF NEW.loss_reversed_at IS DISTINCT FROM OLD.loss_reversed_at OR NEW.status <> #{DISPUTE_STATUS_LOST} THEN
          RAISE EXCEPTION 'A reversed dispute loss is final' USING ERRCODE = '23514';
        END IF;
      ELSIF NEW.loss_reversed_at IS NOT NULL THEN
        IF OLD.status <> #{DISPUTE_STATUS_LOST} OR NEW.status <> #{DISPUTE_STATUS_LOST} THEN
          RAISE EXCEPTION 'Only a recorded dispute loss can be reversed' USING ERRCODE = '23514';
        END IF;
        NEW.loss_reversed_at := #{NOW_UTC};
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS disputes_recorded_at ON disputes;
    CREATE TRIGGER disputes_recorded_at BEFORE INSERT OR UPDATE OF status, loss_recorded_at, loss_reversed_at ON disputes
      FOR EACH ROW EXECUTE FUNCTION hafapass_dispute_recorded_at();
  SQL

  # Append-only gross return postings (design §5.2-§5.4). The writer
  # (Commerce::BuyerReturnPostings) computes every amount; this trigger is the
  # guarantee that what it inserts is a real movement of the classified
  # payment, in the frozen sequence, with excess decided on gross and every
  # cumulative share inside the capture's snapshot. It locks the order
  # FOR UPDATE (rank 3), which every writer already holds.
  POSTING_SQL = <<~SQL.freeze
    CREATE OR REPLACE FUNCTION hafapass_check_buyer_return_posting() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      cap never_fulfilled_captures%ROWTYPE;
      src_payment bigint;
      src_amount integer;
      src_currency text;
      src_status integer;
      stamp timestamp;
      cutover timestamp;
      reversed buyer_return_postings%ROWTYPE;
      prev_sequence integer;
      prev_applied bigint;
      prev_proceeds bigint;
      prev_fee bigint;
      prev_organizer_fee bigint;
      prev_tax bigint;
    BEGIN
      SELECT * INTO cap FROM never_fulfilled_captures WHERE id = NEW.never_fulfilled_capture_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'A return posting needs its classified capture' USING ERRCODE = '23503';
      END IF;
      PERFORM 1 FROM orders WHERE id = cap.order_id FOR UPDATE;

      NEW.capture_recorded_at := COALESCE(NEW.capture_recorded_at, cap.capture_recorded_at);
      IF NEW.capture_recorded_at <> cap.capture_recorded_at OR NEW.allocation_policy <> cap.allocation_policy
          OR NEW.policy_version <> cap.policy_version THEN
        RAISE EXCEPTION 'A return posting copies its capture''s recording time and allocation policy' USING ERRCODE = '23514';
      END IF;

      IF NEW.source_type = 'Refund' THEN
        SELECT payment_id, amount_cents, currency, status, success_recorded_at
          INTO src_payment, src_amount, src_currency, src_status, stamp FROM refunds WHERE id = NEW.source_id;
      ELSE
        SELECT payment_id, amount_cents, currency, status,
            CASE WHEN NEW.kind = 'dispute_loss_reversal' THEN loss_reversed_at ELSE loss_recorded_at END
          INTO src_payment, src_amount, src_currency, src_status, stamp FROM disputes WHERE id = NEW.source_id;
      END IF;
      IF NOT FOUND OR src_payment IS DISTINCT FROM cap.payment_id THEN
        RAISE EXCEPTION 'A return posting''s movement must belong to the classified payment' USING ERRCODE = '23503';
      END IF;
      IF lower(src_currency) <> lower(cap.currency) THEN
        RAISE EXCEPTION 'A return posting''s movement must be in the capture''s currency' USING ERRCODE = '23514';
      END IF;

      IF NEW.kind = 'refund' THEN
        IF src_status <> #{REFUND_STATUS_SUCCEEDED} OR NEW.gross_cents <> src_amount THEN
          RAISE EXCEPTION 'A refund posting needs a succeeded refund of the same gross amount' USING ERRCODE = '23514';
        END IF;
      ELSIF NEW.kind = 'dispute_loss' THEN
        IF src_status <> #{DISPUTE_STATUS_LOST} OR NEW.gross_cents <> src_amount THEN
          RAISE EXCEPTION 'A dispute posting needs a lost dispute of the same gross amount' USING ERRCODE = '23514';
        END IF;
      ELSIF NEW.kind = 'dispute_loss_reversal' THEN
        SELECT * INTO reversed FROM buyer_return_postings WHERE id = NEW.reverses_posting_id;
        IF NOT FOUND OR reversed.never_fulfilled_capture_id <> NEW.never_fulfilled_capture_id
            OR reversed.kind <> 'dispute_loss' OR reversed.source_id <> NEW.source_id
            OR src_status <> #{DISPUTE_STATUS_LOST} OR stamp IS NULL OR NEW.gross_cents <> -reversed.gross_cents THEN
          RAISE EXCEPTION 'A loss reversal needs the reversed loss''s posting and a recorded reversal' USING ERRCODE = '23514';
        END IF;
      ELSE
        -- refund_reversal needs an approved finance action, which A1 does not ship.
        RAISE EXCEPTION 'Refund reversals are posted only by an approved finance correction' USING ERRCODE = '23514';
      END IF;

      IF stamp IS NOT NULL THEN
        NEW.recorded_at := COALESCE(NEW.recorded_at, stamp);
        IF NEW.recorded_at <> stamp OR NEW.recording_source <> 'database' THEN
          RAISE EXCEPTION 'A return posting uses its movement''s database recording time' USING ERRCODE = '23514';
        END IF;
      ELSE
        SELECT recorded_at INTO cutover FROM financial_cutovers WHERE key = 'a1_return_recording';
        IF NEW.recording_source <> 'backfill' OR NEW.recorded_at IS NULL OR cutover IS NULL
            OR NEW.recorded_at > cutover OR NEW.evidence = '{}'::jsonb THEN
          RAISE EXCEPTION 'A movement recorded before A1 needs a backfilled time with evidence, no later than the cutover'
            USING ERRCODE = '23514';
        END IF;
      END IF;
      NEW.recognized_at := COALESCE(NEW.recognized_at, GREATEST(NEW.recorded_at, NEW.capture_recorded_at));

      SELECT COALESCE(MAX(sequence), 0), COALESCE(SUM(applied_cents), 0), COALESCE(SUM(proceeds_cents), 0),
          COALESCE(SUM(fee_cents), 0), COALESCE(SUM(organizer_fee_cents), 0), COALESCE(SUM(tax_cents), 0)
        INTO prev_sequence, prev_applied, prev_proceeds, prev_fee, prev_organizer_fee, prev_tax
        FROM buyer_return_postings WHERE never_fulfilled_capture_id = NEW.never_fulfilled_capture_id;
      IF NEW.sequence <> prev_sequence + 1 THEN
        RAISE EXCEPTION 'Return postings are sequenced 1, 2, ... per capture' USING ERRCODE = '23514';
      END IF;
      -- Excess is decided on gross against the captured amount alone.
      IF NEW.kind IN ('refund', 'dispute_loss') AND NEW.applied_cents <> LEAST(NEW.gross_cents, cap.captured_cents - prev_applied) THEN
        RAISE EXCEPTION 'A return applies the smaller of its gross and the amount still owed' USING ERRCODE = '23514';
      END IF;
      IF prev_applied + NEW.applied_cents NOT BETWEEN 0 AND cap.captured_cents
          OR prev_proceeds + NEW.proceeds_cents NOT BETWEEN 0 AND cap.proceeds_cents
          OR prev_fee + NEW.fee_cents NOT BETWEEN 0 AND cap.fee_cents
          OR prev_organizer_fee + NEW.organizer_fee_cents NOT BETWEEN 0 AND cap.organizer_fee_cents
          OR prev_tax + NEW.tax_cents NOT BETWEEN 0 AND cap.tax_cents THEN
        RAISE EXCEPTION 'Cumulative returned shares must stay within the capture''s components' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS buyer_return_postings_check ON buyer_return_postings;
    CREATE TRIGGER buyer_return_postings_check BEFORE INSERT ON buyer_return_postings
      FOR EACH ROW EXECUTE FUNCTION hafapass_check_buyer_return_posting();
    DROP TRIGGER IF EXISTS buyer_return_postings_append_only ON buyer_return_postings;
    CREATE TRIGGER buyer_return_postings_append_only BEFORE UPDATE OR DELETE ON buyer_return_postings
      FOR EACH ROW EXECUTE FUNCTION hafapass_append_only();
    CREATE OR REPLACE TRIGGER buyer_return_postings_no_truncate BEFORE TRUNCATE ON buyer_return_postings
      FOR EACH STATEMENT EXECUTE FUNCTION hafapass_append_only_truncate();
  SQL

  # Tranche 3 (migration 20261126110000).
  RETURNS_SQL = (RETURN_RECORDED_AT_SQL + POSTING_SQL).freeze

  # Tranche 4 (migration 20261126120000): repayment operations and the R1
  # compatibility fence (design §6.3, §10.1). Codes are literals so the
  # migration never depends on application constants;
  # spec/models/repayment_fence_spec.rb keeps them equal to the app's.
  #
  # A fenced payment is one HåfaPass may owe back in full: it has a
  # never-fulfilled classification, or an exception of one of these codes
  # (open or resolved). Old (7bcd97c2) code never writes repayment
  # operations, so for a fenced payment the fence stops it from
  #   (1) reserving an outbound refund: a refunds row with no provider refund
  #       ID, no repayment operation and a key that is not an inbound
  #       provider record (provider:stripe:refund:*);
  #   (2) passing the last local gate: moving such a row's failure_code to
  #       provider_result_unknown, which RefundCreator persists immediately
  #       before its HTTP call. A row that belongs to a repayment operation
  #       passes the gate only while that operation is "submitting", which
  #       only the operation gate (Commerce::BuyerRepayment) sets.
  # Recording a provider fact (inbound rows, rows carrying a provider refund
  # ID, outcomes of a row already past the gate) is never refused.
  FENCED_PAYMENT_CODES = %w[
    late_payment_success_after_inventory_release late_payment_success_after_hold_expiry
    pass_all_included_nights_cancelled unfulfilled_second_capture never_fulfilled_ownership_ambiguous
    never_fulfilled_classification_quarantined
  ].freeze
  # Open exceptions that keep the event's payouts from being created,
  # released or submitted (P10 strict). never_fulfilled_buyer_overpaid is
  # deliberately absent: a proven platform-only over-return alerts without
  # holding the organizer (P4).
  # A provider refund or lost dispute recorded on a payment that is not
  # positively the sale's own (A1-R1 review finding 1). The provider fact is
  # kept; the sale effects wait for ownership evidence.
  SALE_EFFECTS_HELD_CODE = "never_fulfilled_sale_effects_held"
  PAYOUT_BLOCKING_CODES = (FENCED_PAYMENT_CODES + %W[
    never_fulfilled_return_quarantined never_fulfilled_backfill_ambiguous never_fulfilled_backfill_restatement
    never_fulfilled_repayment_reopened #{SALE_EFFECTS_HELD_CODE}
  ]).freeze
  # Holds that only evidence may close (review finding 3). The database
  # refuses their open -> resolved change unless the same transaction named
  # the exception in hafapass.evidence_resolution, which only the
  # application's evidence paths set (FinancialIntegrity.with_evidence).
  # A note, an older release's admin action or raw SQL cannot close them.
  EVIDENCE_HOLD_CODES = (PAYOUT_BLOCKING_CODES - %w[
    late_payment_success_after_inventory_release late_payment_success_after_hold_expiry
    pass_all_included_nights_cancelled
  ]).freeze
  OPEN_EXCEPTION_STATUS = 0
  PAYOUT_PENDING_STATUS = 0
  PAYOUT_PROCESSING_STATUS = 1
  PAYOUT_PAID_STATUS = 2
  PAYOUT_REVERSED_STATUS = 4
  PAYOUT_HELD_STATUS = 5
  # The settlement reader that leaves never-fulfilled orders out (finding 2).
  # A1_SETTLEMENT_READER is the marker A1-R1's migrations installed and A1
  # processes still set; SETTLEMENT_READER is the reader this release's
  # writers name (A2 payout entry, PAYOUT_ENTRY_SQL below).
  A1_SETTLEMENT_READER = "nfc-a1r1"
  SETTLEMENT_READER = "nfc-a2"
  SETTLEMENT_FINALIZED_STATUS = 1
  OPERATION_STATES = %w[reserved submitting unknown succeeded failed_terminal].freeze

  def self.sql_list(values)
    values.map { |value| "'#{value}'" }.join(", ")
  end

  REPAYMENT_SQL = <<~SQL.freeze
    CREATE OR REPLACE FUNCTION hafapass_fenced_payment(target bigint) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT target IS NOT NULL AND (
        EXISTS (SELECT 1 FROM never_fulfilled_captures WHERE payment_id = target)
        OR EXISTS (SELECT 1 FROM reconciliation_exceptions WHERE payment_id = target
          AND code IN (#{sql_list(FENCED_PAYMENT_CODES)})))
    $$;

    -- Identity is append-only; state moves forward only. Operation n > 1 is
    -- reserved only after every earlier operation reached a verified
    -- terminal state, so a retry is never a new operation (design §6.3).
    CREATE OR REPLACE FUNCTION hafapass_check_repayment_operation() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      cap never_fulfilled_captures%ROWTYPE;
      last_sequence integer;
      expected_key text;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Repayment operations are append-only' USING ERRCODE = '23514';
      END IF;
      IF TG_OP = 'INSERT' THEN
        SELECT * INTO cap FROM never_fulfilled_captures WHERE id = NEW.never_fulfilled_capture_id;
        IF NOT FOUND OR cap.payment_id <> NEW.payment_id OR cap.currency <> NEW.currency THEN
          RAISE EXCEPTION 'A repayment operation belongs to its classified payment' USING ERRCODE = '23514';
        END IF;
        PERFORM 1 FROM orders WHERE id = cap.order_id FOR UPDATE;
        SELECT COALESCE(MAX(sequence), 0) INTO last_sequence FROM repayment_operations
          WHERE never_fulfilled_capture_id = NEW.never_fulfilled_capture_id;
        IF NEW.sequence <> last_sequence + 1 THEN
          RAISE EXCEPTION 'Repayment operations are numbered contiguously' USING ERRCODE = '23514';
        END IF;
        -- Each reserved operation has its own key; only an adopted legacy
        -- first operation keeps the older release's key.
        expected_key := 'late-capture:payment:' || NEW.payment_id ||
          CASE WHEN NEW.adopted THEN '' ELSE ':op:' || NEW.sequence END;
        IF NEW.idempotency_key <> expected_key THEN
          RAISE EXCEPTION 'Repayment operation % must use key %', NEW.sequence, expected_key USING ERRCODE = '23514';
        END IF;
        IF EXISTS (SELECT 1 FROM repayment_operations WHERE never_fulfilled_capture_id = NEW.never_fulfilled_capture_id
            AND state NOT IN ('succeeded', 'failed_terminal')) THEN
          RAISE EXCEPTION 'A new repayment operation waits until earlier ones are verified' USING ERRCODE = '23514';
        END IF;
        IF NOT NEW.adopted AND (NEW.state <> 'reserved' OR NEW.refund_id IS NOT NULL OR NEW.submission_count <> 0) THEN
          RAISE EXCEPTION 'A new repayment operation starts reserved' USING ERRCODE = '23514';
        END IF;
        IF NEW.adopted AND (NEW.sequence <> 1 OR NEW.refund_id IS NULL) THEN
          RAISE EXCEPTION 'Only the legacy first operation is adopted, with its refund' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;

      IF (NEW.never_fulfilled_capture_id, NEW.payment_id, NEW.sequence, NEW.amount_cents, NEW.currency,
          NEW.idempotency_key, NEW.source, NEW.adopted, NEW.created_at) IS DISTINCT FROM
         (OLD.never_fulfilled_capture_id, OLD.payment_id, OLD.sequence, OLD.amount_cents, OLD.currency,
          OLD.idempotency_key, OLD.source, OLD.adopted, OLD.created_at) THEN
        RAISE EXCEPTION 'A repayment operation''s identity is immutable' USING ERRCODE = '23514';
      END IF;
      IF OLD.refund_id IS NOT NULL AND NEW.refund_id IS DISTINCT FROM OLD.refund_id THEN
        RAISE EXCEPTION 'A repayment operation''s refund is set once' USING ERRCODE = '23514';
      END IF;
      IF NEW.submission_count < OLD.submission_count THEN
        RAISE EXCEPTION 'Submission counts never decrease' USING ERRCODE = '23514';
      END IF;
      IF OLD.state IN ('succeeded', 'failed_terminal') AND NEW.state IS DISTINCT FROM OLD.state THEN
        RAISE EXCEPTION 'A verified repayment outcome is final' USING ERRCODE = '23514';
      END IF;
      IF NEW.state IS DISTINCT FROM OLD.state AND NOT (
          -- reserved -> succeeded records a provider fact that arrived without
          -- this operation's own send; it is never refused, and is audited.
          (OLD.state = 'reserved' AND NEW.state IN ('submitting', 'failed_terminal', 'succeeded')) OR
          (OLD.state = 'submitting' AND NEW.state IN ('unknown', 'succeeded', 'failed_terminal')) OR
          (OLD.state = 'unknown' AND NEW.state IN ('submitting', 'succeeded', 'failed_terminal'))) THEN
        RAISE EXCEPTION 'Repayment operation cannot move from % to %', OLD.state, NEW.state USING ERRCODE = '23514';
      END IF;
      -- Only the gate sends, and each send is counted once: entering
      -- "submitting", or re-sending a stale "submitting" after the in-flight
      -- bound, adds exactly one.
      IF NEW.state = 'submitting' AND OLD.state <> 'submitting' AND NEW.submission_count <> OLD.submission_count + 1 THEN
        RAISE EXCEPTION 'Each submission is counted once' USING ERRCODE = '23514';
      END IF;
      IF NEW.submission_count <> OLD.submission_count AND
          (NEW.state <> 'submitting' OR NEW.submission_count <> OLD.submission_count + 1) THEN
        RAISE EXCEPTION 'Submissions are counted only by the gate, one at a time' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS repayment_operations_check ON repayment_operations;
    CREATE TRIGGER repayment_operations_check BEFORE INSERT OR UPDATE OR DELETE ON repayment_operations
      FOR EACH ROW EXECUTE FUNCTION hafapass_check_repayment_operation();
    CREATE OR REPLACE TRIGGER repayment_operations_no_truncate BEFORE TRUNCATE ON repayment_operations
      FOR EACH STATEMENT EXECUTE FUNCTION hafapass_append_only_truncate();

    CREATE OR REPLACE FUNCTION hafapass_refund_repayment_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      op repayment_operations%ROWTYPE;
      inbound boolean;
    BEGIN
      IF NEW.repayment_operation_id IS NOT NULL AND
          (TG_OP = 'INSERT' OR NEW.repayment_operation_id IS DISTINCT FROM OLD.repayment_operation_id) THEN
        IF TG_OP = 'UPDATE' AND OLD.repayment_operation_id IS NOT NULL THEN
          RAISE EXCEPTION 'A refund''s repayment operation is set once' USING ERRCODE = '23514';
        END IF;
        SELECT * INTO op FROM repayment_operations WHERE id = NEW.repayment_operation_id;
        IF NOT FOUND OR op.payment_id IS DISTINCT FROM NEW.payment_id OR op.idempotency_key <> NEW.idempotency_key
            OR op.amount_cents <> NEW.amount_cents OR op.currency <> NEW.currency THEN
          RAISE EXCEPTION 'A refund matches its repayment operation exactly' USING ERRCODE = '23514';
        END IF;
      ELSIF TG_OP = 'UPDATE' AND OLD.repayment_operation_id IS NOT NULL AND NEW.repayment_operation_id IS NULL THEN
        RAISE EXCEPTION 'A refund''s repayment operation is set once' USING ERRCODE = '23514';
      END IF;

      IF NOT hafapass_fenced_payment(NEW.payment_id) THEN
        RETURN NEW;
      END IF;
      -- Provider evidence passes only when positively identified: a row that
      -- carries the provider's refund ID, or the insert of an inbound record
      -- (provider:stripe:refund:<id>), which never reaches the gate.
      IF NEW.provider_refund_id IS NOT NULL THEN
        RETURN NEW;
      END IF;
      inbound := NEW.idempotency_key LIKE 'provider:stripe:refund:%';
      IF TG_OP = 'INSERT' AND inbound THEN
        RETURN NEW;
      END IF;
      IF TG_OP = 'INSERT' AND NEW.repayment_operation_id IS NULL THEN
        RAISE EXCEPTION 'Repayment fence: this payment is returned only through a repayment operation'
          USING ERRCODE = '23514';
      END IF;
      IF NEW.failure_code = 'provider_result_unknown' AND
          (TG_OP = 'INSERT' OR OLD.failure_code IS DISTINCT FROM 'provider_result_unknown') THEN
        IF NEW.repayment_operation_id IS NULL THEN
          RAISE EXCEPTION 'Repayment fence: this refund cannot be submitted' USING ERRCODE = '23514';
        END IF;
        SELECT * INTO op FROM repayment_operations WHERE id = NEW.repayment_operation_id;
        IF op.state <> 'submitting' THEN
          RAISE EXCEPTION 'Repayment fence: only the operation gate submits this refund' USING ERRCODE = '23514';
        END IF;
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS refunds_repayment_fence ON refunds;
    CREATE TRIGGER refunds_repayment_fence BEFORE INSERT OR UPDATE OF failure_code, repayment_operation_id, provider_refund_id ON refunds
      FOR EACH ROW EXECUTE FUNCTION hafapass_refund_repayment_fence();

    -- P10 strict for every payout writer, old or new: no payout on an event
    -- with an open never-fulfilled item is created, released from hold or
    -- submitted. Holding, failing, reversing and recording a transfer that
    -- already left are not refused here (the application guards paid
    -- recording with the existing queue rule).
    CREATE OR REPLACE FUNCTION hafapass_payout_repayment_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.status NOT IN (#{PAYOUT_PENDING_STATUS}, #{PAYOUT_PROCESSING_STATUS}) OR
          (TG_OP = 'UPDATE' AND NEW.status = OLD.status) THEN
        RETURN NEW;
      END IF;
      IF EXISTS (SELECT 1 FROM reconciliation_exceptions re
          WHERE re.status = #{OPEN_EXCEPTION_STATUS} AND re.code IN (#{sql_list(PAYOUT_BLOCKING_CODES)})
            AND (re.order_id IN (SELECT id FROM orders WHERE event_id = NEW.event_id)
              OR re.payment_id IN (SELECT p.id FROM payments p JOIN orders o ON o.id = p.order_id
                WHERE o.event_id = NEW.event_id))) THEN
        RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS payouts_repayment_fence ON payouts;
    CREATE TRIGGER payouts_repayment_fence BEFORE INSERT OR UPDATE OF status ON payouts
      FOR EACH ROW EXECUTE FUNCTION hafapass_payout_repayment_fence();
  SQL
  REPAYMENT_SENTINEL_TABLE = "repayment_operations"

  # A1-R1 review fixes (migration 20261126130000). Each guard sits on the
  # write that actually causes the effect, so an older release's writer, a
  # rollback build or raw SQL fails closed in the same transaction and the
  # provider fact stays in its signed receipt for a later replay.
  #
  #   sale ownership     refund items, commission reversals, dispute ticket
  #                      cancellations and retained-inventory records need a
  #                      payment that positively owns the sale (finding 1)
  #   payout evidence    payout submission authorization (its audit row),
  #                      paid recording and statement finalization on an
  #                      event with an open blocking item (finding 3)
  #   evidence holds     only an evidence path closes them (finding 3)
  #   refund identity    binding a provider refund ID to an outbound row of
  #                      a fenced payment needs an exact identity match the
  #                      application verified (finding 4)
  EVIDENCE_SQL = <<~SQL.freeze
    -- The payment that may change the sale's items, tickets and commission:
    -- the order's recorded fulfilling payment; an order-scope never-
    -- fulfilled capture (there is no sale to damage); or, with no fulfilling
    -- payment recorded, the order's only captured payment of its mode, and
    -- for a fenced payment only when the order was never fulfilled.
    -- Payment.live_or_legacy_capture's mode rule: a test or simulated
    -- capture never competes with a live one for the same sale.
    CREATE OR REPLACE FUNCTION hafapass_live_or_legacy(environment text, payload jsonb) RETURNS boolean
    LANGUAGE sql IMMUTABLE AS $$
      SELECT COALESCE(environment = 'live', false) OR (environment IS NULL
        AND payload->>'livemode' IS DISTINCT FROM 'false' AND payload->>'simulated' IS DISTINCT FROM 'true')
    $$;

    CREATE OR REPLACE FUNCTION hafapass_sale_owner_payment(target bigint) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT COALESCE((
        SELECT CASE
          WHEN o.fulfilled_by_payment_id IS NOT NULL THEN o.fulfilled_by_payment_id = p.id
          WHEN EXISTS (SELECT 1 FROM never_fulfilled_captures c WHERE c.payment_id = p.id AND c.capture_scope = 'order')
            THEN true
          ELSE NOT EXISTS (SELECT 1 FROM payments other WHERE other.order_id = p.order_id AND other.id <> p.id
              AND other.status IN (#{CAPTURED_PAYMENT_STATUSES})
              AND hafapass_live_or_legacy(other.provider_environment, other.provider_payload)
                = hafapass_live_or_legacy(p.provider_environment, p.provider_payload))
            AND (NOT hafapass_fenced_payment(p.id) OR (o.completed_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM tickets t WHERE t.order_id = o.id AND t.status <> #{CANCELLED_TICKET_STATUS})))
        END
        FROM payments p JOIN orders o ON o.id = p.order_id WHERE p.id = target), false)
    $$;

    CREATE OR REPLACE FUNCTION hafapass_sale_effect_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      origin_payment bigint;
    BEGIN
      IF TG_TABLE_NAME = 'tickets' THEN
        IF NOT EXISTS (SELECT 1 FROM disputes d WHERE d.order_id = NEW.order_id AND d.status = 2
            AND (d.payment_id IS NULL OR hafapass_sale_owner_payment(d.payment_id))) THEN
          RAISE EXCEPTION 'Sale ownership: a lost dispute on another payment cannot cancel this order''s tickets'
            USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;
      IF NEW.refund_id IS NOT NULL THEN
        SELECT payment_id INTO origin_payment FROM refunds WHERE id = NEW.refund_id;
      ELSIF TG_TABLE_NAME = 'ticket_inventory_retentions' THEN
        SELECT payment_id INTO origin_payment FROM disputes WHERE id = NEW.dispute_id;
      END IF;
      IF origin_payment IS NOT NULL AND NOT hafapass_sale_owner_payment(origin_payment) THEN
        RAISE EXCEPTION 'Sale ownership: payment % does not own this sale', origin_payment USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS refund_items_sale_ownership ON refund_items;
    CREATE TRIGGER refund_items_sale_ownership BEFORE INSERT ON refund_items
      FOR EACH ROW EXECUTE FUNCTION hafapass_sale_effect_guard();
    DROP TRIGGER IF EXISTS promoter_commission_entries_sale_ownership ON promoter_commission_entries;
    CREATE TRIGGER promoter_commission_entries_sale_ownership BEFORE INSERT ON promoter_commission_entries
      FOR EACH ROW WHEN (NEW.refund_id IS NOT NULL) EXECUTE FUNCTION hafapass_sale_effect_guard();
    DROP TRIGGER IF EXISTS ticket_inventory_retentions_sale_ownership ON ticket_inventory_retentions;
    CREATE TRIGGER ticket_inventory_retentions_sale_ownership BEFORE INSERT ON ticket_inventory_retentions
      FOR EACH ROW EXECUTE FUNCTION hafapass_sale_effect_guard();
    DROP TRIGGER IF EXISTS tickets_dispute_sale_ownership ON tickets;
    CREATE TRIGGER tickets_dispute_sale_ownership BEFORE UPDATE OF status ON tickets
      FOR EACH ROW WHEN (NEW.status = #{CANCELLED_TICKET_STATUS} AND OLD.status IS DISTINCT FROM NEW.status
        AND NEW.cancellation_reason = 'payment_dispute_lost')
      EXECUTE FUNCTION hafapass_sale_effect_guard();

    -- When the event's earliest open blocking never-fulfilled item opened,
    -- or NULL when nothing blocks it.
    CREATE OR REPLACE FUNCTION hafapass_payout_block_start(target_event bigint) RETURNS timestamp
    LANGUAGE sql STABLE AS $$
      SELECT MIN(re.created_at) FROM reconciliation_exceptions re
        WHERE re.status = #{OPEN_EXCEPTION_STATUS} AND re.code IN (#{sql_list(PAYOUT_BLOCKING_CODES)})
          AND (re.order_id IN (SELECT id FROM orders WHERE event_id = target_event)
            OR re.payment_id IN (SELECT p.id FROM payments p JOIN orders o ON o.id = p.order_id
              WHERE o.event_id = target_event))
    $$;

    -- An event whose never-fulfilled order is in a status the 7bcd97c2
    -- settlement reader counts as a sale (completed, refunded or partially
    -- refunded). That reader would pay the organizer its proceeds, so only a
    -- reader that excludes them (this release's Settlements::Finalizer and
    -- PayoutCreator, which name themselves in hafapass.settlement_reader)
    -- may finalize its statement or create a payout on it. This keeps the
    -- fence across a rollback until the A2 readers (A1-R1 review finding 2).
    CREATE OR REPLACE FUNCTION hafapass_settlement_reader_required(target_event bigint) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT EXISTS (SELECT 1 FROM orders o WHERE o.event_id = target_event AND o.never_fulfilled_at IS NOT NULL
          AND o.status IN (1, 2, 4))
        AND current_setting('hafapass.settlement_reader', true) IS DISTINCT FROM '#{A1_SETTLEMENT_READER}'
    $$;

    -- P10 strict for every payout writer, old or new. Refused on an event
    -- with an open blocking item: creating a payout; releasing a held one;
    -- and moving one to processing or paid, unless its submission was
    -- authorized before the earliest open item. That is the outcome of a
    -- request already sent (or money that already left), recorded with its
    -- evidence, never a new payment. Holding, failing and reversing are
    -- never refused.
    CREATE OR REPLACE FUNCTION hafapass_payout_repayment_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      block_start timestamp;
    BEGIN
      IF TG_OP = 'INSERT' AND hafapass_settlement_reader_required(NEW.event_id) THEN
        RAISE EXCEPTION 'Repayment fence: this event''s payouts need the never-fulfilled settlement reader'
          USING ERRCODE = '23514';
      END IF;
      IF NEW.status NOT IN (#{PAYOUT_PENDING_STATUS}, #{PAYOUT_PROCESSING_STATUS}, #{PAYOUT_PAID_STATUS}) OR
          (TG_OP = 'UPDATE' AND NEW.status = OLD.status) THEN
        RETURN NEW;
      END IF;
      block_start := hafapass_payout_block_start(NEW.event_id);
      IF block_start IS NULL THEN
        RETURN NEW;
      END IF;
      IF TG_OP = 'UPDATE' AND ((NEW.status = #{PAYOUT_PROCESSING_STATUS} AND OLD.status = #{PAYOUT_PENDING_STATUS})
            OR (NEW.status = #{PAYOUT_PAID_STATUS} AND OLD.status IN (#{PAYOUT_PENDING_STATUS}, #{PAYOUT_PROCESSING_STATUS}, #{PAYOUT_HELD_STATUS})))
          AND EXISTS (SELECT 1 FROM audit_logs a
          WHERE a.auditable_type = 'Payout' AND a.auditable_id = NEW.id AND a.action = 'payout.submission_requested'
            AND a.occurred_at < block_start) THEN
        RETURN NEW;
      END IF;
      RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
    END;
    $$;
    DROP TRIGGER IF EXISTS payouts_repayment_fence ON payouts;
    CREATE TRIGGER payouts_repayment_fence BEFORE INSERT OR UPDATE OF status ON payouts
      FOR EACH ROW EXECUTE FUNCTION hafapass_payout_repayment_fence();

    -- The actual submission authorization of both releases is this audit
    -- row, written under the payout lock before the gateway call; a pending
    -- payout is submitted without a status change.
    CREATE OR REPLACE FUNCTION hafapass_payout_submission_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF hafapass_payout_block_start((SELECT event_id FROM payouts WHERE id = NEW.auditable_id)) IS NOT NULL THEN
        RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS audit_logs_payout_submission_fence ON audit_logs;
    CREATE TRIGGER audit_logs_payout_submission_fence BEFORE INSERT ON audit_logs
      FOR EACH ROW WHEN (NEW.action = 'payout.submission_requested' AND NEW.auditable_type = 'Payout')
      EXECUTE FUNCTION hafapass_payout_submission_fence();

    CREATE OR REPLACE FUNCTION hafapass_settlement_finalization_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF hafapass_payout_block_start(NEW.event_id) IS NOT NULL THEN
        RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
      END IF;
      IF hafapass_settlement_reader_required(NEW.event_id) THEN
        RAISE EXCEPTION 'Repayment fence: this event''s statement needs the never-fulfilled settlement reader'
          USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS settlements_finalization_fence ON settlements;
    CREATE TRIGGER settlements_finalization_fence BEFORE INSERT OR UPDATE OF status ON settlements
      FOR EACH ROW WHEN (NEW.status = #{SETTLEMENT_FINALIZED_STATUS})
      EXECUTE FUNCTION hafapass_settlement_finalization_fence();

    CREATE OR REPLACE FUNCTION hafapass_evidence_hold_guard() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF current_setting('hafapass.evidence_resolution', true) IS DISTINCT FROM NEW.id::text THEN
        RAISE EXCEPTION 'Evidence hold: % closes only when its evidence is recorded', NEW.code USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS reconciliation_exceptions_evidence_hold ON reconciliation_exceptions;
    CREATE TRIGGER reconciliation_exceptions_evidence_hold BEFORE UPDATE OF status ON reconciliation_exceptions
      FOR EACH ROW WHEN (OLD.status = #{OPEN_EXCEPTION_STATUS} AND NEW.status IS DISTINCT FROM OLD.status
        AND NEW.code IN (#{sql_list(EVIDENCE_HOLD_CODES)}))
      EXECUTE FUNCTION hafapass_evidence_hold_guard();

    -- An outbound row of a fenced payment gets a provider refund ID only
    -- from an exact identity (the provider ID or the row's own metadata
    -- key) that the application matched in this transaction. Never from an
    -- amount and date, and never by an older release's writer.
    CREATE OR REPLACE FUNCTION hafapass_refund_identity_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.idempotency_key = 'provider:stripe:refund:' || NEW.provider_refund_id
          OR NOT hafapass_fenced_payment(NEW.payment_id)
          OR current_setting('hafapass.refund_identity', true) IS NOT DISTINCT FROM NEW.id::text THEN
        RETURN NEW;
      END IF;
      RAISE EXCEPTION 'Repayment fence: refund % needs an exact provider identity match', NEW.id USING ERRCODE = '23514';
    END;
    $$;
    DROP TRIGGER IF EXISTS refunds_identity_fence ON refunds;
    CREATE TRIGGER refunds_identity_fence BEFORE UPDATE OF provider_refund_id ON refunds
      FOR EACH ROW WHEN (OLD.provider_refund_id IS NULL AND NEW.provider_refund_id IS NOT NULL)
      EXECUTE FUNCTION hafapass_refund_identity_fence();
  SQL
  EVIDENCE_SENTINEL_TRIGGER = %w[refund_items_sale_ownership refund_items].freeze
  # The A1 reader rule exactly as EVIDENCE_SQL installed it, for rolling
  # back the A2 payout entry migration (20261126180000).
  A1_READER_REQUIRED_SQL = EVIDENCE_SQL[/CREATE OR REPLACE FUNCTION hafapass_settlement_reader_required.*?\$\$;\n/m].freeze

  # Codes that already record a decision about a captured payment's
  # classification. A captured payment with none of them and no
  # classification row is an unclassified overlap capture (below).
  CLASSIFYING_CODES = (FENCED_PAYMENT_CODES + %w[never_fulfilled_backfill_ambiguous never_fulfilled_backfill_restatement]).freeze
  ORDER_REFUNDED_STATUS = 2
  SALE_STATUSES = "1, 2, 4" # completed, refunded, partially_refunded
  WEBHOOK_IDENTITY_TYPES = (%w[payment_intent.succeeded] + %w[refund.created refund.updated refund.failed
    charge.refund.updated charge.refunded charge.dispute.created charge.dispute.updated charge.dispute.closed]).freeze

  # A1-R1 recheck fixes (migration 20261126140000). Each guard again sits on
  # the write itself, so 7bcd97c2 during the overlap or after a rollback,
  # and raw SQL, fail closed in the same transaction:
  #
  #   sale refund total   an order's refund total and refunded status count
  #                       only the refunds of the payment that owns the sale
  #                       once another payment on it has a refund (blocker 1)
  #   transfer evidence   recording a payout paid on a held event needs its
  #                       pre-hold submission, a transfer time before the
  #                       hold and this release's verified confirmation in
  #                       the same transaction (blocker 2)
  #   overlap captures    a capture an older release acknowledged on an order
  #                       another payment fulfilled (or with another capture
  #                       and no recorded fulfilling payment) holds the
  #                       event's payouts and statements until it is
  #                       classified or quarantined (blocker 3)
  #   receipt identity    clearing a signed receipt's payload keeps its
  #                       provider identity in the non-personal columns
  OVERLAP_SQL = <<~SQL.freeze
    -- What the sale's own payment returned (refunds without a payment are
    -- the sale's: cash and manual returns).
    CREATE OR REPLACE FUNCTION hafapass_sale_refund_total(target_order bigint) RETURNS bigint
    LANGUAGE sql STABLE AS $$
      SELECT COALESCE(SUM(r.amount_cents), 0)::bigint FROM refunds r
        WHERE r.order_id = target_order AND r.status = #{REFUND_STATUS_SUCCEEDED}
          AND (r.payment_id IS NULL OR hafapass_sale_owner_payment(r.payment_id))
    $$;

    -- An older release sums every same-mode refund on the order, so a refund
    -- on another payment (B) would count toward the sale paid by A and could
    -- mark it fully refunded, cancel its tickets and release its inventory.
    -- Once the order has such a refund, its refund total may not exceed what
    -- the owning payment returned and it may become refunded only when that
    -- covers the total. Orders whose refunds all come from the sale's own
    -- payment are never affected.
    CREATE OR REPLACE FUNCTION hafapass_guard_order_refund_aggregate() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      owned bigint;
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM refunds r WHERE r.order_id = NEW.id AND r.status = #{REFUND_STATUS_SUCCEEDED}
          AND r.payment_id IS NOT NULL AND NOT hafapass_sale_owner_payment(r.payment_id)) THEN
        RETURN NEW;
      END IF;
      owned := LEAST(hafapass_sale_refund_total(NEW.id), NEW.total_cents);
      IF (NEW.refund_amount_cents IS DISTINCT FROM OLD.refund_amount_cents AND NEW.refund_amount_cents > owned)
          OR (NEW.status = #{ORDER_REFUNDED_STATUS} AND OLD.status IS DISTINCT FROM NEW.status AND owned < NEW.total_cents) THEN
        RAISE EXCEPTION 'Sale ownership: order % refund total would count another payment''s refunds', NEW.id
          USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS orders_sale_refund_aggregate ON orders;
    CREATE TRIGGER orders_sale_refund_aggregate BEFORE UPDATE OF status, refund_amount_cents ON orders
      FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status OR OLD.refund_amount_cents IS DISTINCT FROM NEW.refund_amount_cents)
      EXECUTE FUNCTION hafapass_guard_order_refund_aggregate();

    -- A real Stripe capture recorded since the A1 capture cutover that no
    -- release classified: on an order another payment fulfilled, or on a sold
    -- order with another capture and no recorded fulfilling payment. 7bcd97c2
    -- acknowledges such a second capture without an exception; this release
    -- classifies or quarantines it (Commerce::NeverFulfilledReconcile).
    CREATE OR REPLACE FUNCTION hafapass_unclassified_capture(target bigint) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT COALESCE((
        SELECT p.provider = 'stripe' AND p.status IN (#{CAPTURED_PAYMENT_STATUSES}) AND p.capture_recorded_at IS NOT NULL
          AND p.provider_environment IN ('test', 'live') AND p.provider_payment_id IS NOT NULL
          AND NOT starts_with(p.provider_payment_id, 'sim_') AND p.provider_payload->>'simulated' IS DISTINCT FROM 'true'
          AND o.never_fulfilled_at IS NULL
          -- Payment.live_or_legacy_capture's mode rule: a test capture never
          -- competes with a live one for the same sale.
          AND CASE WHEN o.fulfilled_by_payment_id IS NOT NULL THEN o.fulfilled_by_payment_id <> p.id
              AND EXISTS (SELECT 1 FROM payments f WHERE f.id = o.fulfilled_by_payment_id
                AND hafapass_live_or_legacy(f.provider_environment, f.provider_payload)
                  = hafapass_live_or_legacy(p.provider_environment, p.provider_payload))
            ELSE (o.completed_at IS NOT NULL OR o.status IN (#{SALE_STATUSES}))
              AND EXISTS (SELECT 1 FROM payments other WHERE other.order_id = o.id AND other.id <> p.id
                AND other.status IN (#{CAPTURED_PAYMENT_STATUSES})
                AND hafapass_live_or_legacy(other.provider_environment, other.provider_payload)
                  = hafapass_live_or_legacy(p.provider_environment, p.provider_payload))
              -- An item on another capture already holds this order.
              AND NOT EXISTS (SELECT 1 FROM reconciliation_exceptions held JOIN payments other ON other.id = held.payment_id
                WHERE other.order_id = o.id AND other.id <> p.id AND held.code IN (#{sql_list(CLASSIFYING_CODES)}))
          END
          AND NOT EXISTS (SELECT 1 FROM never_fulfilled_captures c WHERE c.payment_id = p.id)
          AND NOT EXISTS (SELECT 1 FROM reconciliation_exceptions re WHERE re.payment_id = p.id
            AND re.code IN (#{sql_list(CLASSIFYING_CODES)}))
        FROM payments p JOIN orders o ON o.id = p.order_id WHERE p.id = target), false)
    $$;

    CREATE OR REPLACE FUNCTION hafapass_payout_block_start(target_event bigint) RETURNS timestamp
    LANGUAGE sql STABLE AS $$
      SELECT MIN(started) FROM (
        SELECT re.created_at AS started FROM reconciliation_exceptions re
          WHERE re.status = #{OPEN_EXCEPTION_STATUS} AND re.code IN (#{sql_list(PAYOUT_BLOCKING_CODES)})
            AND (re.order_id IN (SELECT id FROM orders WHERE event_id = target_event)
              OR re.payment_id IN (SELECT p.id FROM payments p JOIN orders o ON o.id = p.order_id
                WHERE o.event_id = target_event))
        UNION ALL
        SELECT p.capture_recorded_at FROM payments p JOIN orders o ON o.id = p.order_id
          WHERE o.event_id = target_event AND p.capture_recorded_at IS NOT NULL
            AND p.status IN (#{CAPTURED_PAYMENT_STATUSES}) AND hafapass_unclassified_capture(p.id)
      ) blocks
    $$;

    -- P10 strict for every payout writer, old or new. On an event with an
    -- open blocking item: creating a payout, releasing a held one and any
    -- other move to pending, processing or paid is refused, except
    --   pending -> processing: the gateway outcome of a submission
    --     authorized before the earliest open item (a request already sent);
    --   pending, processing or held -> paid: that pre-hold submission, a
    --     transfer time (paid_at) before the earliest open item, and this
    --     release's verified confirmation that the money left before the
    --     hold, named in the same transaction (hafapass.payout_transfer).
    --     A submission authorization does not prove a transfer, and a
    --     timestamp alone proves nothing. 7bcd97c2 never names one.
    -- Holding, failing and reversing are never refused.
    CREATE OR REPLACE FUNCTION hafapass_payout_repayment_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      block_start timestamp;
      submitted_before boolean;
    BEGIN
      IF TG_OP = 'INSERT' AND hafapass_settlement_reader_required(NEW.event_id) THEN
        RAISE EXCEPTION 'Repayment fence: this event''s payouts need the never-fulfilled settlement reader'
          USING ERRCODE = '23514';
      END IF;
      IF NEW.status NOT IN (#{PAYOUT_PENDING_STATUS}, #{PAYOUT_PROCESSING_STATUS}, #{PAYOUT_PAID_STATUS}) OR
          (TG_OP = 'UPDATE' AND NEW.status = OLD.status) THEN
        RETURN NEW;
      END IF;
      block_start := hafapass_payout_block_start(NEW.event_id);
      IF block_start IS NULL THEN
        RETURN NEW;
      END IF;
      IF TG_OP = 'UPDATE' THEN
        submitted_before := EXISTS (SELECT 1 FROM audit_logs a
          WHERE a.auditable_type = 'Payout' AND a.auditable_id = NEW.id AND a.action = 'payout.submission_requested'
            AND a.occurred_at < block_start);
        IF NEW.status = #{PAYOUT_PROCESSING_STATUS} AND OLD.status = #{PAYOUT_PENDING_STATUS} AND submitted_before THEN
          RETURN NEW;
        END IF;
        IF NEW.status = #{PAYOUT_PAID_STATUS}
            AND OLD.status IN (#{PAYOUT_PENDING_STATUS}, #{PAYOUT_PROCESSING_STATUS}, #{PAYOUT_HELD_STATUS})
            AND submitted_before AND NEW.paid_at IS NOT NULL AND NEW.paid_at < block_start
            AND current_setting('hafapass.payout_transfer', true) IS NOT DISTINCT FROM NEW.id::text THEN
          RETURN NEW;
        END IF;
        IF NEW.status = #{PAYOUT_PAID_STATUS} THEN
          RAISE EXCEPTION 'Repayment fence: payout % needs verified transfer evidence from before the hold', NEW.id
            USING ERRCODE = '23514';
        END IF;
      END IF;
      RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
    END;
    $$;
    DROP TRIGGER IF EXISTS payouts_repayment_fence ON payouts;
    CREATE TRIGGER payouts_repayment_fence BEFORE INSERT OR UPDATE OF status ON payouts
      FOR EACH ROW EXECUTE FUNCTION hafapass_payout_repayment_fence();

    -- A signed receipt's provider identity, read from its own payload (the
    -- same fields StripeWebhookProcessor.provider_identity stores). A
    -- capture receipt carries it only when the intent succeeded.
    CREATE OR REPLACE FUNCTION hafapass_keep_receipt_identity() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      object jsonb := OLD.payload -> 'data' -> 'object';
      amount jsonb;
    BEGIN
      IF NEW.provider_payment_intent_id IS NOT NULL OR jsonb_typeof(object) IS DISTINCT FROM 'object'
          OR (OLD.event_type = 'payment_intent.succeeded' AND object->>'status' IS DISTINCT FROM 'succeeded') THEN
        RETURN NEW;
      END IF;
      NEW.provider_payment_intent_id := CASE
        WHEN starts_with(OLD.event_type, 'payment_intent.') THEN NULLIF(object->>'id', '')
        WHEN jsonb_typeof(object->'payment_intent') = 'object' THEN NULLIF(object->'payment_intent'->>'id', '')
        ELSE NULLIF(object->>'payment_intent', '') END;
      IF NEW.provider_payment_intent_id IS NULL THEN
        RETURN NEW;
      END IF;
      amount := CASE OLD.event_type WHEN 'charge.refunded' THEN object->'amount_refunded'
        WHEN 'payment_intent.succeeded' THEN object->'amount_received' ELSE object->'amount' END;
      NEW.provider_object_id := COALESCE(NEW.provider_object_id, NULLIF(object->>'id', ''));
      NEW.provider_livemode := COALESCE(NEW.provider_livemode,
        CASE WHEN OLD.payload ? 'livemode' THEN OLD.payload->'livemode' = 'true'::jsonb END);
      NEW.provider_account_id := COALESCE(NEW.provider_account_id, NULLIF(OLD.payload->>'account', ''));
      NEW.provider_amount_cents := COALESCE(NEW.provider_amount_cents,
        CASE WHEN jsonb_typeof(amount) = 'number' AND (amount #>> '{}') ~ '^[0-9]+$' THEN (amount #>> '{}')::bigint END);
      NEW.provider_currency := COALESCE(NEW.provider_currency, lower(NULLIF(object->>'currency', '')));
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS webhook_events_keep_identity ON webhook_events;
    CREATE TRIGGER webhook_events_keep_identity BEFORE UPDATE OF payload ON webhook_events
      FOR EACH ROW WHEN (OLD.payload IS DISTINCT FROM NEW.payload
        AND OLD.event_type IN (#{sql_list(WEBHOOK_IDENTITY_TYPES)}))
      EXECUTE FUNCTION hafapass_keep_receipt_identity();
  SQL
  OVERLAP_SENTINEL_TRIGGER = %w[orders_sale_refund_aggregate orders].freeze

  # A1-R1 boundary fixes (migration 20261126150000), from the exact-head
  # recheck at 1acdb91a. Again on the writes themselves, so 7bcd97c2 during
  # the overlap or after a rollback, and raw SQL, fail closed:
  #
  #   marked orders   a capture an older release acknowledged on an order
  #                   already marked never fulfilled is an overlap capture in
  #                   any status. A refund on the first capture moves the
  #                   order to partially refunded or refunded, where 7bcd97c2
  #                   takes its completed-sale branch and records the next
  #                   capture silently (finding 1).
  #   hold start      an overlap capture's hold starts when it began to
  #                   overlap: its own capture, or the first competing capture
  #                   if that came later. A blocking exception written while
  #                   its payment is still an unclassified overlap capture
  #                   keeps that start (reconciliation_exceptions.
  #                   hold_started_at, stamped here and never changed), so
  #                   classifying or quarantining the capture never moves the
  #                   payout cutoff later; an item added while the payment's
  #                   hold is still open keeps its start too. An episode
  #                   after the payment's items all closed starts at its own
  #                   time (finding 2). From the 2f961e48 recheck: a capture
  #                   from before the cutover (no recording time) counts as
  #                   the order's first competitor instead of being skipped,
  #                   competitors follow the predicate's own mode rule, an
  #                   item keeps the earliest start of any unclassified
  #                   capture on its order, and with no recorded fulfilling
  #                   payment an item stops counting only the order's first
  #                   capture of its mode, never a later one.
  #   event lock      every payout decision the fence makes (creation,
  #                   submission authorization, its outcome, paid, release
  #                   from hold, statement finalization) first holds the event
  #                   row, which every capture holds from its payment update
  #                   to its commit (OrderLifecycle's event context). The
  #                   fence reads in its next statement, a fresh READ
  #                   COMMITTED snapshot, so it sees any capture that
  #                   committed first. This release takes the lock in
  #                   organization -> event -> payout order before any check,
  #                   so the trigger finds it already held. 7bcd97c2's
  #                   submission, outcome and paid writers hold the
  #                   organization and the payout but not the event, so the
  #                   trigger takes it NOWAIT: it never waits in the reverse
  #                   order, and a capture in progress refuses the old write
  #                   instead (finding 3).
  BOUNDARY_SQL = <<~SQL.freeze
    CREATE OR REPLACE FUNCTION hafapass_unclassified_capture(target bigint) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT COALESCE((
        SELECT p.provider = 'stripe' AND p.status IN (#{CAPTURED_PAYMENT_STATUSES}) AND p.capture_recorded_at IS NOT NULL
          AND p.provider_environment IN ('test', 'live') AND p.provider_payment_id IS NOT NULL
          AND NOT starts_with(p.provider_payment_id, 'sim_') AND p.provider_payload->>'simulated' IS DISTINCT FROM 'true'
          AND CASE
            -- Another payment's order-scope capture marked the order. Every
            -- further capture on it is another order-scope capture
            -- (OrderLifecycle), whatever the order's status since; there is
            -- no sale for a test capture to compete with.
            WHEN o.never_fulfilled_at IS NOT NULL THEN true
            -- Payment.live_or_legacy_capture's mode rule: a test capture never
            -- competes with a live one for the same sale.
            WHEN o.fulfilled_by_payment_id IS NOT NULL THEN o.fulfilled_by_payment_id <> p.id
              AND EXISTS (SELECT 1 FROM payments f WHERE f.id = o.fulfilled_by_payment_id
                AND hafapass_live_or_legacy(f.provider_environment, f.provider_payload)
                  = hafapass_live_or_legacy(p.provider_environment, p.provider_payload))
            ELSE (o.completed_at IS NOT NULL OR o.status IN (#{SALE_STATUSES}))
              AND EXISTS (SELECT 1 FROM payments other WHERE other.order_id = o.id AND other.id <> p.id
                AND other.status IN (#{CAPTURED_PAYMENT_STATUSES})
                AND hafapass_live_or_legacy(other.provider_environment, other.provider_payload)
                  = hafapass_live_or_legacy(p.provider_environment, p.provider_payload))
              -- With no recorded fulfilling payment, the order's first capture
              -- of this mode (a capture from before the cutover counts as
              -- first) may be the sale itself: once another capture of this
              -- mode has an item, that first capture alone is no longer an
              -- overlap. Every later capture stays one until it has its own
              -- item, so one payment's item never hides another's liability.
              AND NOT (EXISTS (SELECT 1 FROM reconciliation_exceptions held JOIN payments other ON other.id = held.payment_id
                  WHERE other.order_id = o.id AND other.id <> p.id AND held.code IN (#{sql_list(CLASSIFYING_CODES)})
                    AND hafapass_live_or_legacy(other.provider_environment, other.provider_payload)
                      = hafapass_live_or_legacy(p.provider_environment, p.provider_payload))
                AND NOT EXISTS (SELECT 1 FROM payments earlier WHERE earlier.order_id = o.id AND earlier.id <> p.id
                  AND earlier.status IN (#{CAPTURED_PAYMENT_STATUSES})
                  AND hafapass_live_or_legacy(earlier.provider_environment, earlier.provider_payload)
                    = hafapass_live_or_legacy(p.provider_environment, p.provider_payload)
                  AND (COALESCE(earlier.capture_recorded_at, '-infinity'::timestamp), earlier.id) < (p.capture_recorded_at, p.id)))
          END
          AND NOT EXISTS (SELECT 1 FROM never_fulfilled_captures c WHERE c.payment_id = p.id)
          AND NOT EXISTS (SELECT 1 FROM reconciliation_exceptions re WHERE re.payment_id = p.id
            AND re.code IN (#{sql_list(CLASSIFYING_CODES)}))
        FROM payments p JOIN orders o ON o.id = p.order_id WHERE p.id = target), false)
    $$;

    -- When an unclassified overlap capture began to overlap, or NULL when the
    -- payment is not one: the later of its own capture and the order's first
    -- other capture that can compete with it, by the predicate's own mode
    -- rule (of its mode; any mode on a marked order). The fulfilling or
    -- marking payment is one of them. A capture from before the cutover has
    -- no recording time and was captured before every recorded one, so it
    -- counts as the earliest (-infinity), never as absent. Recording times
    -- are database-stamped once (payments_capture_recorded_at), so a later
    -- capture only adds a competitor and can only make this earlier.
    CREATE OR REPLACE FUNCTION hafapass_overlap_hold_start(target bigint) RETURNS timestamp
    LANGUAGE sql STABLE AS $$
      SELECT GREATEST(p.capture_recorded_at, (SELECT MIN(COALESCE(other.capture_recorded_at, '-infinity'::timestamp))
          FROM payments other WHERE other.order_id = p.order_id AND other.id <> p.id
            AND other.status IN (#{CAPTURED_PAYMENT_STATUSES})
            AND (o.never_fulfilled_at IS NOT NULL OR hafapass_live_or_legacy(other.provider_environment, other.provider_payload)
              = hafapass_live_or_legacy(p.provider_environment, p.provider_payload))))
        FROM payments p JOIN orders o ON o.id = p.order_id WHERE p.id = target AND hafapass_unclassified_capture(p.id)
    $$;

    CREATE OR REPLACE FUNCTION hafapass_payout_block_start(target_event bigint) RETURNS timestamp
    LANGUAGE sql STABLE AS $$
      SELECT MIN(started) FROM (
        SELECT LEAST(re.created_at, COALESCE(re.hold_started_at, re.created_at)) AS started
          FROM reconciliation_exceptions re
          WHERE re.status = #{OPEN_EXCEPTION_STATUS} AND re.code IN (#{sql_list(PAYOUT_BLOCKING_CODES)})
            AND (re.order_id IN (SELECT id FROM orders WHERE event_id = target_event)
              OR re.payment_id IN (SELECT p.id FROM payments p JOIN orders o ON o.id = p.order_id
                WHERE o.event_id = target_event))
        UNION ALL
        SELECT hafapass_overlap_hold_start(p.id) FROM payments p JOIN orders o ON o.id = p.order_id
          WHERE o.event_id = target_event AND p.capture_recorded_at IS NOT NULL
            AND p.status IN (#{CAPTURED_PAYMENT_STATUSES})
      ) blocks
    $$;

    -- Stamped on insert by the database (whatever value a writer supplies)
    -- and never changed: the earliest overlap start of any unclassified
    -- capture on the payment's order (its own included), or the start of a
    -- blocking item still open on the same payment, whichever is earlier.
    -- The new row is not yet visible here, so the first classifying exception
    -- still sees the overlap it is about to end, and any start it takes out
    -- of the overlap set (its own, or the order's first capture that its
    -- item stops counting) is kept on the row. The items discovery writes
    -- after it (a quarantine, a repayment wait) keep the same start for as
    -- long as the payment's hold stays open. Once every item on the payment
    -- is closed and no capture on the order is unclassified, a later item
    -- starts at its own time.
    CREATE OR REPLACE FUNCTION hafapass_exception_hold_start() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF NEW.hold_started_at IS DISTINCT FROM OLD.hold_started_at THEN
          RAISE EXCEPTION 'An exception''s hold start is recorded once, from its capture' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;
      NEW.hold_started_at := CASE WHEN NEW.payment_id IS NOT NULL AND NEW.code IN (#{sql_list(PAYOUT_BLOCKING_CODES)})
        THEN LEAST((SELECT MIN(hafapass_overlap_hold_start(x.id)) FROM payments x
            WHERE x.order_id = (SELECT target.order_id FROM payments target WHERE target.id = NEW.payment_id)),
          (SELECT MIN(LEAST(re.created_at, COALESCE(re.hold_started_at, re.created_at))) FROM reconciliation_exceptions re
            WHERE re.payment_id = NEW.payment_id AND re.status = #{OPEN_EXCEPTION_STATUS}
              AND re.code IN (#{sql_list(PAYOUT_BLOCKING_CODES)}))) END;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS reconciliation_exceptions_hold_start ON reconciliation_exceptions;
    CREATE TRIGGER reconciliation_exceptions_hold_start BEFORE INSERT OR UPDATE OF hold_started_at ON reconciliation_exceptions
      FOR EACH ROW EXECUTE FUNCTION hafapass_exception_hold_start();

    -- The event row every capture holds until it commits (docs/LOCKING.md
    -- rank 2). Already held by this release's payout writers; NOWAIT for an
    -- older writer that holds the payout (rank 3) and would otherwise wait
    -- in reverse order. A row lock taken in this block's subtransaction is
    -- kept when the block returns.
    CREATE OR REPLACE FUNCTION hafapass_lock_payout_event(target_event bigint) RETURNS void
    LANGUAGE plpgsql AS $$
    BEGIN
      PERFORM 1 FROM events WHERE id = target_event FOR NO KEY UPDATE NOWAIT;
    EXCEPTION WHEN lock_not_available THEN
      RAISE EXCEPTION 'Repayment fence: event % has a sale or capture in progress; retry this payout step', target_event
        USING ERRCODE = '55P03';
    END;
    $$;

    -- 20261126140000's fence, after the event lock (finding 3).
    CREATE OR REPLACE FUNCTION hafapass_payout_repayment_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      block_start timestamp;
      submitted_before boolean;
    BEGIN
      IF TG_OP = 'UPDATE' AND (NEW.status = OLD.status
          OR NEW.status NOT IN (#{PAYOUT_PENDING_STATUS}, #{PAYOUT_PROCESSING_STATUS}, #{PAYOUT_PAID_STATUS})) THEN
        RETURN NEW;
      END IF;
      -- Lock in one statement; every later statement reads a fresh snapshot.
      PERFORM hafapass_lock_payout_event(NEW.event_id);
      IF TG_OP = 'INSERT' AND hafapass_settlement_reader_required(NEW.event_id) THEN
        RAISE EXCEPTION 'Repayment fence: this event''s payouts need the never-fulfilled settlement reader'
          USING ERRCODE = '23514';
      END IF;
      IF NEW.status NOT IN (#{PAYOUT_PENDING_STATUS}, #{PAYOUT_PROCESSING_STATUS}, #{PAYOUT_PAID_STATUS}) THEN
        RETURN NEW;
      END IF;
      block_start := hafapass_payout_block_start(NEW.event_id);
      IF block_start IS NULL THEN
        RETURN NEW;
      END IF;
      IF TG_OP = 'UPDATE' THEN
        submitted_before := EXISTS (SELECT 1 FROM audit_logs a
          WHERE a.auditable_type = 'Payout' AND a.auditable_id = NEW.id AND a.action = 'payout.submission_requested'
            AND a.occurred_at < block_start);
        IF NEW.status = #{PAYOUT_PROCESSING_STATUS} AND OLD.status = #{PAYOUT_PENDING_STATUS} AND submitted_before THEN
          RETURN NEW;
        END IF;
        IF NEW.status = #{PAYOUT_PAID_STATUS}
            AND OLD.status IN (#{PAYOUT_PENDING_STATUS}, #{PAYOUT_PROCESSING_STATUS}, #{PAYOUT_HELD_STATUS})
            AND submitted_before AND NEW.paid_at IS NOT NULL AND NEW.paid_at < block_start
            AND current_setting('hafapass.payout_transfer', true) IS NOT DISTINCT FROM NEW.id::text THEN
          RETURN NEW;
        END IF;
        IF NEW.status = #{PAYOUT_PAID_STATUS} THEN
          RAISE EXCEPTION 'Repayment fence: payout % needs verified transfer evidence from before the hold', NEW.id
            USING ERRCODE = '23514';
        END IF;
      END IF;
      RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
    END;
    $$;

    CREATE OR REPLACE FUNCTION hafapass_payout_submission_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      target_event bigint;
    BEGIN
      SELECT event_id INTO target_event FROM payouts WHERE id = NEW.auditable_id;
      PERFORM hafapass_lock_payout_event(target_event);
      IF hafapass_payout_block_start(target_event) IS NOT NULL THEN
        RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;

    CREATE OR REPLACE FUNCTION hafapass_settlement_finalization_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      PERFORM hafapass_lock_payout_event(NEW.event_id);
      IF hafapass_payout_block_start(NEW.event_id) IS NOT NULL THEN
        RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
      END IF;
      IF hafapass_settlement_reader_required(NEW.event_id) THEN
        RAISE EXCEPTION 'Repayment fence: this event''s statement needs the never-fulfilled settlement reader'
          USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
  SQL
  BOUNDARY_SENTINEL_TRIGGER = %w[reconciliation_exceptions_hold_start reconciliation_exceptions].freeze

  # Names an exception (or refund) as backed by evidence for the rest of the
  # caller's transaction, so its database guard lets the write through.
  def self.with_evidence(kind, id)
    raise ArgumentError, "unknown evidence kind" unless %w[evidence_resolution refund_identity settlement_reader payout_transfer
      fee_facts_backfill custody_derivation].include?(kind.to_s)

    connection = ActiveRecord::Base.connection
    raise ArgumentError, "evidence needs an open transaction" unless connection.transaction_open?

    connection.select_value(ActiveRecord::Base.sanitize_sql_array(["SELECT set_config(?, ?, true)", "hafapass.#{kind}", id.to_s]))
    yield
  ensure
    if connection&.transaction_open?
      begin
        connection.select_value(ActiveRecord::Base.sanitize_sql_array(["SELECT set_config(?, '', true)", "hafapass.#{kind}"]))
      rescue ActiveRecord::StatementInvalid
        # The block's own database error aborted the transaction; rolling it
        # (or its savepoint) back discards the setting too. Keep that error.
        raise unless $ERROR_INFO
      end
    end
  end

  def self.with_settlement_reader(&)
    with_evidence(:settlement_reader, SETTLEMENT_READER, &)
  end

  # This release verified that the payout's money left before its event's
  # hold opened (PayoutReconciler); the payout fence requires it for paid.
  def self.with_payout_transfer(payout_id, &)
    with_evidence(:payout_transfer, payout_id, &)
  end

  SQL = (FOUNDATION_SQL + RETURNS_SQL + REPAYMENT_SQL + EVIDENCE_SQL + OVERLAP_SQL + BOUNDARY_SQL).freeze
  RETURNS_SENTINEL_TABLE = "buyer_return_postings"

  # A2 R2-2 (migration 20261126160000, design §8.6, §8.10.5): one frozen
  # custody determination per payout. Append-only and truncation-guarded like
  # §4.2. determined_at is the database clock at insert; an application value
  # is refused. Readers never recompute it.
  CUSTODY_SENTINEL_TABLE = "payout_custody_determinations"
  CUSTODY_SQL = <<~SQL.freeze
    CREATE OR REPLACE FUNCTION hafapass_stamp_custody_determination() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.determined_at IS NOT NULL THEN
        RAISE EXCEPTION 'A custody determination''s time is stamped by the database' USING ERRCODE = '23514';
      END IF;
      NEW.determined_at := timezone('UTC', clock_timestamp());
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS payout_custody_determinations_stamp ON payout_custody_determinations;
    CREATE TRIGGER payout_custody_determinations_stamp BEFORE INSERT ON payout_custody_determinations
      FOR EACH ROW EXECUTE FUNCTION hafapass_stamp_custody_determination();
    DROP TRIGGER IF EXISTS payout_custody_determinations_append_only ON payout_custody_determinations;
    CREATE TRIGGER payout_custody_determinations_append_only BEFORE UPDATE OR DELETE ON payout_custody_determinations
      FOR EACH ROW EXECUTE FUNCTION hafapass_append_only();
    CREATE OR REPLACE TRIGGER payout_custody_determinations_no_truncate BEFORE TRUNCATE ON payout_custody_determinations
      FOR EACH STATEMENT EXECUTE FUNCTION hafapass_append_only_truncate();
  SQL

  # A2 operational readers (migration 20261126170000, design §8.7,
  # §8.10.9).
  #
  # (1) P4 proof. never_fulfilled_buyer_overpaid stops holding payouts only
  #     when the over-returned capture is proven platform-only: classified,
  #     every recorded return movement posted and recognized, nothing in
  #     flight or unknown, no open evidence hold on it, no balance adjustment
  #     linked to it, and no payout custody determination naming it. Any
  #     other open overpaid exception is a hold in the same function the
  #     payout, submission and finalization fences use, so the application
  #     readers and the database agree. Its hold starts at the reading
  #     transaction's time (now()), not the exception's: proof can fail
  #     later (a linked adjustment, a new dispute), and a transfer already
  #     submitted and sent before then can still be recorded as paid.
  # (2) A durable recording time for verified processing facts
  #     (stripe_fee_evidences.facts_recorded_at). The database stamps it the
  #     first time an evidence row carries an evidence_digest and never
  #     changes it, so the projection can book payment-scope processing that
  #     has no fee component (A1 §4.6 item 8). Rows that already had facts
  #     keep NULL until `stripe_fee_evidence:stamp_facts` stamps them at the
  #     time it runs (hafapass.fee_facts_backfill names the row).
  OPERATIONAL_SENTINEL_TRIGGER = %w[stripe_fee_evidences_facts_recorded_at stripe_fee_evidences].freeze
  OVERPAID_CODE = "never_fulfilled_buyer_overpaid"
  REFUND_PENDING_STATUS = 0
  REFUND_SUCCEEDED_STATUS = 1
  DISPUTE_OPEN_STATUS = 0
  DISPUTE_LOST_STATUS = 2
  OPERATIONAL_SQL = <<~SQL.freeze
    CREATE OR REPLACE FUNCTION hafapass_overpaid_platform_only(target bigint) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT COALESCE((
        SELECT
          NOT EXISTS (SELECT 1 FROM refunds r WHERE r.payment_id = target AND r.status = #{REFUND_SUCCEEDED_STATUS}
            AND NOT EXISTS (SELECT 1 FROM buyer_return_postings p WHERE p.kind = 'refund' AND p.source_type = 'Refund'
              AND p.source_id = r.id))
          AND NOT EXISTS (SELECT 1 FROM disputes d WHERE d.payment_id = target AND d.status = #{DISPUTE_LOST_STATUS}
            AND d.amount_cents > 0 AND NOT EXISTS (SELECT 1 FROM buyer_return_postings p WHERE p.kind = 'dispute_loss'
              AND p.source_type = 'Dispute' AND p.source_id = d.id))
          AND NOT EXISTS (SELECT 1 FROM disputes d WHERE d.payment_id = target AND d.status = #{DISPUTE_LOST_STATUS}
            AND d.loss_reversed_at IS NOT NULL AND NOT EXISTS (SELECT 1 FROM buyer_return_postings p
              WHERE p.kind = 'dispute_loss_reversal' AND p.source_type = 'Dispute' AND p.source_id = d.id))
          AND NOT EXISTS (SELECT 1 FROM buyer_return_postings p WHERE p.never_fulfilled_capture_id = c.id
            AND p.recognition_state <> 'recognized')
          AND NOT EXISTS (SELECT 1 FROM refunds r WHERE r.payment_id = target AND r.status = #{REFUND_PENDING_STATUS})
          AND NOT EXISTS (SELECT 1 FROM disputes d WHERE d.payment_id = target AND d.status = #{DISPUTE_OPEN_STATUS})
          AND NOT EXISTS (SELECT 1 FROM repayment_operations o WHERE o.never_fulfilled_capture_id = c.id
            AND o.state NOT IN ('succeeded', 'failed_terminal'))
          AND NOT EXISTS (SELECT 1 FROM reconciliation_exceptions re WHERE re.payment_id = target
            AND re.status = #{OPEN_EXCEPTION_STATUS} AND re.code IN (#{sql_list(PAYOUT_BLOCKING_CODES)}))
          AND NOT EXISTS (SELECT 1 FROM balance_adjustments a WHERE (c.capture_scope = 'order' AND a.order_id = c.order_id)
            OR a.dispute_id IN (SELECT d.id FROM disputes d WHERE d.payment_id = target
              OR (c.capture_scope = 'order' AND d.order_id = c.order_id)))
          AND NOT EXISTS (SELECT 1 FROM payout_custody_determinations pcd WHERE target = ANY (pcd.qualifying_payment_ids))
        FROM never_fulfilled_captures c WHERE c.payment_id = target), false)
    $$;

    CREATE OR REPLACE FUNCTION hafapass_payout_block_start(target_event bigint) RETURNS timestamp
    LANGUAGE sql STABLE AS $$
      SELECT MIN(started) FROM (
        SELECT LEAST(re.created_at, COALESCE(re.hold_started_at, re.created_at)) AS started
          FROM reconciliation_exceptions re
          WHERE re.status = #{OPEN_EXCEPTION_STATUS} AND re.code IN (#{sql_list(PAYOUT_BLOCKING_CODES)})
            AND (re.order_id IN (SELECT id FROM orders WHERE event_id = target_event)
              OR re.payment_id IN (SELECT p.id FROM payments p JOIN orders o ON o.id = p.order_id
                WHERE o.event_id = target_event))
        UNION ALL
        SELECT hafapass_overlap_hold_start(p.id) FROM payments p JOIN orders o ON o.id = p.order_id
          WHERE o.event_id = target_event AND p.capture_recorded_at IS NOT NULL
            AND p.status IN (#{CAPTURED_PAYMENT_STATUSES})
        UNION ALL
        SELECT timezone('UTC', now()) FROM reconciliation_exceptions re
          WHERE re.status = #{OPEN_EXCEPTION_STATUS} AND re.code = '#{OVERPAID_CODE}'
            AND (re.order_id IN (SELECT id FROM orders WHERE event_id = target_event)
              OR re.payment_id IN (SELECT p.id FROM payments p JOIN orders o ON o.id = p.order_id
                WHERE o.event_id = target_event))
            AND NOT hafapass_overpaid_platform_only(re.payment_id)
      ) blocks
    $$;

    CREATE OR REPLACE FUNCTION hafapass_stamp_fee_facts_recorded_at() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        IF NEW.facts_recorded_at IS NOT NULL THEN
          RAISE EXCEPTION 'A fee fact''s recording time is stamped by the database' USING ERRCODE = '23514';
        END IF;
        IF NEW.evidence_digest IS NOT NULL THEN
          NEW.facts_recorded_at := timezone('UTC', clock_timestamp());
        END IF;
        RETURN NEW;
      END IF;
      IF OLD.facts_recorded_at IS NOT NULL THEN
        IF NEW.facts_recorded_at IS DISTINCT FROM OLD.facts_recorded_at THEN
          RAISE EXCEPTION 'A fee fact''s recording time is set once' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;
      IF NEW.evidence_digest IS NOT NULL AND (OLD.evidence_digest IS NULL
          OR current_setting('hafapass.fee_facts_backfill', true) IS NOT DISTINCT FROM NEW.id::text) THEN
        NEW.facts_recorded_at := timezone('UTC', clock_timestamp());
      ELSIF NEW.facts_recorded_at IS NOT NULL THEN
        RAISE EXCEPTION 'A fee fact''s recording time is stamped by the database' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS stripe_fee_evidences_facts_recorded_at ON stripe_fee_evidences;
    CREATE TRIGGER stripe_fee_evidences_facts_recorded_at BEFORE INSERT OR UPDATE ON stripe_fee_evidences
      FOR EACH ROW EXECUTE FUNCTION hafapass_stamp_fee_facts_recorded_at();
  SQL

  # A2 payout entry and overlap fences (migration 20261126180000, design
  # §8.10.11). A2's readers change the statement of every event with a
  # classified capture (one $0 line per capture), so a settlement version an
  # older reader finalized, or one finalized before a later classified
  # capture, no longer describes the event. On the writes themselves, so an
  # A1 process during the A2 overlap or after a rollback, and raw SQL, fail
  # closed:
  #
  #   reader      on an event with a classified capture, only a writer that
  #               names this release's reader (hafapass.settlement_reader =
  #               SETTLEMENT_READER) may finalize, create a payout, release a
  #               held one, authorize a submission, or record processing or
  #               paid. A1 names nfc-a1r1 (finalization and creation) or
  #               nothing (release, submission, outcome, paid).
  #   restated    hafapass_settlement_restated_at(version) is when a version
  #               stopped accounting for the event's classified captures: a
  #               capture with no $0 line in the version, from the capture's
  #               recording, but never before this migration (the A1 reader
  #               governed until then). A payout on a restated version cannot
  #               be created, released or submitted. Its outcome can still be
  #               recorded: processing for a submission authorized before
  #               that time, and paid only for that submission with a
  #               confirmed transfer time before it, named by
  #               hafapass.payout_transfer (PayoutReconciler). It is the same
  #               rule as the never-fulfilled hold, with the earlier cutoff.
  #   custody     a payout becomes paid only with its frozen custody
  #               determination for its own settlement version already
  #               written in the same transaction (payouts_require_custody,
  #               after the repayment fence; Payout before_update ->
  #               PayoutCustody.record!). A recorded_at_paid determination
  #               is inserted only while its payout is not yet paid, and must
  #               be on a paid or reversed payout at commit; a derived_history
  #               one only for a payout already paid or reversed, named by
  #               hafapass.custody_derivation (payout_custody:derive). An
  #               older release's paid recording therefore fails, and nothing
  #               later writes a recorded_at_paid row for it.
  #   stamp       settlements.finalized_reader and finalized_recorded_at are
  #               the reader and database clock at finalization, for the
  #               release checks and the custody bound; reader_digest (set by
  #               this release's Finalizer) is set once with them.
  #
  # No new lock: the payout and submission fences already hold the event
  # (hafapass_lock_payout_event) before these reads.
  PAYOUT_ENTRY_SENTINEL_TRIGGER = %w[payouts_require_custody payouts].freeze
  PAYOUT_ENTRY_CUTOVER = "a2_payout_entry"
  CUSTODY_DERIVED_BASIS = "derived_history"
  CUSTODY_PAID_BASIS = "recorded_at_paid"
  PAYOUT_ENTRY_SQL = <<~SQL.freeze
    CREATE OR REPLACE FUNCTION hafapass_event_has_classified_capture(target_event bigint) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT EXISTS (SELECT 1 FROM never_fulfilled_captures c JOIN orders o ON o.id = c.order_id
        WHERE o.event_id = target_event)
    $$;

    CREATE OR REPLACE FUNCTION hafapass_settlement_reader_required(target_event bigint) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT hafapass_event_has_classified_capture(target_event)
        AND current_setting('hafapass.settlement_reader', true) IS DISTINCT FROM '#{SETTLEMENT_READER}'
    $$;

    CREATE OR REPLACE FUNCTION hafapass_settlement_restated_at(target_settlement bigint) RETURNS timestamp
    LANGUAGE sql STABLE AS $$
      SELECT CASE WHEN MIN(c.capture_recorded_at) IS NULL THEN NULL
        ELSE GREATEST(MIN(c.capture_recorded_at),
          (SELECT fc.recorded_at FROM financial_cutovers fc WHERE fc.key = '#{PAYOUT_ENTRY_CUTOVER}')) END
      FROM settlements s
      JOIN orders o ON o.event_id = s.event_id
      JOIN never_fulfilled_captures c ON c.order_id = o.id
      WHERE s.id = target_settlement
        AND NOT EXISTS (SELECT 1 FROM settlement_items si WHERE si.settlement_id = s.id AND si.kind = 'adjustment'
          AND si.metadata->>'adjustment_kind' = 'never_fulfilled_capture'
          AND si.metadata->'payment_ids' @> jsonb_build_array(c.payment_id))
    $$;

    CREATE OR REPLACE FUNCTION hafapass_payout_repayment_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      block_start timestamp;
      restated_at timestamp;
      cutoff timestamp;
      submitted_before boolean;
    BEGIN
      IF TG_OP = 'UPDATE' AND (NEW.status = OLD.status
          OR NEW.status NOT IN (#{PAYOUT_PENDING_STATUS}, #{PAYOUT_PROCESSING_STATUS}, #{PAYOUT_PAID_STATUS})) THEN
        RETURN NEW;
      END IF;
      -- Lock in one statement; every later statement reads a fresh snapshot.
      PERFORM hafapass_lock_payout_event(NEW.event_id);
      IF hafapass_settlement_reader_required(NEW.event_id) THEN
        RAISE EXCEPTION 'Payout entry fence: payouts on this event need the current settlement reader; retry from the current release'
          USING ERRCODE = '23514';
      END IF;
      IF NEW.status NOT IN (#{PAYOUT_PENDING_STATUS}, #{PAYOUT_PROCESSING_STATUS}, #{PAYOUT_PAID_STATUS}) THEN
        RETURN NEW;
      END IF;
      block_start := hafapass_payout_block_start(NEW.event_id);
      restated_at := hafapass_settlement_restated_at(NEW.settlement_id);
      IF block_start IS NULL AND restated_at IS NULL THEN
        RETURN NEW;
      END IF;
      cutoff := LEAST(block_start, restated_at);
      IF TG_OP = 'UPDATE' THEN
        submitted_before := EXISTS (SELECT 1 FROM audit_logs a
          WHERE a.auditable_type = 'Payout' AND a.auditable_id = NEW.id AND a.action = 'payout.submission_requested'
            AND a.occurred_at < cutoff);
        IF NEW.status = #{PAYOUT_PROCESSING_STATUS} AND OLD.status = #{PAYOUT_PENDING_STATUS} AND submitted_before THEN
          RETURN NEW;
        END IF;
        IF NEW.status = #{PAYOUT_PAID_STATUS}
            AND OLD.status IN (#{PAYOUT_PENDING_STATUS}, #{PAYOUT_PROCESSING_STATUS}, #{PAYOUT_HELD_STATUS})
            AND submitted_before AND NEW.paid_at IS NOT NULL AND NEW.paid_at < cutoff
            AND current_setting('hafapass.payout_transfer', true) IS NOT DISTINCT FROM NEW.id::text THEN
          RETURN NEW;
        END IF;
        IF NEW.status = #{PAYOUT_PAID_STATUS} AND block_start IS NOT NULL THEN
          RAISE EXCEPTION 'Repayment fence: payout % needs verified transfer evidence from before the hold', NEW.id
            USING ERRCODE = '23514';
        END IF;
        IF NEW.status = #{PAYOUT_PAID_STATUS} THEN
          RAISE EXCEPTION 'Payout entry fence: payout % needs verified transfer evidence from before its statement was restated', NEW.id
            USING ERRCODE = '23514';
        END IF;
      END IF;
      IF block_start IS NOT NULL THEN
        RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
      END IF;
      RAISE EXCEPTION 'Payout entry fence: this payout''s statement version predates a never-fulfilled capture; finalize the statement again'
        USING ERRCODE = '23514';
    END;
    $$;

    CREATE OR REPLACE FUNCTION hafapass_payout_submission_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      target_event bigint;
      target_settlement bigint;
    BEGIN
      SELECT event_id, settlement_id INTO target_event, target_settlement FROM payouts WHERE id = NEW.auditable_id;
      PERFORM hafapass_lock_payout_event(target_event);
      IF hafapass_settlement_reader_required(target_event) THEN
        RAISE EXCEPTION 'Payout entry fence: payouts on this event need the current settlement reader; retry from the current release'
          USING ERRCODE = '23514';
      END IF;
      IF hafapass_payout_block_start(target_event) IS NOT NULL THEN
        RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
      END IF;
      IF hafapass_settlement_restated_at(target_settlement) IS NOT NULL THEN
        RAISE EXCEPTION 'Payout entry fence: this payout''s statement version predates a never-fulfilled capture; finalize the statement again'
          USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;

    -- Unchanged body (20261126150000); it now calls the reader rule above.
    CREATE OR REPLACE FUNCTION hafapass_settlement_finalization_fence() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      PERFORM hafapass_lock_payout_event(NEW.event_id);
      IF hafapass_payout_block_start(NEW.event_id) IS NOT NULL THEN
        RAISE EXCEPTION 'Repayment fence: a buyer repayment on this event is unresolved' USING ERRCODE = '23514';
      END IF;
      IF hafapass_settlement_reader_required(NEW.event_id) THEN
        RAISE EXCEPTION 'Repayment fence: this event''s statement needs the never-fulfilled settlement reader'
          USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;

    CREATE OR REPLACE FUNCTION hafapass_stamp_settlement_finalization() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'UPDATE' AND OLD.status = #{SETTLEMENT_FINALIZED_STATUS} THEN
        IF NEW.finalized_reader IS DISTINCT FROM OLD.finalized_reader
            OR NEW.finalized_recorded_at IS DISTINCT FROM OLD.finalized_recorded_at
            OR NEW.reader_digest IS DISTINCT FROM OLD.reader_digest THEN
          RAISE EXCEPTION 'A finalized settlement''s reader, digest and recording time are set once' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END IF;
      IF NEW.status = #{SETTLEMENT_FINALIZED_STATUS} THEN
        NEW.finalized_reader := NULLIF(current_setting('hafapass.settlement_reader', true), '');
        NEW.finalized_recorded_at := timezone('UTC', clock_timestamp());
      ELSE
        NEW.finalized_reader := NULL;
        NEW.finalized_recorded_at := NULL;
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS settlements_finalization_stamp ON settlements;
    CREATE TRIGGER settlements_finalization_stamp BEFORE INSERT OR UPDATE ON settlements
      FOR EACH ROW EXECUTE FUNCTION hafapass_stamp_settlement_finalization();

    CREATE OR REPLACE FUNCTION hafapass_require_payout_custody() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM payout_custody_determinations d
          WHERE d.payout_id = NEW.id AND d.settlement_id = NEW.settlement_id) THEN
        RAISE EXCEPTION 'Payout custody fence: payout % has no custody determination; record it paid from the current release', NEW.id
          USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS payouts_require_custody ON payouts;
    CREATE TRIGGER payouts_require_custody BEFORE UPDATE OF status ON payouts
      FOR EACH ROW WHEN (NEW.status = #{PAYOUT_PAID_STATUS} AND OLD.status IS DISTINCT FROM #{PAYOUT_PAID_STATUS})
      EXECUTE FUNCTION hafapass_require_payout_custody();

    CREATE OR REPLACE FUNCTION hafapass_check_custody_determination() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      payout_status integer;
      payout_settlement bigint;
    BEGIN
      SELECT status, settlement_id INTO payout_status, payout_settlement FROM payouts WHERE id = NEW.payout_id;
      IF payout_settlement IS DISTINCT FROM NEW.settlement_id THEN
        RAISE EXCEPTION 'A custody determination must name its payout''s own settlement version' USING ERRCODE = '23514';
      END IF;
      IF NEW.basis = '#{CUSTODY_PAID_BASIS}' AND payout_status NOT IN
          (#{PAYOUT_PENDING_STATUS}, #{PAYOUT_PROCESSING_STATUS}, #{PAYOUT_HELD_STATUS}) THEN
        RAISE EXCEPTION 'A paid-recording custody determination is written only with the paid recording' USING ERRCODE = '23514';
      END IF;
      IF NEW.basis = '#{CUSTODY_DERIVED_BASIS}' AND (payout_status NOT IN (#{PAYOUT_PAID_STATUS}, #{PAYOUT_REVERSED_STATUS})
          OR current_setting('hafapass.custody_derivation', true) IS DISTINCT FROM NEW.payout_id::text) THEN
        RAISE EXCEPTION 'A historical custody determination needs the authorized derivation for a paid payout'
          USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS payout_custody_determinations_check ON payout_custody_determinations;
    CREATE TRIGGER payout_custody_determinations_check BEFORE INSERT ON payout_custody_determinations
      FOR EACH ROW EXECUTE FUNCTION hafapass_check_custody_determination();

    CREATE OR REPLACE FUNCTION hafapass_check_custody_commit() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM payouts p WHERE p.id = NEW.payout_id
          AND p.status IN (#{PAYOUT_PAID_STATUS}, #{PAYOUT_REVERSED_STATUS})) THEN
        RAISE EXCEPTION 'A custody determination commits only with its payout recorded paid' USING ERRCODE = '23514';
      END IF;
      RETURN NULL;
    END;
    $$;
    DROP TRIGGER IF EXISTS payout_custody_determinations_commit ON payout_custody_determinations;
    CREATE CONSTRAINT TRIGGER payout_custody_determinations_commit AFTER INSERT ON payout_custody_determinations
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION hafapass_check_custody_commit();
  SQL

  module SchemaDump
    private

    def tables(stream)
      super
      trigger, table = SENTINEL_TRIGGER
      return unless @connection.data_source_exists?(table) && @connection.data_source_exists?("never_fulfilled_captures")
      return unless @connection.select_value(
        "SELECT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = '#{trigger}' AND tgrelid = '#{table}'::regclass)"
      )

      sql = FinancialIntegrity::FOUNDATION_SQL
      sql += FinancialIntegrity::RETURNS_SQL if @connection.data_source_exists?(RETURNS_SENTINEL_TABLE)
      sql += FinancialIntegrity::REPAYMENT_SQL if @connection.data_source_exists?(REPAYMENT_SENTINEL_TABLE)
      evidence_trigger, evidence_table = EVIDENCE_SENTINEL_TRIGGER
      if @connection.select_value("SELECT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = '#{evidence_trigger}' " \
          "AND tgrelid = '#{evidence_table}'::regclass)")
        sql += FinancialIntegrity::EVIDENCE_SQL
        overlap_trigger, overlap_table = OVERLAP_SENTINEL_TRIGGER
        if @connection.select_value("SELECT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = '#{overlap_trigger}' " \
            "AND tgrelid = '#{overlap_table}'::regclass)")
          sql += FinancialIntegrity::OVERLAP_SQL
          boundary_trigger, boundary_table = BOUNDARY_SENTINEL_TRIGGER
          if @connection.select_value("SELECT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = '#{boundary_trigger}' " \
              "AND tgrelid = '#{boundary_table}'::regclass)")
            sql += FinancialIntegrity::BOUNDARY_SQL
          end
        end
      end
      sql += FinancialIntegrity::CUSTODY_SQL if @connection.data_source_exists?(CUSTODY_SENTINEL_TABLE)
      operational_trigger, operational_table = OPERATIONAL_SENTINEL_TRIGGER
      if @connection.select_value("SELECT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = '#{operational_trigger}' " \
          "AND tgrelid = '#{operational_table}'::regclass)")
        sql += FinancialIntegrity::OPERATIONAL_SQL
      end
      entry_trigger, entry_table = PAYOUT_ENTRY_SENTINEL_TRIGGER
      if @connection.select_value("SELECT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = '#{entry_trigger}' " \
          "AND tgrelid = '#{entry_table}'::regclass)")
        sql += FinancialIntegrity::PAYOUT_ENTRY_SQL
      end
      stream.puts "  execute <<~SQL"
      sql.each_line { |line| stream.puts(line.strip.empty? ? "" : "    #{line}") }
      stream.puts "  SQL"
      stream.puts
    end
  end
end
