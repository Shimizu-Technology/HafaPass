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

  it "selects the annual organizer payouts by paid time, never by the event's current captures" do
    settlement = create(:settlement, event: event, organization: organization)
    account = create(:connected_account, organization: organization, provider: "manual", with_readiness_approval: false)
    create(:payout, event: event, organization: organization, settlement: settlement, connected_account: account,
      status: :paid, paid_at: at(2027, 1, 20, 10), amount_cents: 700)
    create(:payout, event: event, organization: organization, settlement: settlement, connected_account: account,
      status: :paid, paid_at: at(2027, 1, 21, 10), amount_cents: 300, provider_payout_id: "sim_po_rehearsal")
    expect(organizer_row).to include(net_paid_cents: 700)

    # A capture recorded later on the event does not change it.
    sale!(completed_at: at(2027, 2, 2, 10), captured_at: at(2027, 2, 2, 10))
    expect(organizer_row).to include(net_paid_cents: 700)
  end
end
