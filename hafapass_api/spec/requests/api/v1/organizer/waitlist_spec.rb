require "rails_helper"

RSpec.describe "Api::V1::Organizer::Waitlist", type: :request do
  let(:user) { create(:user, :organizer) }
  let(:organizer_profile) { create(:organizer_profile, user: user) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile, starts_at: 5.days.from_now) }
  let!(:ga_ticket) { create(:ticket_type, event: event, name: "General Admission", price_cents: 2500, quantity_available: 100) }
  let(:headers) { auth_headers(user) }

  before do
    event.organization.update!(marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910",
      marketing_address_certified_at: Time.current)
    allow(EmailService).to receive(:send_waitlist_notification_async)
    allow(EmailService).to receive(:send_waitlist_offer_async)
  end

  describe "POST /api/v1/organizer/events/:event_id/waitlist/:id/offer" do
    it "refuses before reserving inventory when the address is uncertified" do
      event.organization.update!(marketing_address_certified_at: nil)
      entry = create(:waitlist_entry, event: event, ticket_type: ga_ticket)
      before_quantity = ga_ticket.available_quantity
      post "/api/v1/organizer/events/#{event.id}/waitlist/#{entry.id}/offer", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Marketing postal address", "certify")
      expect(entry.reload).to be_waiting
      expect(ga_ticket.reload.available_quantity).to eq(before_quantity)
    end
    it "reserves inventory and queues a single-use offer" do
      entry = create(:waitlist_entry, event: event, ticket_type: ga_ticket, quantity: 2)

      post "/api/v1/organizer/events/#{event.id}/waitlist/#{entry.id}/offer", headers: headers

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("offer", "quantity")).to eq(2)
      expect(entry.reload).to be_offered
      expect(ga_ticket.reload.available_quantity).to eq(98)
      expect(EmailService).to have_received(:send_waitlist_offer_async)
    end

    it "explains a withdrawn delivered offer to the buyer and lets the organizer reissue it" do
      entry = create(:waitlist_entry, event: event, ticket_type: ga_ticket)
      offer = WaitlistOffers::Issuer.call(entry: entry, ticket_type: ga_ticket)
      token = WaitlistCredential.offer(offer)
      delivery = create(:message_delivery, event: event, order: nil, recipient: entry.email,
        template: "waitlist_offer", metadata: { waitlist_offer_id: offer.id }, status: :delivered)
      offer.update!(status: :cancelled, token_version: offer.token_version + 1, cancel_reason: "Inventory withdrawn")
      entry.update!(status: :waiting, expires_at: nil)
      WaitlistDelivery.reconcile_success!(delivery)

      get "/api/v1/waitlist_offers/#{token}"
      expect(response).to have_http_status(:gone)
      expect(response.parsed_body).to include("code" => "offer_withdrawn", "event_slug" => event.slug)

      get "/api/v1/organizer/events/#{event.id}/waitlist", headers: headers
      expect(response.parsed_body.fetch("waitlist").first["withdrawn_offer_delivered"]).to be(true)

      post "/api/v1/organizer/events/#{event.id}/waitlist/#{entry.id}/offer", headers: headers
      expect(response).to have_http_status(:created)
      expect(entry.reload).to be_offered
      expect(response.parsed_body.dig("offer", "id")).not_to eq(offer.id)
    end
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
    it "refuses before marking an alert notified when the address is uncertified" do
      event.organization.update!(marketing_address_certified_at: nil)
      entry = create(:waitlist_entry, event: event, ticket_type: ga_ticket)
      post "/api/v1/organizer/events/#{event.id}/waitlist/#{entry.id}/notify", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["settings_url"]).to eq("/dashboard/settings")
      expect(entry.reload).to be_waiting
    end
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

  describe "POST /api/v1/organizer/events/:event_id/waitlist/:id/retry_unconfirmed" do
    it "requires an unconfirmed round and creates only one explicit retry" do
      entry = create(:waitlist_entry, :notified, event: event, ticket_type: ga_ticket,
        delivery_failure: WaitlistDelivery::UNCONFIRMED)
      path = "/api/v1/organizer/events/#{event.id}/waitlist/#{entry.id}/retry_unconfirmed"

      post path, headers: headers
      expect(response).to have_http_status(:ok)
      expect(entry.reload.delivery_failure).to be_nil
      expect(EmailService).to have_received(:send_waitlist_notification_async).once

      post path, headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(EmailService).to have_received(:send_waitlist_notification_async).once
    end

    it "accepts an unconfirmed active offer without replacing the offer" do
      entry = create(:waitlist_entry, event: event, ticket_type: ga_ticket)
      offer = WaitlistOffers::Issuer.call(entry: entry)
      entry.update!(delivery_failure: WaitlistDelivery::UNCONFIRMED)

      post "/api/v1/organizer/events/#{event.id}/waitlist/#{entry.id}/retry_unconfirmed", headers: headers

      expect(response).to have_http_status(:ok)
      expect(offer.reload).to be_offered
      expect(entry.reload.delivery_failure).to be_nil
      expect(EmailService).to have_received(:send_waitlist_offer_async).with(offer, hash_including(:idempotency_key))
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
    it "cancels a waitlist entry while preserving its history" do
      entry = create(:waitlist_entry, event: event, ticket_type: ga_ticket)

      delete "/api/v1/organizer/events/#{event.id}/waitlist/#{entry.id}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(entry.reload).to be_cancelled
    end
  end
end
