require "rails_helper"

RSpec.describe "Social Proof on Public Events", type: :request do
  let(:organizer_profile) { create(:organizer_profile) }
  let!(:event) { create(:event, :published, organizer_profile: organizer_profile, show_attendees: true) }

  describe "GET /api/v1/events/:slug" do
    it "includes attendee_count and attendees_preview" do
      create(:order, event: event, buyer_name: "Jerry Shimizu", status: :completed)
      create(:order, event: event, buyer_name: "Sarah Johnson", status: :completed)
      get "/api/v1/events/#{event.slug}"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["attendee_count"]).to eq(2)
      expect(json["attendees_preview"]).to include("Jerry S.", "Sarah J.")
    end

    it "does not include attendees_preview when show_attendees is false" do
      event.update!(show_attendees: false)
      create(:order, event: event, buyer_name: "Jerry Shimizu", status: :completed)

      get "/api/v1/events/#{event.slug}"

      json = JSON.parse(response.body)
      expect(json["attendee_count"]).to eq(1)
      expect(json["attendees_preview"]).to eq([])
    end

    it "does not count pending orders" do
      create(:order, event: event, buyer_name: "Jerry Shimizu", status: :completed)
      create(:order, :pending, event: event, buyer_name: "Pending Person")

      get "/api/v1/events/#{event.slug}"

      json = JSON.parse(response.body)
      expect(json["attendee_count"]).to eq(1)
    end
  end
end
