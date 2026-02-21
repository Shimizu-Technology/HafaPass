require "rails_helper"

RSpec.describe "Api::V1::Tickets", type: :request do
  let(:organizer_profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile) }
  let(:ticket_type) { create(:ticket_type, event: event) }
  let(:order) { create(:order, event: event) }
  let(:ticket) { create(:ticket, order: order, ticket_type: ticket_type, event: event, attendee_name: "Jane Doe") }

  describe "GET /api/v1/tickets/:qr_code" do
    it "returns ticket details" do
      get "/api/v1/tickets/#{ticket.qr_code}"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["qr_code"]).to eq(ticket.qr_code)
      expect(json["event"]["title"]).to eq(event.title)
      expect(json["ticket_type"]["name"]).to eq(ticket_type.name)
    end

    it "returns 404 for unknown qr_code" do
      get "/api/v1/tickets/nonexistent"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/tickets/:qr_code/download" do
    it "returns a PDF file" do
      get "/api/v1/tickets/#{ticket.qr_code}/download"

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/pdf")
      expect(response.headers["Content-Disposition"]).to include("attachment")
      expect(response.headers["Content-Disposition"]).to include(".pdf")
    end

    it "returns 404 for unknown qr_code" do
      get "/api/v1/tickets/nonexistent/download"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/tickets/:qr_code/wallet/apple" do
    it "returns 501 not implemented" do
      get "/api/v1/tickets/#{ticket.qr_code}/wallet/apple"

      expect(response).to have_http_status(:not_implemented)
      json = JSON.parse(response.body)
      expect(json["error"]).to include("Coming soon")
    end
  end

  describe "GET /api/v1/tickets/:qr_code/wallet/google" do
    it "returns 501 not implemented" do
      get "/api/v1/tickets/#{ticket.qr_code}/wallet/google"

      expect(response).to have_http_status(:not_implemented)
      json = JSON.parse(response.body)
      expect(json["error"]).to include("Coming soon")
    end
  end
end
