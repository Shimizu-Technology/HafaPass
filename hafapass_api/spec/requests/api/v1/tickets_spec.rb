require "rails_helper"
require "pdf/reader"

RSpec.describe "Api::V1::Tickets", type: :request do
  let(:organizer_profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: organizer_profile) }
  let(:ticket_type) { create(:ticket_type, event: event) }
  let(:order) { create(:order, event: event) }
  let(:ticket) { create(:ticket, order: order, ticket_type: ticket_type, event: event, attendee_name: "Jane Doe") }

  describe "GET /api/v1/tickets/:credential" do
    it "directs a paid transferred holder to support after postponement" do
      recipient = create(:user)
      ticket.update!(holder_user: recipient)
      event.update!(status: :postponed)
      event.event_changes.create!(change_type: "postponed", occurred_at: 1.second.from_now,
        before_data: { status: "published" }, after_data: { status: "postponed" })
      get "/api/v1/tickets/#{ticket.display_credential}", headers: auth_headers(recipient)
      expect(response.parsed_body.fetch("event_change_refund_contact_support")).to be(true)
      get "/api/v1/tickets/#{ticket.display_credential}"
      expect(response.parsed_body.fetch("event_change_refund_contact_support")).to be(false)
    end

    it "counts the buyer fee when a full promotion leaves only the fee paid" do
      recipient = create(:user)
      promo_order = create(:order, event: event, subtotal_cents: 2500, discount_cents: 2500, service_fee_cents: 125, total_cents: 125)
      item = create(:order_item, order: promo_order, ticket_type: ticket_type, quantity: 1, unit_price_cents: 2500,
        subtotal_cents: 2500, discount_cents: 2500, fee_cents: 125)
      promo_ticket = create(:ticket, order: promo_order, order_item: item, ticket_type: ticket_type, event: event, holder_user: recipient)
      event.update!(status: :postponed)
      event.event_changes.create!(change_type: "postponed", occurred_at: 1.second.from_now,
        before_data: { status: "published" }, after_data: { status: "postponed" })

      get "/api/v1/tickets/#{promo_ticket.display_credential}", headers: auth_headers(recipient)

      expect(response.parsed_body.fetch("event_change_refund_contact_support")).to be(true)
    end

    it "returns only the public focal point alongside the image host and cover" do
      event.update!(page_customization: { focal_point: { x: 20, y: 80 }, accent: "#123456" })
      get "/api/v1/tickets/#{ticket.display_credential}"

      expect(response.parsed_body.fetch("event")).to include(
        "cover_image_url" => event.cover_image_url,
        "image_asset_host" => S3Service.public_asset_host,
        "page_customization" => { "focal_point" => { "x" => 20, "y" => 80 } }
      )
    end
    it "returns ticket details without admission authority or public PII" do
      get "/api/v1/tickets/#{ticket.display_credential}"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["scan_credential"]).to be_nil
      expect(json).not_to have_key("attendee_name")
      expect(json).not_to have_key("attendee_email")
      expect(json["event"]["title"]).to eq(event.title)
      expect(json["ticket_type"]["name"]).to eq(ticket_type.name)
      expect(json["wallet_availability"]).to eq("apple" => false, "google" => false)
    end

    it "returns the scan credential only with access to the owning order" do
      token = GuestOrderAccess.issue!(order)

      get "/api/v1/tickets/#{ticket.display_credential}", headers: { "X-Guest-Order-Token" => token }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["scan_credential"]).to eq(ticket.scan_credential)
    end

    it "returns 404 for unknown qr_code" do
      get "/api/v1/tickets/nonexistent"

      expect(response).to have_http_status(:not_found)
    end


    it "rejects a revoked display credential" do
      credential = ticket.display_credential
      ticket.revoke_display_credential!

      get "/api/v1/tickets/#{credential}"

      expect(response).to have_http_status(:not_found)
    end

    it "withholds admission artifacts while a selected refund remains unknown" do
      refund = create(:refund, order: order, status: :pending, provider_refund_id: nil,
        succeeded_at: nil, failure_code: "provider_result_unknown")
      refund.refund_tickets.create!(ticket: ticket, amount_cents: refund.amount_cents)
      headers = { "X-Guest-Order-Token" => GuestOrderAccess.issue!(order) }
      get "/api/v1/tickets/#{ticket.display_credential}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("admission_allowed" => false, "scan_credential" => nil,
        "admission_block_reason" => "Ticket access is paused while its refund is pending")

      get "/api/v1/tickets/#{ticket.display_credential}/download", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(ticket.reload).to be_issued
      expect(refund.reload).to be_pending
    end

    it "does not expose a scan credential after the ticket is cancelled" do
      ticket.update!(status: :cancelled, cancelled_at: Time.current)

      get "/api/v1/tickets/#{ticket.display_credential}"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["scan_credential"]).to be_nil
      expect(response.parsed_body["admission_allowed"]).to be(false)
    end

    it "withholds every owned admission artifact during a legacy unknown full-value refund" do
      create(:refund, order: order, amount_cents: order.total_cents, status: :pending,
        provider_refund_id: nil, succeeded_at: nil, failure_code: "provider_result_unknown")
      headers = { "X-Guest-Order-Token" => GuestOrderAccess.issue!(order) }
      get "/api/v1/tickets/#{ticket.display_credential}", headers: headers
      expect(response.parsed_body).to include("admission_allowed" => false, "scan_credential" => nil,
        "admission_block_reason" => "Ticket access is paused while its refund is pending")
      %w[download wallet/apple wallet/google].each do |suffix|
        get "/api/v1/tickets/#{ticket.display_credential}/#{suffix}", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end

    it "reports retained admission truthfully and denies artifacts after Undo and exception resolution" do
      ticket.check_in!
      retention = Commerce::FinancialReversalInventory.call(ticket: ticket, refund: create(:refund, order: order))
      ticket.reverse_check_in!
      retention.reconciliation_exception.resolve!
      headers = { "X-Guest-Order-Token" => GuestOrderAccess.issue!(order) }
      get "/api/v1/tickets/#{ticket.display_credential}", headers: headers
      expect(response.parsed_body).to include("status" => "issued", "admission_allowed" => false,
        "scan_credential" => nil, "admission_block_reason" => "Refunded or disputed admission requires organizer review")
      get "/api/v1/tickets/#{ticket.display_credential}/download", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "keeps a cancelled ticket record viewable after its free order closes" do
      order.update!(status: :cancelled)
      ticket.update!(status: :cancelled, cancelled_at: Time.current)

      get "/api/v1/tickets/#{ticket.display_credential}"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("status" => "cancelled", "scan_credential" => nil)
    end

    it "returns child_tickets with safe display credentials for pass_parent and parent_pass metadata for pass_child" do
      org = event.organization
      night_1 = create(:event, :published, organization: org, organizer_profile: organizer_profile,
        title: "Night 1", starts_at: 2.days.from_now, ends_at: 2.days.from_now + 3.hours)
      night_2 = create(:event, :published, organization: org, organizer_profile: organizer_profile,
        title: "Night 2", starts_at: 4.days.from_now, ends_at: 4.days.from_now + 3.hours)
      pass_tt = create(:ticket_type, event: event, name: "Full Tourney Pass", price_cents: 0, quantity_available: 10)
      TicketTypeIncludedEvent.create!(ticket_type: pass_tt, included_event: night_1, position: 0)
      TicketTypeIncludedEvent.create!(ticket_type: pass_tt, included_event: night_2, position: 1)

      buyer = create(:user)
      pass_order = Commerce::OrderCreator.call(
        event: event,
        user: buyer,
        line_items: [{ ticket_type_id: pass_tt.id, quantity: 1 }],
        buyer_email: buyer.email,
        buyer_name: "Pass Holder",
        payment_required: false
      ).order
      parent_ticket = pass_order.tickets.find_by!(parent_ticket_id: nil)
      child_1 = pass_order.tickets.find_by!(event: night_1)

      # Unauthenticated guest presenting the valid signed parent.display_credential
      # receives active untransferred children's display links, with NO scan_credential on parent or children
      get "/api/v1/tickets/#{parent_ticket.display_credential}"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "is_pass" => true,
        "pass_parent" => true,
        "pass_child" => false,
        "pass_nights_count" => 2,
        "scan_credential" => nil
      )
      guest_children = response.parsed_body.fetch("child_tickets")
      expect(guest_children.map { |c| c["display_credential"] }).to eq([
        child_1.display_credential,
        pass_order.tickets.find_by!(event: night_2).display_credential
      ])
      expect(guest_children.first["display_token"]).to eq(child_1.display_credential)
      expect(guest_children.first["ticket_url"]).to eq("/tickets/#{child_1.display_credential}")
      expect(guest_children.first).not_to have_key("scan_credential")

      # Guest can follow the exposed child link to inspect the child night ticket
      get "/api/v1/tickets/#{guest_children.first['display_credential']}"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "pass_child" => true,
        "parent_ticket_id" => parent_ticket.id,
        "scan_credential" => nil
      )

      # Authenticated buyer gets safe child display links, still no scan_credential on parent
      get "/api/v1/tickets/#{parent_ticket.display_credential}", headers: auth_headers(buyer)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["scan_credential"]).to be_nil
      children = response.parsed_body.fetch("child_tickets")
      expect(children.map { |c| c.dig("event", "title") }).to eq(["Night 1", "Night 2"])
      expect(children.first["display_token"]).to eq(child_1.display_credential)
      expect(children.first["ticket_url"]).to eq("/tickets/#{child_1.display_credential}")
      expect(children.first).not_to have_key("scan_credential")

      # Parent pass cannot be downloaded as a door PDF
      get "/api/v1/tickets/#{parent_ticket.display_credential}/download", headers: auth_headers(buyer)
      expect(response).to have_http_status(:not_found)

      # Child ticket exposes parent_pass metadata and scannable credential when authorized
      get "/api/v1/tickets/#{child_1.display_credential}", headers: auth_headers(buyer)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "is_pass" => true,
        "pass_parent" => false,
        "pass_child" => true,
        "parent_ticket_id" => parent_ticket.id,
        "scan_credential" => child_1.scan_credential,
        "parent_pass" => {
          "ticket_type_name" => "Full Tourney Pass",
          "event_title" => event.title,
          "event_slug" => event.slug,
          "nights_count" => 2
        }
      )
    end

    it "exposes untransferred child display credentials to guest buyers on active passes and withholds them when cancelled, disputed, or transferred" do
      org = event.organization
      night_1 = create(:event, :published, organization: org, organizer_profile: organizer_profile,
        title: "Night 1", starts_at: 2.days.from_now, ends_at: 2.days.from_now + 3.hours)
      night_2 = create(:event, :published, organization: org, organizer_profile: organizer_profile,
        title: "Night 2", starts_at: 4.days.from_now, ends_at: 4.days.from_now + 3.hours)
      pass_tt = create(:ticket_type, event: event, name: "Guest Tourney Pass", price_cents: 0, quantity_available: 10)
      TicketTypeIncludedEvent.create!(ticket_type: pass_tt, included_event: night_1, position: 0)
      TicketTypeIncludedEvent.create!(ticket_type: pass_tt, included_event: night_2, position: 1)

      guest_order = Commerce::OrderCreator.call(
        event: event,
        user: nil,
        line_items: [{ ticket_type_id: pass_tt.id, quantity: 1 }],
        buyer_email: "guest-pass@example.com",
        buyer_name: "Guest Pass Holder",
        payment_required: false
      ).order
      parent_ticket = guest_order.tickets.find_by!(parent_ticket_id: nil)
      child_1 = guest_order.tickets.find_by!(event: night_1)
      child_2 = guest_order.tickets.find_by!(event: night_2)

      # Guest with only the signed parent.display_credential receives child links
      # and can open the child's door QR with their GuestOrderAccess token
      get "/api/v1/tickets/#{parent_ticket.display_credential}"
      expect(response).to have_http_status(:ok)
      children = response.parsed_body.fetch("child_tickets")
      expect(children.map { |c| c["display_credential"] }).to eq([child_1.display_credential, child_2.display_credential])
      expect(children.map { |c| c["ticket_url"] }).to eq([
        "/tickets/#{child_1.display_credential}",
        "/tickets/#{child_2.display_credential}"
      ])

      guest_token = GuestOrderAccess.issue!(guest_order)
      get "/api/v1/tickets/#{children.first['display_credential']}", headers: { "X-Guest-Order-Token" => guest_token }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["scan_credential"]).to eq(child_1.scan_credential)

      # Transferred-away child has its credential withheld while other active children stay visible
      recipient = create(:user)
      child_1.update!(holder_user: recipient)
      get "/api/v1/tickets/#{parent_ticket.display_credential}"
      expect(response).to have_http_status(:ok)
      children = response.parsed_body.fetch("child_tickets")
      expect(children.first).to include("status" => "transferred", "display_credential" => nil, "ticket_url" => nil)
      expect(children.second).to include("display_credential" => child_2.display_credential, "ticket_url" => "/tickets/#{child_2.display_credential}")
      child_1.update!(holder_user: nil)

      # Disputed order withholds all child credentials on unauthenticated parent display lookup
      dispute = Dispute.create!(
        order: guest_order,
        provider: "stripe",
        provider_dispute_id: "dp_pass_test",
        amount_cents: 100,
        currency: "usd",
        status: :open,
        opened_at: Time.current
      )
      get "/api/v1/tickets/#{parent_ticket.display_credential}"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("child_tickets").map { |c| c["display_credential"] }).to eq([nil, nil])
      expect(response.parsed_body.fetch("child_tickets").map { |c| c["ticket_url"] }).to eq([nil, nil])
      dispute.update!(status: :won)

      # Transferred-away parent withholds all child credentials
      parent_ticket.update!(holder_user: recipient)
      get "/api/v1/tickets/#{parent_ticket.display_credential}"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("child_tickets").map { |c| c["display_credential"] }).to eq([nil, nil])
      parent_ticket.update!(holder_user: nil)

      # Cancelled parent withholds all child credentials
      parent_ticket.update!(status: :cancelled, cancelled_at: Time.current)
      get "/api/v1/tickets/#{parent_ticket.display_credential}"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("child_tickets").map { |c| c["display_credential"] }).to eq([nil, nil])
    end
  end

  describe "GET /api/v1/tickets/:credential/download" do
    it "returns a PDF file only with access to the owning order" do
      token = GuestOrderAccess.issue!(order)
      get "/api/v1/tickets/#{ticket.display_credential}/download",
        headers: { "X-Guest-Order-Token" => token }

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/pdf")
      expect(response.headers["Content-Disposition"]).to include("attachment")
      expect(response.headers["Content-Disposition"]).to include(".pdf")
    end

    it "downloads a multilingual PDF through the owning guest session" do
      event.update!(title: "Music & Food <show> 🎟️ 日本語", venue_name: "Hågatña 日本会館")
      get "/api/v1/tickets/#{ticket.display_credential}/download",
        headers: { "X-Guest-Order-Token" => GuestOrderAccess.issue!(order) }

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/pdf")
      reader = PDF::Reader.new(StringIO.new(response.body))
      expect(reader.pages.map(&:text).join("\n")).to include(event.title.delete("\uFE0F"), event.venue_name)
    end

    it "replaces unsupported PDF text for the owning guest without exposing private fields" do
      event.update!(title: "Unsupported \u{10FFFF}")
      get "/api/v1/tickets/#{ticket.display_credential}/download",
        headers: { "X-Guest-Order-Token" => GuestOrderAccess.issue!(order) }

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/pdf")
      expect(response.headers["Content-Disposition"]).to include("attachment")
      text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n")
      expect(text).to include("Unsupported ?")
      expect(text).not_to include(ticket.scan_credential, ticket.attendee_name, event.title)
    end

    it "does not expose a PDF admission credential to a public display link" do
      get "/api/v1/tickets/#{ticket.display_credential}/download"

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for unknown qr_code" do
      get "/api/v1/tickets/nonexistent/download"

      expect(response).to have_http_status(:not_found)
    end


    it "does not generate a downloadable artifact for a cancelled ticket" do
      ticket.update!(status: :cancelled, cancelled_at: Time.current)

      get "/api/v1/tickets/#{ticket.display_credential}/download"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/tickets/:credential/wallet/apple" do
    it "requires secure order access and reports missing signing configuration" do
      get "/api/v1/tickets/#{ticket.display_credential}/wallet/apple",
        headers: { "X-Guest-Order-Token" => GuestOrderAccess.issue!(order) }

      expect(response).to have_http_status(:service_unavailable)
      json = JSON.parse(response.body)
      expect(json["error"]).to include("not configured")
    end
  end

  describe "GET /api/v1/tickets/:credential/wallet/google" do
    it "requires secure order access and reports missing signing configuration" do
      get "/api/v1/tickets/#{ticket.display_credential}/wallet/google",
        headers: { "X-Guest-Order-Token" => GuestOrderAccess.issue!(order) }

      expect(response).to have_http_status(:service_unavailable)
      json = JSON.parse(response.body)
      expect(json["error"]).to include("not configured")
    end
  end
end
