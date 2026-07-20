require "rails_helper"

RSpec.describe "Api::V1::Tickets", type: :request do
  let(:organizer_profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile) }
  let(:ticket_type) { create(:ticket_type, event: event) }
  let(:order) { create(:order, event: event) }
  let(:ticket) { create(:ticket, order: order, ticket_type: ticket_type, event: event, attendee_name: "Jane Doe") }

  describe "GET /api/v1/tickets/:credential" do
    it "returns ticket details and a separate scan credential without public PII" do
      get "/api/v1/tickets/#{ticket.display_credential}"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["scan_credential"]).to be_present
      expect(json["scan_credential"]).not_to eq(ticket.display_credential)
      expect(json).not_to have_key("attendee_name")
      expect(json).not_to have_key("attendee_email")
      expect(json["event"]["title"]).to eq(event.title)
      expect(json["ticket_type"]["name"]).to eq(ticket_type.name)
    end

    it "returns 404 for unknown qr_code" do
      get "/api/v1/tickets/nonexistent"

      expect(response).to have_http_status(:not_found)
    end


    it "rejects a revoked display credential" do
      credential = ticket.display_credential
      ticket.revoke_display_credential!

      get "/api/v1/tickets/#{credential}"

      expect(response).to have_http_status(:not_found)
    end

    it "does not expose a scan credential after the ticket is cancelled" do
      ticket.update!(status: :cancelled, cancelled_at: Time.current)

      get "/api/v1/tickets/#{ticket.display_credential}"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["scan_credential"]).to be_nil
      expect(response.parsed_body["admission_allowed"]).to be(false)
    end

    it "keeps a cancelled ticket record viewable after its free order closes" do
      order.update!(status: :cancelled)
      ticket.update!(status: :cancelled, cancelled_at: Time.current)

      get "/api/v1/tickets/#{ticket.display_credential}"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("status" => "cancelled", "scan_credential" => nil)
    end
  end

  describe "GET /api/v1/tickets/:credential/download" do
    it "returns a PDF file" do
      get "/api/v1/tickets/#{ticket.display_credential}/download"

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/pdf")
      expect(response.headers["Content-Disposition"]).to include("attachment")
      expect(response.headers["Content-Disposition"]).to include(".pdf")
    end

    it "returns 404 for unknown qr_code" do
      get "/api/v1/tickets/nonexistent/download"

      expect(response).to have_http_status(:not_found)
    end


    it "does not generate a downloadable artifact for a cancelled ticket" do
      ticket.update!(status: :cancelled, cancelled_at: Time.current)

      get "/api/v1/tickets/#{ticket.display_credential}/download"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/tickets/:credential/wallet/apple" do
    it "returns 501 not implemented" do
      get "/api/v1/tickets/#{ticket.display_credential}/wallet/apple"

      expect(response).to have_http_status(:not_implemented)
      json = JSON.parse(response.body)
      expect(json["error"]).to include("Coming soon")
    end
  end

  describe "GET /api/v1/tickets/:credential/wallet/google" do
    it "returns 501 not implemented" do
      get "/api/v1/tickets/#{ticket.display_credential}/wallet/google"

      expect(response).to have_http_status(:not_implemented)
      json = JSON.parse(response.body)
      expect(json["error"]).to include("Coming soon")
    end
  end
end
