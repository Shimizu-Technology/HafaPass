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
    it "shows held payouts separately and keeps them reserved in the balance" do
      cancelled_event = create(:event, :cancelled, organizer_profile: profile, title: "Cancelled Show")
      record_sale!(cancelled_event, bearer: "platform")
      held_settlement = create(:settlement, event: cancelled_event, organization: organization)
      create(:payout, organization: organization, event: cancelled_event, settlement: held_settlement,
        connected_account: payout.connected_account, amount_cents: 1000, status: :held, held_from_status: "pending")

      get "/api/v1/organizer/finances", headers: org_headers(owner)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      row = body.fetch("events").find { |entry| entry.fetch("id") == cancelled_event.id }
      expect(row).to include("held_cents" => 1000, "in_flight_cents" => 0,
        "owed_cents" => row.fetch("payable_cents") - 1000, "payout_state" => "on_hold")
      expect(body.fetch("totals")).to include("held_cents" => 1000)
      expect(body.fetch("breakdown")).to include("held_cents" => 1000)
      expect(body.fetch("breakdown").fetch("balance_cents")).to eq(
        body.fetch("breakdown").fetch("earned_cents") - body.fetch("breakdown").fetch("paid_cents") -
        body.fetch("breakdown").fetch("in_flight_cents") - 1000)
    end

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
        "available_to_payout_cents" => 4632,
        # The paid payout is new statement activity, so nothing is requestable
        # until a new version is finalized (PayoutCreator's digest rule).
        "requestable_cents" => 0
      )
      expect(body["organization"]).to eq("id" => organization.id, "name" => organization.name,
        "slug" => organization.slug, "timezone" => "Pacific/Guam")
      expect(body["processing_fee_bearers"]).to eq("platform" => 1, "organizer" => 1, "legacy" => 2)
      expect(body["events"].map { |row| row["title"] }).to contain_exactly("Closing Night", "Next Show")
    end

    def refund_in_full!(order)
      refund = create(:refund, order: order, amount_cents: 5350, status: :succeeded, succeeded_at: Time.current)
      create(:refund_item, refund: refund, order_item: order.order_items.first, amount_cents: 5350, fee_cents: 350,
        organizer_proceeds_cents: 5000)
      order.update!(status: :refunded, refund_amount_cents: 5350)
    end

    def expect_breakdown_to_sum(breakdown)
      expect(breakdown["sales_cents"] - breakdown["discount_cents"] - breakdown["absorbed_fee_cents"] -
        breakdown["refunded_proceeds_cents"]).to eq(breakdown["proceeds_cents"])
      expect(breakdown["proceeds_cents"] - breakdown["processing_fee_cents"] - breakdown["door_cash_retained_cents"] -
        breakdown["reserve_cents"] + breakdown["adjustment_cents"]).to eq(breakdown["earned_cents"])
      expect(breakdown["earned_cents"] - breakdown["paid_cents"] - breakdown["in_flight_cents"]).to eq(breakdown["balance_cents"])
      expect(breakdown["owed_cents"] - breakdown["negative_balance_cents"]).to eq(breakdown["balance_cents"])
    end

    it "builds a breakdown whose displayed lines sum exactly from the proceeds side" do
      refund_in_full!(organizer_order)

      get "/api/v1/organizer/finances", headers: org_headers(owner)

      breakdown = response.parsed_body["breakdown"]
      expect(breakdown).to include("sales_cents" => 20_000, "discount_cents" => 0, "absorbed_fee_cents" => 0,
        "refunded_proceeds_cents" => 5000, "proceeds_cents" => 15_000, "processing_fee_cents" => 551,
        "earned_cents" => 14_449, "paid_cents" => 10_000, "balance_cents" => 4449, "owed_cents" => 4449,
        "buyer_fee_cents" => 1400, "refunded_to_buyers_cents" => 5350)
      expect_breakdown_to_sum(breakdown)
      expect(response.parsed_body["orders_without_items_count"]).to eq(0)
    end

    it "lets an overpaid event offset the others instead of overstating what is owed" do
      refund_in_full!(organizer_order)
      refund_in_full!(legacy_order)

      get "/api/v1/organizer/finances", headers: org_headers(owner)

      body = response.parsed_body
      # Closing Night: 5,000 proceeds - 368 processing - 10,000 paid = -5,368;
      # Next Show still has 4,817 earned, so the organization is 551 short.
      expect(body["breakdown"]).to include("earned_cents" => 9449, "balance_cents" => -551, "owed_cents" => 0,
        "negative_balance_cents" => 551)
      expect_breakdown_to_sum(body["breakdown"])
      expect(body["totals"]["available_to_payout_cents"]).to eq(0)
    end

    it "counts settled orders that have no line items and so are missing from statements" do
      create(:order, event: completed_event, subtotal_cents: 1000, service_fee_cents: 0, total_cents: 1000)

      get "/api/v1/organizer/finances", headers: org_headers(owner)

      expect(response.parsed_body["orders_without_items_count"]).to eq(1)
    end

    it "reports statement and payout status per event" do
      get "/api/v1/organizer/finances", headers: org_headers(owner)

      rows = response.parsed_body["events"].index_by { |row| row["id"] }
      expect(rows[completed_event.id]).to include("settlement_state" => "finalized", "payout_state" => "needs_new_version",
        "paid_cents" => 10_000, "owed_cents" => 4632, "requestable_cents" => 0)
      expect(rows[completed_event.id]["settlement"]).to include("id" => settlement.id, "version" => 1, "current" => true,
        "payable" => false, "available_to_payout_cents" => 4632)
      expect(rows[upcoming_event.id]).to include("settlement" => nil, "settlement_state" => "not_finalized",
        "payout_state" => "awaiting_statement", "owed_cents" => 4817)
    end

    it "is ready to request once a version covering the last payout is finalized" do
      latest = Settlements::Finalizer.call(event: completed_event, actor: owner)

      get "/api/v1/organizer/finances", headers: org_headers(owner)

      row = response.parsed_body["events"].find { |event| event["id"] == completed_event.id }
      expect(row).to include("payout_state" => "ready", "requestable_cents" => 4632)
      expect(row["settlement"]).to include("id" => latest.id, "version" => 2, "payable" => true)
      expect(response.parsed_body["totals"]["requestable_cents"]).to eq(4632)
      payout = PayoutCreator.call(settlement: latest, actor: owner, idempotency_key: "org-finance-ready")
      expect(payout.amount_cents).to eq(4632)
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

    it "writes negative amounts as plain numbers so spreadsheets can total them" do
      get "/api/v1/organizer/events/#{completed_event.id}/finance/statement_export", headers: org_headers(owner)

      items = csv.select { |row| row["line"] == "item" }
      expect(items.find { |row| row["kind"] == "payout" }["amount"]).to eq("-100.00")
      expect(items.select { |row| row["kind"] == "processing_fee" }.map { |row| row["amount"] })
        .to contain_exactly("0.00", "-1.85", "-1.83")
      expect(response.body).not_to include("\t-")
    end

    it "ends a stream that fails part way with a marker row instead of a silently short file" do
      allow(FinanceExports).to receive(:order_csv_values).and_raise(RuntimeError, "boom")
      allow(Rails.logger).to receive(:error).and_call_original

      get "/api/v1/organizer/finances/orders_export", headers: org_headers(owner)

      expect(response.body.lines.last).to include(SpreadsheetExport::INCOMPLETE_MARKER)
      expect(Rails.logger).to have_received(:error).with(/stopped early: RuntimeError: boom/)
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

    it "downloads a masked annual statement only for finance members" do
      year = Date.current.year
      tax = organization.organizer_tax_information || create(:organizer_tax_information, organization: organization)

      get "/api/v1/organizer/annual_statements/#{year}", headers: org_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      expect(response.headers["Cache-Control"]).to include("no-store")
      expect(response.body).not_to include(tax.tin)
      expect(AuditLog.where(action: "annual_tax_report.statement_downloaded")).to exist

      get "/api/v1/organizer/annual_statements/#{year}", headers: org_headers(member(:marketer))
      expect(response).to have_http_status(:forbidden)
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
