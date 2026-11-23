# frozen_string_literal: true

require "rails_helper"
require "csv"

RSpec.describe "Admin monthly BPT event export", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:path) { "/api/v1/admin/tax_reports/bpt_events_export" }
  let(:september_end) { Time.utc(2026, 9, 30, 14) }
  let(:october_end) { Time.utc(2026, 10, 31, 14) }
  let(:event) { create(:event, title: "Private Organizer Name") }

  def captured_order(event:, at:, fee:, environment: "live", provider: "stripe", currency: "usd", payment_id: nil)
    order = create(:order, :completed, event: event, completed_at: at, currency: currency,
      buyer_email: "private-buyer@example.test")
    payment = create(:payment, :succeeded, order: order, provider: provider, provider_environment: environment,
      **(payment_id ? { provider_payment_id: payment_id } : {}))
    create(:fee_component, order: order, amount_cents: fee)
    [order, payment]
  end

  def export(month)
    get path, params: { year: 2026, month: month }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    CSV.parse(response.body, headers: true)
  end

  it "uses Guam collection, refund and paid dates and keeps negative net fees visible" do
    order, capture = captured_order(event: event, at: september_end, fee: 225)
    line = create(:order_item, order: order, discount_cents: 200, organizer_proceeds_cents: 2200)
    create(:fee_component, order: order, kind: "processing", estimated: false, amount_cents: 81)
    create(:fee_component, order: order, kind: "processing", amount_cents: 99)
    create(:payment, :succeeded, order: order, provider_environment: "live")
    refund = create(:refund, order: order, payment: capture, succeeded_at: october_end)
    create(:refund_item, refund: refund, order_item: line, amount_cents: 500, organizer_proceeds_cents: 390,
      fee_cents: 60, organizer_fee_cents: 50)

    test_payment = create(:payment, :succeeded, order: order, provider_environment: "test")
    test_refund = create(:refund, order: order, payment: test_payment, succeeded_at: october_end)
    create(:refund_item, refund: test_refund, order_item: line, amount_cents: 25, organizer_proceeds_cents: 0, fee_cents: 25)

    settlement = create(:settlement, event: event, organization: event.organization)
    bank_account = create(:connected_account, organization: event.organization, provider: "manual", with_readiness_approval: false)
    check_account = create(:connected_account, organization: event.organization, provider: "check", with_readiness_approval: false,
      payout_details: { payee_name: "Test Payee", delivery_method: "pickup" })
    bank = create(:payout, connected_account: bank_account, settlement: settlement, event: event, organization: event.organization, provider: "manual",
      status: :paid, paid_at: october_end, amount_cents: 2000, withheld_cents: 200, carried_withholding_cents: 50)
    check = create(:payout, connected_account: check_account, settlement: settlement, event: event, organization: event.organization, provider: "check",
      status: :paid, paid_at: october_end, amount_cents: 100, withheld_cents: 20)
    check.payout_check_adjustments.create!(amount_cents: -5, reason: "Matched cleared check", created_by_user: admin)
    create(:payout, connected_account: bank_account, settlement: settlement, event: event, organization: event.organization,
      status: :reversed, paid_at: october_end, amount_cents: 900)

    october = export("10")
    expect(october.map(&:to_h)).to eq([{
      "month" => "2026-10", "organization_id" => event.organization_id.to_s, "event_id" => event.id.to_s,
      "gross_service_fees" => "2.25", "refunded_service_fees" => "0.00", "net_service_fees" => "2.25",
      "stripe_processing_fees_informational" => "0.81", "ticket_face_value_collected_as_agent" => "23.00",
      "organizer_payouts" => "0.00", "currency" => "USD"
    }])
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.headers["Content-Disposition"]).to include("hafapass-bpt-events-2026-10.csv")
    expect(response.body).not_to include("Private Organizer Name", "private-buyer@example.test")

    november = export("11")
    expect(november.size).to eq(1)
    expect(november.first.to_h).to include(
      "gross_service_fees" => "0.00", "refunded_service_fees" => "1.10", "net_service_fees" => "-1.10",
      "stripe_processing_fees_informational" => "0.00", "ticket_face_value_collected_as_agent" => "0.00",
      "organizer_payouts" => FinanceExports.money(bank.disbursement_cents + check.confirmed_check_amount_cents)
    )
    expect(AuditLog.where(action: "tax_report.exported").last.metadata).to include(
      "export" => "monthly_bpt_by_event", "year" => 2026, "month" => 11, "organization_ids" => [event.organization_id], "count" => 1
    )
  end

  it "groups by event and organization and excludes test and simulated captures, direct organizer sales and other currencies" do
    same_organization = create(:event, organization: event.organization)
    elsewhere = create(:event)
    captured_order(event: event, at: september_end, fee: 125)
    captured_order(event: same_organization, at: september_end, fee: 200)
    captured_order(event: elsewhere, at: september_end, fee: 325)
    captured_order(event: elsewhere, at: september_end - 1.second, fee: 700)
    captured_order(event: elsewhere, at: september_end, fee: 800, environment: "test")
    captured_order(event: elsewhere, at: september_end, fee: 900, environment: "simulate")
    captured_order(event: elsewhere, at: september_end, fee: 1000, provider: "door_cash")
    captured_order(event: elsewhere, at: september_end, fee: 1100, currency: "jpy")
    captured_order(event: elsewhere, at: september_end, fee: 1300, provider: "boh_clover", environment: nil)
    captured_order(event: elsewhere, at: september_end, fee: 1400, environment: nil, payment_id: "sim_legacy")
    captured_order(event: elsewhere, at: september_end, fee: 25, environment: nil, payment_id: "pi_legacy_live")

    expect(export("10").map { |row| row.values_at("organization_id", "event_id", "gross_service_fees") }).to contain_exactly(
      [event.organization_id.to_s, event.id.to_s, "1.25"],
      [same_organization.organization_id.to_s, same_organization.id.to_s, "2.00"],
      [elsewhere.organization_id.to_s, elsewhere.id.to_s, "3.50"]
    )
    expect(export("02")).to be_empty
  end

  it "omits a month with only a fee-free refund and a withholding-only payout" do
    order, capture = captured_order(event: event, at: september_end, fee: 0)
    line = create(:order_item, order: order)
    refund = create(:refund, order: order, payment: capture, succeeded_at: october_end, amount_cents: 500)
    create(:refund_item, refund: refund, order_item: line)
    create(:payout, event: event, organization: event.organization, status: :paid,
      paid_at: october_end, amount_cents: 100, withheld_cents: 24, carried_withholding_cents: 76)

    expect(export("11")).to be_empty
    expect(AuditLog.where(action: "tax_report.exported").last.metadata).to include("count" => 0, "organization_ids" => [])
  end

  it "rejects a missing or invalid month" do
    [nil, "0", "13", "2.0", "next"].each do |month|
      get path, params: { year: 2026, month: month }, headers: auth_headers(admin)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Choose a month from 1 to 12")
    end
  end
end
