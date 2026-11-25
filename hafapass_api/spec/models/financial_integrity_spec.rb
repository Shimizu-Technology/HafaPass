# frozen_string_literal: true

require "rails_helper"

# Database guarantees for never-fulfilled capture classification
# (docs/design/never-fulfilled-captures.md §4.2, tests C-01…C-19). Every
# bypass goes through raw SQL, update_all or update_columns, because the
# triggers, not the model callbacks, are the guarantee.
RSpec.describe FinancialIntegrity do
  let(:connection) { ActiveRecord::Base.connection }

  def isolated(&block)
    ActiveRecord::Base.transaction(requires_new: true, &block)
  end

  def expired_order_with_capture(status: :expired)
    order = create(:order, status: status, completed_at: nil, subtotal_cents: 1200, service_fee_cents: 160, total_cents: 1360)
    payment = create(:payment, order: order, status: :succeeded, succeeded_at: Time.current)
    [order, payment]
  end

  def classification_attributes(order, payment, scope: "order")
    order_scope = scope == "order"
    {
      order: order, payment: payment, capture_scope: scope,
      code: order_scope ? "late_payment_success_after_hold_expiry" : "unfulfilled_second_capture",
      captured_cents: payment.amount_cents, currency: payment.currency,
      proceeds_cents: order_scope ? payment.amount_cents - 160 : payment.amount_cents,
      fee_cents: order_scope ? 160 : 0, organizer_fee_cents: 0, tax_cents: 0,
      processing_bearer: "platform", dispute_fee_bearer: "platform",
      allocation_policy: "item_record", policy_version: "nfc-v2.1", provenance: "lifecycle"
    }
  end

  # validate: false sends the row straight to the database triggers.
  def classify!(order, payment, scope: "order", **overrides)
    UnfulfilledCapture.new(classification_attributes(order, payment, scope: scope).merge(overrides)).tap do |row|
      row.save!(validate: false)
    end
  end

  def fulfilled_order
    order = create(:order, :pending, subtotal_cents: 1200, service_fee_cents: 160, total_cents: 1360)
    first = create(:payment, order: order, status: :succeeded, succeeded_at: Time.current)
    order.update!(status: :completed, completed_at: Time.current, fulfilled_by_payment_id: first.id)
    [order, first]
  end

  def legacy_captured_payment(order)
    # A capture recorded before A1: the trigger did not exist, so the column is NULL.
    connection.execute("SET LOCAL session_replication_role = replica")
    create(:payment, order: order, status: :succeeded, succeeded_at: 3.months.ago)
  ensure
    connection.execute("SET LOCAL session_replication_role = DEFAULT")
  end

  describe "payments.capture_recorded_at (C-15)" do
    it "is stamped by the database when a payment is inserted as captured, not when pending" do
      order = create(:order, :pending)
      captured = create(:payment, order: order, status: :succeeded, succeeded_at: 2.months.ago)
      pending = create(:payment, order: order)

      # The legacy backfill writer backdates succeeded_at to order.completed_at;
      # the recording time is still the moment the row was written.
      expect(captured.reload.capture_recorded_at).to be_within(1.minute).of(Time.current)
      expect(captured.succeeded_at).to be < 1.month.ago
      expect(pending.reload.capture_recorded_at).to be_nil
    end

    it "is stamped on the first move into a captured status and never changes afterwards" do
      payment = create(:payment)
      payment.update!(status: :succeeded, succeeded_at: Time.current)
      stamped = payment.reload.capture_recorded_at
      expect(stamped).to be_present

      payment.update!(status: :partially_refunded)
      payment.update!(status: :refunded)
      expect(payment.reload.capture_recorded_at).to eq(stamped)

      expect { isolated { Payment.where(id: payment.id).update_all(capture_recorded_at: 1.year.ago) } }
        .to raise_error(ActiveRecord::StatementInvalid, /set once/)
      expect { isolated { Payment.where(id: payment.id).update_all(capture_recorded_at: nil) } }
        .to raise_error(ActiveRecord::StatementInvalid, /set once/)
      expect { isolated { Payment.where(id: payment.id).update_all(capture_recorded_at: 1.day.from_now) } }
        .to raise_error(ActiveRecord::StatementInvalid, /set once/)
    end

    it "refuses to pre-stamp a non-captured payment or to stamp a capture recorded before A1" do
      order = create(:order, :pending)
      pending = create(:payment, order: order)
      expect { isolated { Payment.where(id: pending.id).update_all(capture_recorded_at: Time.current) } }
        .to raise_error(ActiveRecord::StatementInvalid, /only when the payment is first captured/)

      legacy = legacy_captured_payment(order)
      expect(legacy.reload.capture_recorded_at).to be_nil
      expect { isolated { Payment.where(id: legacy.id).update_all(capture_recorded_at: legacy.succeeded_at) } }
        .to raise_error(ActiveRecord::StatementInvalid, /only when the payment is first captured/)
      legacy.update!(status: :refunded)
      expect(legacy.reload.capture_recorded_at).to be_nil
    end

    it "keeps the application from assigning it" do
      payment = create(:payment, :succeeded)
      expect { payment.update!(capture_recorded_at: 1.day.ago) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    end
  end

  describe "classification ownership (C-01, C-16)" do
    it "classifies an expired order's capture and copies the payment's recording time" do
      order, payment = expired_order_with_capture
      row = classify!(order, payment)
      expect(row.reload.capture_recorded_at).to eq(payment.reload.capture_recorded_at)
      expect(order.reload.never_fulfilled_at).to eq(row.created_at)
      expect(row).to be_order_scope
    end

    it "rejects another order's payment through the composite foreign key" do
      order, = expired_order_with_capture
      _other_order, other_payment = expired_order_with_capture
      expect { isolated { classify!(order, other_payment) } }
        .to raise_error(ActiveRecord::StatementInvalid, /must belong to the classified order/)

      # With the ownership trigger out of the way, the composite foreign key alone still refuses it.
      expect do
        isolated do
          connection.execute("ALTER TABLE never_fulfilled_captures DISABLE TRIGGER never_fulfilled_captures_check")
          classify!(order, other_payment, capture_recorded_at: other_payment.reload.capture_recorded_at)
        end
      end.to raise_error(ActiveRecord::InvalidForeignKey, /fk_never_fulfilled_captures_same_order_payment/)
    end

    it "rejects a payment that is not captured, or whose amount, currency or recording time differ" do
      order, payment = expired_order_with_capture
      failed = create(:payment, order: order, status: :failed)
      expect { isolated { classify!(order, failed) } }.to raise_error(ActiveRecord::StatementInvalid, /Only a captured payment/)
      expect { isolated { classify!(order, payment, captured_cents: 1000, proceeds_cents: 840) } }
        .to raise_error(ActiveRecord::StatementInvalid, /amount and currency/)
      expect { isolated { classify!(order, payment, currency: "eur") } }
        .to raise_error(ActiveRecord::StatementInvalid, /amount and currency/)
      expect { isolated { classify!(order, payment, capture_recorded_at: 1.day.ago) } }
        .to raise_error(ActiveRecord::StatementInvalid, /recorded capture time/)
    end

    it "rejects order scope on a pending, completed, fulfilled, completion-audited or ticketed order" do
      pending_order = create(:order, :pending, subtotal_cents: 1200, service_fee_cents: 160, total_cents: 1360)
      pending_payment = create(:payment, order: pending_order, status: :succeeded, succeeded_at: Time.current)
      expect { isolated { classify!(pending_order, pending_payment) } }
        .to raise_error(ActiveRecord::StatementInvalid, /pending or fulfilled order/)

      completed, first = fulfilled_order
      expect { isolated { classify!(completed, first) } }.to raise_error(ActiveRecord::StatementInvalid, /pending or fulfilled order/)

      # A legacy fulfilled-then-refunded order with a null completed_at.
      refunded, refunded_payment = expired_order_with_capture(status: :refunded)
      AuditLogger.record!(action: "order.completed", auditable: refunded, event: refunded.event,
        deduplication_key: "order:#{refunded.id}:completed")
      expect { isolated { classify!(refunded, refunded_payment) } }
        .to raise_error(ActiveRecord::StatementInvalid, /pending or fulfilled order/)

      ticketed, ticketed_payment = expired_order_with_capture
      create(:ticket, order: ticketed)
      expect { isolated { classify!(ticketed, ticketed_payment) } }
        .to raise_error(ActiveRecord::StatementInvalid, /active tickets/)
      Ticket.where(order_id: ticketed.id).update_all(status: Ticket.statuses[:cancelled])
      expect { classify!(ticketed, ticketed_payment) }.not_to raise_error
    end

    it "requires a verified fulfilling payment for payment scope and never classifies that payment" do
      legacy = create(:order, subtotal_cents: 1200, service_fee_cents: 160, total_cents: 1360)
      legacy_first = create(:payment, order: legacy, status: :succeeded, succeeded_at: Time.current)
      legacy_second = create(:payment, order: legacy, status: :succeeded, succeeded_at: Time.current)
      expect { isolated { classify!(legacy, legacy_second, scope: "payment") } }
        .to raise_error(ActiveRecord::StatementInvalid, /verified fulfilling payment/)
      expect(legacy_first.reload.unfulfilled_capture).to be_nil

      order, first = fulfilled_order
      second = create(:payment, order: order, status: :succeeded, succeeded_at: Time.current)
      expect { isolated { classify!(order, first, scope: "payment") } }
        .to raise_error(ActiveRecord::StatementInvalid, /fulfilling payment cannot be classified/)

      row = classify!(order, second, scope: "payment")
      expect(row).to be_payment_scope
      expect(order.reload.never_fulfilled_at).to be_nil
      expect(order).to be_completed
    end

    it "enforces the component snapshot and the payment-scope principal rule" do
      order, payment = expired_order_with_capture
      expect { isolated { classify!(order, payment, proceeds_cents: 1199) } }
        .to raise_error(ActiveRecord::StatementInvalid, /components_sum/)

      fulfilled, = fulfilled_order
      second = create(:payment, order: fulfilled, status: :succeeded, succeeded_at: Time.current)
      expect { isolated { classify!(fulfilled, second, scope: "payment", proceeds_cents: 1200, fee_cents: 160) } }
        .to raise_error(ActiveRecord::StatementInvalid, /payment_scope_principal/)
    end

    it "accepts a pre-A1 capture only as an evidenced backfill no later than the cutover" do
      order, = expired_order_with_capture
      legacy = legacy_captured_payment(order)
      connection.execute("INSERT INTO financial_cutovers (key) VALUES ('a1_capture_recording') ON CONFLICT (key) DO NOTHING")

      expect { isolated { classify!(order, legacy) } }.to raise_error(ActiveRecord::StatementInvalid, /backfilled time/)
      expect { isolated { classify!(order, legacy, provenance: "backfill", provenance_evidence: {}, capture_recorded_at: 3.months.ago) } }
        .to raise_error(ActiveRecord::StatementInvalid, /backfill_evidence/)
      expect do
        isolated do
          classify!(order, legacy, provenance: "backfill", provenance_evidence: { "exception_id" => 1 }, capture_recorded_at: 1.day.from_now)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /no later than the cutover/)

      row = classify!(order, legacy, provenance: "backfill", provenance_evidence: { "exception_id" => 1 }, capture_recorded_at: 3.months.ago)
      expect(row.reload.capture_recorded_at).to be_within(1.second).of(3.months.ago)
    end

    it "allows one classification per payment" do
      order, payment = expired_order_with_capture
      classify!(order, payment)
      expect { isolated { classify!(order, payment) } }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "append-only classification (C-02)" do
    it "rejects updates, deletes and truncation by any route" do
      order, payment = expired_order_with_capture
      row = classify!(order, payment)

      expect(row.reload).to be_readonly
      expect { isolated { UnfulfilledCapture.where(id: row.id).update_all(code: "event_not_eligible") } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { isolated { UnfulfilledCapture.where(id: row.id).delete_all } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { isolated { connection.execute("UPDATE never_fulfilled_captures SET capture_scope = 'payment'") } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      # Postings reference captures, so a truncation has to name both tables.
      expect { isolated { connection.execute("TRUNCATE never_fulfilled_captures, buyer_return_postings CASCADE") } }
        .to raise_error(ActiveRecord::StatementInvalid, /cannot be truncated/)
      expect { isolated { connection.execute("UPDATE financial_cutovers SET recorded_at = recorded_at") } }
        .not_to raise_error # no rows in a schema-loaded database; the row case is below
      connection.execute("INSERT INTO financial_cutovers (key) VALUES ('a1_capture_recording') ON CONFLICT (key) DO NOTHING")
      expect { isolated { connection.execute("UPDATE financial_cutovers SET recorded_at = recorded_at - interval '1 day'") } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { isolated { connection.execute("DELETE FROM financial_cutovers") } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect(UnfulfilledCapture.find(row.id).capture_scope).to eq("order")
    end
  end

  describe "the derived order marker (C-03, C-06, C-17)" do
    it "is set from the first order-scope row only and cannot be written directly" do
      order, first_payment = expired_order_with_capture
      first = classify!(order, first_payment)
      marked_at = order.reload.never_fulfilled_at
      expect(marked_at).to eq(first.created_at)

      second_payment = create(:payment, order: order, status: :succeeded, succeeded_at: Time.current)
      classify!(order, second_payment, created_at: 1.minute.from_now)
      expect(order.reload.never_fulfilled_at).to eq(marked_at)
      expect(order.unfulfilled_captures.count).to eq(2)

      expect { isolated { order.update_columns(never_fulfilled_at: nil) } }.to raise_error(ActiveRecord::StatementInvalid, /set once/)
      expect { isolated { Order.where(id: order.id).update_all(never_fulfilled_at: 1.day.ago) } }
        .to raise_error(ActiveRecord::StatementInvalid, /set once/)

      other, = expired_order_with_capture
      expect { isolated { other.update_columns(never_fulfilled_at: Time.current) } }
        .to raise_error(ActiveRecord::StatementInvalid, /only from an order-scope classification/)
      expect do
        isolated { create(:order, status: :expired, completed_at: nil).update_columns(never_fulfilled_at: first.created_at) }
      end.to raise_error(ActiveRecord::StatementInvalid, /only from an order-scope classification/)
    end

    it "is refused at order creation" do
      expect do
        isolated do
          order = build(:order, :pending)
          order.never_fulfilled_at = Time.current
          order.save!
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /not at creation/)
    end

    it "keeps a classified order from being completed or reopened" do
      order, payment = expired_order_with_capture
      classify!(order, payment)
      expect { isolated { order.update_columns(status: Order.statuses[:completed]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /orders_never_fulfilled_not_completed/)
      expect { isolated { order.update_columns(completed_at: Time.current) } }
        .to raise_error(ActiveRecord::StatementInvalid, /orders_never_fulfilled_not_completed/)
      expect { isolated { order.update_columns(status: Order.statuses[:pending]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /orders_never_fulfilled_not_completed/)
      order.update!(status: :partially_refunded)
      expect(order.reload).to be_partially_refunded
    end
  end

  describe "the fulfilling payment (C-18)" do
    it "is set once to a captured payment on the same order" do
      order, first = fulfilled_order
      second = create(:payment, order: order, status: :succeeded, succeeded_at: Time.current)
      expect { isolated { order.update_columns(fulfilled_by_payment_id: second.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /set once/)
      expect { isolated { order.update_columns(fulfilled_by_payment_id: nil) } }
        .to raise_error(ActiveRecord::StatementInvalid, /set once/)
      expect(order.reload.fulfilled_by_payment).to eq(first)
    end

    it "rejects another order's payment, a non-captured or classified payment, and unfulfilled orders" do
      _other, other_payment = fulfilled_order
      order = create(:order)
      expect { isolated { order.update_columns(fulfilled_by_payment_id: other_payment.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /must belong to this order/)

      pending_payment = create(:payment, order: order)
      expect { isolated { order.update_columns(fulfilled_by_payment_id: pending_payment.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /must be captured/)

      expired, expired_payment = expired_order_with_capture
      expect { isolated { expired.update_columns(fulfilled_by_payment_id: expired_payment.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /Only a fulfilled order/)

      classify!(expired, expired_payment)
      expect { isolated { expired.update_columns(status: Order.statuses[:refunded], fulfilled_by_payment_id: expired_payment.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /cannot record a fulfilling payment/)
    end
  end

  describe "ticket issuance (C-04, C-19)" do
    let(:pass_type) { create(:ticket_type, is_pass: true) }

    it "rejects a ticket insert on a classified order by the lifecycle, a model insert or raw SQL" do
      order, payment = expired_order_with_capture
      item = create(:order_item, order: order)
      classify!(order, payment)

      expect { isolated { Commerce::OrderLifecycle.send(:issue_tickets!, order.reload) } }
        .to raise_error(ActiveRecord::StatementInvalid, /never-fulfilled order/)
      expect { isolated { create(:ticket, order: order, ticket_type: item.ticket_type) } }
        .to raise_error(ActiveRecord::StatementInvalid, /never-fulfilled order/)
      expect do
        isolated do
          connection.execute(<<~SQL.squish)
            INSERT INTO tickets (order_id, ticket_type_id, event_id, status, qr_code, created_at, updated_at)
            VALUES (#{order.id}, #{item.ticket_type_id}, #{order.event_id}, 0, '#{SecureRandom.uuid}', now(), now())
          SQL
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /never-fulfilled order/)
      expect(order.tickets.where.not(status: :cancelled)).to be_empty
    end

    it "rejects a pass child ticket on a classified order" do
      order, payment = expired_order_with_capture
      parent = create(:ticket, :cancelled, order: order, ticket_type: pass_type, event: order.event)
      classify!(order, payment)
      night = create(:event, :published)

      expect { isolated { Passes::Issuance.call(order: order, parent_ticket: parent, included_events: [night]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /never-fulfilled order/)
    end

    it "rejects reactivating or reassigning a ticket onto a classified order" do
      order, payment = expired_order_with_capture
      cancelled = create(:ticket, :cancelled, order: order)
      classify!(order, payment)
      expect { isolated { cancelled.update_columns(status: Ticket.statuses[:issued]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /never-fulfilled order/)

      elsewhere = create(:ticket)
      expect { isolated { elsewhere.update_columns(order_id: order.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /never-fulfilled order/)
      expect { isolated { Ticket.where(id: elsewhere.id).update_all(order_id: order.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /never-fulfilled order/)
    end

    it "leaves ordinary ticket flows and payment-scope orders alone" do
      ticket = create(:ticket)
      ticket.update!(status: :checked_in, checked_in_at: Time.current)
      ticket.update!(status: :cancelled)
      ticket.update_columns(status: Ticket.statuses[:issued]) # an unclassified order may reactivate
      expect(ticket.reload).to be_issued

      order, first = fulfilled_order
      second = create(:payment, order: order, status: :succeeded, succeeded_at: Time.current)
      classify!(order, second, scope: "payment")
      expect(create(:ticket, order: order)).to be_persisted

      classified, payment = expired_order_with_capture
      classify!(classified, payment)
      expect(create(:ticket, :cancelled, order: classified)).to be_persisted
      expect(first.reload.unfulfilled_capture).to be_nil
    end
  end

  describe "schema reinstallation (C-08)" do
    let(:triggers) do
      {
        "payments" => %w[payments_capture_recorded_at],
        "never_fulfilled_captures" => %w[never_fulfilled_captures_append_only never_fulfilled_captures_check
          never_fulfilled_captures_mark_order never_fulfilled_captures_no_truncate],
        "financial_cutovers" => %w[financial_cutovers_append_only financial_cutovers_no_truncate],
        "orders" => %w[orders_fulfillment_guard],
        "tickets" => %w[tickets_issuance_guard]
      }
    end

    it "dumps every trigger as executable DDL after the audit-log DDL" do
      output = StringIO.new
      ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, output)
      dump = output.string
      triggers.values.flatten.each { |name| expect(dump).to include("TRIGGER #{name}") }
      expect(dump.index("hafapass_guard_ticket_issuance")).to be > dump.index("hafapass_protect_audit_log_truncate")
      expect(dump).not_to match(/[ \t]+$/)
    end

    it "has every trigger installed in this schema-loaded database" do
      installed = connection.select_rows(<<~SQL).group_by(&:first).transform_values { |rows| rows.map(&:last).sort }
        SELECT tgrelid::regclass::text, tgname FROM pg_trigger
        WHERE NOT tgisinternal AND tgrelid::regclass::text IN ('payments', 'never_fulfilled_captures', 'financial_cutovers', 'orders', 'tickets')
          AND tgname <> 'tickets_dispute_sale_ownership' -- A1-R1 review guards (repayment_fence_spec.rb)
      SQL
      expect(installed).to eq(triggers.transform_values(&:sort))
    end
  end
end
