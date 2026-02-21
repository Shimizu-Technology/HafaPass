require "rails_helper"

RSpec.describe "Api::V1::Organizer::Waitlist", type: :request do
  let(:user) { create(:user, :organizer) }
  let(:organizer_profile) { create(:organizer_profile, user: user) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile, starts_at: 5.days.from_now) }
  let!(:ga_ticket) { create(:ticket_type, event: event, name: "General Admission", price_cents: 2500, quantity_available: 100) }
  let(:headers) { auth_headers(user) }

  before do
    allow(EmailService).to receive(:send_waitlist_notification_async)
  end

  describe "GET /api/v1/organizer/events/:event_id/waitlist" do
    it "returns paginated waitlist entries with stats" do
      create_list(:waitlist_entry, 3, event: event, ticket_type: ga_ticket)
      create(:waitlist_entry, :notified, event: event, ticket_type: ga_ticket)

      get "/api/v1/organizer/events/#{event.id}/waitlist", headers: headers
      expect(response).to have_http_status(:ok)

      json = JSON.parse(response.body)
      expect(json["waitlist"].length).to eq(4)
      expect(json["stats"]["total_waiting"]).to eq(3)
      expect(json["stats"]["total_notified"]).to eq(1)
      expect(json["meta"]).to be_present
    end

    it "filters by status" do
      create(:waitlist_entry, event: event, ticket_type: ga_ticket)
      create(:waitlist_entry, :notified, event: event, ticket_type: ga_ticket)

      get "/api/v1/organizer/events/#{event.id}/waitlist", params: { status: "waiting" }, headers: headers
      json = JSON.parse(response.body)
      expect(json["waitlist"].length).to eq(1)
    end

    it "requires organizer profile" do
      non_organizer = create(:user)
      get "/api/v1/organizer/events/#{event.id}/waitlist", headers: auth_headers(non_organizer)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/organizer/events/:event_id/waitlist/:id/notify" do
    it "notifies a waiting entry" do
      entry = create(:waitlist_entry, event: event, ticket_type: ga_ticket)

      post "/api/v1/organizer/events/#{event.id}/waitlist/#{entry.id}/notify", headers: headers
      expect(response).to have_http_status(:ok)

      json = JSON.parse(response.body)
      expect(json["status"]).to eq("notified")
      expect(json["notified_at"]).to be_present
      expect(json["expires_at"]).to be_present
      expect(EmailService).to have_received(:send_waitlist_notification_async)
    end

    it "rejects notifying non-waiting entry" do
      entry = create(:waitlist_entry, :notified, event: event, ticket_type: ga_ticket)

      post "/api/v1/organizer/events/#{event.id}/waitlist/#{entry.id}/notify", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "POST /api/v1/organizer/events/:event_id/waitlist/notify_next" do
    it "notifies the next N entries in position order" do
      e1 = create(:waitlist_entry, event: event, ticket_type: ga_ticket)
      e2 = create(:waitlist_entry, event: event, ticket_type: ga_ticket)
      e3 = create(:waitlist_entry, event: event, ticket_type: ga_ticket)

      post "/api/v1/organizer/events/#{event.id}/waitlist/notify_next", params: { count: 2 }, headers: headers
      expect(response).to have_http_status(:ok)

      json = JSON.parse(response.body)
      expect(json["count"]).to eq(2)
      expect(json["notified"].map { |n| n["id"] }).to eq([e1.id, e2.id])
      expect(e3.reload.status).to eq("waiting")
    end
  end

  describe "DELETE /api/v1/organizer/events/:event_id/waitlist/:id" do
    it "removes a waitlist entry" do
      entry = create(:waitlist_entry, event: event, ticket_type: ga_ticket)

      delete "/api/v1/organizer/events/#{event.id}/waitlist/#{entry.id}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(WaitlistEntry.find_by(id: entry.id)).to be_nil
    end
  end
end
