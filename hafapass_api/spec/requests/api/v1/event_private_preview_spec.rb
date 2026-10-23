require "rails_helper"

RSpec.describe "Private event previews", type: :request do
  let(:owner) { create(:user, :organizer) }
  let(:profile) { create(:organizer_profile, user: owner) }
  let(:event) { create(:event, :published, :featured, organizer_profile: profile, organization: profile.organization, title: "Private Island Show") }
  let(:headers) { auth_headers(owner).merge("X-Organization-Id" => profile.organization_id.to_s) }

  before do
    allow(Rails.env).to receive(:production?).and_return(true)
    create(:ticket_type, event: event, price_cents: 0)
  end

  it "hides unverified and suspended events across public discovery and direct URLs" do
    venue = create(:venue)
    event.update!(venue: venue)
    collection = create(:marketplace_collection)
    collection.marketplace_collection_events.create!(event: event, position: 0)
    ["/api/v1/events", "/api/v1/events?q=Private", "/api/v1/events?featured=true",
      "/api/v1/organizers", "/api/v1/venues", "/api/v1/venues/#{venue.slug}",
      "/api/v1/marketplace_collections"].each do |path|
      get path
      expect(response.body).not_to include(event.slug), path
    end
    ["/api/v1/events/#{event.slug}", "/api/v1/organizers/#{profile.organization.slug}",
      "/og/events/#{event.slug}", "/api/v1/marketplace_collections/#{collection.slug}"].each do |path|
      get path
      expect(response).to have_http_status(:not_found), path
    end
    get "/sitemap.xml"
    expect(response.body).not_to include(event.slug)

    profile.update!(verification_status: :verified)
    get "/api/v1/events/#{event.slug}"
    expect(response).to have_http_status(:ok)
    get "/api/v1/events?q=Private"
    expect(response.parsed_body.fetch("events").pluck("id")).to include(event.id)
    get "/sitemap.xml"
    expect(response.body).to include(event.slug)

    profile.update!(verification_status: :suspended)
    get "/api/v1/events/#{event.slug}"
    expect(response).to have_http_status(:not_found), response.body
    get "/api/v1/events"
    expect(response.body).not_to include(event.slug)
  end

  it "uses a digest-backed token and revokes old links on rotation" do
    get "/api/v1/organizer/events/#{event.id}/preview_link", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("url")).to include("/preview#t=")
    first = response.parsed_body.fetch("url").split("#t=").last
    expect(event.reload.preview_token_digest).to eq(Digest::SHA256.hexdigest(first))
    get "/api/v1/events/#{event.slug}/private_preview", headers: { "X-Preview-Token" => first }
    expect(response).to have_http_status(:ok)
    expect(response.headers["X-Robots-Tag"]).to include("noindex", "nofollow")
    expect(response.headers["Referrer-Policy"]).to eq("no-referrer")
    expect(response.parsed_body).to include("private_preview" => true, "purchasable" => false)
    get "/api/v1/events/#{event.slug}/private_preview", params: { token: "wrong" }
    expect(response).to have_http_status(:not_found)
    get "/api/v1/events/#{event.slug}/private_preview", params: { token: first }
    expect(response).to have_http_status(:not_found)

    post "/api/v1/organizer/events/#{event.id}/rotate_preview_link", headers: headers
    second = response.parsed_body.fetch("url").split("#t=").last
    expect(second).not_to eq(first)
    get "/api/v1/events/#{event.slug}/private_preview", headers: { "X-Preview-Token" => first }
    expect(response).to have_http_status(:not_found)
    get "/api/v1/events/#{event.slug}/private_preview", headers: { "X-Preview-Token" => second }
    expect(response).to have_http_status(:ok)
    expect(AuditLog.where(action: "event.preview_link_rotated", actor_user: owner)).to exist

    profile.update!(verification_status: :verified)
    get "/api/v1/events/#{event.slug}/private_preview", headers: { "X-Preview-Token" => second }
    expect(response.parsed_body).to eq("redirect_to" => event.slug)
    profile.update!(verification_status: :suspended)
    get "/api/v1/events/#{event.slug}/private_preview", headers: { "X-Preview-Token" => second }
    expect(response).to have_http_status(:not_found)
  end

  it "does not issue a link to an unrelated organizer" do
    stranger = create(:user, :organizer)
    get "/api/v1/organizer/events/#{event.id}/preview_link", headers: auth_headers(stranger)
    expect(response).not_to have_http_status(:ok)
    expect(event.reload.preview_token_digest).to be_nil
  end

  ["unverified", "pending", "suspended"].each do |status|
    it "returns the exact unknown-event checkout response for a #{status} organizer" do
      profile.update!(verification_status: status)
      [{}, { seat_hold_token: "invalid" }, { catalog_items: [{ catalog_item_id: -1 }] }].each do |extra|
        post "/api/v1/orders", params: { event_id: event.id }.merge(extra).to_json,
          headers: { "Content-Type" => "application/json" }
        hidden_response = [response.status, response.body.dup]
        post "/api/v1/orders", params: { event_id: -1 }.merge(extra).to_json,
          headers: { "Content-Type" => "application/json" }
        expect(hidden_response).to eq([response.status, response.body])
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  it "hides event-id and slug buyer endpoints before validation details are returned" do
    buyer = create(:user)
    get "/api/v1/events/#{event.slug}/seating"
    expect(response).to have_http_status(:not_found), response.body
    post "/api/v1/events/#{event.slug}/seat_holds", params: { event_seat_ids: [] }
    expect(response).to have_http_status(:not_found)
    get "/api/v1/events/#{event.slug}/waitlist/status"
    expect(response).to have_http_status(:not_found)
    post "/api/v1/events/#{event.slug}/waitlist", params: { email: "buyer@example.com" }
    expect(response).to have_http_status(:not_found)
    post "/api/v1/promo_codes/validate", params: { event_id: event.id, code: "ANY" }
    expect(response).to have_http_status(:not_found)
    post "/api/v1/me/event_favorites", params: { event_id: event.id }, headers: auth_headers(buyer)
    expect(response).to have_http_status(:not_found)
    post "/api/v1/me/event_referrals", params: { event_id: event.id }, headers: auth_headers(buyer)
    expect(response).to have_http_status(:not_found)
    post "/api/v1/me/event_reminders", params: { event_id: event.id }, headers: auth_headers(buyer)
    expect(response).to have_http_status(:not_found)
  end

  it "hides an existing waitlist offer until its event becomes public again" do
    ticket_type = event.ticket_types.first
    entry = create(:waitlist_entry, event: event, ticket_type: ticket_type)
    offer = create(:waitlist_offer, waitlist_entry: entry, event: event, ticket_type: ticket_type)
    token = WaitlistCredential.offer(offer)
    get "/api/v1/waitlist_offers/#{token}"
    hidden_response = [response.status, response.body.dup]
    get "/api/v1/waitlist_offers/unknown"
    expect(hidden_response).to eq([response.status, response.body])
    expect(response).to have_http_status(:not_found)

    profile.update!(verification_status: :verified)
    get "/api/v1/waitlist_offers/#{token}"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("event_slug" => event.slug,
      "ticket_type_name" => ticket_type.name, "unit_price_cents" => offer.unit_price_cents)

    profile.update!(verification_status: :suspended)
    get "/api/v1/waitlist_offers/#{token}"
    expect([response.status, response.body]).to eq(hidden_response)
  end

  it "keeps existing buyer records, receipts, tickets, QR codes and scanning after suspension" do
    buyer = create(:user)
    profile.update!(verification_status: :verified)
    order = create(:order, event: event, user: buyer, subtotal_cents: 0, service_fee_cents: 0, total_cents: 0)
    ticket = create(:ticket, order: order, ticket_type: event.ticket_types.first, event: event)
    event.update!(transfers_enabled: true)
    allow(LaunchCapabilities).to receive(:enabled?).with(:ticket_transfers).and_return(true)
    profile.update!(verification_status: :suspended)

    get "/api/v1/me/orders", headers: auth_headers(buyer)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(order.reference)
    get "/api/v1/orders/#{order.id}", headers: auth_headers(buyer)
    expect(response).to have_http_status(:ok)
    get "/api/v1/orders/#{order.id}/receipt", headers: auth_headers(buyer)
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to include("pdf")
    refunded_order = create(:order, event: event, user: buyer, subtotal_cents: 1000,
      service_fee_cents: 0, total_cents: 1000)
    payment = create(:payment, :succeeded, order: refunded_order, amount_cents: 1000)
    create(:refund, order: refunded_order, payment: payment, amount_cents: 1000)
    get "/api/v1/me/orders/#{refunded_order.id}", headers: auth_headers(buyer)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("refund_history").length).to eq(1)
    get "/api/v1/tickets/#{ticket.display_credential}", headers: auth_headers(buyer)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("scan_credential")).to eq(ticket.scan_credential)
    post "/api/v1/me/tickets/#{ticket.id}/transfer", params: { recipient_email: "friend@example.com" },
      headers: auth_headers(buyer)
    expect(response).to have_http_status(:created)
    get "/api/v1/me/tickets", headers: auth_headers(buyer)
    expect(response.parsed_body.fetch("tickets").sole.dig("pending_transfer", "recipient_email")).to eq("friend@example.com")
    delete "/api/v1/me/tickets/#{ticket.id}/transfer", headers: auth_headers(buyer)
    expect(response).to have_http_status(:ok)
    post "/api/v1/check_in/#{ticket.scan_credential}", headers: headers
    expect(response).to have_http_status(:ok)
  end

  it "audits and notifies owners of admin verification decisions" do
    admin = create(:user, :admin)
    patch "/api/v1/admin/organizer_profiles/#{profile.id}",
      params: { verification_status: "verified" }, headers: headers
    expect(response).not_to have_http_status(:ok)
    patch "/api/v1/admin/organizer_profiles/#{profile.id}",
      params: { verification_status: "rejected" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_content)
    patch "/api/v1/admin/organizer_profiles/#{profile.id}",
      params: { verification_status: "rejected", verification_notes: "Please link your event page." },
      headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(MessageDelivery.where(template: "verification_decision", recipient: owner.email)).to exist
    expect(AuditLog.where(action: "organizer.verification_updated", actor_user: admin)).to exist

    patch "/api/v1/admin/organizer_profiles/#{profile.id}",
      params: { verification_status: "verified" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(MessageDelivery.where(template: "verification_decision", recipient: owner.email).count).to eq(2)
    expect(event.reload).to be_publicly_visible

    patch "/api/v1/admin/organizer_profiles/#{profile.id}",
      params: { verification_status: "suspended" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(MessageDelivery.where(template: "verification_decision", recipient: owner.email).count).to eq(3)
    expect(event.reload).not_to be_publicly_visible
  end
end
