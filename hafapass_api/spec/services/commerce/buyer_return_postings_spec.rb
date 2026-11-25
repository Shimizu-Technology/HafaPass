# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# Gross return postings through the real writers: RefundCreator finalization
# (inbound provider refunds via ExternalRefundRecovery), the Stripe dispute
# webhook, the late-win branch and classify! (docs/design/never-fulfilled-
# captures.md §5, A1 tranche 3; examples E2, E3, E4, E10, E11, L-09, L-10,
# L-17…L-23).
RSpec.describe Commerce::BuyerReturnPostings do
  before do
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(StripeService).to receive(:verify_payment_context!)
    allow(Sentry).to receive(:capture_message)
  end

  let(:guam) { ActiveSupport::TimeZone["Pacific/Guam"] }

  it "posts partial and full gross returns, 1 cent at a time, with no excess (E3)" do
    _order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]])
    ingest_provider_refund!(payment, 1)
    expect(ledger(capture).owed_cents).to eq(1359)
    loss = lose_dispute!(payment, "dp_e3", amount: 1359)

    expect(posting_rows(capture)).to eq([["refund", 1, 1, 0, [1, 0, 0, 0]], ["dispute_loss", 1359, 1359, 0, [1199, 160, 0, 0]]])
    expect(ledger(capture)).to have_attributes(owed_cents: 0, excess_cents: 0, remaining_components: [0, 0, 0, 0])
    posting = capture.buyer_return_postings.find_by!(kind: "dispute_loss")
    expect(posting).to have_attributes(source: loss, recorded_at: loss.reload.loss_recorded_at, recording_source: "database",
      policy_version: "nfc-v2.1", allocation_policy: "item_record", recognition_state: "recognized")
    expect(AuditLog.where(action: "buyer_return_posting.recorded").count).to eq(2)
  end

  it "applies only what is owed and keeps the rest as excess at gross (E2)" do
    _order, payment, capture = classified_capture(items: [[800, 107, 0, 0], [400, 53, 0, 0]])
    ingest_provider_refund!(payment, 470)
    lose_dispute!(payment, "dp_e2", amount: 891)

    expect(posting_rows(capture)).to eq([["refund", 470, 470, 0, [415, 55, 0, 0]],
      ["dispute_loss", 891, 890, 1, [785, 105, 0, 0]]])
    expect(capture.buyer_return_postings.first.allocation_method).to eq("refund_items")
    expect(ledger(capture)).to have_attributes(owed_cents: 0, excess_cents: 1, gross_returned_cents: 1361)
  end

  it "uses the refund's own items for the 75-cent partial return (E11)" do
    _order, payment, capture = classified_capture(items: [[1200, 160, 0, 0], [1200, 0, 0, 0]])
    first = ingest_provider_refund!(payment, 1360)
    ingest_provider_refund!(payment, 1200)

    expect(first.refund_items.pluck(:organizer_proceeds_cents, :fee_cents)).to eq([[1200, 160]])
    expect(posting_rows(capture)).to eq([["refund", 1360, 1360, 0, [1200, 160, 0, 0]], ["refund", 1200, 1200, 0, [1200, 0, 0, 0]]])
    expect(ledger(capture).owed_cents).to eq(0)
  end

  it "records money returned after the outbound balance is exhausted, as excess (E10)" do
    order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]])
    lose_dispute!(payment, "dp_e10")
    refund = ingest_provider_refund!(payment, 1360)
    again = ingest_provider_refund!(payment, 1360)

    expect([refund, again]).to all(be_succeeded)
    expect(posting_rows(capture)).to eq([["dispute_loss", 1360, 1360, 0, [1200, 160, 0, 0]],
      ["refund", 1360, 0, 1360, [0, 0, 0, 0]], ["refund", 1360, 0, 1360, [0, 0, 0, 0]]])
    expect(ledger(capture)).to have_attributes(owed_cents: 0, excess_cents: 2720)
    expect(order.reload.never_fulfilled_at).to be_present
    expect(ReconciliationException.where(code: "refund_operation_not_found")).to be_empty
  end

  it "posts a duplicate or redelivered provider receipt once" do
    _order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]])
    object = { id: "re_dup", object: "refund", payment_intent: payment.provider_payment_id, amount: 500, currency: "usd",
      status: "succeeded" }
    stripe_webhook!("refund.created", object, event_id: "evt_dup_refund")
    stripe_webhook!("refund.created", object, event_id: "evt_dup_refund")
    stripe_webhook!("refund.updated", object, event_id: "evt_dup_refund_updated")
    stripe_webhook!("charge.refunded", { id: "ch_dup", payment_intent: payment.provider_payment_id, amount_refunded: 500,
      refunds: { data: [object] } })
    lose_dispute!(payment, "dp_dup", amount: 860)
    stripe_webhook!("charge.dispute.closed", dispute_object(payment, "dp_dup", amount: 860, status: "lost"))

    expect(Refund.where(provider_refund_id: "re_dup").count).to eq(1)
    expect(posting_rows(capture).map(&:first)).to eq(%w[refund dispute_loss])
    expect(ledger(capture)).to have_attributes(owed_cents: 0, excess_cents: 0)
  end

  describe "recognition time" do
    it "recognizes a loss recorded before its capture at the capture's recording time, through classify! (E4, L-09)" do
      event = create(:event)
      order = create(:order, event: event, status: :expired, completed_at: nil, subtotal_cents: 1360, service_fee_cents: 0,
        total_cents: 1360)
      create(:order_item, order: order, unit_price_cents: 1200, subtotal_cents: 1200, organizer_proceeds_cents: 1200, fee_cents: 160)
      payment = create(:payment, order: order, provider_payment_id: "pi_e4", amount_cents: 1360, status: :pending)
      loss = lose_dispute!(payment, "dp_e4")
      stamp!(loss, :loss_recorded_at, guam.local(2026, 2, 28, 23, 59, 50).utc, trigger: "disputes_recorded_at")
      expect(UnfulfilledCapture.find_by(payment: payment)).to be_nil

      issue = ReconciliationException.create!(order: order, payment: payment, code: "late_payment_success_after_hold_expiry")
      payment.update!(status: :succeeded, succeeded_at: Time.current)
      stamp!(payment, :capture_recorded_at, guam.local(2026, 3, 1, 0, 0, 10).utc, trigger: "payments_capture_recorded_at")
      payment.reload
      capture = Order.transaction do
        order.lock!
        payment.lock!
        Commerce::NeverFulfilledClassification.classify!(order: order, payment: payment, code: issue.code, exception: issue,
          provider_evidence: { source: "provider_lookup", provider_object_id: "pi_e4", livemode: false,
            amount_cents: 1360, currency: "usd" }).capture
      end
      posting = capture.buyer_return_postings.sole
      expect(posting).to have_attributes(kind: "dispute_loss", applied_cents: 1360, recorded_at: loss.reload.loss_recorded_at)
      expect(posting.recognized_at).to eq(capture.capture_recorded_at)
      expect(posting.recognized_at.in_time_zone(guam)).to eq(guam.local(2026, 3, 1, 0, 0, 10))
      expect(posting.note).to match(/before its capture/)
      expect(ledger(capture).owed_cents).to eq(0)
    end

    it "recognizes a return and capture recorded on Feb 28 in February although posted in a later month (L-10)" do
      _order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]])
      connection = ActiveRecord::Base.connection
      capture_at = guam.local(2026, 2, 28, 23, 59, 51).utc
      connection.execute("ALTER TABLE never_fulfilled_captures DISABLE TRIGGER never_fulfilled_captures_append_only")
      UnfulfilledCapture.where(id: capture.id).update_all(capture_recorded_at: capture_at)
      connection.execute("ALTER TABLE never_fulfilled_captures ENABLE TRIGGER never_fulfilled_captures_append_only")
      refund = payment.refunds.create!(order: payment.order, provider: "stripe", provider_refund_id: "re_l10",
        idempotency_key: "provider:stripe:refund:re_l10", amount_cents: 1360, currency: "usd", status: :succeeded)
      stamp!(refund, :success_recorded_at, guam.local(2026, 2, 28, 23, 59, 58).utc, trigger: "refunds_success_recorded_at")

      posting = Order.transaction { described_class.record_refund!(refund.reload) }
      # No posting-month floor: GREATEST(return, capture), both on Feb 28 ChST.
      expect(posting.recognized_at.in_time_zone(guam)).to eq(guam.local(2026, 2, 28, 23, 59, 58))
      expect(posting.posted_at).to be >= guam.local(2026, 3, 1)
    end

    it "recognizes a return recorded after a month-end capture in the return's month (the other delivery order)" do
      _order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]])
      connection = ActiveRecord::Base.connection
      connection.execute("ALTER TABLE never_fulfilled_captures DISABLE TRIGGER never_fulfilled_captures_append_only")
      UnfulfilledCapture.where(id: capture.id).update_all(capture_recorded_at: guam.local(2026, 2, 28, 23, 59, 59).utc)
      connection.execute("ALTER TABLE never_fulfilled_captures ENABLE TRIGGER never_fulfilled_captures_append_only")
      refund = payment.refunds.create!(order: payment.order, provider: "stripe", provider_refund_id: "re_e8",
        idempotency_key: "provider:stripe:refund:re_e8", amount_cents: 1360, currency: "usd", status: :succeeded)
      stamp!(refund, :success_recorded_at, guam.local(2026, 3, 1, 0, 5).utc, trigger: "refunds_success_recorded_at")

      posting = Order.transaction { described_class.record_refund!(refund.reload) }
      expect(posting.recognized_at.in_time_zone(guam)).to eq(guam.local(2026, 3, 1, 0, 5))
      expect(posting.note).to be_nil
    end
  end

  describe "late wins" do
    it "reverses only the loss and leaves the surviving refund's own split (L-18)" do
      _order, payment, capture = classified_capture(items: [[4, 0, 0, 0], [2, 4, 0, 0]])
      ingest_provider_refund!(payment, 4)
      loss = lose_dispute!(payment, "dp_late", amount: 6)
      closed_at = loss.closed_at
      expect(posting_rows(capture)).to eq([["refund", 4, 4, 0, [4, 0, 0, 0]], ["dispute_loss", 6, 6, 0, [2, 4, 0, 0]]])

      win_late!(payment, "dp_late", amount: 6)
      win_late!(payment, "dp_late", amount: 6, type: "charge.dispute.updated")
      stripe_webhook!("charge.dispute.closed", dispute_object(payment, "dp_late", amount: 6, status: "lost"))

      expect(loss.reload).to have_attributes(status: "lost", closed_at: closed_at)
      expect(loss.loss_reversed_at).to be_present
      reversal = capture.buyer_return_postings.find_by!(kind: "dispute_loss_reversal")
      expect(reversal).to have_attributes(sequence: 3, gross_cents: -6, applied_cents: -6, excess_cents: 0,
        components: [-2, -4, 0, 0], reverses_posting: capture.buyer_return_postings.find_by!(kind: "dispute_loss"),
        allocation_method: "recomputed", recorded_at: loss.loss_reversed_at)
      expect(ledger(capture)).to have_attributes(owed_cents: 6, returned_components: [4, 0, 0, 0])
      expect(AuditLog.where(auditable: loss, action: "dispute.loss_reversed").count).to eq(1)
    end

    it "promotes money previously booked as excess when the loss it lost to is reversed" do
      _order, payment, capture = classified_capture(items: [[4, 0, 0, 0], [2, 4, 0, 0]])
      lose_dispute!(payment, "dp_promote", amount: 10)
      ingest_provider_refund!(payment, 4)
      expect(posting_rows(capture)).to eq([["dispute_loss", 10, 10, 0, [6, 4, 0, 0]], ["refund", 4, 0, 4, [0, 0, 0, 0]]])

      win_late!(payment, "dp_promote", amount: 10)
      expect(posting_rows(capture).last).to eq(["dispute_loss_reversal", -10, -6, -4, [-2, -4, 0, 0]])
      expect(ledger(capture)).to have_attributes(owed_cents: 6, excess_cents: 0, applied_cents: 4,
        returned_components: [4, 0, 0, 0])
    end

    it "keeps a loss notice that arrives after the win as evidence, without posting or rewriting the status" do
      _order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]])
      stripe_webhook!("charge.dispute.created", dispute_object(payment, "dp_reordered"))
      won = win_late!(payment, "dp_reordered")
      stripe_webhook!("charge.dispute.closed", dispute_object(payment, "dp_reordered", status: "lost"),
        event_id: "evt_stale_loss")

      expect(won.reload).to have_attributes(status: "won", loss_recorded_at: nil, loss_reversed_at: nil)
      expect(capture.buyer_return_postings).to be_empty
      expect(ledger(capture).owed_cents).to eq(1360)
      expect(AuditLog.where(auditable: won, action: "dispute.loss_receipt_after_win").count).to eq(1)
    end

    it "posts a loss and its reversal recorded before classification in the frozen order" do
      event = create(:event)
      order = create(:order, event: event, status: :expired, completed_at: nil, subtotal_cents: 1360, service_fee_cents: 0,
        total_cents: 1360)
      create(:order_item, order: order, unit_price_cents: 1200, subtotal_cents: 1200, organizer_proceeds_cents: 1200, fee_cents: 160)
      payment = create(:payment, order: order, provider_payment_id: "pi_prewin", amount_cents: 1360, status: :succeeded,
        succeeded_at: Time.current)
      lose_dispute!(payment, "dp_prewin")
      win_late!(payment, "dp_prewin")
      expect(ReconciliationException.where(payment: payment, code: "dispute_late_win").count).to eq(1)

      capture = classify_order_scope!(order, payment)
      Order.transaction { described_class.record_recorded_movements!(capture) }
      expect(posting_rows(capture)).to eq([["dispute_loss", 1360, 1360, 0, [1200, 160, 0, 0]],
        ["dispute_loss_reversal", -1360, -1360, 0, [-1200, -160, 0, 0]]])
      expect(ledger(capture).owed_cents).to eq(1360)
    end
  end

  it "quarantines a movement it cannot post from positive evidence instead of guessing" do
    _order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]])
    refund = payment.refunds.create!(order: payment.order, provider: "stripe", provider_refund_id: "re_legacy",
      idempotency_key: "provider:stripe:refund:re_legacy", amount_cents: 200, currency: "usd", status: :succeeded)
    stamp!(refund, :success_recorded_at, nil, trigger: "refunds_success_recorded_at")

    expect(Order.transaction { described_class.record_refund!(refund.reload) }).to be_nil
    issue = ReconciliationException.find_by!(payment: payment, code: described_class::QUARANTINE_CODE)
    expect(issue.details).to include("reason" => "recording_time_unknown", "source_id" => refund.id, "kind" => "refund")
    expect(Commerce::RefundSafety.finance_review_required?(payment.order)).to be(true)
    expect(capture.buyer_return_postings).to be_empty
    Order.transaction { described_class.record_refund!(refund) }
    expect(ReconciliationException.where(code: described_class::QUARANTINE_CODE).count).to eq(1)
  end

  it "keeps a second payment's returns on its own capture and leaves the fulfilled sale untouched" do
    order = create(:order, :pending, subtotal_cents: 1200, service_fee_cents: 160, total_cents: 1360)
    create(:order_item, order: order, unit_price_cents: 1200, subtotal_cents: 1200, organizer_proceeds_cents: 1200, fee_cents: 160)
    payment_a = create(:payment, order: order, provider_payment_id: "pi_iso_a3", status: :succeeded, succeeded_at: Time.current)
    order.update!(status: :completed, completed_at: Time.current, fulfilled_by_payment_id: payment_a.id)
    payment_b = create(:payment, order: order, provider_payment_id: "pi_iso_b3", amount_cents: 1500, status: :succeeded,
      succeeded_at: Time.current)
    capture_b = UnfulfilledCapture.create!(order: order, payment: payment_b, capture_scope: "payment",
      code: "unfulfilled_second_capture", captured_cents: 1500, currency: "usd", proceeds_cents: 1500, fee_cents: 0,
      organizer_fee_cents: 0, tax_cents: 0, processing_bearer: "platform", dispute_fee_bearer: "platform",
      allocation_policy: "item_record", policy_version: "nfc-v2.1", provenance: "lifecycle").reload
    before = [order.reload.status, order.refund_amount_cents, order.refunded_cents, order.refundable_cents]

    ingest_provider_refund!(payment_b, 700)
    lose_dispute!(payment_b, "dp_iso_b3", amount: 1500)

    expect(posting_rows(capture_b)).to eq([["refund", 700, 700, 0, [700, 0, 0, 0]], ["dispute_loss", 1500, 800, 700, [800, 0, 0, 0]]])
    expect([order.reload.status, order.refund_amount_cents, order.refunded_cents, order.refundable_cents]).to eq(before)
    expect(UnfulfilledCapture.where(payment: payment_a)).to be_empty
    expect(RefundItem.joins(:refund).where(refunds: { order_id: order.id })).to be_empty
    expect(BuyerReturnPosting.count).to eq(2)
  end
end
