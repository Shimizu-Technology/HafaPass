# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# Payment-only boundaries for a payment-scope never-fulfilled capture
# (docs/design/never-fulfilled-captures.md §4.3, A1 tranche 2). Payment A
# fulfilled the order; a distinct second payment B was captured later. B's
# refunds, disputes and fees never act on A's sale, and A's refunds and
# disputes never change B. Driven through the real Stripe webhook paths with
# synthetic Stripe objects.
RSpec.describe "Payment-scope capture isolation", type: :request do
  let(:organizer_profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 1200, quantity_available: 10, quantity_sold: 0) }
  let(:promoter) { create(:promoter, event: event, commission_bps: 1000) }
  let(:provider_refunds) { [] }

  before do
    SiteSetting.instance.update!(payment_mode: "test")
    allow(StripeService).to receive(:card_only_intent?).and_return(true)
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(Sentry).to receive(:capture_message)
    allow(StripeService).to receive(:refund_payment) do |intent_id, amount_cents:, idempotency_key:, **|
      provider_refunds << [intent_id, amount_cents, idempotency_key]
      OpenStruct.new(id: "re_sale_#{provider_refunds.length}", status: "succeeded", amount: amount_cents, currency: "usd",
        payment_intent: intent_id, metadata: { "hafapass_refund_key" => idempotency_key })
    end
  end

  def post_stripe_event(type, object, event_id: "evt_iso_#{SecureRandom.hex(4)}")
    post "/webhooks/stripe", params: { id: event_id, type: type, data: { object: object } }.to_json,
      headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:ok)
  end

  def succeed!(payment)
    post_stripe_event("payment_intent.succeeded", { id: payment.provider_payment_id, amount: payment.amount_cents,
      amount_received: payment.amount_cents, currency: "usd", status: "succeeded" })
  end

  # A fulfilled two-ticket sale with a promoter commission, plus a distinct
  # verified second capture B classified in payment scope.
  def sale_with_second_capture
    allow(StripeService).to receive(:create_payment_intent).and_return(OpenStruct.new(id: "pi_iso_a",
      client_secret: "pi_iso_a_secret", allowed_payment_method_types: ["card"], payment_method_types: ["card"]))
    result = Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: 2 }],
      buyer_email: "buyer@example.com", buyer_name: "Buyer")
    order = result.order
    ReferralAttribution.create!(order: order, promoter: promoter, code_snapshot: promoter.code, attributed_at: Time.current)
    succeed!(result.payment)
    payment_b = order.payments.create!(provider: "stripe", provider_environment: "test",
      provider_platform_account_id: result.payment.provider_platform_account_id, provider_payment_id: "pi_iso_b",
      idempotency_key: "second:#{order.id}", amount_cents: 1500, currency: "usd", status: :pending)
    succeed!(payment_b)
    expect(UnfulfilledCapture.find_by!(payment: payment_b)).to have_attributes(capture_scope: "payment", captured_cents: 1500)
    [order.reload, result.payment.reload, payment_b.reload]
  end

  def sale_snapshot(order)
    order.reload
    { status: order.status, refund_amount_cents: order.refund_amount_cents, refunded_cents: order.refunded_cents,
      refundable_cents: order.refundable_cents, fulfilled_by: order.fulfilled_by_payment_id,
      tickets: order.tickets.order(:id).pluck(:id, :status),
      sold: ticket_type.reload.quantity_sold, refund_items: RefundItem.joins(:refund).where(refunds: { order_id: order.id }).count,
      commissions: order.promoter_commission_entries.order(:id).pluck(:kind, :amount_cents),
      blocked: order.ticket_access_blocked?, buyer_status: order.buyer_status,
      admission: order.tickets.order(:id).map(&:admission_block_reason) }
  end

  def provider_refund(payment, id, amount)
    post_stripe_event("refund.created", { id: id, object: "refund", payment_intent: payment.provider_payment_id,
      amount: amount, currency: "usd", status: "succeeded" })
  end

  def dispute!(payment, id, closed_status: nil)
    object = { id: id, payment_intent: payment.provider_payment_id, amount: payment.amount_cents, currency: "usd",
      status: "needs_response", reason: "fraudulent" }
    post_stripe_event("charge.dispute.created", object)
    post_stripe_event("charge.dispute.closed", object.merge(status: closed_status)) if closed_status
    Dispute.find_by!(provider_dispute_id: id)
  end

  it "records a provider refund and a lost dispute on B against B only; A's sale, admission and commission are unchanged" do
    order, payment_a, payment_b = sale_with_second_capture
    expect(order.promoter_commission_entries.earned.count).to eq(1)
    before = sale_snapshot(order)
    expect(before).to include(status: "completed", refunded_cents: 0, refundable_cents: order.total_cents,
      blocked: false, buyer_status: "paid", admission: [nil, nil])

    provider_refund(payment_b, "re_iso_b", 600)
    provider_refund(payment_b, "re_iso_b", 600) # repeated delivery
    refund_b = Refund.find_by!(provider_refund_id: "re_iso_b")
    expect(refund_b).to have_attributes(payment_id: payment_b.id, amount_cents: 600, status: "succeeded")
    expect(refund_b.refund_items).to be_empty
    expect(payment_b.reload).to be_partially_refunded
    expect(sale_snapshot(order)).to eq(before)
    expect(EmailService).not_to have_received(:send_refund_notification_async)
    expect(Commerce::RefundCreator.remaining_cents(order: order, payment: payment_b)).to eq(900)
    expect(Commerce::RefundCreator.remaining_cents(order: order, payment: payment_a)).to eq(payment_a.amount_cents)

    dispute_b = dispute!(payment_b, "dp_iso_b", closed_status: "lost")
    expect(dispute_b).to have_attributes(payment_id: payment_b.id, status: "lost")
    # A repeated closed notice for the decided dispute changes nothing either.
    dispute!(payment_b, "dp_iso_b", closed_status: "lost")
    expect(sale_snapshot(order)).to eq(before)
    expect(order.tickets.reload).to all(be_issued)
    expect(EventCancellationRefunds.balance_cents(order)).to eq(payment_a.amount_cents)
    expect(provider_refunds).to be_empty

    # A's own refund still works on A's own balance, and reverses A's commission.
    refund_a = Commerce::RefundCreator.call(order: order, reason: "requested_by_customer", requested_by: create(:user, :admin))
    expect(refund_a).to have_attributes(payment_id: payment_a.id, amount_cents: payment_a.amount_cents, status: "succeeded")
    expect(provider_refunds).to eq([["pi_iso_a", payment_a.amount_cents, refund_a.idempotency_key]])
    expect(order.reload).to be_refunded
    expect(order.refund_amount_cents).to eq(payment_a.amount_cents)
    expect(order.tickets.reload).to all(be_cancelled)
    expect(order.promoter_commission_entries.refund_reversal.count).to eq(1)
    expect(payment_b.reload).to be_partially_refunded
    expect(UnfulfilledCapture.find_by!(payment: payment_b)).to have_attributes(captured_cents: 1500, capture_scope: "payment")
  end

  it "keeps B unchanged when A is refunded or lost, and still records B's later provider refund" do
    order, payment_a, payment_b = sale_with_second_capture

    dispute_a = dispute!(payment_a, "dp_iso_a")
    expect(order.reload.ticket_access_blocked?).to be(true)
    expect(order.tickets.first.admission_block_reason).to eq("payment_blocked")
    post_stripe_event("charge.dispute.closed", { id: "dp_iso_a", payment_intent: "pi_iso_a",
      amount: payment_a.amount_cents, currency: "usd", status: "lost", reason: "fraudulent" })
    expect(dispute_a.reload).to be_lost
    expect(order.tickets.reload).to all(be_cancelled)
    expect(Commerce::RefundCreator.remaining_cents(order: order, payment: payment_b)).to eq(1500)
    expect(payment_b.reload).to be_succeeded

    # The sale is now fully returned; B's refund is still recorded on B alone.
    order.update_columns(status: Order.statuses[:refunded])
    provider_refund(payment_b, "re_iso_b_after", 1500)
    expect(Refund.find_by!(provider_refund_id: "re_iso_b_after")).to have_attributes(payment_id: payment_b.id, status: "succeeded")
    expect(payment_b.reload).to be_refunded
    expect(order.reload.refund_amount_cents).to eq(0)
    # B's refund asks for its own fee adjustment review, on B.
    expect(ReconciliationException.where(payment: payment_b).pluck(:code))
      .to contain_exactly("unfulfilled_second_capture", "stripe_fee_adjustment_review_required")
  end

  it "never sends a refund for B through the order-wide refund path" do
    order, payment_a, payment_b = sale_with_second_capture
    admin = create(:user, :admin)

    expect do
      Commerce::RefundCreator.call(order: order, payment: payment_b, reason: "requested_by_customer", requested_by: admin)
    end.to raise_error(Commerce::RefundCreator::RefundError, /second payment on a fulfilled order/)
    expect do
      Commerce::RefundCreator.call(order: order, payment: payment_b, amount_cents: 100, reason: "requested_by_customer",
        requested_by: admin, provider_refund: nil, tickets: [order.tickets.first])
    end.to raise_error(Commerce::RefundCreator::RefundError)
    expect { Commerce::LateCaptureRefund.call(payment: payment_b) }.to raise_error(Commerce::LateCaptureRefund::NotApplicable)
    expect(provider_refunds).to be_empty
    expect(payment_b.refunds).to be_empty

    # A's refund options and limits ignore B entirely.
    options = Commerce::AdminOrderRefund.options(order)
    expect(options).to include(refundable_cents: payment_a.amount_cents)
    expect(Commerce::OrganizerRefundOptions.new(order).call.to_h.to_s).not_to include("several captured")
  end

  it "keeps B's verified processing fee on B's own evidence and never charges it to A's sale" do
    order, payment_a, payment_b = sale_with_second_capture
    fee_intent = lambda do |payment, fee, suffix|
      balance = { "id" => "txn_#{suffix}", "source" => "ch_#{suffix}", "type" => "charge", "status" => "available",
        "amount" => payment.amount_cents, "currency" => "usd", "fee" => fee, "net" => payment.amount_cents - fee,
        "fee_details" => [{ "type" => "stripe_fee", "amount" => fee, "currency" => "usd" }] }
      charge = { "id" => "ch_#{suffix}", "payment_intent" => payment.provider_payment_id, "status" => "succeeded",
        "paid" => true, "captured" => true, "amount" => payment.amount_cents, "amount_captured" => payment.amount_cents,
        "currency" => "usd", "livemode" => false, "balance_transaction" => balance }
      { "id" => payment.provider_payment_id, "status" => "succeeded", "amount" => payment.amount_cents,
        "amount_received" => payment.amount_cents, "currency" => "usd", "livemode" => false, "latest_charge" => charge }
    end
    allow(StripeService).to receive(:retrieve_fee_payment_intent).with(payment_b).and_return(fee_intent.call(payment_b, 74, "b"))
    allow(StripeService).to receive(:retrieve_fee_payment_intent).with(payment_a).and_return(fee_intent.call(payment_a, 92, "a"))

    evidence_b = StripeProcessingFees.call(payment: payment_b)
    expect(evidence_b).to have_attributes(status: "review_required", last_error_code: "payment_scope_processing_deferred",
      fee_cents: 74, provider_charge_id: "ch_b", provider_balance_transaction_id: "txn_b", fee_component_id: nil)
    expect(StripeProcessingFees.call(payment: payment_b).reload.status).to eq("review_required")

    evidence_a = StripeProcessingFees.call(payment: payment_a)
    expect(evidence_a).to be_status_verified
    expect(order.fee_components.where(kind: "processing", estimated: false).pluck(:amount_cents)).to eq([92])
    expect(evidence_a.fee_component.metadata).to include("payment_id" => payment_a.id)
    expect(ReconciliationException.open.where(payment: payment_b, code: StripeProcessingFees::REVIEW_CODE).count).to eq(1)
  end
end
