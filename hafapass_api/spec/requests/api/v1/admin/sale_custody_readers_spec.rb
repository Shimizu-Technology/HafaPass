# frozen_string_literal: true

require "rails_helper"
require "csv"

# A2 review finding 4 (17324039): one fixture through every reader. The CPA
# workpaper, the BPT detail CSV, the BPT monthly receipts view and the annual
# organizer view share which capture puts a sale in custody and when
# (Commerce::SaleCustody), so a legacy completion just before Guam midnight
# whose qualifying capture was recorded just after it, and its fee refund
# recorded between them, land in the same month everywhere. A Clover sale
# with a classified Stripe second payment is never Stripe custody, never
# HåfaPass fee revenue in BPT detail, and a later capture changes no
# closed month.
RSpec.describe "Shared sale custody across CPA and BPT readers", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:guam) { ActiveSupport::TimeZone["Pacific/Guam"] }
  let(:organization) { create(:organization) }
  let(:profile) { create(:organizer_profile, organization: organization) }
  let(:event) { create(:event, organization: organization, organizer_profile: profile) }

  def at(*parts) = guam.local(*parts)

  def sale!(completed_at:, captured_at:, provider: "stripe", fee: 100, proceeds: 1000)
    order = create(:order, :completed, event: event, completed_at: completed_at, currency: "usd",
      subtotal_cents: proceeds, service_fee_cents: fee, total_cents: proceeds + fee, created_at: completed_at - 1.hour)
    item = create(:order_item, order: order, quantity: 1, unit_price_cents: proceeds, subtotal_cents: proceeds,
      organizer_proceeds_cents: proceeds, fee_cents: fee)
    payment = create(:payment, :succeeded, order: order, provider: provider, amount_cents: proceeds + fee,
      provider_environment: provider == "stripe" ? "live" : nil, created_at: captured_at, succeeded_at: captured_at,
      provider_payment_id: "#{provider == 'stripe' ? 'pi_live' : 'clover'}_#{SecureRandom.hex(4)}")
    order.update!(fulfilled_by_payment_id: payment.id)
    stamp!(payment, :capture_recorded_at, captured_at, trigger: "payments_capture_recorded_at") if payment.reload.capture_recorded_at
    create(:fee_component, order: order, kind: "platform", amount_cents: fee, created_at: completed_at)
    [order, item, payment]
  end

  def fee_refund!(order, item, payment, at:, fee: 100)
    refund = create(:refund, order: order, payment: payment, amount_cents: fee, status: :succeeded, succeeded_at: at,
      created_at: at)
    create(:refund_item, refund: refund, order_item: item, amount_cents: fee, organizer_proceeds_cents: 0, fee_cents: fee)
    refund
  end

  def cpa_row(month)
    CpaMonthlyReport.new(2027, month).report[:rows].find { |row| row[:event_id] == event.id }
  end

  def cpa_csv(month)
    get "/api/v1/admin/tax_reports/cpa_monthly_export", params: { year: 2027, month: month }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    CSV.parse(response.body.delete_prefix("﻿"), headers: true).find { |row| row["event_id"] == event.id.to_s }&.to_h
  end

  def bpt_csv(month)
    get "/api/v1/admin/tax_reports/bpt_events_export", params: { year: 2027, month: month }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    CSV.parse(response.body, headers: true).find { |row| row["event_id"] == event.id.to_s }&.to_h
  end

  def months = TaxReports.new(2027).months

  def organizer_row = TaxReports.new(2027).organizers.find { |row| row[:organization_id] == organization.id }

  it "books a midnight-straddling legacy sale and its fee refund in the capture's month in every reader" do
    order, item, payment = sale!(completed_at: at(2027, 1, 31, 23, 58), captured_at: at(2027, 2, 1, 0, 1))
    fee_refund!(order, item, payment, at: at(2027, 1, 31, 23, 59))

    # January holds no custody, fee or refund (only the CPA's documented
    # non-custodial bridge for a completed sale not yet in custody).
    expect(cpa_row(1)).to include(proceeds_collected_cents: 0, fee_revenue_gross_cents: 0, fee_refunds_cents: 0,
      proceeds_refunded_cents: 0, closing_custodial_liability_cents: 0, non_custodial_settlement_bridge_cents: 1000)
    expect(cpa_row(2)).to include(proceeds_collected_cents: 1000, fee_revenue_gross_cents: 100, fee_refunds_cents: 100)
    expect(cpa_csv(2)).to include("proceeds_collected" => "10.00", "fee_revenue_gross" => "1.00", "fee_refunds" => "1.00")
    expect(bpt_csv(1)).to be_nil
    expect(bpt_csv(2)).to include("gross_service_fees" => "1.00", "refunded_service_fees" => "1.00",
      "ticket_face_value_collected_as_agent" => "10.00")
    expect(months.values_at(0, 1).map { |row| row.values_at(:fees_collected_cents, :fees_refunded_cents) })
      .to eq([[0, 0], [100, 100]])
    expect(organizer_row).to include(fees_collected_cents: 100, fee_refunds_cents: 100)
  end

  it "never counts a Clover sale with a classified Stripe second payment as custody or fee revenue, and keeps closed months" do
    clover, = sale!(completed_at: at(2027, 1, 10, 10), captured_at: at(2027, 1, 10, 10), provider: "boh_clover", fee: 50,
      proceeds: 1200)
    stripe_order, = sale!(completed_at: at(2027, 1, 12, 10), captured_at: at(2027, 1, 12, 10))
    second = create(:payment, :succeeded, order: clover, provider: "stripe", provider_environment: "live", amount_cents: 1250,
      provider_payment_id: "pi_live_b_#{SecureRandom.hex(4)}", created_at: at(2027, 1, 11, 10), succeeded_at: at(2027, 1, 11, 10))
    UnfulfilledCapture.create!(order: clover, payment: second, capture_scope: "payment", code: "unfulfilled_second_capture",
      captured_cents: 1250, currency: "usd", proceeds_cents: 1250, fee_cents: 0, organizer_fee_cents: 0, tax_cents: 0,
      processing_bearer: "platform", dispute_fee_bearer: "platform", allocation_policy: "item_record",
      policy_version: Commerce::NeverFulfilledClassification::POLICY_VERSION, provenance: "lifecycle")

    january_cpa = cpa_csv(1)
    january_bpt = bpt_csv(1)
    # Only the Stripe sale is custody and BPT fee revenue.
    expect(cpa_row(1)).to include(proceeds_collected_cents: 1000, fee_revenue_gross_cents: 100)
    expect(january_bpt).to include("gross_service_fees" => "1.00", "ticket_face_value_collected_as_agent" => "10.00")
    expect(CpaMonthlyReport.new(2027, 1).send(:agent_orders).pluck(:id)).to eq([stripe_order.id])

    # A later capture (March) changes no closed month.
    sale!(completed_at: at(2027, 3, 2, 10), captured_at: at(2027, 3, 2, 10))
    expect(cpa_csv(1)).to eq(january_cpa)
    expect(bpt_csv(1)).to eq(january_bpt)
  end

  # The annual organizer view keeps a0b25ffe's payout population (A2
  # recheck finding 5, e49e94d2): payouts on events with a live capture from
  # any provider, Clover included, bounded by each payout's paid recording so
  # a later capture adds no earlier payout. Only the BPT detail reads Stripe
  # custody (PayoutCustody.bpt_payouts). Never every USD payout.
  it "keeps the a0b25ffe annual payout population across providers, frozen against later captures" do
    account = create(:connected_account, organization: organization, provider: "manual", with_readiness_approval: false)
    payout = lambda do |target, paid_at, amount, owner: organization, via: account, **extra|
      create(:payout, event: target, organization: owner, connected_account: via, status: :paid, paid_at: paid_at,
        amount_cents: amount, settlement: create(:settlement, event: target, organization: owner), **extra)
    end
    # Stripe custody: a live sale before the payout.
    sale!(completed_at: at(2027, 1, 5, 10), captured_at: at(2027, 1, 5, 10))
    payout.call(event, at(2027, 1, 20, 10), 700)
    payout.call(event, at(2027, 1, 21, 10), 300, provider_payout_id: "sim_po_rehearsal").tap do |simulated|
      simulated.update_columns(status: Payout.statuses[:reversed])
    end
    # A Clover-only event of the same organization: in this view (not in BPT).
    clover_event = create(:event, organization: organization, organizer_profile: profile)
    clover = create(:order, :completed, event: clover_event, completed_at: at(2027, 1, 6, 10), currency: "usd")
    create(:payment, :succeeded, order: clover, provider: "boh_clover", provider_environment: nil,
      provider_payment_id: "clover_#{SecureRandom.hex(4)}", amount_cents: clover.total_cents)
    payout.call(clover_event, at(2027, 1, 22, 10), 400)
    # A payout on an event with no sale yet; its Stripe sale comes later.
    later_event = create(:event, organization: organization, organizer_profile: profile)
    early = payout.call(later_event, at(2027, 1, 23, 10), 200)
    # An unrelated organization's Stripe-custody payout.
    other = create(:organization)
    other_event = create(:event, organization: other, organizer_profile: create(:organizer_profile, organization: other))
    other_order = create(:order, :completed, event: other_event, completed_at: at(2027, 1, 7, 10), currency: "usd")
    create(:payment, :succeeded, order: other_order, provider: "stripe", provider_environment: "live",
      provider_payment_id: "pi_live_other_#{SecureRandom.hex(4)}", amount_cents: other_order.total_cents,
      created_at: at(2027, 1, 7, 10), succeeded_at: at(2027, 1, 7, 10))
    payout.call(other_event, at(2027, 1, 24, 10), 900, owner: other,
      via: create(:connected_account, organization: other, provider: "manual", with_readiness_approval: false))

    expect(organizer_row).to include(net_paid_cents: 1100)
    expect(TaxReports.new(2027).organizers.find { |row| row[:organization_id] == other.id }).to include(net_paid_cents: 900)
    expect(PayoutCustody.bpt_payouts(Payout.where(event: clover_event))).to be_empty

    # A Stripe capture recorded later on the early payout's event adds nothing.
    order = create(:order, :completed, event: later_event, completed_at: at(2027, 2, 2, 10), currency: "usd")
    late = create(:payment, :succeeded, order: order, provider: "stripe", provider_environment: "live",
      provider_payment_id: "pi_live_late_#{SecureRandom.hex(4)}", amount_cents: order.total_cents,
      created_at: at(2027, 2, 2, 10), succeeded_at: at(2027, 2, 2, 10))
    stamp!(late, :capture_recorded_at, at(2027, 2, 2, 10), trigger: "payments_capture_recorded_at")
    expect(organizer_row).to include(net_paid_cents: 1100)
    expect(PayoutCustody.bpt_payouts(Payout.where(id: early.id))).to be_empty
  end
end
