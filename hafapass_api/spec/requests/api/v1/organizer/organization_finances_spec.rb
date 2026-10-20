# frozen_string_literal: true

require "rails_helper"
require "csv"

RSpec.describe "Organizer finances and exports", type: :request do
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:owner) { profile.user }
  let(:completed_event) { create(:event, :completed, organizer_profile: profile, title: "Closing Night") }
  let(:upcoming_event) { create(:event, :published, organizer_profile: profile, title: "Next Show") }

  def org_headers(user)
    auth_headers(user).merge("X-Organization-Id" => organization.id.to_s)
  end

  def member(role)
    create(:user).tap { |user| create(:organization_membership, organization: organization, user: user, role: role) }
  end

  # A settled $50.00 card order with a verified actual processing cost and the
  # order's creation-time processing-fee bearer snapshot (nil = legacy).
  def record_sale!(sale_event, bearer:, processing_fee_cents: 185, buyer_name: "Jane Smith")
    order = create(:order, event: sale_event, subtotal_cents: 5000, service_fee_cents: 350, discount_cents: 0,
      total_cents: 5350, processing_fee_bearer_snapshot: bearer, buyer_name: buyer_name)
    item = create(:order_item, order: order, unit_price_cents: 5000, subtotal_cents: 5000, fee_cents: 350,
      organizer_proceeds_cents: 5000)
    create(:ticket, order: order, order_item: item, ticket_type: item.ticket_type, event: sale_event)
    create(:fee_component, order: order, kind: "platform", amount_cents: 350, estimated: true)
    component = create(:fee_component, order: order, order_item: item, kind: "processing",
      amount_cents: processing_fee_cents, estimated: false, provider_reference: "txn_fixture_#{SecureRandom.hex(8)}")
    capture = create(:payment, :succeeded, order: order, amount_cents: 5350)
    create(:stripe_fee_evidence, :verified, payment: capture, fee_component: component,
      provider_balance_transaction_id: component.provider_reference)
    order
  end

  let!(:platform_order) { record_sale!(completed_event, bearer: "platform") }
  let!(:organizer_order) { record_sale!(completed_event, bearer: "organizer") }
  let!(:legacy_order) { record_sale!(completed_event, bearer: nil, processing_fee_cents: 183, buyer_name: "=HYPERLINK(\"x\")") }
  let!(:upcoming_order) { record_sale!(upcoming_event, bearer: nil, processing_fee_cents: 183) }
  let!(:settlement) { Settlements::Finalizer.call(event: completed_event, actor: owner) }
  let!(:payout) do
    create(:payout, organization: organization, event: completed_event, settlement: settlement,
      amount_cents: 10_000, status: :paid, paid_at: 1.hour.ago, provider_payout_id: "po_fixture_1")
  end
  let!(:other_org_order) do
    other_profile = create(:organizer_profile, :verified)
    record_sale!(create(:event, :completed, organizer_profile: other_profile, title: "Someone Else's Show"), bearer: nil)
  end

  describe "GET /api/v1/organizer/finances" do
    it "totals every event using each order's own processing-fee bearer snapshot" do
      get "/api/v1/organizer/finances", headers: org_headers(owner)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      # Platform order: HåfaPass covers its 1.85. Organizer order: 1.85 to the
      # organizer. Legacy (NULL) orders: 1.83 each deducted, as before.
      expect(body["totals"]).to include(
        "gross_cents" => 20_000,
        "refund_cents" => 0,
        "platform_fee_cents" => 1400,
        "processing_fee_cents" => 185 + 183 + 183,
        "platform_processing_fee_cents" => 185,
        "organizer_proceeds_cents" => 20_000,
        "payable_cents" => 14_632 + 4817,
        "paid_cents" => 10_000,
        "in_flight_cents" => 0,
        "owed_cents" => 4632 + 4817,
        "negative_balance_cents" => 0,
        "available_to_payout_cents" => 4632
      )
      expect(body["processing_fee_bearers"]).to eq("platform" => 1, "organizer" => 1, "legacy" => 2)
      expect(body["events"].map { |row| row["title"] }).to contain_exactly("Closing Night", "Next Show")
    end

    it "reports statement and payout status per event" do
      get "/api/v1/organizer/finances", headers: org_headers(owner)

      rows = response.parsed_body["events"].index_by { |row| row["id"] }
      expect(rows[completed_event.id]).to include("settlement_state" => "finalized", "payout_state" => "ready",
        "paid_cents" => 10_000, "owed_cents" => 4632)
      expect(rows[completed_event.id]["settlement"]).to include("id" => settlement.id, "version" => 1, "current" => true,
        "available_to_payout_cents" => 4632)
      expect(rows[upcoming_event.id]).to include("settlement" => nil, "settlement_state" => "not_finalized",
        "payout_state" => "awaiting_statement", "owed_cents" => 4817)
    end

    it "marks a statement changed when money moves after approval, without touching the stored version" do
      refund = create(:refund, order: organizer_order, amount_cents: 5350, status: :succeeded, succeeded_at: Time.current)
      create(:refund_item, refund: refund, order_item: organizer_order.order_items.first, amount_cents: 5350,
        fee_cents: 350, organizer_proceeds_cents: 5000)
      before = settlement.reload.attributes

      get "/api/v1/organizer/finances", headers: org_headers(owner)

      row = response.parsed_body["events"].find { |event| event["id"] == completed_event.id }
      expect(row).to include("settlement_state" => "changed", "refund_cents" => 5350)
      expect(settlement.reload.attributes).to eq(before)
    end

    it "lists payout history with the provider reference" do
      get "/api/v1/organizer/finances", headers: org_headers(owner)

      expect(response.parsed_body["payouts_count"]).to eq(1)
      expect(response.parsed_body["payouts"].first).to include("id" => payout.id, "event_title" => "Closing Night",
        "settlement_version" => 1, "amount_cents" => 10_000, "status" => "paid", "provider_payout_id" => "po_fixture_1")
    end

    it "allows finance and manager members" do
      %i[finance manager].each do |role|
        get "/api/v1/organizer/finances", headers: org_headers(member(role))
        expect(response).to have_http_status(:ok)
      end
    end

    it "denies roles without organization finance access, including event-level manager assignments" do
      %i[marketer box_office scanner].each do |role|
        get "/api/v1/organizer/finances", headers: org_headers(member(role))
        expect(response).to have_http_status(:forbidden)
      end
      assigned = member(:box_office)
      create(:event_staff_assignment, organization: organization, event: completed_event, user: assigned, role: :manager)
      get "/api/v1/organizer/finances", headers: org_headers(assigned)
      expect(response).to have_http_status(:forbidden)
    end

    it "denies another organization's owner naming this organization" do
      outsider = create(:organizer_profile).user

      get "/api/v1/organizer/finances", headers: org_headers(outsider)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "CSV exports" do
    def csv
      CSV.parse(response.body, headers: true)
    end

    it "exports organization orders with the per-order processing split, safe for spreadsheets" do
      get "/api/v1/organizer/finances/orders_export", headers: org_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/csv")
      expect(response.headers["Content-Disposition"]).to include("attachment")
      rows = csv
      expect(rows.headers).to eq(FinanceExports::ORDER_HEADER)
      expect(rows.map { |row| row["order_reference"] })
        .to contain_exactly(platform_order.reference, organizer_order.reference, legacy_order.reference, upcoming_order.reference)
      by_ref = rows.index_by { |row| row["order_reference"] }
      expect(by_ref[platform_order.reference].to_h).to include("card_processing_paid_by_organizer" => "0.00",
        "card_processing_paid_by_hafapass" => "1.85", "card_processing_terms" => "hafapass_covers_tickets",
        "net_organizer_proceeds" => "50.00", "subtotal" => "50.00", "service_fee_paid_by_buyer" => "3.50",
        "ticket_count" => "1", "channel" => "online", "status" => "completed")
      expect(by_ref[organizer_order.reference].to_h).to include("card_processing_paid_by_organizer" => "1.85",
        "card_processing_terms" => "organizer", "net_organizer_proceeds" => "48.15")
      expect(by_ref[legacy_order.reference].to_h).to include("card_processing_paid_by_organizer" => "1.83",
        "card_processing_terms" => "organizer_earlier_terms", "net_organizer_proceeds" => "48.17")
      expect(by_ref[legacy_order.reference]["buyer_name"]).to eq("\t=HYPERLINK(\"x\")")
      expect(response.body).not_to include("Someone Else's Show")
      expect(AuditLog.where(action: "finance.exported", organization: organization).last.metadata)
        .to include("export" => "orders", "scope" => "organization")
    end

    it "agrees with the settlement statement for an event" do
      get "/api/v1/organizer/events/#{completed_event.id}/finance/orders_export", headers: org_headers(owner)

      expect(response).to have_http_status(:ok)
      net = csv.sum { |row| (BigDecimal(row["net_organizer_proceeds"]) * 100).to_i }
      expect(net).to eq(settlement.payable_cents)
      expect(csv.map { |row| row["event"] }.uniq).to eq(["Closing Night"])
    end

    it "exports a stored statement version from its immutable lines" do
      get "/api/v1/organizer/events/#{completed_event.id}/finance/statement_export",
        params: { settlement_id: settlement.id }, headers: org_headers(owner)

      expect(response).to have_http_status(:ok)
      rows = csv
      expect(rows.headers).to eq(FinanceExports::STATEMENT_HEADER)
      items = rows.select { |row| row["line"] == "item" }
      expect(items.size).to eq(settlement.settlement_items.count)
      expect(items.map { |row| row["statement_version"] }.uniq).to eq(["1"])
      expect(items.filter_map { |row| row["order_reference"] }.uniq)
        .to contain_exactly(platform_order.reference, organizer_order.reference, legacy_order.reference)
      payable = rows.find { |row| row["line"] == "total" && row["kind"] == "payable" }
      expect(payable["amount"]).to eq("146.32")
    end

    it "exports the current unapproved preview" do
      get "/api/v1/organizer/events/#{upcoming_event.id}/finance/statement_export", headers: org_headers(owner)

      expect(response).to have_http_status(:ok)
      payable = csv.find { |row| row["line"] == "total" && row["kind"] == "payable" }
      expect(payable.to_h).to include("statement_version" => "current", "statement_status" => "preview", "amount" => "48.17")
    end

    it "does not export another event's statement" do
      other_settlement = create(:settlement, organization: organization, event: upcoming_event)

      get "/api/v1/organizer/events/#{completed_event.id}/finance/statement_export",
        params: { settlement_id: other_settlement.id }, headers: org_headers(owner)

      expect(response).to have_http_status(:not_found)
    end

    it "exports payouts" do
      get "/api/v1/organizer/finances/payouts_export", headers: org_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(csv.map(&:to_h)).to contain_exactly(include("payout_id" => payout.id.to_s, "event" => "Closing Night",
        "amount" => "100.00", "status" => "paid", "provider_reference" => "po_fixture_1", "statement_version" => "1"))
    end

    it "denies exports to roles without finance access and to other organizations" do
      marketer = member(:marketer)
      get "/api/v1/organizer/finances/orders_export", headers: org_headers(marketer)
      expect(response).to have_http_status(:forbidden)
      get "/api/v1/organizer/finances/payouts_export", headers: org_headers(marketer)
      expect(response).to have_http_status(:forbidden)
      get "/api/v1/organizer/events/#{completed_event.id}/finance/orders_export", headers: org_headers(marketer)
      expect(response).to have_http_status(:forbidden)

      outsider = create(:organizer_profile).user
      get "/api/v1/organizer/events/#{completed_event.id}/finance/orders_export", headers: auth_headers(outsider)
      expect(response).to have_http_status(:not_found)
      get "/api/v1/organizer/finances/orders_export", headers: org_headers(outsider)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
