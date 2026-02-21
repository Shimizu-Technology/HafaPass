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
      expect(json["tickets"].first["qr_code"]).to be_present
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
  end

  describe "GET /api/v1/organizer/events/:event_id/box_office/summary" do
    it "returns box office sales summary" do
      # Create a box office order
      order = create(:order, event: event, user: user, status: :completed, source: "box_office", payment_method: "door_cash", total_cents: 5000)
      create(:ticket, order: order, event: event, ticket_type: ticket_type)

      get "/api/v1/organizer/events/#{event.id}/box_office/summary", headers: headers

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["total_orders"]).to eq(1)
      expect(json["total_revenue_cents"]).to eq(5000)
    end
  end
end
