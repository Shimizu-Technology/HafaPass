require "rails_helper"

RSpec.describe "Social Proof on Public Events", type: :request do
  let(:organizer_profile) { create(:organizer_profile) }
  let!(:event) { create(:event, :published, organizer_profile: organizer_profile, show_attendees: true) }
  let(:ticket_type) { create(:ticket_type, event: event) }

  def create_attendee(name:, status: :completed)
    order = create(:order, event: event, buyer_name: name, status: status)
    create(:ticket, order: order, event: event, ticket_type: ticket_type) if order.completed?
    order
  end

  describe "GET /api/v1/events/:slug" do
    it "includes attendee_count and attendees_preview" do
      create_attendee(name: "Jerry Shimizu")
      create_attendee(name: "Sarah Johnson")
      get "/api/v1/events/#{event.slug}"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["attendee_count"]).to eq(2)
      expect(json["attendees_preview"]).to include("Jerry S.", "Sarah J.")
    end

    it "does not include attendees_preview when show_attendees is false" do
      event.update!(show_attendees: false)
      create_attendee(name: "Jerry Shimizu")

      get "/api/v1/events/#{event.slug}"

      json = JSON.parse(response.body)
      expect(json["attendee_count"]).to eq(1)
      expect(json["attendees_preview"]).to eq([])
    end

    it "does not count pending orders" do
      create_attendee(name: "Jerry Shimizu")
      create_attendee(name: "Pending Person", status: :pending)

      get "/api/v1/events/#{event.slug}"

      json = JSON.parse(response.body)
      expect(json["attendee_count"]).to eq(1)
    end
  end
end
