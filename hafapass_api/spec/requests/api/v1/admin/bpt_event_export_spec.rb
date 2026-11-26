# frozen_string_literal: true

require "rails_helper"
require "csv"
require "ostruct"

RSpec.describe "Admin monthly BPT event export", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:admin) { create(:user, :admin) }
  let(:path) { "/api/v1/admin/tax_reports/bpt_events_export" }
  let(:september_end) { Time.utc(2026, 9, 30, 14) }
  let(:october_end) { Time.utc(2026, 10, 31, 14) }
  let(:event) { create(:event, title: "Private Organizer Name") }

  def captured_order(event:, at:, fee:, environment: "live", provider: "stripe", currency: "usd", payment_id: nil)
    order = create(:order, :completed, event: event, completed_at: at, currency: currency,
      buyer_email: "private-buyer@example.test")
    # Captured at the sale: CPA and BPT book custody no earlier than the
    # capture's recording (Commerce::SaleCustody).
    payment = create(:payment, :succeeded, order: order, provider: provider, provider_environment: environment,
      created_at: at, succeeded_at: at, **(payment_id ? { provider_payment_id: payment_id } : {}))
    # Completion records the fulfilling payment; a later capture is not the sale's.
    order.update!(fulfilled_by_payment_id: payment.id)
    # The database stamps the capture with its own clock; record it at the
    # fixture's time, as a database whose clock read `at` would (R2-2 bounds
    # payout custody by capture recording time).
    stamp!(payment, :capture_recorded_at, at, trigger: "payments_capture_recorded_at") if payment.reload.capture_recorded_at
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
    later_capture = create(:payment, :succeeded, order: order, provider_environment: "live")
    # A historical later capture (recorded before A1), which reconcile's
    # backfill decides; a capture recorded since A1 and left unclassified
    # would hold this event's payouts (hafapass_unclassified_capture).
    stamp!(later_capture, :capture_recorded_at, nil, trigger: "payments_capture_recorded_at")
    refund = create(:refund, order: order, payment: capture, succeeded_at: october_end)
    create(:refund_item, refund: refund, order_item: line, amount_cents: 500, organizer_proceeds_cents: 390,
      fee_cents: 60, organizer_fee_cents: 50)

    test_payment = create(:payment, :succeeded, order: order, provider_environment: "test")
    test_refund = create(:refund, order: order, payment: test_payment, succeeded_at: october_end)
    # A test-mode refund's items on a live sale exist only from before A1:
    # the sale-ownership guard now refuses them (only the fulfilling payment
    # changes the sale). Readers must still ignore the historical row.
    ActiveRecord::Base.connection.execute("ALTER TABLE refund_items DISABLE TRIGGER refund_items_sale_ownership")
    create(:refund_item, refund: test_refund, order_item: line, amount_cents: 25, organizer_proceeds_cents: 0, fee_cents: 25)
    ActiveRecord::Base.connection.execute("ALTER TABLE refund_items ENABLE TRIGGER refund_items_sale_ownership")

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

  it "keeps closed January unchanged when a late door-card capture and auto-refund settle in February and dates cross-month capture and refund by recording month",
    repayment_submitter: :active do
    same_month_event = create(:event, :published, online_door_card_enabled: true, max_capacity: 1)
    cross_month_event = create(:event, :published, online_door_card_enabled: true, max_capacity: 1)
    tt1 = create(:ticket_type, event: same_month_event, price_cents: 1_200, quantity_available: 1)
    tt2 = create(:ticket_type, event: cross_month_event, price_cents: 1_200, quantity_available: 1)

    jan_reserve = Time.zone.parse("2027-01-31T23:00:00+10:00")
    jan_expire = Time.zone.parse("2027-01-31T23:40:00+10:00")
    feb_capture = Time.zone.parse("2027-02-01T00:30:00+10:00")
    feb_late_capture = Time.zone.parse("2027-02-28T23:00:00+10:00")
    mar_refund = Time.zone.parse("2027-03-01T01:00:00+10:00")

    create_expired_door_order = lambda do |target_event, target_tt, suffix|
      order = nil
      payment = nil
      travel_to(jan_reserve) do
        order = create(:order,
          event: target_event, status: :pending, completed_at: nil, expires_at: jan_reserve + 35.minutes,
          currency: "usd", payment_method: "door_card_link", source: "box_office",
          subtotal_cents: 1_200, discount_cents: 0, service_fee_cents: 160, organizer_fee_cents: 0,
          total_cents: 1_360, processing_fee_bearer_snapshot: "platform")
        item = create(:order_item,
          order: order, ticket_type: target_tt, quantity: 1, unit_price_cents: 1_200,
          subtotal_cents: 1_200, discount_cents: 0, fee_cents: 160, organizer_fee_cents: 0,
          organizer_proceeds_cents: 1_200)
        create(:fee_component, order: order, kind: "platform", estimated: false, amount_cents: 160, created_at: jan_reserve)
        create(:inventory_hold, order: order, order_item: item, ticket_type: target_tt, quantity: 1, expires_at: jan_reserve + 35.minutes)
        payment = create(:payment,
          order: order, provider: "stripe", provider_environment: "live",
          provider_platform_account_id: "acct_LivePlatform",
          stripe_checkout_session_id: "cs_live_Bpt#{suffix}",
          provider_payment_id: "pi_live_Bpt#{suffix}",
          amount_cents: 1_360, currency: "usd", status: :pending, succeeded_at: nil, created_at: jan_reserve)
      end
      travel_to(jan_expire) do
        Commerce::OrderLifecycle.expire!(order, provider_expired: true)
        target_tt.update!(quantity_sold: 1)
      end
      [order.reload, payment.reload]
    end

    order1, payment1 = create_expired_door_order.call(same_month_event, tt1, "SameFeb")
    order2, payment2 = create_expired_door_order.call(cross_month_event, tt2, "CrossMar")

    get path, params: { year: 2027, month: 1 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    jan_body_before = response.body.dup
    expect(CSV.parse(jan_body_before, headers: true)).to be_empty

    allow(StripeService).to receive(:refund_payment).and_return(
      OpenStruct.new(id: "re_live_BptSameFeb", status: "succeeded", amount: 1_360, currency: "usd", payment_intent: payment1.provider_payment_id)
    )
    travel_to(feb_capture) do
      Commerce::OrderLifecycle.complete!(order1, payment: payment1, provider_amount_cents: 1_360, provider_currency: "usd", late_completion: true,
        provider_lookup: { provider_object_id: payment1.provider_payment_id, livemode: payment1.provider_environment == "live" })
      Commerce::LateCaptureRefund.call(payment: payment1)
    end
    align_recording_times!(payment1)

    travel_to(feb_late_capture) do
      Commerce::OrderLifecycle.complete!(order2, payment: payment2, provider_amount_cents: 1_360, provider_currency: "usd", late_completion: true,
        provider_lookup: { provider_object_id: payment2.provider_payment_id, livemode: payment2.provider_environment == "live" })
    end
    align_recording_times!(payment2)

    get path, params: { year: 2027, month: 2 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    feb_body_before_mar_refund = response.body.dup

    allow(StripeService).to receive(:refund_payment).and_return(
      OpenStruct.new(id: "re_live_BptCrossMar", status: "succeeded", amount: 1_360, currency: "usd", payment_intent: payment2.provider_payment_id)
    )
    travel_to(mar_refund) do
      Commerce::LateCaptureRefund.call(payment: payment2)
    end
    align_recording_times!(payment2)

    # Closed January remains empty and byte-identical
    get path, params: { year: 2027, month: 1 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq(jan_body_before)

    # Closed February remains byte-identical after the March 1 refund
    get path, params: { year: 2027, month: 2 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq(feb_body_before_mar_refund)
    feb_by_event = CSV.parse(response.body, headers: true).index_by { |r| r["event_id"] }
    expect(feb_by_event.fetch(same_month_event.id.to_s).to_h).to include(
      "gross_service_fees" => "1.60",
      "refunded_service_fees" => "1.60",
      "net_service_fees" => "0.00",
      "ticket_face_value_collected_as_agent" => "0.00"
    )
    expect(feb_by_event.fetch(cross_month_event.id.to_s).to_h).to include(
      "gross_service_fees" => "1.60",
      "refunded_service_fees" => "0.00",
      "net_service_fees" => "1.60",
      "ticket_face_value_collected_as_agent" => "0.00"
    )

    # A2: both captures are classified, so their fee share comes from the
    # snapshot at capture recording and their refunds from postings, and a
    # never-fulfilled order's face value is not an organizer sale (§8.4).
    expect(UnfulfilledCapture.where(payment: [payment1, payment2]).count).to eq(2)

    # March records the cross-month refund
    get path, params: { year: 2027, month: 3 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    mar_row = CSV.parse(response.body, headers: true).sole.to_h
    expect(mar_row).to include(
      "event_id" => cross_month_event.id.to_s,
      "gross_service_fees" => "0.00",
      "refunded_service_fees" => "1.60",
      "net_service_fees" => "-1.60",
      "ticket_face_value_collected_as_agent" => "0.00"
    )
  end
end
