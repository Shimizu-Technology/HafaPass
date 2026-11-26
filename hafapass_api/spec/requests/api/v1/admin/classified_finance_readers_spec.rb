# frozen_string_literal: true

require "rails_helper"
require "csv"
require "ostruct"

# A2 CPA and BPT reader switch (docs/design/never-fulfilled-captures.md §5.3,
# §8.2, §8.5, §8.10.3). Classified payments are read only from A1's ledger
# through Commerce::ClassifiedPaymentFinance; ordinary sales keep their rules,
# recognized no earlier than the custody they reverse. Saved CSV bodies are
# compared byte for byte across later activity.
RSpec.describe "Classified-payment CPA and BPT readers", type: :request do
  before do
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeProcessingFees).to receive(:require_adjustment_review!)
    allow(StripeService).to receive(:verify_payment_context!)
    allow(Sentry).to receive(:capture_message)
  end

  let(:admin) { create(:user, :admin) }
  let(:guam) { ActiveSupport::TimeZone["Pacific/Guam"] }
  let(:org) { create(:organization) }
  let(:profile) { create(:organizer_profile, organization: org) }
  let(:event) { create(:event, :published, organization: org, organizer_profile: profile) }

  def at(*parts) = guam.local(*parts)
  def cents(row, column) = (BigDecimal(row.fetch(column, "0")) * 100).to_i

  def cpa_body(month)
    get "/api/v1/admin/tax_reports/cpa_monthly_export", params: { year: 2027, month: month }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    response.body.dup
  end

  def bpt_body(month)
    get "/api/v1/admin/tax_reports/bpt_events_export", params: { year: 2027, month: month }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    response.body.dup
  end

  def row_for(body, target = event)
    CSV.parse(body, headers: true).find { |row| row["event_id"] == target.id.to_s && row["row_type"] != "total" }&.to_h || {}
  end

  # The columns that existed before A2 (through `currency`), for like-for-like
  # comparison when A2 only adds appended columns.
  def pre_a2_columns(row)
    row.to_a.first(CpaMonthlyReport::HEADER.index("currency") + 1).to_h
  end

  def expect_gross_bridge(row)
    expect(cents(row, "closing_buyer_owed_gross")).to eq(
      cents(row, "closing_buyer_refunds_owed") - cents(row, "closing_buyer_refunds_owed_unclassified_legacy") +
        cents(row, "closing_buyer_owed_second_capture_principal") + cents(row, "closing_buyer_owed_fee_tax_share")
    )
  end

  def expect_roll_forward(row)
    expect(cents(row, "opening_custodial_liability") + cents(row, "proceeds_collected") - cents(row, "proceeds_refunded") -
      cents(row, "chargebacks") - cents(row, "organizer_processing_deducted") + cents(row, "other_adjustments") -
      cents(row, "organizer_payouts_made") + cents(row, "payout_reversals")).to eq(cents(row, "closing_custodial_liability"))
    expect(cents(row, "opening_buyer_refunds_owed") + cents(row, "buyer_refund_captures") - cents(row, "buyer_refunds_paid"))
      .to eq(cents(row, "closing_buyer_refunds_owed"))
    expect(cents(row, "opening_buyer_owed_gross") + cents(row, "buyer_owed_captures_gross") -
      cents(row, "buyer_owed_returned_gross")).to eq(cents(row, "closing_buyer_owed_gross"))
  end

  def without_trigger(table, trigger)
    connection = ActiveRecord::Base.connection
    connection.execute("ALTER TABLE #{table} DISABLE TRIGGER #{trigger}")
    yield
  ensure
    connection.execute("ALTER TABLE #{table} ENABLE TRIGGER #{trigger}")
  end

  # A capture's database recording time, as a database whose clock read
  # `time` would hold it (payment and classification row together).
  def captured_at!(payment, time)
    stamp!(payment, :capture_recorded_at, time, trigger: "payments_capture_recorded_at")
    without_trigger("never_fulfilled_captures", "never_fulfilled_captures_append_only") do
      UnfulfilledCapture.where(payment_id: payment.id).update_all(capture_recorded_at: time)
    end
  end

  def live_payment!(order, amount, time, suffix)
    create(:payment, order: order, provider: "stripe", provider_environment: "live", provider_payment_id: "pi_live_#{suffix}",
      amount_cents: amount, currency: "usd", status: :succeeded, created_at: time, succeeded_at: time)
  end

  # An order-scope classified live capture with a $1.60 fee, recorded at `time`.
  def classified_capture!(time, target: event, created_at: time - 1.hour)
    order = create(:order, event: target, status: :expired, completed_at: nil, created_at: created_at, currency: "usd",
      subtotal_cents: 1200, service_fee_cents: 160, total_cents: 1360, processing_fee_bearer_snapshot: "platform")
    create(:order_item, order: order, unit_price_cents: 1200, quantity: 1, subtotal_cents: 1200,
      organizer_proceeds_cents: 1200, fee_cents: 160, organizer_fee_cents: 0, tax_cents: 0)
    create(:fee_component, order: order, kind: "platform", estimated: false, amount_cents: 160, created_at: created_at)
    payment = live_payment!(order, 1360, time, "nf_#{SecureRandom.hex(4)}")
    classify_order_scope!(order, payment)
    captured_at!(payment, time)
    [order, payment.reload]
  end

  # A fulfilled live sale: $12.00 ticket plus a $1.60 fee, paid by payment A.
  def fulfilled_sale!(completed_at:, captured_at: completed_at, target: event)
    order = create(:order, :pending, event: target, created_at: completed_at - 1.hour, currency: "usd",
      subtotal_cents: 1200, service_fee_cents: 160, total_cents: 1360, processing_fee_bearer_snapshot: "platform")
    item = create(:order_item, order: order, unit_price_cents: 1200, quantity: 1, subtotal_cents: 1200,
      organizer_proceeds_cents: 1200, fee_cents: 160)
    payment = live_payment!(order, 1360, captured_at, "sale_#{SecureRandom.hex(4)}")
    order.update!(status: :completed, completed_at: completed_at, fulfilled_by_payment_id: payment.id)
    create(:fee_component, order: order, kind: "platform", estimated: false, amount_cents: 160, created_at: completed_at)
    [order, item, payment]
  end

  # A distinct second live capture B on a fulfilled order (payment scope).
  def second_capture!(order, time, amount: 1500)
    payment = live_payment!(order, amount, time, "b_#{SecureRandom.hex(4)}")
    UnfulfilledCapture.create!(order: order, payment: payment, capture_scope: "payment", code: "unfulfilled_second_capture",
      captured_cents: amount, currency: "usd", proceeds_cents: amount, fee_cents: 0, organizer_fee_cents: 0, tax_cents: 0,
      processing_bearer: "platform", dispute_fee_bearer: "platform", allocation_policy: "item_record",
      policy_version: Commerce::NeverFulfilledClassification::POLICY_VERSION, provenance: "lifecycle")
    captured_at!(payment, time)
    payment.reload
  end

  # A provider refund on a classified payment recorded at `time`, posted by the real writer.
  def classified_refund!(payment, amount, time)
    id = "re_cfr_#{SecureRandom.hex(4)}"
    refund = payment.refunds.create!(order: payment.order, provider: "stripe", provider_refund_id: id,
      idempotency_key: "provider:stripe:refund:#{id}", amount_cents: amount, currency: "usd", status: :succeeded,
      succeeded_at: time)
    stamp!(refund, :success_recorded_at, time, trigger: "refunds_success_recorded_at")
    Order.transaction { Commerce::BuyerReturnPostings.record_refund!(refund.reload) }
    refund
  end

  def lost_dispute!(payment, amount, time)
    dispute = Dispute.create!(order: payment.order, payment: payment, provider: "stripe",
      provider_dispute_id: "dp_cfr_#{SecureRandom.hex(4)}", amount_cents: amount, currency: "usd", status: :lost,
      opened_at: time - 1.day, closed_at: time)
    stamp!(dispute, :loss_recorded_at, time, trigger: "disputes_recorded_at")
    Order.transaction { Commerce::BuyerReturnPostings.record_dispute_loss!(dispute.reload) }
    dispute
  end

  def late_win!(dispute, time)
    stamp!(dispute, :loss_reversed_at, time, trigger: "disputes_recorded_at")
    Order.transaction { Commerce::BuyerReturnPostings.record_loss_reversal!(dispute.reload) }
  end

  describe "a lost dispute and its late win on a classified capture" do
    it "books the fee share and its reversal in their own months and keeps February's saved CSVs byte-identical" do
      _order, payment = classified_capture!(at(2027, 2, 10, 10))
      dispute = lost_dispute!(payment, 1360, at(2027, 2, 20, 12))
      feb_cpa = cpa_body(2)
      feb_bpt = bpt_body(2)

      late_win!(dispute, at(2027, 3, 5, 9))
      expect(cpa_body(2)).to eq(feb_cpa)
      expect(bpt_body(2)).to eq(feb_bpt)

      feb = row_for(feb_cpa)
      expect(feb).to include("proceeds_collected" => "0.00", "chargebacks" => "0.00", "closing_custodial_liability" => "0.00",
        "buyer_refund_captures" => "12.00", "buyer_refunds_paid" => "12.00", "closing_buyer_refunds_owed" => "0.00",
        "fee_revenue_gross" => "1.60", "fee_refunds" => "1.60", "fee_revenue_net" => "0.00",
        "buyer_owed_captures_gross" => "13.60", "buyer_owed_returned_gross" => "13.60", "closing_buyer_owed_gross" => "0.00",
        "classified_allocation_policy" => "item_record #{Commerce::NeverFulfilledClassification::POLICY_VERSION}")
      mar = row_for(cpa_body(3))
      expect(mar).to include("opening_buyer_refunds_owed" => "0.00", "buyer_refund_captures" => "0.00",
        "buyer_refunds_paid" => "-12.00", "closing_buyer_refunds_owed" => "12.00",
        "fee_revenue_gross" => "0.00", "fee_refunds" => "-1.60", "fee_revenue_net" => "1.60",
        "buyer_owed_returned_gross" => "-13.60", "closing_buyer_owed_gross" => "13.60",
        "closing_buyer_owed_fee_tax_share" => "1.60", "chargebacks" => "0.00")
      [feb, mar].each do |row|
        expect_roll_forward(row)
        expect_gross_bridge(row)
      end
      expect(mar["opening_buyer_owed_gross"]).to eq(feb["closing_buyer_owed_gross"])

      expect(row_for(feb_bpt)).to include("gross_service_fees" => "1.60", "refunded_service_fees" => "1.60",
        "net_service_fees" => "0.00", "ticket_face_value_collected_as_agent" => "0.00")
      expect(row_for(bpt_body(3))).to include("gross_service_fees" => "0.00", "refunded_service_fees" => "-1.60",
        "net_service_fees" => "1.60")

      year = TaxReports.new(2027)
      months = year.months.index_by { |month| month[:month] }
      expect(months[2]).to include(fees_collected_cents: 160, fees_refunded_cents: 160, gross_receipts_cents: 0)
      expect(months[3]).to include(fees_collected_cents: 0, fees_refunded_cents: -160, gross_receipts_cents: 160)
      expect(year.months.sum { |month| month[:gross_receipts_cents] }).to eq(160)
      expect(year.organizers).to be_empty # never an organizer's sale
    end

    it "keeps a lost dispute's fee share as revenue when P2 says :retained" do
      _order, payment = classified_capture!(at(2027, 2, 10, 10))
      dispute = lost_dispute!(payment, 1360, at(2027, 2, 20, 12))
      late_win!(dispute, at(2027, 3, 5, 9))
      stub_const("Commerce::NeverFulfilledCapture::LOST_DISPUTE_FEE_SHARE", :retained)

      expect(row_for(cpa_body(2))).to include("fee_revenue_gross" => "1.60", "fee_refunds" => "0.00",
        "buyer_owed_returned_gross" => "13.60")
      expect(row_for(cpa_body(3))).to include("fee_refunds" => "0.00", "buyer_owed_returned_gross" => "-13.60")
      expect(row_for(bpt_body(2))).to include("refunded_service_fees" => "0.00", "net_service_fees" => "1.60")
    end
  end

  describe "a distinct second capture B on a fulfilled sale" do
    it "keeps B's capture, refund, loss and excess out of the sale's custody, fee and refund buckets" do
      order, item, payment_a = fulfilled_sale!(completed_at: at(2027, 2, 5, 10))
      sale_refund = create(:refund, order: order, payment: payment_a, amount_cents: 500, succeeded_at: at(2027, 2, 15, 10))
      create(:refund_item, refund: sale_refund, order_item: item, amount_cents: 500, organizer_proceeds_cents: 500, fee_cents: 0)
      payment_b = second_capture!(order, at(2027, 2, 10, 10))
      classified_refund!(payment_b, 700, at(2027, 2, 12, 10))
      lost_dispute!(payment_b, 1500, at(2027, 2, 20, 10))
      expect(order.reload).to have_attributes(status: "completed")

      feb = row_for(cpa_body(2))
      expect(feb).to include("proceeds_collected" => "12.00", "proceeds_refunded" => "5.00", "chargebacks" => "0.00",
        "closing_custodial_liability" => "7.00", "unallocated_refunds_exception" => "0.00",
        "fee_revenue_gross" => "1.60", "fee_refunds" => "0.00",
        "buyer_refund_captures" => "0.00", "buyer_refunds_paid" => "0.00", "closing_buyer_refunds_owed" => "0.00",
        "buyer_owed_captures_gross" => "15.00", "buyer_owed_returned_gross" => "15.00", "closing_buyer_owed_gross" => "0.00",
        "buyer_overpaid_in_month_gross" => "7.00", "closing_buyer_owed_second_capture_principal" => "0.00",
        "reconciliation_exception_flag" => "yes")
      expect(feb["reconciliation_exception_note"]).to include("beyond what was owed: $7.00 gross cumulative")
      expect_roll_forward(feb)
      expect_gross_bridge(feb)

      expect(row_for(bpt_body(2))).to include("gross_service_fees" => "1.60", "refunded_service_fees" => "0.00",
        "ticket_face_value_collected_as_agent" => "12.00")
      organizer = TaxReports.new(2027).organizers.sole
      expect(organizer).to include(gross_ticket_proceeds_cents: 1200, ticket_refunds_cents: 500, unallocated_refunds_cents: 0,
        fee_refunds_cents: 0, fees_collected_cents: 160)
    end

    it "shows B's open principal in the bridge column while it is still owed" do
      order, = fulfilled_sale!(completed_at: at(2027, 2, 5, 10))
      payment_b = second_capture!(order, at(2027, 2, 10, 10))
      classified_refund!(payment_b, 400, at(2027, 2, 12, 10))

      feb = row_for(cpa_body(2))
      expect(feb).to include("closing_buyer_owed_gross" => "11.00", "closing_buyer_owed_second_capture_principal" => "11.00",
        "closing_buyer_refunds_owed" => "0.00", "proceeds_collected" => "12.00", "proceeds_refunded" => "0.00")
      expect_gross_bridge(feb)
    end
  end

  describe "ordinary sales: recognition no earlier than custody (§5.3)" do
    it "books a refund and a lost dispute recorded before a backfilled capture's custody in the custody month" do
      order, item, payment = fulfilled_sale!(completed_at: at(2027, 2, 20, 10), captured_at: at(2027, 3, 2, 10))
      refund = create(:refund, order: order, payment: payment, amount_cents: 500, succeeded_at: at(2027, 2, 25, 10))
      create(:refund_item, refund: refund, order_item: item, amount_cents: 500, organizer_proceeds_cents: 500, fee_cents: 0)
      Dispute.create!(order: order, payment: payment, provider: "stripe", provider_dispute_id: "dp_ord_early",
        amount_cents: 200, currency: "usd", status: :lost, opened_at: at(2027, 2, 21), closed_at: at(2027, 2, 26))

      # February: the capture is not recorded yet, so the sale sits in the
      # pre-existing settlement bridge only, and nothing reverses custody.
      expect(row_for(cpa_body(2))).to include("proceeds_collected" => "0.00", "proceeds_refunded" => "0.00",
        "chargebacks" => "0.00", "closing_custodial_liability" => "0.00")
      mar = row_for(cpa_body(3))
      expect(mar).to include("opening_custodial_liability" => "0.00", "proceeds_collected" => "12.00",
        "proceeds_refunded" => "5.00", "chargebacks" => "2.00", "closing_custodial_liability" => "5.00")
      expect(mar["prior_period_note"]).to include("Stripe capture backfill relates to Feb 2027")
      expect_roll_forward(mar)
    end

    it "returns BPT fees no earlier than the sale that collected them" do
      order, item, payment = fulfilled_sale!(completed_at: at(2027, 3, 2, 10))
      refund = create(:refund, order: order, payment: payment, amount_cents: 660, succeeded_at: at(2027, 2, 27, 10))
      create(:refund_item, refund: refund, order_item: item, amount_cents: 660, organizer_proceeds_cents: 500, fee_cents: 160)

      expect(row_for(bpt_body(2))).to be_empty
      expect(row_for(bpt_body(3))).to include("gross_service_fees" => "1.60", "refunded_service_fees" => "1.60")
      months = TaxReports.new(2027).months.index_by { |month| month[:month] }
      expect(months[2]).to include(fees_refunded_cents: 0)
      expect(months[3]).to include(fees_collected_cents: 160, fees_refunded_cents: 160)
    end
  end

  describe "an unclassified legacy capture (no classification row yet)" do
    it "keeps the published ticket-share treatment, stays out of gross, is alerted, and keeps pre-A2 columns once classified" do
      captured = at(2027, 2, 10, 10)
      order = create(:order, event: event, status: :expired, completed_at: nil, created_at: captured - 1.hour, currency: "usd",
        subtotal_cents: 1200, service_fee_cents: 160, total_cents: 1360, processing_fee_bearer_snapshot: "platform")
      create(:order_item, order: order, unit_price_cents: 1200, quantity: 1, subtotal_cents: 1200,
        organizer_proceeds_cents: 1200, fee_cents: 160)
      create(:fee_component, order: order, kind: "platform", estimated: false, amount_cents: 160, created_at: captured)
      payment = live_payment!(order, 1360, captured, "legacy_#{SecureRandom.hex(4)}")
      stamp!(payment, :capture_recorded_at, captured, trigger: "payments_capture_recorded_at")
      ReconciliationException.create!(order: order, payment: payment, code: "late_payment_success_after_hold_expiry",
        created_at: captured + 1.second)

      before = row_for(cpa_body(2))
      expect(before).to include("proceeds_collected" => "0.00", "buyer_refund_captures" => "12.00",
        "closing_buyer_refunds_owed" => "12.00", "closing_buyer_refunds_owed_unclassified_legacy" => "12.00",
        "closing_buyer_owed_gross" => "0.00", "fee_revenue_gross" => "1.60")
      expect_gross_bridge(before)
      alerts = CpaMonthlyReport.new(2027, 2).report[:current_integrity_alerts][:classified_payment_alerts]
      expect(alerts).to include(include(code: "unclassified_late_capture", payment_id: payment.id))

      classify_order_scope!(order, payment)
      after = row_for(cpa_body(2))
      expect(pre_a2_columns(after)).to eq(pre_a2_columns(before))
      expect(after).to include("closing_buyer_refunds_owed_unclassified_legacy" => "0.00",
        "buyer_owed_captures_gross" => "13.60", "closing_buyer_owed_gross" => "13.60", "closing_buyer_owed_fee_tax_share" => "1.60")
      expect_gross_bridge(after)
    end
  end
end
