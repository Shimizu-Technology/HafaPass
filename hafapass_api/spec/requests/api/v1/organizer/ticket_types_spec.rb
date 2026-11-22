# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Organizer TicketTypes pass configuration, sync_pass_holders, stats, and guards", type: :request do
  let(:owner) { create(:user) }
  let(:profile) { create(:organizer_profile, user: owner) }
  let(:org) { profile.organization }
  let(:headers) { auth_headers(owner).merge("X-Organization-Id" => org.id.to_s) }
  let(:pass_event) do
    create(:event, :published, organizer_profile: profile, organization: org,
      title: "Season Pass Event", max_capacity: 50, starts_at: 2.days.from_now, ends_at: 10.days.from_now)
  end
  let(:night_1) do
    create(:event, :published, organizer_profile: profile, organization: org,
      title: "Night 1", max_capacity: 20, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 3.hours)
  end
  let(:night_2) do
    create(:event, :published, organizer_profile: profile, organization: org,
      title: "Night 2", max_capacity: 20, starts_at: 3.days.from_now, ends_at: 3.days.from_now + 3.hours)
  end
  let(:night_3) do
    create(:event, :published, organizer_profile: profile, organization: org,
      title: "Championship Night", max_capacity: 20, starts_at: 4.days.from_now, ends_at: 4.days.from_now + 3.hours)
  end

  before do
    allow(EmailService).to receive(:send_order_confirmation_async)
  end

  describe "POST / PATCH / GET organizer ticket_types with included_event_ids" do
    it "creates, serializes, and updates a multi-night pass preserving included_event_ids order" do
      post "/api/v1/organizer/events/#{pass_event.id}/ticket_types",
        params: {
          name: "All-Tourney Pass",
          price_cents: 5000,
          quantity_available: 30,
          included_event_ids: [night_2.id, night_1.id]
        },
        headers: headers

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["is_pass"]).to be(true)
      expect(body["included_event_ids"]).to eq([night_2.id, night_1.id])

      tt_id = body["id"]
      get "/api/v1/organizer/events/#{pass_event.id}/ticket_types", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.sole).to include("id" => tt_id, "is_pass" => true, "included_event_ids" => [night_2.id, night_1.id])

      # Reorder and add night_3
      patch "/api/v1/organizer/events/#{pass_event.id}/ticket_types/#{tt_id}",
        params: { included_event_ids: [night_1.id, night_2.id, night_3.id] },
        headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["included_event_ids"]).to eq([night_1.id, night_2.id, night_3.id])
      expect(TicketType.find(tt_id).ticket_type_included_events.pluck(:included_event_id, :position)).to eq([
        [night_1.id, 0], [night_2.id, 1], [night_3.id, 2]
      ])

      # Rejects cross-organization event
      other_event = create(:event, :published)
      patch "/api/v1/organizer/events/#{pass_event.id}/ticket_types/#{tt_id}",
        params: { included_event_ids: [night_1.id, other_event.id] },
        headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(TicketType.find(tt_id).ticket_type_included_events.pluck(:included_event_id)).to eq([night_1.id, night_2.id, night_3.id])
    end

    it "refuses removing an already-linked event once passes have been sold" do
      tt = create(:ticket_type, event: pass_event, name: "Season Pass", price_cents: 5000, quantity_available: 20)
      TicketTypeIncludedEvent.create!(ticket_type: tt, included_event: night_1, position: 0)
      TicketTypeIncludedEvent.create!(ticket_type: tt, included_event: night_2, position: 1)

      Commerce::OrderCreator.call(
        event: pass_event,
        line_items: [{ ticket_type_id: tt.id, quantity: 1 }],
        buyer_email: "buyer@example.com",
        buyer_name: "Buyer",
        payment_required: false
      )

      patch "/api/v1/organizer/events/#{pass_event.id}/ticket_types/#{tt.id}",
        params: { included_event_ids: [night_1.id] },
        headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(tt.reload.ticket_type_included_events.pluck(:included_event_id)).to eq([night_1.id, night_2.id])
    end
  end

  describe "POST /api/v1/organizer/events/:event_id/ticket_types/:id/sync_pass_holders" do
    let!(:pass_tt) do
      tt = create(:ticket_type, event: pass_event, name: "Season Pass", price_cents: 5000, quantity_available: 20)
      TicketTypeIncludedEvent.create!(ticket_type: tt, included_event: night_1, position: 0)
      tt.reload
    end

    it "idempotently backfills newly added nights, audits the action, and rolls back atomically on insufficient capacity" do
      order1 = Commerce::OrderCreator.call(
        event: pass_event,
        line_items: [{ ticket_type_id: pass_tt.id, quantity: 2 }],
        buyer_email: "fan1@example.com",
        buyer_name: "Fan 1",
        payment_required: false
      ).order
      expect(order1.tickets.where(event: night_1).count).to eq(2)

      # Add night_2 (capacity 20) and night_3 (capacity 1 -> insufficient for 2 pass holders!)
      night_3.update!(max_capacity: 1)
      patch "/api/v1/organizer/events/#{pass_event.id}/ticket_types/#{pass_tt.id}",
        params: { included_event_ids: [night_1.id, night_2.id, night_3.id] },
        headers: headers
      expect(response).to have_http_status(:ok)

      # Sync fails with 422 and ZERO partial issuance on night_2 OR night_3
      post "/api/v1/organizer/events/#{pass_event.id}/ticket_types/#{pass_tt.id}/sync_pass_holders", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Championship Night")
      expect(Ticket.where(event: night_2).count).to eq(0)
      expect(Ticket.where(event: night_3).count).to eq(0)

      # Raise night_3 capacity -> sync succeeds and creates 4 missing child tickets (2 on night_2 + 2 on night_3)
      night_3.update!(max_capacity: 5)
      post "/api/v1/organizer/events/#{pass_event.id}/ticket_types/#{pass_tt.id}/sync_pass_holders", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "ticket_type_id" => pass_tt.id,
        "parent_ticket_count" => 2,
        "issued_ticket_count" => 4
      )
      expect(Ticket.where(event: night_2).count).to eq(2)
      expect(Ticket.where(event: night_3).count).to eq(2)
      expect(AuditLog.where(action: "ticket_type.pass_holders_synced", auditable: pass_tt).count).to eq(1)

      # Re-running is idempotent (0 newly issued)
      post "/api/v1/organizer/events/#{pass_event.id}/ticket_types/#{pass_tt.id}/sync_pass_holders", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["issued_ticket_count"]).to eq(0)
    end

    it "forbids staff without manage_inventory or manage_events" do
      scanner = create(:user)
      create(:organization_membership, organization: org, user: scanner, role: :scanner)
      create(:event_staff_assignment, event: pass_event, organization: org, user: scanner, role: :scanner)
      scanner_headers = auth_headers(scanner).merge("X-Organization-Id" => org.id.to_s)

      post "/api/v1/organizer/events/#{pass_event.id}/ticket_types/#{pass_tt.id}/sync_pass_holders", headers: scanner_headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "Buyer cancel_ticket guard, admissions search, and organizer summary/stats" do
    let!(:pass_tt) do
      tt = create(:ticket_type, event: pass_event, name: "Season Pass", price_cents: 0, quantity_available: 20)
      TicketTypeIncludedEvent.create!(ticket_type: tt, included_event: night_1, position: 0)
      TicketTypeIncludedEvent.create!(ticket_type: tt, included_event: night_2, position: 1)
      tt.reload
    end
    let!(:night_1_tt) { create(:ticket_type, event: night_1, name: "Night 1 GA", price_cents: 1000, quantity_available: 10) }

    it "blocks single-night cancellation, hides pass parents from search, and reports accurate summary & stats" do
      buyer = create(:user)
      pass_order = Commerce::OrderCreator.call(
        event: pass_event,
        user: buyer,
        line_items: [{ ticket_type_id: pass_tt.id, quantity: 1 }],
        buyer_email: buyer.email,
        buyer_name: "Pass Holder",
        payment_required: false
      ).order
      night_1_child = pass_order.tickets.find_by!(event: night_1)

      # Buyer cannot cancel a single night child ticket
      post "/api/v1/orders/#{pass_order.id}/tickets/#{night_1_child.id}/cancel", headers: auth_headers(buyer)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Multi-night pass tickets cannot be cancelled one night at a time")

      # Also sell 1 direct ticket on night_1 and check in the pass child
      Commerce::OrderCreator.call(
        event: night_1,
        line_items: [{ ticket_type_id: night_1_tt.id, quantity: 1 }],
        buyer_email: "daily@example.com",
        buyer_name: "Daily Guest",
        payment_required: false
      )
      night_1_child.check_in!

      # Admissions search hides pass parent on pass_event, shows pass child on night_1
      get "/api/v1/organizer/events/#{pass_event.id}/admissions/search", params: { q: "Pass Holder" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to be_empty

      get "/api/v1/organizer/events/#{night_1.id}/admissions/search", params: { q: "Pass Holder" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.map { |t| t["id"] }).to eq([night_1_child.id])

      # Summary excludes pass children: 1 parent pass + 1 direct night ticket = 2
      get "/api/v1/organizer/events/summary", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["tickets_sold"]).to eq(2)

      # Night 1 stats: total_tickets_sold = 1 direct, tickets_checked_in = 1 (pass child), pass_tickets summary populated
      get "/api/v1/organizer/events/#{night_1.id}/stats", headers: headers
      expect(response).to have_http_status(:ok)
      stats = response.parsed_body
      expect(stats["total_tickets_sold"]).to eq(1)
      expect(stats["tickets_checked_in"]).to eq(1)
      expect(stats["pass_tickets"]).to eq(
        "eligible" => 1,
        "checked_in" => 1,
        "by_type" => [
          { "name" => "Season Pass", "eligible" => 1, "checked_in" => 1, "revenue_cents" => 0 }
        ]
      )
    end
  end
end
