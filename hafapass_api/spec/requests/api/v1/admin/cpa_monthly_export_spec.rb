# frozen_string_literal: true

require "rails_helper"
require "csv"

RSpec.describe "Admin monthly CPA custodial & BPT export", type: :request do
  include ActiveSupport::Testing::TimeHelpers
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
    environment: "live", provider: "stripe", currency: "usd", payment_id: nil, payment_method: "stripe",
    buyer_email: "private-buyer@example.invalid")
    buyer_fee = fee - organizer_fee
    order = create(:order, :completed,
      event: event,
      completed_at: at,
      currency: currency,
      payment_method: payment_method,
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

  def settlement_unpaid_balance_cents(calc_attrs)
    if calc_attrs[:negative_balance_cents].positive?
      -calc_attrs[:negative_balance_cents]
    else
      calc_attrs[:payable_cents] - calc_attrs[:paid_cents]
    end
  end

  def fetch_csv(year:, month:)
    get export_path, params: { year: year, month: month }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    CSV.parse(response.body, headers: true)
  end

  it "separates custodial liability from fee revenue, marks W-9 nonprofit separately from DRT verification, crosses months cleanly, and reconciles with Settlements::Calculator" do
    org = create(:organization, name: "Secret Legal Org")
    create(:organizer_tax_information, organization: org, tax_classification: "nonprofit",
      legal_name: "Secret Nonprofit Legal Name", tin: "123456789")
    event = create(:event, organization: org, title: "Private Gala Title")

    order, item, capture = captured_order(
      event: event, at: october_start_utc, subtotal: 10_000, fee: 600, processing_bearer: "platform"
    )
    create(:fee_component, order: order, kind: "processing", estimated: false, amount_cents: 320,
      created_at: october_start_utc + 1.hour)
    create(:fee_component, order: order, kind: "processing", estimated: true, amount_cents: 999,
      created_at: october_start_utc + 1.hour)

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
      "w9_nonprofit_classification" => "yes",
      "drt_exemption_verified" => "not_tracked",
      "nonprofit_exemption_note" => CpaMonthlyReport::NONPROFIT_NOTE,
      "opening_custodial_liability" => "0.00",
      "proceeds_collected" => "100.00",
      "proceeds_refunded" => "0.00",
      "chargebacks" => "0.00",
      "organizer_processing_deducted" => "0.00",
      "other_adjustments" => "0.00",
      "organizer_payouts_made" => "90.00",
      "payout_reversals" => "0.00",
      "closing_custodial_liability" => "10.00",
      "closing_custodial_payables" => "10.00",
      "closing_organizer_deficits" => "0.00",
      "reserve_held" => "10.00",
      "reserve_released" => "0.00",
      "ending_reserve_balance" => "10.00",
      "unallocated_refunds_exception" => "0.00",
      "reconciliation_exception_flag" => "no",
      "non_custodial_settlement_bridge" => "0.00",
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
      "w9_nonprofit_classification" => "",
      "drt_exemption_verified" => "not_tracked",
      "nonprofit_exemption_note" => "1 W-9 nonprofit row(s); DRT exemption not tracked",
      "closing_custodial_liability" => "10.00",
      "closing_custodial_payables" => "10.00",
      "closing_organizer_deficits" => "0.00",
      "ending_reserve_balance" => "10.00",
      "fee_revenue_net" => "6.00",
      "estimated_bpt_on_fee_revenue_estimate" => "0.24"
    )

    nov = fetch_csv(year: 2026, month: 11)
    expect(nov.size).to eq(2)
    nov_event = nov[0].to_h
    expect(nov_event).to include(
      "opening_custodial_liability" => "10.00",
      "proceeds_collected" => "0.00",
      "proceeds_refunded" => "3.00",
      "chargebacks" => "2.00",
      "organizer_payouts_made" => "5.00",
      "payout_reversals" => "0.00",
      "closing_custodial_liability" => "0.00",
      "reserve_released" => "10.00",
      "ending_reserve_balance" => "0.00",
      "backup_withholding_memo" => "1.20",
      "fee_refunds" => "0.50",
      "fee_revenue_net" => "-0.50",
      "estimated_bpt_on_fee_revenue_estimate" => "0.00"
    )

    expect(nov_event["opening_custodial_liability"]).to eq(oct_event["closing_custodial_liability"])

    settlement_calc = Settlements::Calculator.call(event).attributes
    nov_report = CpaMonthlyReport.new(2026, 11).report[:rows].first
    oct_report = CpaMonthlyReport.new(2026, 10).report[:rows].first

    unrestricted_closing = nov_report[:closing_custodial_liability_cents] -
      nov_report[:ending_reserve_balance_cents] +
      nov_report[:non_custodial_settlement_bridge_cents]
    expect(unrestricted_closing).to eq(settlement_unpaid_balance_cents(settlement_calc))
    expect(nov_report[:ending_reserve_balance_cents]).to eq(settlement_calc[:reserve_cents])
    expect(oct_report[:fee_revenue_net_cents] + nov_report[:fee_revenue_net_cents]).to eq(settlement_calc[:platform_fee_cents])
    expect(oct_report[:stripe_processing_costs_cents] + nov_report[:stripe_processing_costs_cents])
      .to eq(settlement_calc[:processing_fee_cents] + settlement_calc[:platform_processing_fee_cents])

    dec = fetch_csv(year: 2026, month: 12)
    expect(dec.size).to eq(1)
    expect(dec.first.to_h).to include(
      "row_type" => "total",
      "month" => "2026-12",
      "opening_custodial_liability" => "0.00",
      "closing_custodial_liability" => "0.00",
      "closing_custodial_payables" => "0.00",
      "closing_organizer_deficits" => "0.00",
      "fee_revenue_net" => "0.00",
      "estimated_bpt_on_fee_revenue_estimate" => "0.00"
    )
  end

  # Regression spec for Finding #1: closed month is period-stable when a payout
  # is reversed in a later month or when late Stripe processing evidence arrives.
  it "keeps closed months immutable when a payout is reversed or late processing evidence arrives in a later month" do
    org = create(:organization)
    event = create(:event, organization: org)
    order, _item, capture = captured_order(
      event: event, at: october_start_utc + 1.day, subtotal: 10_000, fee: 600, processing_bearer: "organizer"
    )
    settlement = create(:settlement, event: event, organization: org)
    account = create(:connected_account, organization: org, provider: "manual", with_readiness_approval: false)
    payout = create(:payout,
      connected_account: account, settlement: settlement, event: event, organization: org,
      provider: "manual", provider_payout_id: "bank-oct-001", status: :paid,
      created_at: october_start_utc + 2.days,
      paid_at: october_start_utc + 5.days,
      amount_cents: 9_000, withheld_cents: 0, carried_withholding_cents: 0)

    # Snapshot October BEFORE November events occur
    oct_before = fetch_csv(year: 2026, month: 10).map(&:to_h)
    expect(oct_before.first).to include(
      "proceeds_collected" => "100.00",
      "organizer_processing_deducted" => "0.00",
      "organizer_payouts_made" => "90.00",
      "payout_reversals" => "0.00",
      "closing_custodial_liability" => "10.00",
      "stripe_processing_costs_informational" => "0.00"
    )

    # November event A: October payout is reversed via PayoutReconciler on Nov 5
    travel_to(november_start_utc + 5.days) do
      PayoutReconciler.call(
        payout: payout,
        actor: admin,
        status: "reversed",
        provider_payout_id: "bank-oct-001",
        evidence: {
          reference: "bank/rev-nov-001",
          confirmed_at: (november_start_utc + 4.days).iso8601,
          reason: "ACH returned by receiving bank"
        }
      )
    end

    # November event B: Late Stripe processing fee evidence arrives on Nov 6
    proc_component = create(:fee_component, order: order, kind: "processing", estimated: false,
      amount_cents: 320, provider_reference: "txn_late_1", created_at: november_start_utc + 6.days)
    StripeFeeEvidence.create!(
      payment: capture,
      fee_component: proc_component,
      context_digest: StripeProcessingFees.context_digest(capture),
      status: :verified,
      provider_charge_id: "ch_late_1",
      provider_balance_transaction_id: "txn_late_1",
      evidence_digest: "digest_late_1",
      amount_cents: order.total_cents,
      fee_cents: 320,
      net_cents: order.total_cents - 320,
      currency: "usd",
      verified_at: november_start_utc + 6.days
    )

    # Regenerate October: MUST be byte-for-byte identical to before November happened!
    oct_after = fetch_csv(year: 2026, month: 10).map(&:to_h)
    expect(oct_after).to eq(oct_before)

    # November records both movements cleanly and reconciles to Settlements::Calculator
    nov = fetch_csv(year: 2026, month: 11).first.to_h
    expect(nov).to include(
      "opening_custodial_liability" => "10.00",
      "organizer_processing_deducted" => "3.20",
      "organizer_payouts_made" => "0.00",
      "payout_reversals" => "90.00",
      "closing_custodial_liability" => "96.80",
      "stripe_processing_costs_informational" => "3.20"
    )
    calc = Settlements::Calculator.call(event).attributes
    expect(CpaMonthlyReport.new(2026, 11).report[:rows].first[:closing_custodial_liability_cents])
      .to eq(settlement_unpaid_balance_cents(calc))
  end

  # Regression spec for Finding #2: adjustment-only orgs/events appear in opening
  # & closing liability, and unallocated legacy refunds are surfaced as exceptions.
  it "includes adjustment-only events and organizations in opening liability and flags unallocated legacy refunds" do
    adj_only_org = create(:organization)
    adj_only_event = create(:event, organization: adj_only_org)
    BalanceAdjustment.create!(
      organization: adj_only_org, event: adj_only_event, kind: "manual_credit", amount_cents: 4_500,
      currency: "usd", status: :posted, reason: "Opening event balance credit",
      effective_at: october_start_utc + 2.days
    )

    org_level_only = create(:organization)
    BalanceAdjustment.create!(
      organization: org_level_only, event: nil, kind: "manual_credit", amount_cents: 2_500,
      currency: "usd", status: :posted, reason: "Org-level opening balance credit",
      effective_at: october_start_utc + 2.days
    )

    legacy_org = create(:organization)
    legacy_event = create(:event, organization: legacy_org)
    order, _item, capture = captured_order(
      event: legacy_event, at: october_start_utc + 1.day, subtotal: 5_000, fee: 350
    )
    # Succeeded legacy refund with ZERO RefundItem allocations
    create(:refund, order: order, payment: capture, succeeded_at: november_start_utc + 2.days, amount_cents: 1_500)

    nov = fetch_csv(year: 2026, month: 11).map(&:to_h)
    by_key = nov.select { |row| row["row_type"] == "event" }.index_by { |row| [row["organization_id"], row["event_id"]] }

    expect(by_key[[adj_only_org.id.to_s, adj_only_event.id.to_s]]).to include(
      "opening_custodial_liability" => "45.00",
      "closing_custodial_liability" => "45.00",
      "reconciliation_exception_flag" => "no"
    )
    expect(by_key[[org_level_only.id.to_s, ""]]).to include(
      "opening_custodial_liability" => "25.00",
      "closing_custodial_liability" => "25.00",
      "reconciliation_exception_flag" => "no"
    )
    expect(by_key[[legacy_org.id.to_s, legacy_event.id.to_s]]).to include(
      "opening_custodial_liability" => "50.00",
      "proceeds_refunded" => "0.00",
      "unallocated_refunds_exception" => "15.00",
      "reconciliation_exception_flag" => "yes"
    )
    total = nov.find { |row| row["row_type"] == "total" }
    expect(total).to include(
      "unallocated_refunds_exception" => "15.00",
      "reconciliation_exception_flag" => "yes"
    )
  end

  # Regression spec for Finding #3: settlement bridge for organizer-direct Clover
  # sales, exact negative-balance reconciliation (no double-counting), and
  # disputes scoped by disputes.payment_id.
  it "bridges non-custodial Clover sales to Settlements::Calculator, reconciles negative balances without double-counting, and scopes disputes by payment_id" do
    org = create(:organization)
    event = create(:event, organization: org)

    # 1. Custodial Stripe sale ($100) + organizer-direct Clover sale ($40) on same event
    stripe_order, _item, live_capture = captured_order(
      event: event, at: october_start_utc + 1.day, subtotal: 10_000, fee: 600
    )
    captured_order(
      event: event, at: october_start_utc + 2.days, subtotal: 4_000, fee: 0,
      provider: "boh_clover", environment: nil, payment_method: "door_card"
    )

    # 2. A test payment on the SAME Stripe order has a lost dispute ($25) — must NOT enter custodial chargebacks!
    test_payment = create(:payment, :succeeded, order: stripe_order, provider: "stripe", provider_environment: "test")
    Dispute.create!(
      order: stripe_order, payment: test_payment, provider: "stripe", provider_dispute_id: "dp_test_ignored",
      amount_cents: 2_500, currency: "usd", status: :lost,
      opened_at: october_start_utc + 3.days, closed_at: october_start_utc + 4.days
    )

    # 3. Overpay custodial payout ($120 paid on $100 custodial proceeds) -> -$20 custodial shortfall
    settlement = create(:settlement, event: event, organization: org)
    account = create(:connected_account, organization: org, provider: "manual", with_readiness_approval: false)
    create(:payout,
      connected_account: account, settlement: settlement, event: event, organization: org,
      provider: "manual", status: :paid, paid_at: october_start_utc + 5.days,
      amount_cents: 12_000, withheld_cents: 0, carried_withholding_cents: 0)

    oct_data = CpaMonthlyReport.new(2026, 10).report
    row = oct_data[:rows].first

    # Custodial liability reflects ONLY Stripe live capture ($100) - payout ($120) = -$20; test dispute excluded
    expect(row[:proceeds_collected_cents]).to eq(10_000)
    expect(row[:chargebacks_cents]).to eq(0)
    expect(row[:closing_custodial_liability_cents]).to eq(-2_000)
    # Bridge accounts for Clover ($40) minus non-agent test dispute ($25) = +$15 in Settlements::Calculator
    expect(row[:non_custodial_settlement_bridge_cents]).to eq(1_500)

    calc = Settlements::Calculator.call(event).attributes
    # Settlements::Calculator has $100 + $40 - $25 dispute - $120 paid = -$5 (negative_balance_cents = 500, payable = 0)
    expect(calc[:negative_balance_cents]).to eq(500)
    expect(settlement_unpaid_balance_cents(calc)).to eq(-500)
    expect(row[:closing_custodial_liability_cents] - row[:ending_reserve_balance_cents] + row[:non_custodial_settlement_bridge_cents])
      .to eq(settlement_unpaid_balance_cents(calc))
  end

  # Regression spec for Finding #4: totals separate custodial payables from
  # organizer deficits and never net unrelated organizers against each other.
  it "separates custodial payables and organizer deficits per organization without netting unrelated organizers" do
    org_a = create(:organization)
    event_a1 = create(:event, organization: org_a)
    event_a2 = create(:event, organization: org_a)
    # Org A Event 1: +$500; Org A Event 2: -$100 (offset allowed within Org A -> Org A net = +$400 payable)
    captured_order(event: event_a1, at: october_start_utc + 1.day, subtotal: 50_000, fee: 2_600)
    BalanceAdjustment.create!(
      organization: org_a, event: event_a2, kind: "manual_debit", amount_cents: -10_000,
      currency: "usd", status: :posted, reason: "Same-org deficit", effective_at: october_start_utc + 2.days
    )

    org_b = create(:organization)
    event_b = create(:event, organization: org_b)
    # Org B: -$200 deficit (MUST NOT net against Org A's +$400 payable!)
    BalanceAdjustment.create!(
      organization: org_b, event: event_b, kind: "manual_debit", amount_cents: -20_000,
      currency: "usd", status: :posted, reason: "Unrelated org deficit", effective_at: october_start_utc + 2.days
    )

    csv = fetch_csv(year: 2026, month: 10)
    total = csv.find { |row| row["row_type"] == "total" }.to_h
    expect(total).to include(
      "closing_custodial_liability" => "200.00",
      "closing_custodial_payables" => "400.00",
      "closing_organizer_deficits" => "200.00"
    )
  end

  it "reconciles platform mixed-cart processing splits, organizer-borne processing, and general adjustments with Settlements::Calculator" do
    org = create(:organization)
    event = create(:event, organization: org)
    # Order 1: organizer-borne processing ($1.80)
    order1, = captured_order(event: event, at: october_start_utc + 1.day, subtotal: 5_000, fee: 350, processing_bearer: "organizer")
    create(:fee_component, order: order1, kind: "processing", estimated: false, amount_cents: 180,
      created_at: october_start_utc + 1.day)

    # Order 2: platform-borne mixed cart ($20 ticket + $10 add-on = $30, processing $90 -> $60 platform, $30 organizer)
    catalog_item = CatalogItem.create!(event: event, name: "Event Tee", kind: :add_on, price_cents: 1_000, inventory_quantity: 10)
    order2 = create(:order, :completed, event: event, completed_at: october_start_utc + 2.days,
      currency: "usd", subtotal_cents: 3_000, discount_cents: 0, service_fee_cents: 0,
      organizer_fee_cents: 0, total_cents: 3_000, processing_fee_bearer_snapshot: "platform")
    create(:order_item, order: order2, quantity: 1, unit_price_cents: 2_000, subtotal_cents: 2_000,
      discount_cents: 0, fee_cents: 0, organizer_proceeds_cents: 2_000)
    create(:order_item, order: order2, item_kind: :add_on, ticket_type: nil, catalog_item: catalog_item,
      name: "Event Tee", quantity: 1, unit_price_cents: 1_000, subtotal_cents: 1_000,
      discount_cents: 0, fee_cents: 0, organizer_proceeds_cents: 1_000)
    create(:payment, :succeeded, order: order2, provider: "stripe", provider_environment: "live", amount_cents: 3_000)
    create(:fee_component, order: order2, kind: "processing", estimated: false, amount_cents: 90,
      created_at: october_start_utc + 2.days)

    BalanceAdjustment.create!(
      organization: org, event: event, kind: "manual_debit", amount_cents: -250, currency: "usd",
      status: :posted, reason: "Reconciled fee debit", effective_at: october_start_utc + 2.days
    )
    BalanceAdjustment.create!(
      organization: org, event: event, kind: "reserve_hold", amount_cents: -500, currency: "usd",
      status: :posted, reason: "Reserve hold", effective_at: october_start_utc + 2.days
    )

    row = CpaMonthlyReport.new(2026, 10).report[:rows].first
    expect(row[:w9_nonprofit_classification]).to be(false)
    expect(row[:drt_exemption_verified]).to eq("not_tracked")
    expect(row[:organizer_processing_deducted_cents]).to eq(180 + 30)
    expect(row[:stripe_processing_costs_cents]).to eq(180 + 90)
    expect(row[:other_adjustments_cents]).to eq(-250)
    expect(row[:closing_custodial_liability_cents]).to eq(8_000 - 210 - 250)
    expect(row[:ending_reserve_balance_cents]).to eq(500)

    calc = Settlements::Calculator.call(event).attributes
    expect(row[:closing_custodial_liability_cents] - row[:ending_reserve_balance_cents])
      .to eq(settlement_unpaid_balance_cents(calc))
    expect(row[:ending_reserve_balance_cents]).to eq(calc[:reserve_cents])
  end

  it "enforces Guam timezone month boundaries, P.L. 38-136 rate schedule, and excludes test, simulated, cash, Clover, and non-USD sales" do
    org = create(:organization)
    event = create(:event, organization: org)

    captured_order(event: event, at: october_start_utc - 1.second, subtotal: 2_000, fee: 200)
    captured_order(event: event, at: october_start_utc, subtotal: 3_000, fee: 250)
    captured_order(event: event, at: october_start_utc + 1.hour, subtotal: 4_000, fee: 300, environment: "test")
    captured_order(event: event, at: october_start_utc + 1.hour, subtotal: 4_000, fee: 300, environment: "simulate")
    captured_order(event: event, at: october_start_utc + 1.hour, subtotal: 4_000, fee: 300, provider: "door_cash", payment_method: "door_cash")
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
    expect(SpreadsheetExport.safe_value(FinanceExports.money(-110))).to eq("-1.10")

    allow_any_instance_of(CpaMonthlyReport).to receive(:csv_rows).and_return([
      ["event", "2026-10", 1, 2, "yes", "not_tracked", "=HYPERLINK(\"http://evil.invalid\")",
        FinanceExports.money(-110), *Array.new(14, FinanceExports.money(0)), "no",
        *Array.new(9, FinanceExports.money(0)), "USD"]
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
    expect(response.parsed_body["bpt_rate_note"]).to include("P.L. 38-136")

    [nil, "0", "13", "abc"].each do |bad_month|
      get export_path, params: { year: 2026, month: bad_month }, headers: auth_headers(admin)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Choose a month from 1 to 12")
    end
  end
end
