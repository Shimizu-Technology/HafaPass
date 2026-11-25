# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# A1-R1 recheck blocker 3 (docs/design/never-fulfilled-captures.md §6.8):
# 7bcd97c2 acknowledges a second capture B that arrives after A fulfilled
# the order by marking B captured, with no exception, and its receipt becomes
# processed. The database then holds the event's payouts and statements
# (hafapass_unclassified_capture in hafapass_payout_block_start) and
# `never_fulfilled:verify` counts it, until this release classifies B from
# that exact receipt (a redelivered notice, RefundReconciliationJob or an
# authorized reconcile) or quarantines it when the receipt cannot prove it.
# Clearing the receipt's payload keeps its provider identity.
RSpec.describe "Overlap capture discovery", type: :request do
  let(:organizer_profile) { create(:organizer_profile, :verified) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 1200, quantity_available: 10, quantity_sold: 0) }
  let(:admin) { create(:user, :admin) }

  before do
    SiteSetting.instance.update!(payment_mode: "test")
    allow(StripeService).to receive_messages(card_only_intent?: true, payment_enabled?: true, verify_payment_context!: nil)
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(Sentry).to receive(:capture_message)
    allow(StripeService).to receive(:refund_payment).and_raise("no outbound refund in these examples")
  end

  def capture_payload(payment, event_id)
    { "id" => event_id, "type" => "payment_intent.succeeded", "livemode" => false,
      "data" => { "object" => { "id" => payment.provider_payment_id, "status" => "succeeded", "amount" => payment.amount_cents,
        "amount_received" => payment.amount_cents, "currency" => "usd" } } }
  end

  def deliver!(payload)
    StripeWebhookProcessor.call(event: Stripe::Event.construct_from(payload), payload: payload)
  end

  def fulfilled_sale
    allow(StripeService).to receive(:create_payment_intent).and_return(OpenStruct.new(id: "pi_disc_a",
      client_secret: "pi_disc_a_secret", allowed_payment_method_types: ["card"], payment_method_types: ["card"]))
    result = Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "buyer@example.com", buyer_name: "Buyer")
    deliver!(capture_payload(result.payment, "evt_disc_a"))
    [result.order.reload, result.payment.reload]
  end

  def second_payment(order, a, intent: "pi_disc_b")
    order.payments.create!(provider: "stripe", provider_environment: "test",
      provider_platform_account_id: a.provider_platform_account_id, provider_payment_id: intent,
      idempotency_key: "second:#{order.id}:#{intent}", amount_cents: order.total_cents, currency: "usd", status: :pending)
  end

  # What 7bcd97c2 writes for B's success on a completed order: the signed
  # receipt (without the identity columns), its payment event, B captured,
  # the receipt processed. No exception, no classification.
  def legacy_acknowledge!(payment, event_id: "evt_disc_b_old", payload: capture_payload(payment, event_id))
    receipt = WebhookEvent.create!(provider: "stripe", provider_event_id: event_id, event_type: "payment_intent.succeeded",
      payload: payload, provider_created_at: 1.second.ago, status: :processing, attempts: 1)
    receipt.create_payment_event!(payment: payment, event_type: "payment_intent.succeeded", amount_cents: payment.amount_cents,
      currency: "usd", provider_created_at: receipt.provider_created_at, data: {})
    payment.update!(status: :succeeded, succeeded_at: Time.current)
    receipt.update!(status: :processed, processed_at: Time.current)
    receipt
  end

  def verify_counts
    pending = Commerce::NeverFulfilledReconcile.call(dry_run: true).assessments.reject { |item| %w[held reconciled].include?(item.disposition) }
    [pending.map { |item| [item.payment_id, item.disposition] }, Commerce::NeverFulfilledReconcile.overlap_capture_ids]
  end

  it "holds finance on a second capture 7bcd97c2 acknowledged after A, then classifies it from that receipt on redelivery" do
    order, a = fulfilled_sale
    expect(order.fulfilled_by_payment_id).to eq(a.id)
    record_card_sale!(event, ticket_type: ticket_type, quantity: 2, processing_fee_cents: 100)
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(false)
    b = second_payment(order, a)

    receipt = legacy_acknowledge!(b)

    expect(b.reload.capture_recorded_at).to be_present
    expect(ReconciliationException.where(payment: b)).to be_empty
    expect(verify_counts).to eq([[[b.id, "discover"]], [b.id]])
    expect(Commerce::NeverFulfilledPayoutHold.block_started_at(event)).to be_within(0.001).of(b.capture_recorded_at)
    event.update_columns(status: Event.statuses.fetch("completed"))
    expect { Settlements::Finalizer.call(event: event, actor: admin) }.to raise_error(Settlements::Finalizer::FinalizationError)
    # 7bcd97c2's own checks see nothing (no exception exists); only the
    # database refuses. Its unrelated fee precheck is set aside here.
    legacy_finalizer = Legacy7bcd97c2.settlements_finalizer
    allow(legacy_finalizer).to receive(:open_money_blocker).and_return(nil)
    expect { ActiveRecord::Base.transaction(requires_new: true) { legacy_finalizer.call(event: event, actor: admin) } }
      .to raise_error(ActiveRecord::StatementInvalid, /Repayment fence: a buyer repayment on this event is unresolved/)
    expect(Settlement.where(event: event)).to be_empty

    # Stripe (or an operator replay) redelivers the processed notice.
    expect(deliver!(receipt.payload)).to have_attributes(id: receipt.id, status: "processed")

    capture = UnfulfilledCapture.find_by!(payment: b)
    expect(capture).to have_attributes(capture_scope: "payment", code: "unfulfilled_second_capture", provenance: "lifecycle",
      captured_cents: order.total_cents, capture_recorded_at: b.capture_recorded_at)
    expect(capture.provenance_evidence).to include("source" => "signed_webhook", "webhook_event_id" => receipt.id,
      "provider_object_id" => b.provider_payment_id, "discovered_by" => "reconcile", "receipt_status" => "processed",
      "receipt_facts" => "payload", "fulfilling_payment_id" => a.id)
    expect(ReconciliationException.where(payment: b).pluck(:code, :status)).to eq([%w[unfulfilled_second_capture open]])
    expect(order.reload).to have_attributes(status: "completed", fulfilled_by_payment_id: a.id)
    expect(order.tickets).to all(be_issued)
    expect(verify_counts).to eq([[], []])

    expect { deliver!(receipt.payload) }
      .not_to(change { [UnfulfilledCapture.count, ReconciliationException.count, AuditLog.count] })
  end

  it "quarantines an acknowledged capture whose receipt cannot prove it, and keeps finance held without a note path" do
    order, a = fulfilled_sale
    b = second_payment(order, a)
    legacy_acknowledge!(b, payload: {}) # cleared before any release kept its identity
    expect(verify_counts.last).to eq([b.id])

    RefundReconciliationJob.perform_now

    issue = ReconciliationException.find_by!(payment: b, code: Commerce::NeverFulfilledClassification::QUARANTINE_CODE)
    expect(issue.details).to include("reason" => "receipt_identity_missing", "capture_scope" => "payment",
      "classification_code" => "unfulfilled_second_capture", "discovered_by" => "reconcile")
    expect(UnfulfilledCapture.where(payment: b)).to be_empty
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(true)
    expect(Commerce::BuyerRepayment.fenced_payment?(b)).to be(true)
    expect(verify_counts).to eq([[], []])
    expect(Api::V1::Admin::ReconciliationExceptionsController.new.send(:resolution_rule, issue)[:blocked]).to match(/note cannot close/)
    expect { ActiveRecord::Base.transaction(requires_new: true) { issue.resolve! } }
      .to raise_error(ActiveRecord::StatementInvalid, /Evidence hold/)
  end

  it "recovers the sale's payment from the completion audit on a legacy-completed order, then classifies B" do
    order, a = fulfilled_sale
    # Completed by 7bcd97c2 during the overlap: no fulfilling payment recorded.
    ActiveRecord::Base.connection.execute("ALTER TABLE orders DISABLE TRIGGER orders_fulfillment_guard")
    Order.where(id: order.id).update_all(fulfilled_by_payment_id: nil)
    ActiveRecord::Base.connection.execute("ALTER TABLE orders ENABLE TRIGGER orders_fulfillment_guard")
    b = second_payment(order, a)
    legacy_acknowledge!(b)
    expect(verify_counts.last).to eq([a.id, b.id])
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(true)

    assessments = Commerce::NeverFulfilledReconcile.discover_overlap_captures!

    expect(assessments.map { |item| [item.payment_id, item.disposition] }).to eq([[a.id, "discover"], [b.id, "discover"]])
    expect(order.reload.fulfilled_by_payment_id).to eq(a.id)
    expect(UnfulfilledCapture.find_by!(payment: b).capture_scope).to eq("payment")
    expect(UnfulfilledCapture.where(payment: a)).to be_empty
    expect(verify_counts).to eq([[], []])
  end

  it "proves the capture from the identity the database kept when retention cleared the receipt" do
    order, a = fulfilled_sale
    b = second_payment(order, a)
    receipt = legacy_acknowledge!(b)
    expect(receipt.provider_payment_intent_id).to be_nil

    WebhookEvent.where(id: receipt.id).update_all(payload: {}, last_error: nil, retention_anonymized_at: Time.current)
    expect(receipt.reload).to have_attributes(payload: {}, provider_payment_intent_id: b.provider_payment_id,
      provider_amount_cents: b.amount_cents, provider_currency: "usd", provider_livemode: false)

    Commerce::NeverFulfilledReconcile.discover_overlap_captures!
    expect(UnfulfilledCapture.find_by!(payment: b).provenance_evidence)
      .to include("webhook_event_id" => receipt.id, "receipt_facts" => "stored_identity")
  end

  it "stores a capture receipt's identity in this release and leaves ordinary single captures alone" do
    order, a = fulfilled_sale
    receipt = WebhookEvent.find_by!(provider_event_id: "evt_disc_a")
    expect(receipt).to have_attributes(provider_payment_intent_id: a.provider_payment_id, provider_amount_cents: order.total_cents,
      provider_livemode: false)
    expect(Commerce::NeverFulfilledReconcile.overlap_capture_ids).to be_empty
    expect(Commerce::NeverFulfilledPayoutHold.blocked?(event)).to be(false)

    # This release receiving B itself classifies it at once.
    b = second_payment(order, a)
    deliver!(capture_payload(b, "evt_disc_b_new"))
    expect(UnfulfilledCapture.find_by!(payment: b).capture_scope).to eq("payment")
    expect(Commerce::NeverFulfilledReconcile.overlap_capture_ids).to be_empty
  end
end
