require "rails_helper"

RSpec.describe "Api::V1::Organizer::Events Clone & Recurrence", type: :request do
  let(:user) { create(:user, :organizer) }
  let!(:organizer_profile) { create(:organizer_profile, user: user) }
  let(:headers) { auth_headers(user) }
  let!(:event) { create(:event, :published, organizer_profile: organizer_profile, title: "Weekly Mixer") }
  let!(:ticket_type) { create(:ticket_type, event: event, name: "GA", price_cents: 2000, quantity_available: 100, quantity_sold: 15) }
  let!(:promo_code) { create(:promo_code, event: event, code: "SAVE10", discount_type: "percentage", discount_value: 10) }

  describe "POST /api/v1/organizer/events/:id/clone" do
    it "clones the event as a draft with (Copy) suffix" do
      post "/api/v1/organizer/events/#{event.id}/clone", headers: headers

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json["title"]).to eq("Weekly Mixer (Copy)")
      expect(json["status"]).to eq("draft")
      expect(json["starts_at"]).to be_nil
      expect(json["ends_at"]).to be_nil
      expect(json["slug"]).not_to eq(event.slug)
    end

    it "clones ticket types with quantity_sold reset to 0" do
      post "/api/v1/organizer/events/#{event.id}/clone", headers: headers

      json = JSON.parse(response.body)
      cloned_tt = json["ticket_types"].first
      expect(cloned_tt["name"]).to eq("GA")
      expect(cloned_tt["price_cents"]).to eq(2000)
      expect(cloned_tt["quantity_available"]).to eq(100)
      expect(cloned_tt["quantity_sold"]).to eq(0)
    end

    it "clones promo codes with current_uses reset to 0" do
      post "/api/v1/organizer/events/#{event.id}/clone", headers: headers

      cloned_event = Event.order(:created_at).last
      cloned_pc = cloned_event.promo_codes.first
      expect(cloned_pc.code).to eq("SAVE10")
      expect(cloned_pc.current_uses).to eq(0)
    end

    it "does not clone orders" do
      create(:order, event: event, status: :completed)

      post "/api/v1/organizer/events/#{event.id}/clone", headers: headers

      cloned_event = Event.order(:created_at).last
      expect(cloned_event.orders.count).to eq(0)
    end

    it "returns 401 without auth" do
      post "/api/v1/organizer/events/#{event.id}/clone"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /api/v1/organizer/events/:id/generate_recurrences" do
    before do
      event.update!(
        recurrence_rule: "weekly",
        starts_at: 1.week.from_now,
        ends_at: 1.week.from_now + 4.hours
      )
    end

    it "generates recurring events with correct date offsets" do
      post "/api/v1/organizer/events/#{event.id}/generate_recurrences",
        params: { count: 3 }, headers: headers

      expect(response).to have_http_status(:created)
      json = JSON.parse(response.body)
      expect(json["generated_count"]).to eq(3)
      expect(json["events"].length).to eq(3)

      # Check first generated event is 1 week after parent
      first = json["events"].first
      expect(Time.parse(first["starts_at"])).to be_within(1.second).of(event.starts_at + 1.week)
    end

    it "sets recurrence_parent_id on generated events" do
      post "/api/v1/organizer/events/#{event.id}/generate_recurrences",
        params: { count: 2 }, headers: headers

      json = JSON.parse(response.body)
      json["events"].each do |e|
        child = Event.find(e["id"])
        expect(child.recurrence_parent_id).to eq(event.id)
      end
    end

    it "caps at 12 instances" do
      post "/api/v1/organizer/events/#{event.id}/generate_recurrences",
        params: { count: 20 }, headers: headers

      json = JSON.parse(response.body)
      expect(json["generated_count"]).to be <= 12
    end

    it "requires a recurrence rule" do
      event.update!(recurrence_rule: nil)

      post "/api/v1/organizer/events/#{event.id}/generate_recurrences",
        params: { count: 3 }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      json = JSON.parse(response.body)
      expect(json["error"]).to include("recurrence rule")
    end

    it "respects recurrence_end_date" do
      event.update!(recurrence_end_date: 2.weeks.from_now.to_date)

      post "/api/v1/organizer/events/#{event.id}/generate_recurrences",
        params: { count: 5 }, headers: headers

      json = JSON.parse(response.body)
      # Only 1 event should fit (1 week after parent, within 2-week window)
      expect(json["generated_count"]).to be <= 2
    end
  end
end
