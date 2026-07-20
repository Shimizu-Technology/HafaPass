require "rails_helper"

RSpec.describe "Stripe webhooks", type: :request do
  let(:organizer_profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile) }
  let(:ticket_type) { create(:ticket_type, event: event, quantity_sold: 1) }
  let(:pricing_tier) do
    create(:pricing_tier, ticket_type: ticket_type, tier_type: :quantity_based, quantity_limit: 10, quantity_sold: 1)
  end

  before do
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(EmailService).to receive(:send_ticket_email_async)
    allow(EmailService).to receive(:send_refund_notification_async)
  end

  def post_stripe_event(type, object, event_id: "evt_test_#{SecureRandom.hex(4)}")
    post "/webhooks/stripe", params: {
      id: event_id,
      type: type,
      data: { object: object }
    }.to_json, headers: { "Content-Type" => "application/json" }
  end

  def create_pending_checkout(intent_id: "pi_checkout")
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:create_payment_intent).and_return(
      OpenStruct.new(id: intent_id, client_secret: "#{intent_id}_secret")
    )
    Commerce::OrderCreator.call(
      event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "buyer@example.com",
      buyer_name: "Buyer"
    )
  end

  it "rejects unsigned webhooks outside development and test" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))

    expect do
      post_stripe_event("payment_intent.succeeded", { id: "pi_unsigned" }, event_id: "evt_unsigned")
    end.not_to change(WebhookEvent, :count)

    expect(response).to have_http_status(:bad_request)
  end

  it "identifies a missing Stripe signature when the production secret is configured" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("STRIPE_WEBHOOK_SECRET").and_return("whsec_test")

    post_stripe_event("payment_intent.succeeded", { id: "pi_unsigned" }, event_id: "evt_missing_signature")

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq("error" => "Stripe signature missing")
  end

  it "rejects an invalid Stripe signature before storing a receipt" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("STRIPE_WEBHOOK_SECRET").and_return("whsec_test")
    allow(Stripe::Webhook).to receive(:construct_event).and_raise(
      Stripe::SignatureVerificationError.new("bad signature", "sig")
    )

    expect do
      post "/webhooks/stripe", params: { id: "evt_bad_signature" }.to_json,
        headers: { "Content-Type" => "application/json", "Stripe-Signature" => "sig" }
    end.not_to change(WebhookEvent, :count)

    expect(response).to have_http_status(:bad_request)
  end

  it "releases ticket type and pricing tier inventory when payment fails" do
    order = create(:order, :pending, event: event, stripe_payment_intent_id: "pi_failed")
    ticket = create(:ticket, order: order, event: event, ticket_type: ticket_type, pricing_tier: pricing_tier)

    post_stripe_event("payment_intent.payment_failed", { id: "pi_failed" })

    expect(response).to have_http_status(:ok)
    expect(order.reload).to be_cancelled
    expect(ticket.reload).to be_cancelled
    expect(ticket_type.reload.quantity_sold).to eq(0)
    expect(pricing_tier.reload.quantity_sold).to eq(0)
  end

  it "records reconciliation instead of guessing allocations for a legacy order without item snapshots" do
    order = create(:order, event: event, total_cents: 5250, stripe_payment_intent_id: "pi_refunded")
    create(:ticket, order: order, event: event, ticket_type: ticket_type, pricing_tier: pricing_tier)

    post_stripe_event("charge.refunded", { payment_intent: "pi_refunded", amount_refunded: 5250 })

    expect(response).to have_http_status(:ok)
    expect(order.reload).to be_completed
    expect(order.reconciliation_exceptions).to exist(code: "refund_missing_order_item_ledger")
  end

  it "stores, normalizes, and idempotently processes a successful payment event" do
    checkout = create_pending_checkout
    payload = { id: "pi_checkout", amount: checkout.payment.amount_cents, amount_received: checkout.payment.amount_cents,
                currency: "usd", status: "succeeded" }

    expect do
      post_stripe_event("payment_intent.succeeded", payload, event_id: "evt_success_once")
    end.to change(WebhookEvent, :count).by(1)
      .and change(PaymentEvent, :count).by(1)
      .and change(Ticket, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(checkout.order.reload).to be_completed
    expect(WebhookEvent.last.payload.dig("data", "object", "id")).to eq("pi_checkout")

    expect do
      post_stripe_event("payment_intent.succeeded", payload, event_id: "evt_success_once")
    end.not_to change { [WebhookEvent.count, PaymentEvent.count, Ticket.count] }
    expect(response).to have_http_status(:ok)
  end

  it "ignores a late failure after success but retains both provider events" do
    checkout = create_pending_checkout(intent_id: "pi_out_of_order")
    post_stripe_event(
      "payment_intent.succeeded",
      { id: "pi_out_of_order", amount_received: checkout.payment.amount_cents, currency: "usd" },
      event_id: "evt_success_first"
    )
    post_stripe_event(
      "payment_intent.payment_failed",
      { id: "pi_out_of_order", amount: checkout.payment.amount_cents, currency: "usd" },
      event_id: "evt_failure_late"
    )

    expect(response).to have_http_status(:ok)
    expect(checkout.order.reload).to be_completed
    expect(checkout.payment.reload).to be_succeeded
    expect(checkout.payment.payment_events.count).to eq(2)
  end

  it "quarantines a late success after failure and released inventory" do
    checkout = create_pending_checkout(intent_id: "pi_late_success")
    post_stripe_event(
      "payment_intent.payment_failed",
      { id: "pi_late_success", amount: checkout.payment.amount_cents, currency: "usd" },
      event_id: "evt_failure_first"
    )
    expect(checkout.order.reload).to be_cancelled

    post_stripe_event(
      "payment_intent.succeeded",
      { id: "pi_late_success", amount_received: checkout.payment.amount_cents, currency: "usd" },
      event_id: "evt_success_late"
    )

    expect(response).to have_http_status(:ok)
    expect(checkout.order.reload).to be_cancelled
    expect(checkout.payment.reload).to be_succeeded
    expect(checkout.order.reconciliation_exceptions).to exist(code: "late_payment_success_after_inventory_release")
    expect(checkout.order.tickets).to be_empty
  end

  it "keeps a mismatched provider amount pending and opens reconciliation" do
    checkout = create_pending_checkout(intent_id: "pi_mismatch")
    post_stripe_event(
      "payment_intent.succeeded",
      { id: "pi_mismatch", amount_received: checkout.payment.amount_cents + 500, currency: "usd" },
      event_id: "evt_mismatch"
    )

    expect(response).to have_http_status(:ok)
    expect(checkout.order.reload).to be_pending
    expect(checkout.order.reconciliation_exceptions).to exist(code: "payment_amount_mismatch")
  end

  it "reconciles a provider-side full refund into additive ledger records" do
    checkout = create_pending_checkout(intent_id: "pi_provider_refund")
    post_stripe_event(
      "payment_intent.succeeded",
      { id: "pi_provider_refund", amount_received: checkout.payment.amount_cents, currency: "usd" },
      event_id: "evt_paid_for_refund"
    )

    post_stripe_event(
      "charge.refunded",
      { id: "ch_refunded", payment_intent: "pi_provider_refund", amount_refunded: checkout.payment.amount_cents,
        currency: "usd", refunds: { data: [{ id: "re_actual_provider_refund", status: "succeeded" }] } },
      event_id: "evt_provider_refund"
    )

    expect(response).to have_http_status(:ok)
    expect(checkout.order.reload).to be_refunded
    expect(checkout.order.refunds.succeeded.sum(:amount_cents)).to eq(checkout.order.total_cents)
    expect(checkout.order.refunds.succeeded.last.provider_refund_id).to eq("re_actual_provider_refund")
    expect(checkout.order.tickets.reload).to all(be_cancelled)
  end

  it "suspends ticket access during a dispute and restores it when the dispute is won" do
    checkout = create_pending_checkout(intent_id: "pi_disputed_won")
    post_stripe_event(
      "payment_intent.succeeded",
      { id: "pi_disputed_won", amount_received: checkout.payment.amount_cents, currency: "usd" },
      event_id: "evt_disputed_payment"
    )

    dispute = { id: "dp_won", payment_intent: "pi_disputed_won", amount: checkout.payment.amount_cents,
                currency: "usd", reason: "fraudulent", status: "needs_response" }
    post_stripe_event("charge.dispute.created", dispute, event_id: "evt_dispute_open")

    expect(checkout.order.reload.ticket_access_blocked?).to be(true)
    expect(checkout.order.tickets.first).to be_issued

    post_stripe_event("charge.dispute.closed", dispute.merge(status: "won"), event_id: "evt_dispute_won")

    expect(Dispute.find_by(provider_dispute_id: "dp_won")).to be_won
    expect(checkout.order.reload.ticket_access_blocked?).to be(false)
  end

  it "revokes tickets and releases inventory when a dispute is lost, idempotently" do
    checkout = create_pending_checkout(intent_id: "pi_disputed_lost")
    post_stripe_event(
      "payment_intent.succeeded",
      { id: "pi_disputed_lost", amount_received: checkout.payment.amount_cents, currency: "usd" },
      event_id: "evt_lost_payment"
    )
    ticket = checkout.order.reload.tickets.first
    old_scan = ticket.scan_credential
    sold_before = ticket_type.reload.quantity_sold
    dispute = { id: "dp_lost", payment_intent: "pi_disputed_lost", amount: checkout.payment.amount_cents,
                currency: "usd", reason: "fraudulent", status: "lost" }

    post_stripe_event("charge.dispute.closed", dispute, event_id: "evt_dispute_lost")

    expect(response).to have_http_status(:ok)
    expect(ticket.reload).to be_cancelled
    expect(ticket_type.reload.quantity_sold).to eq(sold_before - 1)
    expect(TicketCredential.find_scan(old_scan)).to be_nil

    expect do
      post_stripe_event("charge.dispute.closed", dispute, event_id: "evt_dispute_lost")
    end.not_to change { ticket_type.reload.quantity_sold }
  end
end
