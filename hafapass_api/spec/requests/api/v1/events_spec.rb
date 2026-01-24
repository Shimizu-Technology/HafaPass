require "rails_helper"

RSpec.describe "Api::V1::Events", type: :request do
  let(:organizer_profile) { create(:organizer_profile) }

  describe "GET /api/v1/events" do
    it "returns only published upcoming events" do
      published_upcoming = create(:event, :published, organizer_profile: organizer_profile, starts_at: 3.days.from_now)
      create(:event, organizer_profile: organizer_profile) # draft
      create(:event, :published, organizer_profile: organizer_profile, starts_at: 3.days.ago) # past
      create(:event, :cancelled, organizer_profile: organizer_profile) # cancelled

      get "/api/v1/events"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.length).to eq(1)
      expect(json.first["id"]).to eq(published_upcoming.id)
    end

    it "orders events by starts_at ascending" do
      later = create(:event, :published, organizer_profile: organizer_profile, starts_at: 10.days.from_now)
      sooner = create(:event, :published, organizer_profile: organizer_profile, starts_at: 2.days.from_now)

      get "/api/v1/events"

      json = JSON.parse(response.body)
      expect(json.first["id"]).to eq(sooner.id)
      expect(json.last["id"]).to eq(later.id)
    end

    it "returns event attributes including organizer info" do
      event = create(:event, :published, organizer_profile: organizer_profile, starts_at: 5.days.from_now)

      get "/api/v1/events"

      json = JSON.parse(response.body).first
      expect(json["title"]).to eq(event.title)
      expect(json["slug"]).to eq(event.slug)
      expect(json["venue_name"]).to eq(event.venue_name)
      expect(json["status"]).to eq("published")
      expect(json["organizer"]["business_name"]).to eq(organizer_profile.business_name)
    end

    it "returns empty array when no published events exist" do
      create(:event, organizer_profile: organizer_profile) # draft only

      get "/api/v1/events"

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq([])
    end
  end

  describe "GET /api/v1/events/:slug" do
    it "returns a published event with ticket types" do
      event = create(:event, :published, organizer_profile: organizer_profile, starts_at: 5.days.from_now)
      ga = create(:ticket_type, event: event, name: "General Admission", price_cents: 2500, sort_order: 0)
      vip = create(:ticket_type, :vip, event: event, sort_order: 1)

      get "/api/v1/events/#{event.slug}"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["id"]).to eq(event.id)
      expect(json["title"]).to eq(event.title)
      expect(json["ticket_types"].length).to eq(2)
      expect(json["ticket_types"].first["name"]).to eq("General Admission")
      expect(json["ticket_types"].first["price_cents"]).to eq(2500)
      expect(json["ticket_types"].last["name"]).to eq("VIP")
    end

    it "returns 404 for non-existent slug" do
      get "/api/v1/events/nonexistent-slug"

      expect(response).to have_http_status(:not_found)
      json = JSON.parse(response.body)
      expect(json["error"]).to eq("Event not found")
    end

    it "returns 404 for draft events" do
      event = create(:event, organizer_profile: organizer_profile) # draft

      get "/api/v1/events/#{event.slug}"

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for cancelled events" do
      event = create(:event, :cancelled, organizer_profile: organizer_profile)

      get "/api/v1/events/#{event.slug}"

      expect(response).to have_http_status(:not_found)
    end

    it "includes ticket type availability info" do
      event = create(:event, :published, organizer_profile: organizer_profile, starts_at: 5.days.from_now)
      create(:ticket_type, event: event, quantity_available: 100, quantity_sold: 30)

      get "/api/v1/events/#{event.slug}"

      json = JSON.parse(response.body)
      tt = json["ticket_types"].first
      expect(tt["quantity_available"]).to eq(100)
      expect(tt["quantity_sold"]).to eq(30)
    end
  end
end
