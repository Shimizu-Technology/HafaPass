require "rails_helper"

RSpec.describe "Api::V1::Waitlist", type: :request do
  let(:organizer_profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile, starts_at: 5.days.from_now) }
  let!(:ga_ticket) { create(:ticket_type, event: event, name: "General Admission", price_cents: 2500, quantity_available: 100) }

  describe "POST /api/v1/events/:slug/waitlist" do
    let(:valid_params) do
      { email: "fan@example.com", name: "Test Fan", quantity: 2, ticket_type_id: ga_ticket.id }
    end

    it "creates a waitlist entry and returns position" do
      post "/api/v1/events/#{event.slug}/waitlist", params: valid_params
      expect(response).to have_http_status(:created)

      json = JSON.parse(response.body)
      expect(json["email"]).to eq("fan@example.com")
      expect(json["position"]).to eq(1)
      expect(json["quantity"]).to eq(2)
      expect(json["status"]).to eq("waiting")
    end

    it "auto-increments position" do
      create(:waitlist_entry, event: event, ticket_type: ga_ticket, email: "first@example.com")

      post "/api/v1/events/#{event.slug}/waitlist", params: valid_params
      json = JSON.parse(response.body)
      expect(json["position"]).to eq(2)
    end

    it "prevents duplicate entries for same email + ticket type" do
      create(:waitlist_entry, event: event, ticket_type: ga_ticket, email: "fan@example.com")

      post "/api/v1/events/#{event.slug}/waitlist", params: valid_params
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "rejects invalid email" do
      post "/api/v1/events/#{event.slug}/waitlist", params: { email: "bad", name: "Test" }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "rejects quantity > 10" do
      post "/api/v1/events/#{event.slug}/waitlist", params: valid_params.merge(quantity: 11)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "allows entry without ticket_type_id (any ticket)" do
      post "/api/v1/events/#{event.slug}/waitlist", params: { email: "any@example.com", name: "Any Fan" }
      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json["ticket_type_id"]).to be_nil
    end
  end

  describe "GET /api/v1/events/:slug/waitlist/status" do
    it "returns entries for given email" do
      entry = create(:waitlist_entry, event: event, ticket_type: ga_ticket, email: "fan@example.com")

      get "/api/v1/events/#{event.slug}/waitlist/status", params: { email: "fan@example.com" }
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["entries"].length).to eq(1)
      expect(json["entries"][0]["position"]).to eq(entry.position)
    end

    it "returns empty when email not found" do
      get "/api/v1/events/#{event.slug}/waitlist/status", params: { email: "nobody@example.com" }
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["entries"]).to be_empty
    end

    it "requires email param" do
      get "/api/v1/events/#{event.slug}/waitlist/status"
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "DELETE /api/v1/events/:slug/waitlist" do
    it "cancels active waitlist entries" do
      create(:waitlist_entry, event: event, ticket_type: ga_ticket, email: "fan@example.com")

      delete "/api/v1/events/#{event.slug}/waitlist", params: { email: "fan@example.com" }
      expect(response).to have_http_status(:no_content)
      expect(WaitlistEntry.last.status).to eq("cancelled")
    end

    it "returns 404 when no entries found" do
      delete "/api/v1/events/#{event.slug}/waitlist", params: { email: "nobody@example.com" }
      expect(response).to have_http_status(:not_found)
    end
  end
end
