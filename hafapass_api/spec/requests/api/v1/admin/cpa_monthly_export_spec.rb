# frozen_string_literal: true

require "rails_helper"
require "csv"

RSpec.describe "Admin monthly CPA custodial & BPT export", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:export_path) { "/api/v1/admin/tax_reports/cpa_monthly_export" }
  let(:json_path) { "/api/v1/admin/tax_reports/cpa_monthly" }

  # Pacific/Guam is UTC+10 year-round (no DST):
  # 2026-09-30 13:59:59 UTC == 2026-09-30 23:59:59 ChST (September)
  # 2026-09-30 14:00:00 UTC == 2026-10-01 00:00:00 ChST (October)
  # 2026-10-31 14:00:00 UTC == 2026-11-01 00:00:00 ChST (November)
  let(:october_start_utc) { Time.utc(2026, 9, 30, 14, 0, 0) }
  let(:november_start_utc) { Time.utc(2026, 10, 31, 14, 0, 0) }

  def captured_order(event:, at:, subtotal:, fee:, discount: 0, organizer_fee: 0, processing_bearer: "platform",
    environment: "live", provider: "stripe", currency: "usd", payment_id: nil, buyer_email: "private-buyer@example.invalid")
    buyer_fee = fee - organizer_fee
    order = create(:order, :completed,
      event: event,
      completed_at: at,
      currency: currency,
      buyer_name: "Private Buyer Name",
      buyer_email: buyer_email,
      subtotal_cents: subtotal,
      discount_cents: discount,
      service_fee_cents: buyer_fee,
      organizer_fee_cents: organizer_fee,
      total_cents: subtotal - discount + buyer_fee,
      processing_fee_bearer_snapshot: processing_bearer)
    item = create(:order_item,
      order: order,
      quantity: 1,
      unit_price_cents: subtotal,
      subtotal_cents: subtotal,
      discount_cents: discount,
      fee_cents: buyer_fee,
      organizer_fee_cents: organizer_fee,
      organizer_proceeds_cents: subtotal - discount - organizer_fee)
    payment = create(:payment, :succeeded,
      order: order,
      provider: provider,
      provider_environment: environment,
      amount_cents: order.total_cents,
      currency: currency,
      **(payment_id ? { provider_payment_id: payment_id } : {}))
    create(:fee_component, order: order, kind: "platform", estimated: false, amount_cents: fee) if fee.positive?
    [order, item, payment]
  end

  def fetch_csv(year:, month:)
    get export_path, params: { year: year, month: month }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    CSV.parse(response.body, headers: true)
  end

  it "separates custodial liability from fee revenue, tracks reserves, crosses months cleanly, and reconciles with Settlements::Calculator" do
    org = create(:organization, name: "Secret Legal Org")
    create(:organizer_tax_information, organization: org, tax_classification: "nonprofit",
      legal_name: "Secret Nonprofit Legal Name", tin: "123456789")
    event = create(:event, organization: org, title: "Private Gala Title")

    # October 2026: $100.00 ticket collected (buyer pays $6.00 service fee; HåfaPass bears $3.20 Stripe processing)
    order, item, capture = captured_order(
      event: event, at: october_start_utc, subtotal: 10_000, fee: 600, processing_bearer: "platform"
    )
    create(:fee_component, order: order, kind: "processing", estimated: false, amount_cents: 320)
    # Estimated processing fee must be ignored
    create(:fee_component, order: order, kind: "processing", estimated: true, amount_cents: 999)

    # October 2026: 10% reserve held ($10.00) and initial 90% payout paid ($90.00 gross, $0 withheld)
    BalanceAdjustment.create!(
      organization: org, event: event, kind: "reserve_hold", amount_cents: -1_000, currency: "usd",
      status: :posted, reason: "10% 30-day chargeback reserve", effective_at: october_start_utc + 5.days
    )
    settlement = create(:settlement, event: event, organization: org)
    account = create(:connected_account, organization: org, provider: "manual", with_readiness_approval: false)
    create(:payout,
      connected_account: account, settlement: settlement, event: event, organization: org,
      provider: "manual", status: :paid, paid_at: october_start_utc + 6.days,
      amount_cents: 9_000, withheld_cents: 0, carried_withholding_cents: 0)

    # November 2026: cross-month partial refund ($20.00 proceeds + $1.20 fee), lost chargeback ($5.00),
    # reserve release ($10.00), and final payout ($0 — negative balance -$15.00 carried!)
    # Wait: let's make November have a partial refund ($3.00 proceeds + $0.50 fee), a lost chargeback ($2.00),
    # a reserve release ($10.00), and a final payout of the remaining $5.00 (with $1.20 backup withholding memo).
    refund = create(:refund, order: order, payment: capture, succeeded_at: november_start_utc, amount_cents: 350)
    create(:refund_item, refund: refund, order_item: item,
      amount_cents: 350, organizer_proceeds_cents: 300, fee_cents: 50, organizer_fee_cents: 0)
    Dispute.create!(
      order: order, payment: capture, provider: "stripe", provider_dispute_id: "dp_lost_1",
      amount_cents: 200, currency: "usd", status: :lost,
      opened_at: november_start_utc + 1.day, closed_at: november_start_utc + 2.days
    )
    BalanceAdjustment.create!(
      organization: org, event: event, kind: "reserve_release", amount_cents: 1_000, currency: "usd",
      status: :posted, reason: "30-day reserve released", effective_at: november_start_utc + 10.days
    )
    create(:payout,
      connected_account: account, settlement: settlement, event: event, organization: org,
      provider: "manual", status: :paid, paid_at: november_start_utc + 11.days,
      amount_cents: 500, withheld_cents: 120, carried_withholding_cents: 0)

    oct = fetch_csv(year: 2026, month: 10)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.headers["Content-Disposition"]).to include("hafapass-cpa-monthly-2026-10.csv")
    expect(response.body).not_to include(
      "Secret Legal Org", "Secret Nonprofit Legal Name", "Private Gala Title",
      "Private Buyer Name", "private-buyer@example.invalid", "123456789"
    )

    expect(oct.size).to eq(2)
    oct_event = oct[0].to_h
    oct_total = oct[1].to_h
    expect(oct_event).to eq({
      "row_type" => "event",
      "month" => "2026-10",
      "organization_id" => org.id.to_s,
      "event_id" => event.id.to_s,
      "nonprofit_exempt_flag" => "yes",
      "nonprofit_exemption_note" => CpaMonthlyReport::NONPROFIT_NOTE,
      "opening_custodial_liability" => "0.00",
      "proceeds_collected" => "100.00",
      "proceeds_refunded" => "0.00",
      "chargebacks" => "0.00",
      "organizer_processing_deducted" => "0.00",
      "other_adjustments" => "0.00",
      "organizer_payouts_made" => "90.00",
      "closing_custodial_liability" => "10.00",
      "reserve_held" => "10.00",
      "reserve_released" => "0.00",
      "ending_reserve_balance" => "10.00",
      "backup_withholding_memo" => "0.00",
      "fee_revenue_gross" => "6.00",
      "fee_refunds" => "0.00",
      "fee_revenue_net" => "6.00",
      "stripe_processing_costs_informational" => "3.20",
      "bpt_base_fee_revenue_estimate" => "6.00",
      "estimated_bpt_rate_pct" => "4.00",
      "estimated_bpt_on_fee_revenue_estimate" => "0.24",
      "currency" => "USD"
    })
    expect(oct_total).to include(
      "row_type" => "total",
      "organization_id" => "",
      "event_id" => "",
      "nonprofit_exemption_note" => "1 nonprofit-flagged row(s)",
      "closing_custodial_liability" => "10.00",
      "ending_reserve_balance" => "10.00",
      "fee_revenue_net" => "6.00",
      "estimated_bpt_on_fee_revenue_estimate" => "0.24"
    )

    nov = fetch_csv(year: 2026, month: 11)
    expect(nov.size).to eq(2)
    nov_event = nov[0].to_h
    expect(nov_event).to eq({
      "row_type" => "event",
      "month" => "2026-11",
      "organization_id" => org.id.to_s,
      "event_id" => event.id.to_s,
      "nonprofit_exempt_flag" => "yes",
      "nonprofit_exemption_note" => CpaMonthlyReport::NONPROFIT_NOTE,
      "opening_custodial_liability" => "10.00",
      "proceeds_collected" => "0.00",
      "proceeds_refunded" => "3.00",
      "chargebacks" => "2.00",
      "organizer_processing_deducted" => "0.00",
      "other_adjustments" => "0.00",
      "organizer_payouts_made" => "5.00",
      "closing_custodial_liability" => "0.00",
      "reserve_held" => "0.00",
      "reserve_released" => "10.00",
      "ending_reserve_balance" => "0.00",
      "backup_withholding_memo" => "1.20",
      "fee_revenue_gross" => "0.00",
      "fee_refunds" => "0.50",
      "fee_revenue_net" => "-0.50",
      "stripe_processing_costs_informational" => "0.00",
      "bpt_base_fee_revenue_estimate" => "-0.50",
      "estimated_bpt_rate_pct" => "4.00",
      "estimated_bpt_on_fee_revenue_estimate" => "0.00",
      "currency" => "USD"
    })

    # Roll-forward continuity: Oct closing == Nov opening
    expect(nov_event["opening_custodial_liability"]).to eq(oct_event["closing_custodial_liability"])

    # Exact reconciliation to Settlements::Calculator (the payout statement service)
    settlement_calc = Settlements::Calculator.call(event).attributes
    nov_report = CpaMonthlyReport.new(2026, 11).report[:rows].first
    oct_report = CpaMonthlyReport.new(2026, 10).report[:rows].first

    unrestricted_closing = nov_report[:closing_custodial_liability_cents] - nov_report[:ending_reserve_balance_cents]
    calc_unpaid = settlement_calc[:payable_cents] - settlement_calc[:paid_cents] - settlement_calc[:negative_balance_cents]
    expect(unrestricted_closing).to eq(calc_unpaid)
    expect(nov_report[:ending_reserve_balance_cents]).to eq(settlement_calc[:reserve_cents])
    expect(oct_report[:fee_revenue_net_cents] + nov_report[:fee_revenue_net_cents]).to eq(settlement_calc[:platform_fee_cents])
    expect(oct_report[:stripe_processing_costs_cents] + nov_report[:stripe_processing_costs_cents])
      .to eq(settlement_calc[:processing_fee_cents] + settlement_calc[:platform_processing_fee_cents])

    # December 2026: settled event with zero liability and zero activity is omitted; totals row remains zero
    dec = fetch_csv(year: 2026, month: 12)
    expect(dec.size).to eq(1)
    expect(dec.first.to_h).to include(
      "row_type" => "total",
      "month" => "2026-12",
      "opening_custodial_liability" => "0.00",
      "closing_custodial_liability" => "0.00",
      "fee_revenue_net" => "0.00",
      "estimated_bpt_on_fee_revenue_estimate" => "0.00"
    )

    audit = AuditLog.where(action: "tax_report.exported").last
    expect(audit.metadata).to include(
      "export" => "monthly_cpa_custodial_bpt", "year" => 2026, "month" => 12, "count" => 0, "organization_ids" => []
    )
  end

  it "reconciles organizer-borne processing costs and general balance adjustments with Settlements::Calculator" do
    org = create(:organization)
    event = create(:event, organization: org)
    # Organizer-borne processing order + manual debit adjustment
    order, = captured_order(event: event, at: october_start_utc + 1.day, subtotal: 5_000, fee: 350, processing_bearer: "organizer")
    create(:fee_component, order: order, kind: "processing", estimated: false, amount_cents: 180)
    BalanceAdjustment.create!(
      organization: org, event: event, kind: "manual_debit", amount_cents: -250, currency: "usd",
      status: :posted, reason: "Reconciled fee debit", effective_at: october_start_utc + 2.days
    )
    BalanceAdjustment.create!(
      organization: org, event: event, kind: "reserve_hold", amount_cents: -500, currency: "usd",
      status: :posted, reason: "Reserve hold", effective_at: october_start_utc + 2.days
    )

    data = CpaMonthlyReport.new(2026, 10).report
    row = data[:rows].first
    expect(row[:nonprofit_exempt_flag]).to be(false)
    expect(row[:organizer_processing_deducted_cents]).to eq(180)
    expect(row[:stripe_processing_costs_cents]).to eq(180)
    expect(row[:other_adjustments_cents]).to eq(-250)
    expect(row[:closing_custodial_liability_cents]).to eq(5_000 - 180 - 250)
    expect(row[:ending_reserve_balance_cents]).to eq(500)

    calc = Settlements::Calculator.call(event).attributes
    expect(row[:closing_custodial_liability_cents] - row[:ending_reserve_balance_cents]).to eq(calc[:payable_cents] - calc[:paid_cents])
    expect(row[:ending_reserve_balance_cents]).to eq(calc[:reserve_cents])
  end

  it "enforces Guam timezone month boundaries and excludes test, simulated, cash, Clover, and non-USD sales" do
    org = create(:organization)
    event = create(:event, organization: org)

    # 1 second before October starts in Guam (Sept 30 23:59:59 ChST)
    captured_order(event: event, at: october_start_utc - 1.second, subtotal: 2_000, fee: 200)
    # Exact start of October in Guam (Oct 1 00:00:00 ChST)
    captured_order(event: event, at: october_start_utc, subtotal: 3_000, fee: 250)
    # Excluded non-agent / non-live / non-USD orders in October
    captured_order(event: event, at: october_start_utc + 1.hour, subtotal: 4_000, fee: 300, environment: "test")
    captured_order(event: event, at: october_start_utc + 1.hour, subtotal: 4_000, fee: 300, environment: "simulate")
    captured_order(event: event, at: october_start_utc + 1.hour, subtotal: 4_000, fee: 300, provider: "door_cash")
    captured_order(event: event, at: october_start_utc + 1.hour, subtotal: 4_000, fee: 300, provider: "boh_clover", environment: nil)
    captured_order(event: event, at: october_start_utc + 1.hour, subtotal: 4_000, fee: 300, currency: "jpy")
    captured_order(event: event, at: october_start_utc + 1.hour, subtotal: 4_000, fee: 300, environment: nil, payment_id: "sim_legacy")

    sept = fetch_csv(year: 2026, month: 9)
    expect(sept.first.to_h).to include(
      "month" => "2026-09",
      "opening_custodial_liability" => "0.00",
      "proceeds_collected" => "20.00",
      "closing_custodial_liability" => "20.00",
      "fee_revenue_gross" => "2.00",
      "estimated_bpt_rate_pct" => "4.50",
      "estimated_bpt_on_fee_revenue_estimate" => "0.09"
    )

    oct = fetch_csv(year: 2026, month: 10)
    expect(oct.first.to_h).to include(
      "month" => "2026-10",
      "opening_custodial_liability" => "20.00",
      "proceeds_collected" => "30.00",
      "closing_custodial_liability" => "50.00",
      "fee_revenue_gross" => "2.50",
      "estimated_bpt_rate_pct" => "4.00",
      "estimated_bpt_on_fee_revenue_estimate" => "0.10"
    )
  end

  it "neutralizes formula-injection strings while preserving negative numeric Amount cells" do
    expect(SpreadsheetExport.safe_value("=SUM(A1:A2)")).to eq("\t=SUM(A1:A2)")
    expect(SpreadsheetExport.safe_value("+cmd|' /C calc'!A0")).to eq("\t+cmd|' /C calc'!A0")
    expect(SpreadsheetExport.safe_value("@SUM(1+1)")).to eq("\t@SUM(1+1)")
    expect(SpreadsheetExport.safe_value("-1+1")).to eq("\t-1+1")
    expect(SpreadsheetExport.safe_value(FinanceExports.money(-110))).to eq("-1.10")

    # Even if a note/text cell were injected with a leading formula character, stream_csv neutralizes it
    allow_any_instance_of(CpaMonthlyReport).to receive(:csv_rows).and_return([
      ["event", "2026-10", 1, 2, "yes", "=HYPERLINK(\"http://evil.invalid\")",
        FinanceExports.money(-110), *Array.new(18, FinanceExports.money(0)), "USD"]
    ])
    get export_path, params: { year: 2026, month: 10 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    row = CSV.parse(response.body, headers: true).first
    expect(row["nonprofit_exemption_note"]).to eq("\t=HYPERLINK(\"http://evil.invalid\")")
    expect(row["opening_custodial_liability"]).to eq("-1.10")
  end

  it "returns JSON preview for admins, rejects non-admins, and rejects invalid months" do
    non_admin = create(:user)
    [json_path, export_path].each do |endpoint|
      get endpoint, params: { year: 2026, month: 10 }, headers: auth_headers(non_admin)
      expect(response).to have_http_status(:forbidden)
    end

    get json_path, params: { year: 2026, month: 10 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.parsed_body).to include(
      "year" => 2026, "month" => 10, "period" => "2026-10", "timezone" => "Pacific/Guam", "bpt_rate_pct" => "4.00"
    )

    [nil, "0", "13", "abc"].each do |bad_month|
      get export_path, params: { year: 2026, month: bad_month }, headers: auth_headers(admin)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Choose a month from 1 to 12")
    end
  end
end
