require "rails_helper"

RSpec.describe "Api::V1::Organizer::BoxOffice", type: :request do
  let(:user) { create(:user, :organizer) }
  let(:organizer_profile) { create(:organizer_profile, user: user) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile, starts_at: 3.days.from_now) }
  let!(:ticket_type) { create(:ticket_type, event: event, name: "General Admission", price_cents: 2500, quantity_available: 100) }
  let(:headers) { auth_headers(user) }

  describe "POST /api/v1/organizer/events/:event_id/box_office" do
    let(:valid_params) do
      {
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 2 }],
        payment_method: "door_cash",
        buyer_name: "John Doe",
        buyer_email: "john@example.com"
      }
    end

    it "creates a box office order" do
      post "/api/v1/organizer/events/#{event.id}/box_office", params: valid_params, headers: headers

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json["source"]).to eq("box_office")
      expect(json["payment_method"]).to eq("door_cash")
      expect(json["status"]).to eq("completed")
      expect(json["tickets"].length).to eq(2)
      expect(json["tickets"].first["scan_credential"]).to be_present
      expect(json["tickets"].first["display_credential"]).to be_present
    end

    it "creates order with walk-in defaults when no buyer info provided" do
      post "/api/v1/organizer/events/#{event.id}/box_office",
        params: { line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }], payment_method: "door_cash" },
        headers: headers

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json["buyer_name"]).to eq("Walk-in")
    end

    it "rejects invalid payment method" do
      post "/api/v1/organizer/events/#{event.id}/box_office",
        params: valid_params.merge(payment_method: "stripe"),
        headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "rejects when quantity exceeds availability" do
      post "/api/v1/organizer/events/#{event.id}/box_office",
        params: valid_params.merge(line_items: [{ ticket_type_id: ticket_type.id, quantity: 999 }]),
        headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "increments quantity_sold on ticket type" do
      expect {
        post "/api/v1/organizer/events/#{event.id}/box_office", params: valid_params, headers: headers
      }.to change { ticket_type.reload.quantity_sold }.by(2)
    end

    it "records the door payment and immutable order item ledger" do
      post "/api/v1/organizer/events/#{event.id}/box_office", params: valid_params, headers: headers

      expect(response).to have_http_status(:created)
      order = Order.find(response.parsed_body.fetch("id"))
      expect(order.order_items.sum(:quantity)).to eq(2)
      expect(order.payments.succeeded.first).to have_attributes(
        provider: "door_cash",
        amount_cents: order.total_cents,
        currency: "usd"
      )
    end

    it "requires a verified Guam account and idempotency key for card sales" do
      card_params = valid_params.merge(payment_method: "door_card")

      post "/api/v1/organizer/events/#{event.id}/box_office", params: card_params, headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("Idempotency-Key")

      post "/api/v1/organizer/events/#{event.id}/box_office", params: card_params,
        headers: headers.merge("Idempotency-Key" => "door-card-1")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("verified Guam")
    end

    it "confirms a card-present payment before issuing one set of tickets and safely replays it" do
      create(:card_present_account, :verified, organization: event.organization)
      card_params = valid_params.merge(payment_method: "door_card")
      card_headers = headers.merge("Idempotency-Key" => "door-card-confirmed")

      expect do
        post "/api/v1/organizer/events/#{event.id}/box_office", params: card_params, headers: card_headers
      end.to change(CardPresentPaymentAttempt, :count).by(1)
      expect(response).to have_http_status(:created)
      order_id = response.parsed_body.fetch("id")
      expect(response.parsed_body).to include("status" => "completed", "payment_method" => "door_card")
      expect(response.parsed_body.dig("card_present_payment", "status")).to eq("succeeded")

      expect do
        post "/api/v1/organizer/events/#{event.id}/box_office", params: card_params, headers: card_headers
      end.not_to change(Order, :count)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("id")).to eq(order_id)
      expect(Order.find(order_id).tickets.count).to eq(2)
    end

    it "rejects reuse of a card idempotency key for different inventory" do
      create(:card_present_account, :verified, organization: event.organization)
      card_headers = headers.merge("Idempotency-Key" => "door-card-conflict")
      post "/api/v1/organizer/events/#{event.id}/box_office",
        params: valid_params.merge(payment_method: "door_card"), headers: card_headers

      post "/api/v1/organizer/events/#{event.id}/box_office",
        params: valid_params.merge(payment_method: "door_card", line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }]),
        headers: card_headers

      expect(response).to have_http_status(:conflict)
    end
  end

  describe "GET /api/v1/organizer/events/:event_id/box_office/summary" do
    it "returns box office sales summary" do
      # Create a box office order
      order = create(
        :order,
        event: event,
        user: user,
        status: :completed,
        source: "box_office",
        payment_method: "door_cash",
        subtotal_cents: 5000,
        service_fee_cents: 0,
        total_cents: 5000
      )
      item = create(:order_item, order: order, ticket_type: ticket_type, unit_price_cents: 5000,
        subtotal_cents: 5000, fee_cents: 0, organizer_proceeds_cents: 5000)
      create(:ticket, order: order, order_item: item, event: event, ticket_type: ticket_type)
      refund = create(:refund, order: order, amount_cents: 1000)
      create(:refund_item, refund: refund, order_item: item, amount_cents: 1000,
        organizer_proceeds_cents: 1000)
      order.update!(status: :partially_refunded, refund_amount_cents: 1000)

      get "/api/v1/organizer/events/#{event.id}/box_office/summary", headers: headers

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["total_orders"]).to eq(1)
      expect(json["total_revenue_cents"]).to eq(4000)
      expect(json.dig("by_payment_method", "door_cash")).to eq(4000)
    end
  end
end
