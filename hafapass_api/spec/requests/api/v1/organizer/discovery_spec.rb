require "rails_helper"

RSpec.describe "Organizer operational discovery", type: :request do
  let(:owner) { create(:user, :organizer) }
  let!(:profile) { create(:organizer_profile, user: owner) }
  let(:organization) { profile.organization }
  let(:headers) { auth_headers(owner).merge("X-Organization-Id" => organization.id.to_s) }
  let(:event) { create(:event, organizer_profile: profile) }

  describe "events" do
    it "reaches event 21 with stable pages, including tied creation times" do
      events = create_list(:event, 21, organizer_profile: profile, created_at: 1.day.ago)
      get "/api/v1/organizer/events", headers: headers
      expect(response.parsed_body["events"].map { |e| e["id"] }).to eq(events.reverse.first(20).map(&:id))
      expect(response.parsed_body["meta"]).to include("total_count" => 21, "total_pages" => 2)
      get "/api/v1/organizer/events", params: { page: 2 }, headers: headers
      expect(response.parsed_body["events"].map { |e| e["id"] }).to eq([events.first.id])
      get "/api/v1/organizer/events", params: { page: 3 }, headers: headers
      expect(response.parsed_body["events"]).to eq([])
    end

    it "searches names, venue and IDs literally within the selected organization" do
      target = create(:event, organizer_profile: profile, title: "Door 100% Guam", venue_name: "Special Arena")
      create(:event, title: "Door 100% Guam")
      create(:event, organizer_profile: profile, title: "Door 1000 Guam")
      ["100%", "special arena", target.id.to_s].each do |query|
        get "/api/v1/organizer/events", params: { q: query }, headers: headers
        expect(response.parsed_body["events"].map { |e| e["id"] }).to eq([target.id])
      end
    end

    it "only exposes effective scanner assignments in search and direct resolution" do
      scanner = create(:user)
      create(:organization_membership, organization: organization, user: scanner, role: :scanner)
      assigned = create(:event, organizer_profile: profile)
      unassigned = create(:event, organizer_profile: profile)
      create(:event_staff_assignment, event: assigned, user: scanner)
      scoped_headers = auth_headers(scanner).merge("X-Organization-Id" => organization.id.to_s)
      get "/api/v1/organizer/events", params: { purpose: "scan" }, headers: scoped_headers
      expect(response.parsed_body["events"].map { |e| e["id"] }).to eq([assigned.id])
      get "/api/v1/organizer/events/#{assigned.id}", headers: scoped_headers
      expect(response.parsed_body.dig("permissions", "scan")).to eq(true)
      get "/api/v1/organizer/events/#{unassigned.id}", headers: scoped_headers
      expect(response).to have_http_status(:forbidden)
      assigned.event_staff_assignments.update_all(status: EventStaffAssignment.statuses[:revoked])
      get "/api/v1/organizer/events/#{assigned.id}", headers: scoped_headers
      expect(response).to have_http_status(:forbidden)
    end

    it "narrows by status and end time and orders by start for the scanner default without widening access" do
      now = Time.current.change(usec: 0)
      soon = create(:event, :published, organizer_profile: profile, starts_at: now + 2.days, ends_at: now + 2.days + 4.hours)
      live = create(:event, :published, organizer_profile: profile, starts_at: now - 1.hour, ends_at: now + 3.hours)
      past = create(:event, :published, organizer_profile: profile, starts_at: now - 5.days, ends_at: now - 5.days + 4.hours)
      create(:event, organizer_profile: profile, status: :draft, starts_at: now + 1.day, ends_at: now + 1.day + 4.hours)
      create(:event, :published, starts_at: now + 1.day, ends_at: now + 1.day + 4.hours)
      params = { purpose: "scan", status: "published", ends_after: (now - 1.day).iso8601, order: "starts_at" }
      get "/api/v1/organizer/events", params: params, headers: headers
      expect(response.parsed_body["events"].map { |e| e["id"] }).to eq([live.id, soon.id])
      get "/api/v1/organizer/events", params: { purpose: "scan", status: "published", order: "-starts_at", per_page: 1 }, headers: headers
      expect(response.parsed_body["events"].map { |e| e["id"] }).to eq([soon.id])
      get "/api/v1/organizer/events", params: { status: "bogus", ends_after: "not a time", order: "bogus" }, headers: headers
      expect(response.parsed_body["meta"]["total_count"]).to eq(4)
      expect(response.parsed_body["events"].map { |e| e["id"] }).to include(past.id)
    end

    it "keeps scanner assignment scoping when narrowing by status" do
      scanner = create(:user)
      create(:organization_membership, organization: organization, user: scanner, role: :scanner)
      assigned = create(:event, :published, organizer_profile: profile)
      create(:event, :published, organizer_profile: profile)
      create(:event_staff_assignment, event: assigned, user: scanner)
      scoped_headers = auth_headers(scanner).merge("X-Organization-Id" => organization.id.to_s)
      get "/api/v1/organizer/events", params: { purpose: "scan", status: "published", order: "starts_at" }, headers: scoped_headers
      expect(response.parsed_body["events"].map { |e| e["id"] }).to eq([assigned.id])
    end

    it "filters non-scanning roles before pagination while honoring event-specific scanner grants" do
      finance = create(:user)
      create(:organization_membership, organization: organization, user: finance, role: :finance)
      create(:event, organizer_profile: profile)
      create(:event_staff_assignment, event: event, user: finance)
      get "/api/v1/organizer/events", params: { purpose: "scan", per_page: 1 }, headers: auth_headers(finance)
      expect(response.parsed_body["meta"]["total_count"]).to eq(1)
      expect(response.parsed_body["events"].map { |e| e["id"] }).to eq([event.id])
    end
  end

  describe "refund order history" do
    let(:path) { "/api/v1/organizer/events/#{event.id}/orders" }

    it "paginates every settled order beyond the recent ten in deterministic order" do
      orders = create_list(:order, 21, event: event, created_at: 1.day.ago)
      create(:order, :pending, event: event)
      create(:order, :cancelled, event: event)
      create(:order)
      get path, params: { per_page: 10, page: 3 }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["orders"].map { |o| o["id"] }).to eq([orders.first.id])
      expect(response.parsed_body["orders"].first).to include("reference" => orders.first.reference, "refundable_cents" => 5250)
      expect(response.parsed_body["meta"]).to include("total_count" => 21, "total_pages" => 3, "current_page" => 3)
      get path, params: { per_page: 10, page: 4 }, headers: headers
      expect(response.parsed_body["orders"]).to eq([])
    end

    it "finds orders by reference, number, buyer name or email with literal wildcard matching" do
      target = create(:order, event: event, buyer_name: "Older 100% Buyer", buyer_email: "older@example.test")
      create(:order, event: event, buyer_name: "Older 1000 Buyer", buyer_email: "other@example.test")
      [target.reference.downcase, "##{target.id}", "100%", "OLDER@example"].each do |query|
        get path, params: { q: query }, headers: headers
        expect(response.parsed_body["orders"].map { |o| o["id"] }).to eq([target.id])
      end
    end

    it "includes partially and fully refunded orders for historical lookup" do
      partial = create(:order, event: event, status: :partially_refunded)
      refunded = create(:order, :refunded, event: event)
      get path, headers: headers
      expect(response.parsed_body["orders"].map { |o| o["id"] }).to contain_exactly(partial.id, refunded.id)
    end

    it "permits finance and rejects a manager, marketer or scanner without refund authority" do
      %i[finance manager marketer scanner].each do |role|
        user = create(:user)
        create(:organization_membership, organization: organization, user: user, role: role)
        get path, headers: auth_headers(user).merge("X-Organization-Id" => organization.id.to_s)
        expect(response.status).to eq(role == :finance ? 200 : 403)
      end
    end

    it "refuses foreign events, revoked memberships and unauthenticated requests" do
      other = create(:event)
      get "/api/v1/organizer/events/#{other.id}/orders", headers: headers
      expect(response).to have_http_status(:not_found)
      organization.organization_memberships.find_by!(user: owner).update!(status: :revoked)
      get path, headers: headers
      expect(response).to have_http_status(:forbidden)
      get path
      expect(response).to have_http_status(:unauthorized)
    end

    it "bounds page sizes" do
      get path, params: { per_page: 10000 }, headers: headers
      expect(response.parsed_body["meta"]["per_page"]).to eq(100)
      get path, params: { per_page: 0 }, headers: headers
      expect(response.parsed_body["meta"]["per_page"]).to eq(1)
    end
  end
end
