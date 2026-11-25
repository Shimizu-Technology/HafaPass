# frozen_string_literal: true

require "rails_helper"
require "timeout"

# A1-R1 boundary fix 3 (docs/design/never-fulfilled-captures.md §6.9,
# docs/LOCKING.md): payout submission, its outcome and paid recording are
# serialized with captures on the same event row. Every capture holds the
# event (FOR NO KEY UPDATE) from its payment update until it commits; this
# release's payout writers take organization -> event -> payout before any
# check, so a payout decision waits for an in-flight capture and then reads a
# fresh READ COMMITTED snapshot that includes it. 7bcd97c2's submission and
# paid writers hold the organization and the payout but not the event, so
# the database fence takes the event NOWAIT: with a capture in flight it
# refuses the old write instead of waiting in reverse lock order, and with
# the old write in flight a capture waits for it. Real connections and
# commits; pg_blocking_pids proves each wait. No sleep is an assertion.
RSpec.describe "Payout decisions serialized with captures", :non_transactional do
  self.use_transactional_tests = false

  DEADLINE = 20

  # A rendezvous: the worker stops at #hit! until the example releases it.
  class Pause
    def initialize
      @reached = Queue.new
      @go = Queue.new
    end

    def hit!(value = true)
      @reached << value
      @go.pop(timeout: DEADLINE) || raise("pause never released")
    end

    def reached
      @reached.pop(timeout: DEADLINE) || raise("pause never reached")
    end

    def release!
      @go << true
    end
  end

  def clean_test_data
    unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database.end_with?("_test")
      raise "Isolated test database required"
    end

    ActiveRecord::Base.connection.execute(<<~SQL)
      TRUNCATE TABLE audit_logs, audit_write_failures, organizations, users, organizer_profiles, events, site_settings,
        webhook_events, checkout_attempts
      RESTART IDENTITY CASCADE
    SQL
  end

  let(:gateway_calls) { Queue.new }
  let(:admin) { create(:user, :admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :completed, organization: organization, organizer_profile: profile) }
  let(:other_event) { create(:event, :completed, organization: organization, organizer_profile: profile) }

  before do
    clean_test_data
    allow(PayoutGateway).to receive(:submit) do |payout|
      gateway_calls << payout.id
      PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing)
    end
    allow(Sentry).to receive(:capture_message)
    allow(Sentry).to receive(:capture_exception)
    approved_bank_account!(organization, actor: profile.user, admin: admin)
  end

  after { clean_test_data }

  # A fulfilled sale on `target` (its fulfilling payment recorded) and a
  # finalized statement.
  def fulfilled_sale(target)
    order, _item, a = record_card_sale!(target, ticket_type: create(:ticket_type, event: target, price_cents: 2000),
      quantity: 5, processing_fee_cents: 100)
    order.update!(fulfilled_by_payment_id: a.id)
    order
  end

  # Each payout from a statement finalized just before it (a payout changes
  # the event's financial activity).
  def current_settlement(target)
    Settlements::Finalizer.call(event: target, actor: admin)
  end

  def reserve!(target, key, amount_cents: 2000)
    PayoutCreator.new(settlement: current_settlement(target), actor: admin, idempotency_key: key, amount_cents: amount_cents)
      .send(:reserve!).first
  end

  def submitted!(target, key)
    PayoutCreator.call(settlement: current_settlement(target), actor: admin, idempotency_key: key, amount_cents: 2000).tap do |payout|
      expect(payout).to be_status_processing
    end
  end

  def second_payment(order)
    create(:payment, order: order, amount_cents: order.total_cents, status: :pending)
  end

  def evidence(confirmed_at, **flags)
    { reference: "Bank transfer record", reason: "Transfer confirmed by the bank", confirmed_at: confirmed_at.iso8601(6),
      approved_tax_payee_confirmed: true }.merge(flags)
  end

  def gateway_ids
    Array.new(gateway_calls.size) { gateway_calls.pop }
  end

  # Runs `work` on its own connection; returns [thread, pid queue, result queue].
  def worker(&work)
    pid = Queue.new
    result = Queue.new
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true) do |connection|
        connection.execute("SET lock_timeout = '15s'")
        pid << connection.select_value("SELECT pg_backend_pid()")
        begin
          result << work.call
        ensure
          connection.execute("RESET lock_timeout")
        end
      end
    rescue StandardError => error
      result << error
    end
    [thread, pid.pop(timeout: DEADLINE) || raise("worker never started"), result]
  end

  def blocked?(pid)
    ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{pid.to_i}))").to_i.positive?
  end

  def wait_until_blocked(pid)
    Timeout.timeout(DEADLINE) { sleep 0.02 until blocked?(pid) }
  end

  def outcome(thread, result)
    thread.join(DEADLINE) || raise("worker never finished")
    result.pop(timeout: 1)
  end

  # 7bcd97c2's old-first capture of B on a completed sale with no waitlist
  # offer (OrderLifecycle#complete_with_audit!): event context, order and
  # payment locks, then B captured and the transaction left open at `pause`.
  def legacy_capture(order_id, payment_id, pause)
    Order.transaction do
      order = Order.find(order_id)
      Passes::Locking.lock_events_for_order!(order)
      order.lock!
      payment = Payment.find(payment_id).lock!
      payment.update!(status: :succeeded, succeeded_at: Time.current)
      pause&.hit!(payment.reload.capture_recorded_at)
    end
    :captured
  end

  # This release's lifecycle classifying B from its receipt, left open after
  # it inserted B's exception and classification.
  def current_capture(order_id, payment_id, receipt_id, pause)
    Order.transaction do
      payment = Payment.find(payment_id)
      Commerce::OrderLifecycle.complete!(Order.find(order_id), payment: payment, webhook_event: WebhookEvent.find(receipt_id),
        provider_amount_cents: payment.amount_cents, provider_currency: "usd")
      pause.hit!(Payment.find(payment_id).capture_recorded_at)
    end
    :captured
  end

  def receipt_for(payment)
    WebhookEvent.create!(provider: "stripe", provider_event_id: "evt_ser_#{payment.id}", event_type: "payment_intent.succeeded",
      provider_created_at: 1.second.ago, status: :processing, attempts: 1,
      payload: { "id" => "evt_ser_#{payment.id}", "type" => "payment_intent.succeeded", "livemode" => false,
        "data" => { "object" => { "id" => payment.provider_payment_id, "amount_received" => payment.amount_cents,
          "currency" => "usd", "status" => "succeeded" } } })
  end

  def legacy_submit(payout_id)
    payout = Payout.find(payout_id)
    Legacy7bcd97c2.payout_creator.new(settlement: payout.settlement, actor: User.find(admin.id),
      idempotency_key: payout.idempotency_key).send(:submit_payout!, payout)
  end

  def current_submit(payout_id)
    payout = Payout.find(payout_id)
    PayoutCreator.new(settlement: payout.settlement, actor: User.find(admin.id), idempotency_key: payout.idempotency_key)
      .send(:submit_payout!, payout)
  end

  def record_paid(reconciler, payout_id, confirmed_at, reference)
    reconciler.call(payout: Payout.find(payout_id), actor: User.find(admin.id), status: "paid", provider_payout_id: reference,
      evidence: evidence(confirmed_at, sent_before_hold_confirmed: true))
  end

  describe "capture first" do
    it "makes this release's submission wait for an old-first capture, then refuses it; the old submission is refused at once" do
      order = fulfilled_sale(event)
      fulfilled_sale(other_event)
      pending = reserve!(event, "ser-pending")
      other_pending = reserve!(other_event, "ser-other")
      other_sent = reserve!(other_event, "ser-other-new", amount_cents: 1000)
      b = second_payment(order)
      expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(false)

      pause = Pause.new
      capture, = worker { legacy_capture(order.id, b.id, pause) }
      captured_at = pause.reached
      # Before the capture commits, nothing outside its transaction sees B.
      expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(false)

      # 7bcd97c2's submission holds the organization and the payout; the
      # fence takes the event NOWAIT and refuses.
      expect { legacy_submit(pending.id) }
        .to raise_error(ActiveRecord::LockWaitTimeout, /Repayment fence: event #{event.id} has a sale or capture in progress/)
      # The capture does not hold an unrelated event's payouts, in either
      # release (the organization lock still orders payout writers).
      expect(legacy_submit(other_pending.id)).to be_a(PayoutGateway::Result)
      expect(current_submit(other_sent.id)).to be_a(PayoutGateway::Result)
      expect(gateway_ids).to eq([other_pending.id, other_sent.id])
      # This release's submission waits on the event row.
      submit, submit_pid, submit_result = worker { current_submit(pending.id) }
      wait_until_blocked(submit_pid)

      pause.release!
      expect(outcome(capture, Queue.new.tap { |queue| queue << :captured })).to eq(:captured)
      refused = outcome(submit, submit_result)
      expect(refused).to be_a(PayoutCreator::PayoutError)
      expect(refused.message).to eq(Commerce::NeverFulfilledPayoutHold::MESSAGE)
      expect(gateway_ids).to be_empty
      expect(AuditLog.where(auditable: pending, action: "payout.submission_requested")).to be_empty
      expect(pending.reload).to be_status_pending
      expect(Commerce::NeverFulfilledPayoutHold.block_started_at(event)).to be_within(0.001).of(captured_at)
      # After the commit the old writer gets the event and the fence refuses.
      expect { legacy_submit(pending.id) }.to raise_error(ActiveRecord::StatementInvalid, /buyer repayment/)
      expect(gateway_ids).to be_empty
    end

    it "makes this release's paid recording wait and read the capture: a gap transfer is refused, a pre-hold one recorded" do
      order = fulfilled_sale(event)
      gap = submitted!(event, "ser-gap")
      pre = submitted!(event, "ser-pre")
      sleep 0.02
      pre_hold = Time.current
      sleep 0.02
      b = second_payment(order)

      pause = Pause.new
      capture, = worker { legacy_capture(order.id, b.id, pause) }
      captured_at = pause.reached
      sleep 0.02
      during_gap = Time.current
      expect(during_gap).to be > captured_at

      # 7bcd97c2's paid writer: refused at once while the capture is open.
      expect { record_paid(Legacy7bcd97c2.payout_reconciler, gap.id, during_gap, "bank-ser-old") }
        .to raise_error(ActiveRecord::LockWaitTimeout, /in progress/)
      # This release: both wait for the event, then see B. Without the event
      # lock its snapshot would miss B and record the gap transfer as paid.
      refused, refused_pid, refused_result = worker { record_paid(PayoutReconciler, gap.id, during_gap, "bank-ser-gap") }
      wait_until_blocked(refused_pid)
      pause.release!
      capture.join(DEADLINE)
      error = outcome(refused, refused_result)
      expect(error).to be_a(PayoutReconciler::ReconciliationError)
      expect(error.message).to eq(Commerce::NeverFulfilledPayoutHold::PAID_MESSAGE)
      expect(gap.reload).to be_status_processing

      recorded = record_paid(PayoutReconciler, pre.id, pre_hold, "bank-ser-pre")
      expect(recorded.reload).to have_attributes(status: "paid", provider_payout_id: "bank-ser-pre")
      audit = AuditLog.where(auditable: pre, action: "payout.reconciled").sole
      expect(Time.iso8601(audit.metadata.fetch("never_fulfilled_hold_started_at"))).to be_within(0.001).of(captured_at)
    end

    it "waits for a capture this release is classifying and reads the hold it inserted" do
      order = fulfilled_sale(event)
      pending = reserve!(event, "ser-classify")
      in_flight = submitted!(event, "ser-classify-sent")
      b = second_payment(order)
      receipt = receipt_for(b)

      pause = Pause.new
      capture, = worker { current_capture(order.id, b.id, receipt.id, pause) }
      captured_at = pause.reached
      during_gap = Time.current

      submit, submit_pid, submit_result = worker { current_submit(pending.id) }
      paid, paid_pid, paid_result = worker { record_paid(PayoutReconciler, in_flight.id, during_gap, "bank-ser-cls") }
      wait_until_blocked(submit_pid)
      wait_until_blocked(paid_pid)
      pause.release!
      capture.join(DEADLINE)

      expect(outcome(submit, submit_result)).to be_a(PayoutCreator::PayoutError)
      expect(outcome(paid, paid_result)).to be_a(PayoutReconciler::ReconciliationError)
      expect(gateway_ids).to eq([in_flight.id])
      expect([pending.reload.status, in_flight.reload.status]).to eq(%w[pending processing])
      expect(Commerce::NeverFulfilledPayoutHold.block_started_at(event)).to be_within(0.001).of(captured_at)
      issue = ReconciliationException.find_by!(payment: b, code: "unfulfilled_second_capture")
      expect(issue.hold_started_at).to be_within(0.001).of(captured_at)
    end
  end

  describe "payout first" do
    it "makes a capture wait for this release's submission, whose outcome is then recorded as a pre-hold request" do
      order = fulfilled_sale(event)
      pending = reserve!(event, "ser-first")
      b = second_payment(order)
      pause = Pause.new
      allow(PayoutWithholdingGuard).to receive(:call).and_wrap_original do |original, **kwargs|
        value = original.call(**kwargs)
        pause.hit! if Thread.current[:pause_submission]
        value
      end

      submit, _pid, submit_result = worker do
        Thread.current[:pause_submission] = true
        result = current_submit(pending.id)
        Thread.current[:pause_submission] = false
        result
      end
      pause.reached
      capture, capture_pid, capture_result = worker { legacy_capture(order.id, b.id, nil) }
      wait_until_blocked(capture_pid)
      pause.release!

      expect(outcome(submit, submit_result)).to be_a(PayoutGateway::Result)
      expect(outcome(capture, capture_result)).to eq(:captured)
      submission = AuditLog.find_by!(auditable: pending, action: "payout.submission_requested")
      expect(b.reload.capture_recorded_at).to be > submission.occurred_at
      # The gateway outcome of that request is recorded on the now-held event.
      PayoutCreator.new(settlement: pending.settlement, actor: admin, idempotency_key: "ser-first")
        .send(:record_submission_outcome!, pending, provider_payout_id: "manual_po_#{pending.id}", status: :processing,
          initiated_at: Time.current)
      expect(pending.reload).to be_status_processing
      expect(Commerce::NeverFulfilledPayoutHold.block_started_at(event)).to be_within(0.001).of(b.capture_recorded_at)
    end

    { "submission" => "payout.submission_requested", "paid recording" => "payout.reconciled" }.each do |name, action|
      it "makes a capture wait for 7bcd97c2's #{name}, which holds the event through the fence" do
        order = fulfilled_sale(event)
        payout = name == "submission" ? reserve!(event, "ser-old-first") : submitted!(event, "ser-old-sent")
        gateway_ids
        b = second_payment(order)
        pause = Pause.new
        allow(AuditLogger).to receive(:record!).and_wrap_original do |original, **kwargs|
          value = original.call(**kwargs)
          pause.hit! if Thread.current[:pause_audit] == kwargs[:action]
          value
        end

        writer, _pid, writer_result = worker do
          Thread.current[:pause_audit] = action
          value = if name == "submission"
            legacy_submit(payout.id)
          else
            record_paid(Legacy7bcd97c2.payout_reconciler, payout.id, Time.current, "bank-old-first")
          end
          Thread.current[:pause_audit] = nil
          value
        end
        pause.reached
        capture, capture_pid, capture_result = worker { legacy_capture(order.id, b.id, nil) }
        wait_until_blocked(capture_pid)
        pause.release!

        expect(outcome(writer, writer_result)).to be_a(name == "submission" ? PayoutGateway::Result : Payout)
        expect(outcome(capture, capture_result)).to eq(:captured)
        written = AuditLog.where(auditable: payout, action: action).sole
        expect(b.reload.capture_recorded_at).to be > written.occurred_at
        expect(name == "submission" ? gateway_ids : payout.reload.status).to eq(name == "submission" ? [payout.id] : "paid")
        expect(Commerce::NeverFulfilledPayoutHold.block_started_at(event)).to be_within(0.001).of(b.capture_recorded_at)
      end
    end
  end
end
