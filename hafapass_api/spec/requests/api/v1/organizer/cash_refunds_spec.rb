require "rails_helper"

RSpec.describe "Organizer cash return recording", type: :request do
  let(:user) { create(:user, :organizer) }
  let(:profile) { create(:organizer_profile, user: user) }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:order) { create(:order, event: event, payment_method: "door_cash", created_at: 1.day.ago) }
  let!(:item) { create(:order_item, order: order, unit_price_cents: 5000, subtotal_cents: 5000, fee_cents: 250) }
  let!(:payment) { create(:payment, :succeeded, order: order, provider: "door_cash", amount_cents: 5250, provider_payment_id: "cash_receipt_1") }
  let(:path) { "/api/v1/organizer/events/#{event.id}/orders/#{order.id}/refund" }
  let(:headers) { auth_headers(user).merge("Idempotency-Key" => "cash-return-1") }
  let(:evidence) { { reference: "receipt-671", returned_at: 1.hour.ago.iso8601 } }

  before do
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeService).to receive(:refund_payment)
  end

  it "records evidence and actor, serializes the manual outcome, and replays without issuing money" do
    payload = { amount_cents: 1000, reason: "Cash already returned to buyer", cash_return: evidence }
    expect { post path, params: payload, headers: headers, as: :json }.to change(Refund, :count).by(1)
    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("provider" => "door_cash", "manual_record" => true, "status" => "succeeded")
    expect(response.parsed_body["cash_return"]).to include("reference" => "receipt-671", "recorded_by_user_id" => user.id, "cash_custodian" => "organizer")
    expect(order.refunds.last.requested_by).to eq(user)
    expect { post path, params: payload, headers: headers, as: :json }.not_to change(Refund, :count)
    expect(response).to have_http_status(:created)
    expect(StripeService).not_to have_received(:refund_payment)
    get "/api/v1/organizer/events/#{event.id}/orders", headers: auth_headers(user)
    history = response.parsed_body["orders"].first
    expect(history).to include("payment_method" => "door_cash", "payment_provider" => "door_cash")
    expect(history["refunds"].first).to include("manual_record" => true, "provider" => "door_cash")
  end

  it "rejects changed evidence on an existing key" do
    post path, params: { amount_cents: 1000, reason: "Already returned", cash_return: evidence }, headers: headers, as: :json
    expect(response).to have_http_status(:created)
    expect do
      post path, params: { amount_cents: 1000, reason: "Already returned", cash_return: evidence.merge(reference: "different") }, headers: headers, as: :json
    end.not_to change(Refund, :count)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "rejects cash without evidence and invalid evidence without recording a refund" do
    [nil, {}, evidence.merge(reference: ""), evidence.merge(returned_at: 1.day.from_now.iso8601)].each do |cash_return|
      expect do
        post path, params: { reason: "Already returned", cash_return: cash_return }.compact, headers: headers, as: :json
      end.not_to change(Refund, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end
    expect(StripeService).not_to have_received(:refund_payment)
  end

  it "rejects cash evidence for an online payment" do
    order.update!(payment_method: "online")
    post path, params: { reason: "Already returned", cash_return: evidence }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(order.refunds).to be_empty
    expect(StripeService).not_to have_received(:refund_payment)
  end

  it "refuses a manager without refund permission before calling the service" do
    manager = create(:user)
    create(:organization_membership, organization: profile.organization, user: manager, role: :manager)
    expect(Commerce::RefundCreator).not_to receive(:call)
    post path, params: { reason: "Already returned", cash_return: evidence }, headers: auth_headers(manager).merge("Idempotency-Key" => "manager-cash"), as: :json
    expect(response).to have_http_status(:forbidden)
  end
end
