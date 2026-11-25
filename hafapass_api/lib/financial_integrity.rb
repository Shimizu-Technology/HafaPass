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

  SQL = (CAPTURE_RECORDED_AT_SQL + APPEND_ONLY_SQL + CLASSIFICATION_SQL + ORDER_GUARD_SQL + TICKET_GUARD_SQL).freeze

  module SchemaDump
    private

    def tables(stream)
      super
      trigger, table = SENTINEL_TRIGGER
      return unless @connection.data_source_exists?(table) && @connection.data_source_exists?("never_fulfilled_captures")
      return unless @connection.select_value(
        "SELECT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = '#{trigger}' AND tgrelid = '#{table}'::regclass)"
      )

      stream.puts "  execute <<~SQL"
      FinancialIntegrity::SQL.each_line { |line| stream.puts(line.strip.empty? ? "" : "    #{line}") }
      stream.puts "  SQL"
      stream.puts
    end
  end
end
