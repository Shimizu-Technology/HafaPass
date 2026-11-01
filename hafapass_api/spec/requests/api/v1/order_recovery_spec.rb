require "rails_helper"

RSpec.describe "Order recovery", type: :request do
  let(:order) { create(:order, user: nil, buyer_email: "guest@example.com") }

  before do
    allow(EmailService).to receive(:send_order_recovery_async) do |matched_order|
      create(:message_delivery, order: matched_order, template: "order_recovery", recipient: matched_order.buyer_email)
    end
  end

  it "returns the same response for matching and non-matching details" do
    post "/api/v1/order_lookup", params: { reference: order.reference, buyer_email: "guest@example.com" }
    matching = response.parsed_body

    post "/api/v1/order_lookup", params: { reference: "HP-NOTFOUND", buyer_email: "guest@example.com" }

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to eq(matching)
  end

  it "queues recovery for a match without revoking the buyer's existing links" do
    old_token = GuestOrderAccess.issue!(order)

    post "/api/v1/order_lookup", params: { reference: order.reference.downcase, buyer_email: "GUEST@example.com" }

    expect(response).to have_http_status(:accepted)
    expect(EmailService).to have_received(:send_order_recovery_async).with(order)
    expect(GuestOrderAccess.find(old_token)).to eq(order)
  end

  it "restores access with a fresh link version after the buyer's links were revoked" do
    revoked_token = GuestOrderAccess.issue!(order)
    GuestOrderAccess.revoke!(order)

    post "/api/v1/order_lookup", params: { reference: order.reference, buyer_email: order.buyer_email }

    expect(response).to have_http_status(:accepted)
    expect(order.reload.guest_access_revoked_at).to be_nil
    expect(GuestOrderAccess.find(revoked_token)).to be_nil
    expect(GuestOrderAccess.find(GuestOrderAccess.issue!(order))).to eq(order)
  end

  it "does not issue guest recovery for an account-owned order" do
    owned = create(:order, user: create(:user), buyer_email: "member@example.com")

    post "/api/v1/order_lookup", params: { reference: owned.reference, buyer_email: owned.buyer_email }

    expect(response).to have_http_status(:accepted)
    expect(EmailService).not_to have_received(:send_order_recovery_async)
  end

  it "keeps the response enumeration-safe when the delivery queue fails" do
    allow(EmailService).to receive(:send_order_recovery_async).and_raise(StandardError, "queue unavailable")

    post "/api/v1/order_lookup", params: { reference: order.reference, buyer_email: order.buyer_email }

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to eq(
      "message" => "If those details match an order, a secure access link has been sent."
    )
  end
end
