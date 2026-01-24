require "rails_helper"

RSpec.describe "Api::V1::CheckIns", type: :request do
  let(:organizer_profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile, starts_at: 1.day.from_now) }
  let(:ticket_type) { create(:ticket_type, event: event) }
  let(:order) { create(:order, event: event) }

  describe "POST /api/v1/check_in/:qr_code" do
    context "with a valid issued ticket" do
      let(:ticket) { create(:ticket, order: order, ticket_type: ticket_type, event: event) }

      it "checks in the ticket successfully" do
        post "/api/v1/check_in/#{ticket.qr_code}"

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json["message"]).to eq("Check-in successful")
        expect(json["ticket"]["status"]).to eq("checked_in")
        expect(json["ticket"]["checked_in_at"]).not_to be_nil
      end

      it "updates the ticket status to checked_in" do
        post "/api/v1/check_in/#{ticket.qr_code}"

        ticket.reload
        expect(ticket.status).to eq("checked_in")
        expect(ticket.checked_in_at).to be_within(2.seconds).of(Time.current)
      end

      it "returns event and ticket_type details" do
        post "/api/v1/check_in/#{ticket.qr_code}"

        json = JSON.parse(response.body)
        expect(json["ticket"]["event"]["id"]).to eq(event.id)
        expect(json["ticket"]["event"]["title"]).to eq(event.title)
        expect(json["ticket"]["event"]["venue_name"]).to eq(event.venue_name)
        expect(json["ticket"]["ticket_type"]["id"]).to eq(ticket_type.id)
        expect(json["ticket"]["ticket_type"]["name"]).to eq(ticket_type.name)
      end

      it "returns attendee information" do
        post "/api/v1/check_in/#{ticket.qr_code}"

        json = JSON.parse(response.body)
        expect(json["ticket"]["attendee_name"]).to eq(ticket.attendee_name)
        expect(json["ticket"]["attendee_email"]).to eq(ticket.attendee_email)
      end
    end

    context "with an already checked-in ticket" do
      let(:ticket) { create(:ticket, :checked_in, order: order, ticket_type: ticket_type, event: event) }

      it "returns 422 with error message" do
        post "/api/v1/check_in/#{ticket.qr_code}"

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to eq("Ticket already checked in")
        expect(json["checked_in_at"]).not_to be_nil
      end

      it "does not update the ticket" do
        original_checked_in_at = ticket.checked_in_at

        post "/api/v1/check_in/#{ticket.qr_code}"

        expect(ticket.reload.checked_in_at).to eq(original_checked_in_at)
      end
    end

    context "with a cancelled ticket" do
      let(:ticket) { create(:ticket, :cancelled, order: order, ticket_type: ticket_type, event: event) }

      it "returns 422 with error message" do
        post "/api/v1/check_in/#{ticket.qr_code}"

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to eq("Ticket is cancelled")
      end
    end

    context "with a non-existent QR code" do
      it "returns 404" do
        post "/api/v1/check_in/nonexistent-qr-code"

        expect(response).to have_http_status(:not_found)
        json = JSON.parse(response.body)
        expect(json["error"]).to eq("Ticket not found")
      end
    end

    it "does not require authentication" do
      ticket = create(:ticket, order: order, ticket_type: ticket_type, event: event)

      post "/api/v1/check_in/#{ticket.qr_code}"

      expect(response).to have_http_status(:ok)
    end
  end
end
