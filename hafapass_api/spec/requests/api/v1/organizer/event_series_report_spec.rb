# frozen_string_literal: true

require "rails_helper"
require "csv"

RSpec.describe "Api::V1::Organizer::EventSeries Report & Export", type: :request do
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:owner) { profile.user }
  let(:series) do
    create(
      :event_series,
      organization: organization,
      name: "FD Alumni Tournament 2026",
      slug: "fd-alumni-2026",
      status: :active,
      revenue_share_bps: 1600,
      revenue_share_base: "admissions_net_proceeds",
      revenue_share_includes_door_cash: true,
      revenue_share_label: "School Share",
      primary_share_label: "Alumni Share"
    )
  end
  let!(:event_night) do
    create(:event, :completed, organizer_profile: profile, organization: organization, title: "=SUM(A1:A10) Night 1")
  end
  let!(:ticket_type) { create(:ticket_type, event: event_night, name: "+VIP Pass", price_cents: 2500) }

  def org_headers(user)
    auth_headers(user).merge("X-Organization-Id" => organization.id.to_s)
  end

  def member_with_role(role)
    create(:user).tap { |u| create(:organization_membership, organization: organization, user: u, role: role) }
  end

  before do
    series.event_series_memberships.create!(event: event_night, role: :regular_night, position: 0)
    order = create(:order, event: event_night, status: :completed, subtotal_cents: 5000,
      service_fee_cents: 350, discount_cents: 0, total_cents: 5350, processing_fee_bearer_snapshot: "platform")
    item = create(:order_item, order: order, ticket_type: ticket_type, name: ticket_type.name,
      unit_price_cents: 2500, quantity: 2, subtotal_cents: 5000, fee_cents: 350, organizer_proceeds_cents: 5000)
    create(:ticket, :checked_in, order: order, order_item: item, ticket_type: ticket_type, event: event_night)
    create(:ticket, order: order, order_item: item, ticket_type: ticket_type, event: event_night)
    create(:payment, :succeeded, order: order, amount_cents: 5350, provider_environment: "live")
  end

  describe "GET /api/v1/organizer/event_series/:id/report" do
    it "returns the full series report JSON for owners, finance members, and platform admins" do
      finance_user = member_with_role(:finance)
      admin_user = create(:user, :admin)

      [owner, finance_user, admin_user].each do |actor|
        get "/api/v1/organizer/event_series/#{series.id}/report", headers: org_headers(actor)
        expect(response).to have_http_status(:ok)

        body = response.parsed_body
        expect(body.dig("series", "id")).to eq(series.id)
        expect(body.dig("groups", "admissions", "gross_cents")).to eq(5000)
        expect(body.dig("groups", "combined", "organizer_proceeds_cents")).to eq(5000)
        expect(body.dig("channels", "online_stripe", "orders_count")).to eq(1)
        expect(body.dig("revenue_share", "revenue_share_bps")).to eq(1600)
        expect(body.dig("revenue_share", "base_cents")).to eq(5000)
        expect(body.dig("revenue_share", "share_cents")).to eq(800)
        expect(body.dig("revenue_share", "primary_cents")).to eq(4200)
        expect(body.dig("closeout_checklist", "check_reference_pattern")).to eq("CHK-<check_number>-E<event_id>")
        expect(body.fetch("events").size).to eq(1)
        expect(body.fetch("ticket_types").size).to eq(1)
      end
    end

    %i[scanner box_office marketer].each do |role|
      it "forbids #{role} members with 403 before loading the series (no ID probing)" do
        staff = member_with_role(role)
        other_series = create(:event_series, organization: create(:organization))

        get "/api/v1/organizer/event_series/#{series.id}/report", headers: org_headers(staff)
        expect(response).to have_http_status(:forbidden)

        # Even for another organization's series ID, unauthorized role gets 403, not 404
        get "/api/v1/organizer/event_series/#{other_series.id}/report", headers: org_headers(staff)
        expect(response).to have_http_status(:forbidden)
      end
    end

    it "forbids an event-level manager assignment without organization-level view_finance" do
      staff = member_with_role(:scanner)
      create(:event_staff_assignment, organization: organization, event: event_night, user: staff, role: :manager)

      get "/api/v1/organizer/event_series/#{series.id}/report", headers: org_headers(staff)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 404 for cross-organization requests by an authorized finance user" do
      other_series = create(:event_series, organization: create(:organization))

      get "/api/v1/organizer/event_series/#{other_series.id}/report", headers: org_headers(owner)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/organizer/event_series/:id/report_export" do
    it "streams a UTF-8 BOM multi-section CSV with formula-injection escaping and audit log" do
      expect {
        get "/api/v1/organizer/event_series/#{series.id}/report_export", headers: org_headers(owner)
      }.to change { AuditLog.where(action: "finance.exported", auditable: series).count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to include("text/csv")
      expect(response.headers["Content-Type"]).to include("charset=utf-8")
      expect(response.headers["Content-Disposition"]).to include("attachment")
      expect(response.headers["Content-Disposition"]).to include("fd-alumni-2026-series-report.csv")

      body = response.body.force_encoding(Encoding::UTF_8)
      expect(body.start_with?("\uFEFF")).to be(true)

      rows = CSV.parse(body.delete_prefix("\uFEFF"))
      flat_text = rows.flatten.compact.join("\n")

      expect(flat_text).to include("SECTION 1: SERIES SUMMARY & REVENUE-SHARE WORKSHEET")
      expect(flat_text).to include("SECTION 2: GROUP SUBTOTALS")
      expect(flat_text).to include("SECTION 3: CHANNEL BREAKDOWN")
      expect(flat_text).to include("SECTION 4: PER-EVENT BREAKDOWN")
      expect(flat_text).to include("SECTION 5: TICKET-TYPE BREAKDOWN")

      # Formula-injection protection: leading = and + cells are tab-prefixed
      event_section_idx = rows.index { |r| r.first == "SECTION 4: PER-EVENT BREAKDOWN" }
      event_row = rows[event_section_idx + 2]
      expect(event_row[1]).to eq("\t=SUM(A1:A10) Night 1")

      tt_section_idx = rows.index { |r| r.first == "SECTION 5: TICKET-TYPE BREAKDOWN" }
      tt_row = rows[tt_section_idx + 2]
      expect(tt_row[1]).to eq("\t=SUM(A1:A10) Night 1")
      expect(tt_row[3]).to eq("\t+VIP Pass")
    end

    it "forbids non-finance roles from exporting CSV and returns 404 cross-org" do
      scanner = member_with_role(:scanner)
      get "/api/v1/organizer/event_series/#{series.id}/report_export", headers: org_headers(scanner)
      expect(response).to have_http_status(:forbidden)

      other_series = create(:event_series, organization: create(:organization))
      get "/api/v1/organizer/event_series/#{other_series.id}/report_export", headers: org_headers(owner)
      expect(response).to have_http_status(:not_found)
    end

    it "surfaces negative_balance_cents and unresolved_buyer_liability_cents in both JSON and CSV" do
      order = event_night.orders.first
      item = order.order_items.first
      payment = order.payments.first
      component = create(:fee_component, order: order, order_item: item, kind: "processing",
        amount_cents: 185, estimated: false, provider_reference: "txn_#{SecureRandom.hex(6)}")
      create(:stripe_fee_evidence, :verified, payment: payment, fee_component: component,
        provider_balance_transaction_id: component.provider_reference)

      settlement = Settlements::Finalizer.call(event: event_night, actor: owner)
      create(:payout, organization: organization, event: event_night, settlement: settlement,
        amount_cents: 5000, status: :paid, paid_at: 1.hour.ago, provider_payout_id: "CHK-201-E#{event_night.id}")

      refund = create(:refund, :succeeded, order: order, payment: payment, amount_cents: 2500)
      create(:refund_item, refund: refund, order_item: item, quantity: 1,
        organizer_proceeds_cents: 2500, fee_cents: 0, organizer_fee_cents: 0, tax_cents: 0, amount_cents: 2500)
      order.update!(status: :partially_refunded, refund_amount_cents: 2500)

      get "/api/v1/organizer/event_series/#{series.id}/report", headers: org_headers(owner)
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body.dig("groups", "combined", "owed_cents")).to eq(0)
      expect(body.dig("groups", "combined", "negative_balance_cents")).to eq(2500)
      expect(body.dig("events", 0, "negative_balance_cents")).to eq(2500)
      expect(body.dig("events", 0, "unresolved_buyer_liability_cents")).to eq(0)

      get "/api/v1/organizer/event_series/#{series.id}/report_export", headers: org_headers(owner)
      expect(response).to have_http_status(:ok)
      rows = CSV.parse(response.body.force_encoding(Encoding::UTF_8).delete_prefix("\uFEFF"))

      event_section_idx = rows.index { |r| r.first == "SECTION 4: PER-EVENT BREAKDOWN" }
      event_header = rows[event_section_idx + 1]
      event_row = rows[event_section_idx + 2]
      neg_idx = event_header.index("Negative Balance")
      liability_idx = event_header.index("Unresolved Buyer Liability")
      expect(neg_idx).not_to be_nil
      expect(liability_idx).not_to be_nil
      expect(event_row[neg_idx]).to eq("25.00")
      expect(event_row[liability_idx]).to eq("0.00")
    end
  end

  describe "PATCH /api/v1/organizer/event_series/:id revenue-share updates" do
    it "allows finance members and platform admins to update revenue-share fields and audits the change" do
      finance_user = member_with_role(:finance)

      expect {
        patch "/api/v1/organizer/event_series/#{series.id}", params: {
          revenue_share_bps: 2000,
          revenue_share_base: "admissions_gross",
          revenue_share_includes_door_cash: false,
          revenue_share_label: "School Partner",
          primary_share_label: "Alumni Org"
        }, headers: org_headers(finance_user), as: :json
      }.to change { AuditLog.where(action: "event_series.updated", auditable: series).count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "revenue_share_bps" => 2000,
        "revenue_share_base" => "admissions_gross",
        "revenue_share_includes_door_cash" => false,
        "revenue_share_label" => "School Partner",
        "primary_share_label" => "Alumni Org"
      )

      admin_user = create(:user, :admin)
      patch "/api/v1/organizer/event_series/#{series.id}", params: {
        revenue_share_bps: 1600
      }, headers: org_headers(admin_user), as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["revenue_share_bps"]).to eq(1600)
    end

    it "still forbids finance members from modifying non-revenue-share series fields" do
      finance_user = member_with_role(:finance)

      patch "/api/v1/organizer/event_series/#{series.id}", params: {
        name: "Renamed By Finance",
        revenue_share_bps: 1800
      }, headers: org_headers(finance_user), as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "forbids managers without manage_finance from modifying revenue-share fields while allowing non-finance updates" do
      manager_user = member_with_role(:manager)

      patch "/api/v1/organizer/event_series/#{series.id}", params: {
        revenue_share_bps: 1800
      }, headers: org_headers(manager_user), as: :json
      expect(response).to have_http_status(:forbidden)

      patch "/api/v1/organizer/event_series/#{series.id}", params: {
        name: "Updated By Manager",
        revenue_share_bps: 1800
      }, headers: org_headers(manager_user), as: :json
      expect(response).to have_http_status(:forbidden)

      patch "/api/v1/organizer/event_series/#{series.id}", params: {
        name: "Updated By Manager"
      }, headers: org_headers(manager_user), as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["name"]).to eq("Updated By Manager")

      patch "/api/v1/organizer/event_series/#{series.id}", params: {
        revenue_share_bps: 1800
      }, headers: org_headers(owner), as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["revenue_share_bps"]).to eq(1800)
    end

    it "forbids scanner and marketer roles from modifying or deleting series before loading (no ID probing)" do
      other_series = create(:event_series, organization: create(:organization))

      %i[scanner box_office marketer].each do |role|
        user = member_with_role(role)
        patch "/api/v1/organizer/event_series/#{series.id}", params: {
          revenue_share_bps: 1800
        }, headers: org_headers(user), as: :json
        expect(response).to have_http_status(:forbidden)

        patch "/api/v1/organizer/event_series/#{other_series.id}", params: {
          revenue_share_bps: 1800
        }, headers: org_headers(user), as: :json
        expect(response).to have_http_status(:forbidden)

        delete "/api/v1/organizer/event_series/#{other_series.id}", headers: org_headers(user)
        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
