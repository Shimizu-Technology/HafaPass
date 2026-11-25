# frozen_string_literal: true

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

  SQL = (FOUNDATION_SQL + RETURNS_SQL).freeze
  RETURNS_SENTINEL_TABLE = "buyer_return_postings"

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
      stream.puts "  execute <<~SQL"
      sql.each_line { |line| stream.puts(line.strip.empty? ? "" : "    #{line}") }
      stream.puts "  SQL"
      stream.puts
    end
  end
end
