require "rails_helper"

RSpec.describe "Assigned seating APIs", type: :request do
  let(:user) { create(:user, :organizer) }
  let(:profile) { create(:organizer_profile, user: user) }
  let(:organization) { profile.organization }
  let(:venue) { create(:venue) }
  let(:event) do
    create(:event, :published, organizer_profile: profile, organization: organization, venue: venue,
      starts_at: 5.days.from_now, max_capacity: 4)
  end
  let!(:ticket_type) { create(:ticket_type, event: event, quantity_available: 4) }
  let(:headers) { auth_headers(user) }

  def create_layout
    post "/api/v1/organizer/venue_layouts", headers: headers, params: {
      venue_id: venue.id,
      name: "Guam Museum Hall",
      publish: true,
      price_zones: [{ name: "Main", code: "MAIN", color: "#2563EB" }],
      sections: [{
        name: "Orchestra",
        code: "ORCH",
        rows: [{
          label: "A",
          seats: [
            { label: "1", position: 1, price_zone_code: "MAIN" },
            { label: "2", position: 2, price_zone_code: "MAIN" }
          ]
        }]
      }]
    }
    response.parsed_body
  end

  it "creates a reusable layout, activates it, and serves a buyer-safe seat map" do
    layout = create_layout
    expect(response).to have_http_status(:created)
    zone_id = layout.fetch("price_zones").first.fetch("id")

    post "/api/v1/organizer/events/#{event.id}/seating", headers: headers, params: {
      venue_layout_id: layout.fetch("id"),
      zone_ticket_types: { zone_id => ticket_type.id }
    }
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("sections", 0, "rows", 0, "seats").length).to eq(2)

    get "/api/v1/events/#{event.slug}/seating"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.to_json).not_to include("buyer_email", "attendee_name", "token_digest")
  end

  it "holds and releases a seat using only the high-entropy bearer token" do
    layout = create_layout
    zone_id = layout.fetch("price_zones").first.fetch("id")
    post "/api/v1/organizer/events/#{event.id}/seating", headers: headers,
      params: { venue_layout_id: layout.fetch("id"), zone_ticket_types: { zone_id => ticket_type.id } }
    event_seat_id = response.parsed_body.dig("sections", 0, "rows", 0, "seats", 0, "id")

    post "/api/v1/events/#{event.slug}/seat_holds",
      params: { event_seat_ids: [event_seat_id], accessibility_attested: false }
    expect(response).to have_http_status(:created)
    token = response.parsed_body.fetch("token")
    expect(token.length).to be >= 40
    expect(SeatHoldSession.last.token_digest).not_to eq(token)

    delete "/api/v1/events/#{event.slug}/seat_holds", params: { token: token }
    expect(response).to have_http_status(:ok)
    expect(SeatHoldSession.last.reload).to be_status_released
  end

  it "refuses to release a seat session after checkout has claimed it" do
    layout = create_layout
    zone_id = layout.fetch("price_zones").first.fetch("id")
    post "/api/v1/organizer/events/#{event.id}/seating", headers: headers,
      params: { venue_layout_id: layout.fetch("id"), zone_ticket_types: { zone_id => ticket_type.id } }
    event_seat_id = response.parsed_body.dig("sections", 0, "rows", 0, "seats", 0, "id")
    post "/api/v1/events/#{event.slug}/seat_holds", params: { event_seat_ids: [event_seat_id] }
    token = response.parsed_body.fetch("token")
    order = create(:order, :pending, event: event, expires_at: 10.minutes.from_now)
    item = create(:order_item, order: order, ticket_type: ticket_type)
    session = Seating::SessionLifecycle.claim!(token: token, event: event, order: order, order_items: [item])

    delete "/api/v1/events/#{event.slug}/seat_holds", params: { token: token }

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error")).to match(/already been used for checkout/)
    expect(session.reload).to be_status_claimed
    expect(order.reload).to be_pending
  end

  it "does not let another authenticated user release an owned hold" do
    layout = create_layout
    zone_id = layout.fetch("price_zones").first.fetch("id")
    post "/api/v1/organizer/events/#{event.id}/seating", headers: headers,
      params: { venue_layout_id: layout.fetch("id"), zone_ticket_types: { zone_id => ticket_type.id } }
    event_seat_id = response.parsed_body.dig("sections", 0, "rows", 0, "seats", 0, "id")
    post "/api/v1/events/#{event.slug}/seat_holds", headers: headers, params: { event_seat_ids: [event_seat_id] }
    token = response.parsed_body.fetch("token")
    session = SeatHoldSession.last

    delete "/api/v1/events/#{event.slug}/seat_holds", headers: auth_headers(create(:user)), params: { token: token }

    expect(response).to have_http_status(:not_found)
    expect(session.reload).to be_status_active
  end

  it "requires inventory permission for organizer seating controls" do
    layout = create_layout
    zone_id = layout.fetch("price_zones").first.fetch("id")
    post "/api/v1/organizer/events/#{event.id}/seating", headers: headers,
      params: { venue_layout_id: layout.fetch("id"), zone_ticket_types: { zone_id => ticket_type.id } }
    expect(response).to have_http_status(:created)

    marketer = create(:user)
    create(:organization_membership, organization: organization, user: marketer, role: :marketer)
    post "/api/v1/organizer/events/#{event.id}/seating/suspend",
      headers: auth_headers(marketer), params: { reason: "Unauthorized test" }

    expect(response).to have_http_status(:forbidden)
    expect(event.reload.sales_suspended_at).to be_nil
  end

  it "rejects malformed zone mappings before they reach seating configuration" do
    layout = create_layout

    post "/api/v1/organizer/events/#{event.id}/seating", headers: headers, params: {
      venue_layout_id: layout.fetch("id"),
      zone_ticket_types: { "not-a-zone" => ticket_type.id }
    }

    expect(response).to have_http_status(:bad_request)
    expect(event.reload.event_seating_configuration).to be_nil
  end

  it "audits emergency sales suspension and resumption" do
    post "/api/v1/organizer/events/#{event.id}/seating/suspend", headers: headers, params: { reason: "Venue evacuation" }
    expect(response).to have_http_status(:ok)
    expect(event.reload.sales_suspension_reason).to eq("Venue evacuation")

    post "/api/v1/organizer/events/#{event.id}/seating/resume", headers: headers
    expect(response).to have_http_status(:ok)
    expect(event.reload.sales_suspended_at).to be_nil
    expect(event.seat_audit_events.pluck(:action)).to eq(["seating.sales_suspended", "seating.sales_resumed"])
  end
end
