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

  def post_stripe_event(type, object)
    post "/webhooks/stripe", params: {
      id: "evt_test_#{SecureRandom.hex(4)}",
      type: type,
      data: { object: object }
    }.to_json, headers: { "Content-Type" => "application/json" }
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

  it "releases ticket type and pricing tier inventory on full refund" do
    order = create(:order, event: event, total_cents: 5250, stripe_payment_intent_id: "pi_refunded")
    ticket = create(:ticket, order: order, event: event, ticket_type: ticket_type, pricing_tier: pricing_tier)

    post_stripe_event("charge.refunded", { payment_intent: "pi_refunded", amount_refunded: 5250 })

    expect(response).to have_http_status(:ok)
    expect(order.reload).to be_refunded
    expect(ticket.reload).to be_cancelled
    expect(ticket_type.reload.quantity_sold).to eq(0)
    expect(pricing_tier.reload.quantity_sold).to eq(0)
  end
end
