require "rails_helper"

RSpec.describe "Api::V1::Events", type: :request do
  let(:organizer_profile) { create(:organizer_profile) }

  describe "GET /api/v1/events" do
    it "returns published and completed events, excludes drafts and cancelled" do
      published_upcoming = create(:event, :published, organizer_profile: organizer_profile, starts_at: 3.days.from_now)
      create(:event, organizer_profile: organizer_profile) # draft
      past_published = create(:event, :published, organizer_profile: organizer_profile, starts_at: 3.days.ago) # past but still published
      create(:event, :cancelled, organizer_profile: organizer_profile) # cancelled
      completed = create(:event, :completed, organizer_profile: organizer_profile, starts_at: 5.days.ago) # completed

      get "/api/v1/events"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      events = json["events"]
      event_ids = events.map { |e| e["id"] }
      expect(event_ids).to include(published_upcoming.id)
      expect(event_ids).to include(past_published.id)
      expect(event_ids).to include(completed.id)
      expect(events.length).to eq(3)
    end

    it "orders events by starts_at ascending" do
      later = create(:event, :published, organizer_profile: organizer_profile, starts_at: 10.days.from_now)
      sooner = create(:event, :published, organizer_profile: organizer_profile, starts_at: 2.days.from_now)

      get "/api/v1/events"

      json = JSON.parse(response.body)
      events = json["events"]
      expect(events.first["id"]).to eq(sooner.id)
      expect(events.last["id"]).to eq(later.id)
    end

    it "returns event attributes including organizer info" do
      event = create(:event, :published, organizer_profile: organizer_profile, starts_at: 5.days.from_now)

      get "/api/v1/events"

      json = JSON.parse(response.body)
      first_event = json["events"].first
      expect(first_event["title"]).to eq(event.title)
      expect(first_event["slug"]).to eq(event.slug)
      expect(first_event["venue_name"]).to eq(event.venue_name)
      expect(first_event["status"]).to eq("published")
      expect(first_event["organizer"]["business_name"]).to eq(organizer_profile.business_name)
    end

    it "returns empty array when no published events exist" do
      create(:event, organizer_profile: organizer_profile) # draft only

      get "/api/v1/events"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["events"]).to eq([])
      expect(json["meta"]).to be_present
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

    it "allows organizer to preview their own draft events" do
      user = create(:user, :organizer)
      org_profile = create(:organizer_profile, user: user)
      draft_event = create(:event, organizer_profile: org_profile)

      get "/api/v1/events/#{draft_event.slug}?preview=true", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["id"]).to eq(draft_event.id)
    end

    it "returns completed events publicly" do
      event = create(:event, :completed, organizer_profile: organizer_profile, starts_at: 5.days.ago)

      get "/api/v1/events/#{event.slug}"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["status"]).to eq("completed")
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
