require "rails_helper"

RSpec.describe "Api::V1::Organizer::Events", type: :request do
  let(:user) { create(:user, :organizer) }
  let!(:organizer_profile) { create(:organizer_profile, user: user) }
  let(:headers) { auth_headers(user) }

  describe "GET /api/v1/organizer/events" do
    it "returns the organizer's events" do
      event1 = create(:event, organizer_profile: organizer_profile, title: "Event 1")
      event2 = create(:event, :published, organizer_profile: organizer_profile, title: "Event 2")

      get "/api/v1/organizer/events", headers: headers

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      events = json["events"]
      expect(events.length).to eq(2)
      titles = events.map { |e| e["title"] }
      expect(titles).to include("Event 1", "Event 2")
    end

    it "does not return other organizers' events" do
      other_profile = create(:organizer_profile)
      create(:event, organizer_profile: other_profile)
      create(:event, organizer_profile: organizer_profile)

      get "/api/v1/organizer/events", headers: headers

      json = JSON.parse(response.body)
      events = json["events"]
      expect(events.length).to eq(1)
    end

    it "returns 401 without authentication" do
      get "/api/v1/organizer/events"

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 without organizer profile" do
      user_without_profile = create(:user)
      headers = auth_headers(user_without_profile)

      get "/api/v1/organizer/events", headers: headers

      expect(response).to have_http_status(:forbidden)
      json = JSON.parse(response.body)
      expect(json["error"]).to eq("Organizer profile required")
    end

    it "orders events by created_at descending" do
      old_event = create(:event, organizer_profile: organizer_profile, created_at: 2.days.ago)
      new_event = create(:event, organizer_profile: organizer_profile, created_at: 1.day.ago)

      get "/api/v1/organizer/events", headers: headers

      json = JSON.parse(response.body)
      events = json["events"]
      expect(events.first["id"]).to eq(new_event.id)
      expect(events.last["id"]).to eq(old_event.id)
    end
  end

  describe "GET /api/v1/organizer/events/:id" do
    it "returns event with ticket types" do
      event = create(:event, organizer_profile: organizer_profile)
      create(:ticket_type, event: event, name: "GA")
      create(:ticket_type, :vip, event: event)

      get "/api/v1/organizer/events/#{event.id}", headers: headers

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["id"]).to eq(event.id)
      expect(json["ticket_types"].length).to eq(2)
    end

    it "returns 404 for another organizer's event" do
      other_profile = create(:organizer_profile)
      other_event = create(:event, organizer_profile: other_profile)

      get "/api/v1/organizer/events/#{other_event.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/organizer/events" do
    let(:valid_event_params) do
      {
        title: "New Beach Party",
        description: "A party on the beach",
        short_description: "Beach party!",
        venue_name: "Tumon Bay",
        venue_address: "123 Beach Rd",
        venue_city: "Tumon",
        starts_at: 7.days.from_now.iso8601,
        ends_at: (7.days.from_now + 4.hours).iso8601,
        category: "nightlife",
        age_restriction: "twenty_one_plus",
        max_capacity: 200
      }
    end

    it "creates a draft event" do
      post "/api/v1/organizer/events", params: valid_event_params, headers: headers

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json["title"]).to eq("New Beach Party")
      expect(json["status"]).to eq("draft")
      expect(json["venue_name"]).to eq("Tumon Bay")
      expect(json["category"]).to eq("nightlife")
      expect(json["age_restriction"]).to eq("twenty_one_plus")
    end

    it "generates a slug from the title" do
      post "/api/v1/organizer/events", params: valid_event_params, headers: headers

      json = JSON.parse(response.body)
      expect(json["slug"]).to start_with("new-beach-party")
    end

    it "returns 422 with invalid params" do
      post "/api/v1/organizer/events", params: { title: "" }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      json = JSON.parse(response.body)
      expect(json["errors"]).to be_an(Array)
    end

    it "associates event with current organizer" do
      post "/api/v1/organizer/events", params: valid_event_params, headers: headers

      event = Event.last
      expect(event.organizer_profile_id).to eq(organizer_profile.id)
    end
  end

  describe "PUT /api/v1/organizer/events/:id" do
    let!(:event) { create(:event, organizer_profile: organizer_profile, title: "Original Title") }

    it "updates the event" do
      put "/api/v1/organizer/events/#{event.id}", params: { title: "Updated Title" }, headers: headers

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["title"]).to eq("Updated Title")
    end

    it "returns 404 for another organizer's event" do
      other_profile = create(:organizer_profile)
      other_event = create(:event, organizer_profile: other_profile)

      put "/api/v1/organizer/events/#{other_event.id}", params: { title: "Hacked" }, headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/organizer/events/:id" do
    it "deletes the event" do
      event = create(:event, organizer_profile: organizer_profile)

      expect {
        delete "/api/v1/organizer/events/#{event.id}", headers: headers
      }.to change(Event, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end

    it "returns 404 for another organizer's event" do
      other_profile = create(:organizer_profile)
      other_event = create(:event, organizer_profile: other_profile)

      delete "/api/v1/organizer/events/#{other_event.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(Event.exists?(other_event.id)).to be true
    end
  end

  describe "POST /api/v1/organizer/events/:id/publish" do
    it "publishes a draft event" do
      event = create(:event, organizer_profile: organizer_profile)

      post "/api/v1/organizer/events/#{event.id}/publish", headers: headers

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["status"]).to eq("published")
      expect(json["published_at"]).not_to be_nil
    end

    it "returns 422 for already published events" do
      event = create(:event, :published, organizer_profile: organizer_profile)

      post "/api/v1/organizer/events/#{event.id}/publish", headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      json = JSON.parse(response.body)
      expect(json["error"]).to include("Only draft events")
    end

    it "returns 422 for cancelled events" do
      event = create(:event, :cancelled, organizer_profile: organizer_profile)

      post "/api/v1/organizer/events/#{event.id}/publish", headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "GET /api/v1/organizer/events/:id/stats" do
    let(:event) { create(:event, :published, organizer_profile: organizer_profile) }
    let(:ga_type) { create(:ticket_type, event: event, name: "GA", price_cents: 2500, quantity_available: 100) }
    let(:vip_type) { create(:ticket_type, :vip, event: event, price_cents: 7500, quantity_available: 20) }

    before do
      order1 = create(:order, event: event, total_cents: 5525)
      create(:ticket, order: order1, ticket_type: ga_type, event: event)
      create(:ticket, order: order1, ticket_type: ga_type, event: event)

      order2 = create(:order, event: event, total_cents: 8025)
      create(:ticket, order: order2, ticket_type: vip_type, event: event)

      # Checked-in ticket
      order3 = create(:order, event: event, total_cents: 3025)
      create(:ticket, :checked_in, order: order3, ticket_type: ga_type, event: event)

      # Cancelled ticket (shouldn't count)
      order4 = create(:order, event: event, total_cents: 3025)
      create(:ticket, :cancelled, order: order4, ticket_type: ga_type, event: event)
    end

    it "returns correct stats" do
      get "/api/v1/organizer/events/#{event.id}/stats", headers: headers

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["total_tickets_sold"]).to eq(4) # excludes cancelled
      expect(json["total_revenue_cents"]).to eq(5525 + 8025 + 3025 + 3025)
      expect(json["tickets_checked_in"]).to eq(1)
    end

    it "returns tickets_by_type breakdown" do
      get "/api/v1/organizer/events/#{event.id}/stats", headers: headers

      json = JSON.parse(response.body)
      ga = json["tickets_by_type"].find { |t| t["name"] == "GA" }
      vip = json["tickets_by_type"].find { |t| t["name"] == "VIP" }

      expect(ga["sold"]).to eq(3) # 2 issued + 1 checked_in (excludes cancelled)
      expect(vip["sold"]).to eq(1)
    end

    it "returns recent_orders" do
      get "/api/v1/organizer/events/#{event.id}/stats", headers: headers

      json = JSON.parse(response.body)
      expect(json["recent_orders"].length).to eq(4)
      expect(json["recent_orders"].first).to have_key("buyer_name")
      expect(json["recent_orders"].first).to have_key("buyer_email")
      expect(json["recent_orders"].first).to have_key("total_cents")
    end
  end

  describe "GET /api/v1/organizer/events/:id/attendees" do
    it "returns attendee list with check-in status" do
      event = create(:event, :published, organizer_profile: organizer_profile)
      tt = create(:ticket_type, event: event)
      order = create(:order, event: event, buyer_name: "John Doe", buyer_email: "john@test.com")
      ticket1 = create(:ticket, order: order, ticket_type: tt, event: event)
      ticket2 = create(:ticket, :checked_in, order: order, ticket_type: tt, event: event)

      get "/api/v1/organizer/events/#{event.id}/attendees", headers: headers

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      attendees = json["attendees"]
      expect(attendees.length).to eq(2)
      statuses = attendees.map { |a| a["status"] }
      expect(statuses).to include("issued", "checked_in")
      expect(attendees.first).to have_key("attendee_name")
      expect(attendees.first).to have_key("qr_code")
      expect(attendees.first).to have_key("ticket_type")
    end
  end
end
