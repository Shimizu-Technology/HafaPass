require "rails_helper"

RSpec.describe "Organizer refunds", type: :request do
  let(:user) { create(:user, :organizer) }
  let(:profile) { create(:organizer_profile, user: user) }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:headers) { auth_headers(user).merge("Idempotency-Key" => "organizer-refund-request") }
  let(:order) do
    create(:order, event: event, subtotal_cents: 5000, service_fee_cents: 250, total_cents: 5250)
  end
  let!(:item) do
    create(
      :order_item,
      order: order,
      unit_price_cents: 5000,
      subtotal_cents: 5000,
      fee_cents: 250,
      organizer_proceeds_cents: 5000
    )
  end
  let!(:payment) do
    create(:payment, :succeeded, order: order, amount_cents: 5250, provider_payment_id: "sim_pi_request")
  end

  before do
    allow(EmailService).to receive(:send_refund_notification_async)
  end

  it "requires an idempotency key before contacting the provider" do
    path = "/api/v1/organizer/events/#{event.id}/orders/#{order.id}/refund"

    expect do
      post path, params: { amount_cents: 1000 }, headers: auth_headers(user)
    end.not_to change(Refund, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("Idempotency-Key")
  end

  it "creates an allocated refund and safely replays the same request" do
    path = "/api/v1/organizer/events/#{event.id}/orders/#{order.id}/refund"

    expect do
      post path, params: { amount_cents: 1000, reason: "buyer request" }, headers: headers
    end.to change(Refund, :count).by(1).and change(RefundItem, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include(
      "status" => "succeeded",
      "amount_cents" => 1000,
      "refunded_total_cents" => 1000,
      "remaining_cents" => 4250
    )

    expect do
      post path, params: { amount_cents: 1000, reason: "buyer request" }, headers: headers
    end.not_to change(Refund, :count)
    expect(response).to have_http_status(:created)
  end
end
