# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# The A2 finance projection of classified payments
# (docs/design/never-fulfilled-captures.md §5.3, §8.4, §8.5, §8.10).
RSpec.describe Commerce::ClassifiedPaymentFinance do
  before do
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(StripeService).to receive(:verify_payment_context!)
    allow(Sentry).to receive(:capture_message)
  end

  let(:guam) { ActiveSupport::TimeZone["Pacific/Guam"] }
  let(:event) { create(:event) }

  def at(*parts) = guam.local(*parts)
  def month(year, number) = at(year, number, 1)...at(year, number, 1).next_month
  def project(range) = described_class.new(range)

  # An order-scope classified live capture. items: [[proceeds, fee, organizer_fee, tax], ...].
  def live_capture(items:, policy: "item_record", bearer: "platform", environment: "live", target: event)
    total = items.flatten.sum
    order = create(:order, event: target, status: :expired, completed_at: nil, subtotal_cents: total,
      service_fee_cents: 0, total_cents: total)
    items.each do |proceeds, fee, organizer_fee, tax|
      create(:order_item, order: order, unit_price_cents: proceeds + organizer_fee, quantity: 1,
        subtotal_cents: proceeds + organizer_fee, organizer_proceeds_cents: proceeds, fee_cents: fee,
        organizer_fee_cents: organizer_fee, tax_cents: tax)
    end
    payment = create(:payment, order: order, provider_environment: environment,
      provider_payment_id: "pi_#{environment}_#{SecureRandom.hex(4)}", amount_cents: total, status: :succeeded,
      succeeded_at: Time.current)
    capture = UnfulfilledCapture.create!(order: order, payment: payment, capture_scope: "order",
      code: "late_payment_success_after_hold_expiry", captured_cents: total, currency: "usd",
      proceeds_cents: items.sum { |row| row[0] }, fee_cents: items.sum { |row| row[1] },
      organizer_fee_cents: items.sum { |row| row[2] }, tax_cents: items.sum { |row| row[3] },
      processing_bearer: bearer, dispute_fee_bearer: "platform", allocation_policy: policy,
      policy_version: Commerce::NeverFulfilledClassification::POLICY_VERSION, provenance: "lifecycle").reload
    [order, payment, capture]
  end

  # Moves a capture's recording time, as a capture recorded at that moment
  # would hold it (both the payment and its classification row).
  def captured_at!(capture, time)
    stamp!(capture.payment, :capture_recorded_at, time, trigger: "payments_capture_recorded_at")
    connection = ActiveRecord::Base.connection
    connection.execute("ALTER TABLE never_fulfilled_captures DISABLE TRIGGER never_fulfilled_captures_append_only")
    UnfulfilledCapture.where(id: capture.id).update_all(capture_recorded_at: time)
  ensure
    connection.execute("ALTER TABLE never_fulfilled_captures ENABLE TRIGGER never_fulfilled_captures_append_only")
  end

  # A provider refund recorded at `time`, posted through the real writer.
  def refund_at!(payment, amount, time)
    id = "re_cpf_#{SecureRandom.hex(4)}"
    refund = payment.refunds.create!(order: payment.order, provider: "stripe", provider_refund_id: id,
      idempotency_key: "provider:stripe:refund:#{id}", amount_cents: amount, currency: "usd", status: :succeeded)
    stamp!(refund, :success_recorded_at, time, trigger: "refunds_success_recorded_at")
    Order.transaction { Commerce::BuyerReturnPostings.record_refund!(refund.reload) }
  end

  # Actual processing recorded the way StripeProcessingFees records it: a
  # component plus the evidence row that names its exact payment.
  def verified_processing!(payment, amount)
    reference = "txn_cpf_#{SecureRandom.hex(4)}"
    component = create(:fee_component, order: payment.order, kind: "processing", estimated: false, amount_cents: amount,
      currency: "usd", provider_reference: reference)
    StripeFeeEvidence.create!(payment: payment, fee_component: component, context_digest: "ctx_#{reference}",
      status: :verified, provider_charge_id: "ch_#{reference}", provider_balance_transaction_id: reference,
      evidence_digest: "digest_#{reference}", currency: "usd", fee_cents: amount, verified_at: Time.current)
    component
  end

  def flows(totals)
    { owed: totals.owed.to_a + [totals.owed.closing] }.merge(
      totals.shares.transform_values { |flow| flow.to_a + [flow.closing] }.reject { |_share, values| values.all?(&:zero?) }
    )
  end

  describe "Guam month boundaries" do
    it "books a capture at 23:59:59 and returns either side of midnight in their own half-open months" do
      _order, payment, capture = live_capture(items: [[1200, 160, 0, 0]])
      captured_at!(capture, at(2027, 2, 28, 23, 59, 59))
      refund_at!(payment.reload, 500, at(2027, 2, 28, 23, 59, 59) + 0.5)
      refund_at!(payment, 860, at(2027, 3, 1))

      feb = project(month(2027, 2)).for_event(event.id)
      mar = project(month(2027, 3)).for_event(event.id)
      feb_postings, mar_postings = capture.buyer_return_postings.in_sequence.partition { |p| p.recognized_at < at(2027, 3, 1) }
      expect([feb_postings.sum(&:gross_cents), mar_postings.sum(&:gross_cents)]).to eq([500, 860])

      feb_fee = feb_postings.sum(&:fee_cents)
      expect(flows(feb)).to eq(owed: [0, 1360, 500, 860], ticket_proceeds: [0, 1200, 500 - feb_fee, 700 + feb_fee],
        fee: [0, 160, feb_fee, 160 - feb_fee])
      expect(flows(mar)).to eq(owed: [860, 0, 860, 0], ticket_proceeds: [700 + feb_fee, 0, 700 + feb_fee, 0],
        fee: [160 - feb_fee, 0, 160 - feb_fee, 0])
      expect([feb.bridge_difference_cents, mar.bridge_difference_cents]).to eq([0, 0])
      expect(project(month(2027, 4)).by_event).to be_empty
      expect(project(month(2027, 1)).by_event).to be_empty
    end

    it "recognizes a return recorded before its capture at the capture's time (max of recorded and capture)" do
      _order, payment, capture = live_capture(items: [[1200, 160, 0, 0]])
      refund = payment.refunds.create!(order: payment.order, provider: "stripe", provider_refund_id: "re_cpf_pre",
        idempotency_key: "provider:stripe:refund:re_cpf_pre", amount_cents: 1360, currency: "usd", status: :succeeded)
      stamp!(refund, :success_recorded_at, at(2027, 2, 28, 23, 59, 50), trigger: "refunds_success_recorded_at")
      captured_at!(capture, at(2027, 3, 1, 0, 0, 10))
      Order.transaction { Commerce::BuyerReturnPostings.record_refund!(refund.reload) }

      expect(project(month(2027, 2)).by_event).to be_empty
      expect(flows(project(month(2027, 3)).for_event(event.id))).to include(owed: [0, 1360, 1360, 0])
    end
  end

  describe "gross, shares and the bridge" do
    it "splits partial and full returns into ticket proceeds, fee, organizer fee and tax, and the bridge holds" do
      _order, payment, capture = live_capture(items: [[1000, 100, 50, 30]])
      ingest_provider_refund!(payment, 590)
      current = month(Time.current.in_time_zone(guam).year, Time.current.in_time_zone(guam).month)

      partial = project(current).for_event(event.id)
      returned = capture.buyer_return_postings.sole.components
      expect(partial.owed.to_a).to eq([0, 1180, 590])
      expect(partial.shares.values_at(:ticket_proceeds, :fee, :organizer_fee, :tax).map(&:added)).to eq([1000, 100, 50, 30])
      expect(partial.shares.values_at(:ticket_proceeds, :fee, :organizer_fee, :tax).map(&:returned)).to eq(returned)
      expect(partial.fee_share_flow.added).to eq(150)
      expect(partial.bridge_difference_cents).to eq(0)

      ingest_provider_refund!(payment, 590)
      full = project(current).for_event(event.id)
      expect(full.owed.closing).to eq(0)
      expect(full.shares.values.map(&:closing)).to all(eq(0))
      expect([full.returned_gross_cents, full.excess_cents, full.bridge_difference_cents]).to eq([1180, 0, 0])
    end

    it "keeps money returned beyond what was owed as platform excess, at gross" do
      _order, payment, _capture = live_capture(items: [[1200, 160, 0, 0]])
      lose_dispute!(payment, "dp_cpf_excess")
      ingest_provider_refund!(payment, 500)
      now = Time.current.in_time_zone(guam)
      totals = project(month(now.year, now.month)).for_event(event.id)

      expect(totals.owed.to_a + [totals.owed.closing]).to eq([0, 1360, 1360, 0])
      expect([totals.returned_gross_cents, totals.excess_cents, totals.excess_cumulative_cents]).to eq([1860, 500, 500])
      # Like the CPA export's cumulative overpaid note, the excess stays visible
      # in later months while nothing else moves.
      later = project(now.next_month.beginning_of_month...now.next_month.next_month.beginning_of_month).for_event(event.id)
      expect(flows(later)).to eq(owed: [0, 0, 0, 0])
      expect([later.excess_cents, later.excess_cumulative_cents]).to eq([0, 500])
    end

    it "reproduces the 75-cent difference between the two allocation policies, with identical gross (§5.5)" do
      results = %w[item_record cumulative_pro_rata].to_h do |policy|
        _order, payment, = live_capture(items: [[1200, 160, 0, 0], [1200, 0, 0, 0]], policy: policy,
          target: create(:event))
        ingest_provider_refund!(payment, 1360)
        now = Time.current.in_time_zone(guam)
        first = project(month(now.year, now.month)).for_event(payment.order.event_id)
        ingest_provider_refund!(payment, 1200)
        both = project(month(now.year, now.month)).for_event(payment.order.event_id)
        [policy, [first.owed.closing, first.shares[:fee].returned, both.shares[:fee].returned - first.shares[:fee].returned,
          both.shares[:ticket_proceeds].returned]]
      end

      expect(results).to eq("item_record" => [1200, 160, 0, 2400], "cumulative_pro_rata" => [1200, 85, 75, 2400])
    end
  end

  describe "late wins" do
    it "books the reversal as a signed delta in its own period and leaves the loss period unchanged" do
      _order, payment, capture = live_capture(items: [[4, 0, 0, 0], [2, 4, 0, 0]])
      ingest_provider_refund!(payment, 4)
      lose_dispute!(payment, "dp_cpf_late", amount: 6)
      win_late!(payment, "dp_cpf_late", amount: 6)
      reversal = capture.buyer_return_postings.find_by!(kind: "dispute_loss_reversal")
      split = reversal.recognized_at
      before = project((split - 1.hour)...split).for_event(event.id)
      after = project(split...(split + 1.hour)).for_event(event.id)

      expect(flows(before)).to eq(owed: [0, 10, 10, 0], ticket_proceeds: [0, 6, 6, 0], fee: [0, 4, 4, 0])
      # Only the 4c refund (4, 0) survives, so (2, 4) is owed again.
      expect(flows(after)).to eq(owed: [0, 0, -6, 6], ticket_proceeds: [0, 0, -2, 2], fee: [0, 0, -4, 4])
      expect([after.returned_gross_cents, after.excess_cents, after.bridge_difference_cents]).to eq([-6, 0, 0])
    end
  end

  describe "the fulfilled sale and its second capture" do
    it "projects only payment B's principal and leaves A's sale, fees and processing out" do
      order = create(:order, :pending, event: event, subtotal_cents: 1200, service_fee_cents: 160, total_cents: 1360)
      create(:order_item, order: order, unit_price_cents: 1200, subtotal_cents: 1200, organizer_proceeds_cents: 1200, fee_cents: 160)
      payment_a = create(:payment, order: order, provider_environment: "live", provider_payment_id: "pi_live_cpf_a",
        status: :succeeded, succeeded_at: Time.current)
      order.update!(status: :completed, completed_at: Time.current, fulfilled_by_payment_id: payment_a.id)
      verified_processing!(payment_a, 69)
      payment_b = create(:payment, order: order, provider_environment: "live", provider_payment_id: "pi_live_cpf_b",
        amount_cents: 1500, status: :succeeded, succeeded_at: Time.current)
      UnfulfilledCapture.create!(order: order, payment: payment_b, capture_scope: "payment",
        code: "unfulfilled_second_capture", captured_cents: 1500, currency: "usd", proceeds_cents: 1500, fee_cents: 0,
        organizer_fee_cents: 0, tax_cents: 0, processing_bearer: "platform", dispute_fee_bearer: "platform",
        allocation_policy: "item_record", policy_version: "nfc-v2.1", provenance: "lifecycle")
      StripeFeeEvidence.create!(payment: payment_b, context_digest: "ctx_b", status: :review_required, fee_cents: 74,
        evidence_digest: "digest_b", last_error_code: StripeProcessingFees::PAYMENT_SCOPE_DEFERRED_CODE)
      ingest_provider_refund!(payment_b, 700)
      lose_dispute!(payment_b, "dp_cpf_b", amount: 1500)
      now = Time.current.in_time_zone(guam)
      projection = project(month(now.year, now.month))
      totals = projection.for_event(event.id)

      expect(flows(totals)).to eq(owed: [0, 1500, 1500, 0], second_capture_principal: [0, 1500, 1500, 0])
      expect([totals.excess_cents, totals.processing_platform_cents, totals.processing_organizer_cents]).to eq([700, 0, 0])
      expect(projection.alerts).to eq([{ code: "processing_deferred", event_id: event.id, payment_id: payment_b.id,
        processing_bearer: "platform", amount_cents: 74 }])
      expect(order.reload).to have_attributes(status: "completed", refund_amount_cents: 0)
    end
  end

  describe "provider costs" do
    it "attributes actual processing by verified evidence or a sole capture, by the snapshot bearer, and alerts the rest" do
      _order_a, payment_a, _capture_a = live_capture(items: [[1200, 160, 0, 0]])
      verified_processing!(payment_a, 69)
      _order_b, _payment_b, capture_b = live_capture(items: [[1200, 160, 0, 0]], bearer: "organizer")
      create(:fee_component, order: capture_b.order, kind: "processing", estimated: false, amount_cents: 70)
      create(:fee_component, order: capture_b.order, kind: "processing", estimated: true, amount_cents: 99)
      order_c, _payment_c, _capture_c = live_capture(items: [[1200, 160, 0, 0]])
      create(:payment, order: order_c, provider_environment: "test", amount_cents: 1360, status: :succeeded,
        succeeded_at: Time.current)
      unattributed = create(:fee_component, order: order_c, kind: "processing", estimated: false, amount_cents: 71)
      now = Time.current.in_time_zone(guam)
      projection = project(month(now.year, now.month))
      totals = projection.for_event(event.id)

      expect([totals.processing_platform_cents, totals.processing_organizer_cents]).to eq([69, 70])
      expect(projection.alerts).to eq([{ code: "processing_unattributed", event_id: event.id, payment_id: nil,
        order_id: order_c.id, fee_component_id: unattributed.id, amount_cents: 71 }])
      expect(project(month(now.prev_month.year, now.prev_month.month)).by_event).to be_empty
    end
  end

  describe "pre-cutover history and ambiguity" do
    it "projects a backfilled pre-A1 capture at its frozen recording time" do
      ActiveRecord::Base.connection.execute(
        "INSERT INTO financial_cutovers (key) VALUES ('a1_capture_recording') ON CONFLICT (key) DO NOTHING"
      )
      order = create(:order, event: event, status: :expired, completed_at: nil, subtotal_cents: 1200,
        service_fee_cents: 160, total_cents: 1360)
      create(:order_item, order: order, unit_price_cents: 1200, subtotal_cents: 1200, organizer_proceeds_cents: 1200, fee_cents: 160)
      connection = ActiveRecord::Base.connection
      connection.execute("SET LOCAL session_replication_role = replica")
      payment = create(:payment, order: order, provider_environment: "live", provider_payment_id: "pi_live_cpf_legacy",
        amount_cents: 1360, status: :succeeded, succeeded_at: at(2026, 9, 1))
      connection.execute("SET LOCAL session_replication_role = DEFAULT")
      expect(payment.reload.capture_recorded_at).to be_nil
      UnfulfilledCapture.create!(order: order, payment: payment, capture_scope: "order",
        code: "late_payment_success_after_hold_expiry", captured_cents: 1360, currency: "usd", proceeds_cents: 1200,
        fee_cents: 160, organizer_fee_cents: 0, tax_cents: 0, processing_bearer: "platform", dispute_fee_bearer: "platform",
        allocation_policy: "item_record", policy_version: "nfc-v2.1", provenance: "backfill",
        provenance_evidence: { "exception_id" => 1 }, capture_recorded_at: at(2026, 9, 30, 23, 59, 59))

      expect(flows(project(month(2026, 9)).for_event(event.id))).to include(owed: [0, 1360, 0, 1360])
      expect(flows(project(month(2026, 10)).for_event(event.id))).to include(owed: [1360, 0, 0, 1360])
    end

    it "lists unclassified late captures and open ambiguity holds instead of projecting them" do
      order = create(:order, event: event, status: :expired, completed_at: nil, subtotal_cents: 1200,
        service_fee_cents: 160, total_cents: 1360)
      unclassified = create(:payment, order: order, provider_environment: "live", provider_payment_id: "pi_live_cpf_u",
        amount_cents: 1360, status: :succeeded, succeeded_at: Time.current)
      ReconciliationException.create!(order: order, payment: unclassified, code: "late_payment_success_after_hold_expiry")
      held = ReconciliationException.create!(order: order, payment: unclassified,
        code: Commerce::NeverFulfilledClassification::OWNERSHIP_AMBIGUOUS_CODE)
      test_order = create(:order, event: event, status: :expired, completed_at: nil, subtotal_cents: 500,
        service_fee_cents: 0, total_cents: 500)
      test_payment = create(:payment, order: test_order, amount_cents: 500, status: :succeeded, succeeded_at: Time.current)
      ReconciliationException.create!(order: test_order, payment: test_payment, code: "late_payment_success_after_hold_expiry")
      now = Time.current.in_time_zone(guam)
      projection = project(month(now.year, now.month))

      expect(projection.by_event).to be_empty
      expect(projection.alerts.map { |alert| alert.slice(:code, :payment_id, :event_id) }).to eq([
        { code: "never_fulfilled_ownership_ambiguous", payment_id: unclassified.id, event_id: event.id },
        { code: "unclassified_late_capture", payment_id: unclassified.id, event_id: event.id }
      ])
      expect(projection.alerts.first[:exception_id]).to eq(held.id)
    end

    it "leaves test-mode captures out of the live projection" do
      live_capture(items: [[1200, 160, 0, 0]], environment: "test")
      now = Time.current.in_time_zone(guam)

      expect(project(month(now.year, now.month)).by_event).to be_empty
      expect(described_class.new(month(now.year, now.month), payments: Payment.all).for_event(event.id).owed.added).to eq(1360)
    end
  end

  describe "first caller: the CPA monthly export's gross buyer columns (P3)" do
    it "appends gross owed, returned and overpaid after currency, rolling forward across Guam months" do
      _order, payment, capture = live_capture(items: [[1200, 160, 0, 0]])
      captured_at!(capture, at(2027, 2, 28, 23, 59, 59))
      refund_at!(payment.reload, 500, at(2027, 2, 28, 23, 59, 59) + 0.5)
      refund_at!(payment, 860, at(2027, 3, 1))
      refund_at!(payment, 100, at(2027, 3, 2))
      gross = CpaMonthlyReport::GROSS_BUYER_KEYS

      expect(CpaMonthlyReport::HEADER.last(11)).to eq(%w[currency opening_buyer_owed_gross buyer_owed_captures_gross
        buyer_owed_returned_gross closing_buyer_owed_gross buyer_overpaid_in_month_gross buyer_overpaid_cumulative_gross
        closing_buyer_owed_second_capture_principal closing_buyer_owed_fee_tax_share
        closing_buyer_refunds_owed_unclassified_legacy classified_allocation_policy])
      feb_fee = capture.buyer_return_postings.in_sequence.first.fee_cents
      feb = CpaMonthlyReport.new(2027, 2)
      mar = CpaMonthlyReport.new(2027, 3)
      feb_row = feb.report[:rows].find { |row| row[:event_id] == event.id }
      mar_row = mar.report[:rows].find { |row| row[:event_id] == event.id }
      expect(feb_row.values_at(*gross)).to eq([0, 1360, 500, 860, 0, 0, 0, 160 - feb_fee, 0])
      expect(mar_row.values_at(*gross)).to eq([860, 0, 860, 0, 100, 100, 0, 0, 0])
      expect(feb_row[:closing_buyer_refunds_owed_cents]).to eq(860 - (160 - feb_fee))
      expect(feb.report[:totals].values_at(*gross)).to eq(feb_row.values_at(*gross))
      expect(feb.csv_rows.to_a.first.last(11)).to eq(["USD", "0.00", "13.60", "5.00", "8.60", "0.00", "0.00", "0.00",
        FinanceExports.money(160 - feb_fee), "0.00", "item_record #{Commerce::NeverFulfilledClassification::POLICY_VERSION}"])
      expect(mar.report[:current_integrity_alerts]).to include(has_alerts: false, classified_payment_alerts: [])
    end
  end

  it "refuses an unbounded or closed-ended period" do
    expect { described_class.new(at(2027, 1, 1)..at(2027, 2, 1)) }.to raise_error(ArgumentError)
    expect { described_class.new(at(2027, 1, 1)..) }.to raise_error(ArgumentError)
  end
end
