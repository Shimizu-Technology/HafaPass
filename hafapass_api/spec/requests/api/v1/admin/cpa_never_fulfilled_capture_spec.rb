# frozen_string_literal: true

require "rails_helper"
require "csv"

# PR #247 review round 3 (R3-1, R3-2, R3-3): a never-fulfilled door-card capture
# is booked the same way by the CPA export, Settlements::Calculator and the
# payout statement, from the same durable evidence (Commerce::NeverFulfilledCapture).
RSpec.describe "Never-fulfilled capture accounting across the CPA export and payout statement", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:admin) { create(:user, :admin) }
  let(:org) { create(:organization) }
  let(:profile) { create(:organizer_profile, organization: org) }
  let(:event) do
    create(:event, :published, organization: org, organizer_profile: profile, online_door_card_enabled: true, max_capacity: 1)
  end
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 1_200, quantity_available: 1) }

  def guam(time) = Time.zone.parse("#{time}+10:00")

  def fetch_csv(month, year: 2027)
    get "/api/v1/admin/tax_reports/cpa_monthly_export", params: { year: year, month: month }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    CSV.parse(response.body, headers: true)
  end

  def event_row(csv, target_event = event)
    csv.find { |row| row["row_type"] == "event" && row["event_id"] == target_event.id.to_s }&.to_h || {}
  end

  def cents(row, column) = (BigDecimal(row.fetch(column, "0")) * 100).to_i

  def expect_roll_forward(row)
    organizer = cents(row, "opening_custodial_liability") + cents(row, "proceeds_collected") -
      cents(row, "proceeds_refunded") - cents(row, "chargebacks") - cents(row, "organizer_processing_deducted") +
      cents(row, "other_adjustments") - cents(row, "organizer_payouts_made") + cents(row, "payout_reversals")
    expect(organizer).to eq(cents(row, "closing_custodial_liability"))
    buyer = cents(row, "opening_buyer_refunds_owed") + cents(row, "buyer_refund_captures") - cents(row, "buyer_refunds_paid")
    expect(buyer).to eq(cents(row, "closing_buyer_refunds_owed"))
  end

  def expect_continuity(previous, current)
    expect(current.fetch("opening_custodial_liability", "0.00")).to eq(previous.fetch("closing_custodial_liability", "0.00"))
    expect(current.fetch("opening_buyer_refunds_owed", "0.00")).to eq(previous.fetch("closing_buyer_refunds_owed", "0.00"))
  end

  def unpaid_balance(attributes)
    attributes[:negative_balance_cents].positive? ? -attributes[:negative_balance_cents] : attributes[:payable_cents] - attributes[:paid_cents]
  end

  # Builds the real writer path: a door-card checkout that expires, then a
  # late Stripe capture that OrderLifecycle records with its late-capture
  # exception in one transaction and does not fulfill.
  def never_fulfilled_capture!(reserved_at:, captured_at:, bearer: "organizer", processing_cents: 69)
    order = nil
    payment = nil
    travel_to(reserved_at) do
      order = create(:order,
        event: event, status: :pending, completed_at: nil, expires_at: reserved_at + 35.minutes,
        currency: "usd", payment_method: "door_card_link", source: "box_office",
        subtotal_cents: 1_200, discount_cents: 0, service_fee_cents: 160, organizer_fee_cents: 0,
        total_cents: 1_360, processing_fee_bearer_snapshot: bearer)
      item = create(:order_item, order: order, ticket_type: ticket_type, quantity: 1, unit_price_cents: 1_200,
        subtotal_cents: 1_200, discount_cents: 0, fee_cents: 160, organizer_fee_cents: 0, organizer_proceeds_cents: 1_200)
      create(:fee_component, order: order, kind: "platform", estimated: false, amount_cents: 160, created_at: reserved_at)
      create(:inventory_hold, order: order, order_item: item, ticket_type: ticket_type, quantity: 1, expires_at: reserved_at + 35.minutes)
      payment = create(:payment, order: order, provider: "stripe", provider_environment: "live",
        provider_platform_account_id: "acct_LivePlatform", stripe_checkout_session_id: "cs_live_Door#{order.id}",
        provider_payment_id: "pi_live_Door#{order.id}", amount_cents: 1_360, currency: "usd",
        status: :pending, succeeded_at: nil, created_at: reserved_at)
    end
    travel_to(reserved_at + 40.minutes) do
      Commerce::OrderLifecycle.expire!(order, provider_expired: true)
      ticket_type.update!(quantity_sold: 1) # the released seat sold out, so the capture cannot fulfill
    end
    travel_to(captured_at) do
      Commerce::OrderLifecycle.complete!(order, payment: payment, provider_amount_cents: 1_360, provider_currency: "usd",
        late_completion: true, provider_lookup: { provider_object_id: payment.provider_payment_id, livemode: payment.provider_environment == "live" })
      create(:fee_component, order: order, kind: "processing", estimated: false, amount_cents: processing_cents,
        created_at: captured_at) if processing_cents.positive?
    end
    expect(order.reload).to be_expired
    expect(order.completed_at).to be_nil
    expect(order.tickets).to be_empty
    expect(ReconciliationException.where(payment: payment, code: Commerce::LateCaptureRefund::CODES).count).to eq(1)
    [order, payment.reload]
  end

  def auto_refund!(payment, at:)
    allow(StripeService).to receive(:refund_payment).and_return(
      OpenStruct.new(id: "re_live_#{payment.id}", status: "succeeded", amount: 1_360, currency: "usd",
        payment_intent: payment.provider_payment_id)
    )
    travel_to(at) { Commerce::LateCaptureRefund.call(payment: payment) }
    expect(payment.order.reload).to be_refunded
    expect(payment.order.completed_at).to be_nil
  end

  def lose_dispute!(order, payment, at:, amount_cents: 1_360)
    Dispute.create!(order: order, payment: payment, provider: "stripe", provider_dispute_id: "dp_lost_#{order.id}",
      amount_cents: amount_cents, currency: "usd", status: :lost, opened_at: at - 1.day, closed_at: at)
  end

  describe "R3-1: a capture and its exception straddling Guam midnight" do
    it "books the capture as owed to the buyer in both months, so each month's roll-forward and the opening balance hold",
      repayment_submitter: :active do
      order, payment = never_fulfilled_capture!(reserved_at: guam("2027-02-28T23:00:00"),
        captured_at: guam("2027-02-28T23:59:59"))
      # OrderLifecycle stamps the exception a moment after the capture inside
      # the same transaction; here that moment falls on March 1 in Guam.
      ReconciliationException.where(payment: payment).update_all(created_at: guam("2027-03-01T00:00:00"))
      expect(order.payments.sole.succeeded_at).to eq(guam("2027-02-28T23:59:59"))

      feb = event_row(fetch_csv(2))
      expect(feb).to include(
        "proceeds_collected" => "0.00",
        "organizer_processing_deducted" => "0.00",
        "closing_custodial_liability" => "0.00",
        "closing_organizer_deficits" => "0.00",
        "buyer_refund_captures" => "12.00",
        "closing_buyer_refunds_owed" => "12.00",
        "stripe_processing_costs_informational" => "0.69"
      )
      expect_roll_forward(feb)

      auto_refund!(payment, at: guam("2027-03-01T00:05:00"))
      expect(event_row(fetch_csv(2))).to eq(feb)

      mar = event_row(fetch_csv(3))
      expect_continuity(feb, mar)
      expect(mar).to include(
        "opening_custodial_liability" => "0.00",
        "closing_custodial_liability" => "0.00",
        "opening_buyer_refunds_owed" => "12.00",
        "buyer_refunds_paid" => "12.00",
        "closing_buyer_refunds_owed" => "0.00"
      )
      expect_roll_forward(mar)
    end

    it "ignores a late-capture exception added long after the capture, so closed months stay as booked" do
      order, payment = never_fulfilled_capture!(reserved_at: guam("2027-02-10T10:00:00"),
        captured_at: guam("2027-02-10T11:00:00"), processing_cents: 0)
      ReconciliationException.where(payment: payment).update_all(created_at: guam("2027-03-15T09:00:00"))
      expect(Commerce::NeverFulfilledCapture.order_ids_among([order.id])).to be_empty
      expect(event_row(fetch_csv(2))).to include("buyer_refund_captures" => "0.00")
    end
  end

  describe "R3-2: organizer-borne processing on a never-fulfilled capture" do
    it "charges the organizer nothing on the payout statement, the calculator and the CPA export after the auto-refund",
      repayment_submitter: :active do
      _order, payment = never_fulfilled_capture!(reserved_at: guam("2027-02-27T09:00:00"),
        captured_at: guam("2027-02-28T22:00:00"))
      auto_refund!(payment, at: guam("2027-03-01T01:00:00"))

      attributes = Settlements::Calculator.call(event).attributes
      expect(attributes).to include(processing_fee_cents: 0, platform_processing_fee_cents: 69, negative_balance_cents: 0,
        payable_cents: 0, organizer_proceeds_cents: 0)

      statement = PayoutStatement.call(event: event)
      expect(statement[:closing][:total_cents]).to eq(0)
      expect(statement[:reconciles]).to be(true)
      expect(statement[:totals][:processing_covered_by_hafapass_cents]).to eq(69)

      mar = event_row(fetch_csv(3))
      expect(mar).to include("closing_custodial_liability" => "0.00", "closing_organizer_deficits" => "0.00")
      cpa_unpaid = cents(mar, "closing_custodial_liability") - cents(mar, "ending_reserve_balance") +
        cents(mar, "non_custodial_settlement_bridge")
      expect(cpa_unpaid).to eq(unpaid_balance(attributes))
    end

    it "keeps the bearer rule in one switch that both readers follow", repayment_submitter: :active do
      _order, payment = never_fulfilled_capture!(reserved_at: guam("2027-02-27T09:00:00"),
        captured_at: guam("2027-02-28T22:00:00"))
      auto_refund!(payment, at: guam("2027-03-01T01:00:00"))
      stub_const("Commerce::NeverFulfilledCapture::ORGANIZER_BEARS_PROCESSING", true)

      expect(Settlements::Calculator.call(event).attributes).to include(processing_fee_cents: 69, negative_balance_cents: 69)
      expect(event_row(fetch_csv(2))).to include("organizer_processing_deducted" => "0.69", "closing_organizer_deficits" => "0.69")
    end
  end

  describe "R3-3: a lost dispute on a never-fulfilled capture" do
    it "clears the buyer obligation instead of debiting the organizer, and a later refund cannot clear it twice",
      repayment_submitter: :active do
      order, payment = never_fulfilled_capture!(reserved_at: guam("2027-02-10T09:00:00"),
        captured_at: guam("2027-02-10T10:00:00"), processing_cents: 0)
      lose_dispute!(order, payment, at: guam("2027-02-20T12:00:00"))

      feb = event_row(fetch_csv(2))
      expect(feb).to include(
        "chargebacks" => "0.00",
        "closing_custodial_liability" => "0.00",
        "closing_organizer_deficits" => "0.00",
        "buyer_refund_captures" => "12.00",
        "buyer_refunds_paid" => "12.00",
        "closing_buyer_refunds_owed" => "0.00",
        "reconciliation_exception_flag" => "no"
      )
      expect_roll_forward(feb)

      # The automatic refund still goes through in March: the buyer is repaid twice.
      auto_refund!(payment, at: guam("2027-03-02T09:00:00"))
      expect(event_row(fetch_csv(2))).to eq(feb)

      mar = event_row(fetch_csv(3))
      expect_continuity(feb, mar)
      expect(mar).to include(
        "chargebacks" => "0.00",
        "proceeds_refunded" => "0.00",
        "closing_custodial_liability" => "0.00",
        "opening_buyer_refunds_owed" => "0.00",
        "buyer_refunds_paid" => "0.00",
        "closing_buyer_refunds_owed" => "0.00",
        "reconciliation_exception_flag" => "yes"
      )
      expect(mar["reconciliation_exception_note"]).to include("returned to the buyer twice", "$12.00 ticket share cumulative")
      expect_roll_forward(mar)

      attributes = Settlements::Calculator.call(event).attributes
      expect(attributes).to include(adjustment_cents: 0, negative_balance_cents: 0, payable_cents: 0)
      statement = PayoutStatement.call(event: event)
      expect(statement[:closing][:total_cents]).to eq(0)
      expect(statement[:reconciles]).to be(true)
    end

    it "caps the buyer obligation when the refund came first and the dispute is lost later", repayment_submitter: :active do
      order, payment = never_fulfilled_capture!(reserved_at: guam("2027-02-10T09:00:00"),
        captured_at: guam("2027-02-10T10:00:00"), processing_cents: 0)
      auto_refund!(payment, at: guam("2027-02-10T10:05:00"))
      lose_dispute!(order, payment, at: guam("2027-03-20T12:00:00"))

      feb = event_row(fetch_csv(2))
      expect(feb).to include("buyer_refunds_paid" => "12.00", "closing_buyer_refunds_owed" => "0.00")
      mar = event_row(fetch_csv(3))
      expect_continuity(feb, mar)
      expect(mar).to include("chargebacks" => "0.00", "buyer_refunds_paid" => "0.00", "closing_buyer_refunds_owed" => "0.00",
        "closing_organizer_deficits" => "0.00", "reconciliation_exception_flag" => "yes")
      expect_roll_forward(mar)
      expect(Settlements::Calculator.call(event).attributes).to include(negative_balance_cents: 0, adjustment_cents: 0)
    end
  end

  describe "regressions" do
    def fulfilled_order!(at:, bearer: "organizer", completed_at: at, payment_at: at)
      order = create(:order, :completed, event: event, completed_at: completed_at, created_at: at, currency: "usd",
        payment_method: "stripe", subtotal_cents: 1_200, discount_cents: 0, service_fee_cents: 160,
        organizer_fee_cents: 0, total_cents: 1_360, processing_fee_bearer_snapshot: bearer)
      item = create(:order_item, order: order, ticket_type: ticket_type, quantity: 1, unit_price_cents: 1_200,
        subtotal_cents: 1_200, discount_cents: 0, fee_cents: 160, organizer_fee_cents: 0, organizer_proceeds_cents: 1_200)
      payment = create(:payment, :succeeded, order: order, provider: "stripe", provider_environment: "live",
        provider_payment_id: "pi_live_Fulfilled#{order.id}", amount_cents: 1_360, currency: "usd",
        created_at: payment_at, succeeded_at: payment_at)
      create(:fee_component, order: order, kind: "platform", estimated: false, amount_cents: 160, created_at: at)
      create(:fee_component, order: order, kind: "processing", estimated: false, amount_cents: 69, created_at: payment_at)
      [order, item, payment]
    end

    it "still charges organizer-borne processing on a normal fulfilled sale" do
      fulfilled_order!(at: guam("2027-02-10T10:00:00"))

      feb = event_row(fetch_csv(2))
      expect(feb).to include("proceeds_collected" => "12.00", "organizer_processing_deducted" => "0.69",
        "closing_custodial_liability" => "11.31", "buyer_refund_captures" => "0.00")
      expect(Settlements::Calculator.call(event).attributes).to include(processing_fee_cents: 69, payable_cents: 1_131)
    end

    it "keeps a fulfilled late capture with a partial refund in organizer custody" do
      order, item, payment = fulfilled_order!(at: guam("2027-02-28T23:50:00"), completed_at: guam("2027-03-01T00:10:00"),
        payment_at: guam("2027-03-01T00:10:00"))
      refund = create(:refund, order: order, payment: payment, amount_cents: 500, succeeded_at: guam("2027-03-05T10:00:00"))
      create(:refund_item, refund: refund, order_item: item, amount_cents: 500, organizer_proceeds_cents: 500, fee_cents: 0)
      order.update!(status: :partially_refunded)

      mar = event_row(fetch_csv(3))
      expect(mar).to include("proceeds_collected" => "12.00", "proceeds_refunded" => "5.00", "organizer_processing_deducted" => "0.69",
        "closing_custodial_liability" => "6.31", "buyer_refund_captures" => "0.00", "buyer_refunds_paid" => "0.00")
      expect_roll_forward(mar)
      attributes = Settlements::Calculator.call(event).attributes
      expect(unpaid_balance(attributes)).to eq(631)
    end

    it "keeps a legacy completed order with a null completed_at in organizer custody and charges its processing" do
      order, = fulfilled_order!(at: guam("2027-02-10T10:00:00"))
      order.update_columns(completed_at: nil)

      feb = event_row(fetch_csv(2))
      expect(feb).to include("proceeds_collected" => "12.00", "organizer_processing_deducted" => "0.69",
        "buyer_refund_captures" => "0.00")
      expect(Settlements::Calculator.call(event).attributes).to include(processing_fee_cents: 69, payable_cents: 1_131)
    end

    it "still debits the organizer for an ordinary lost dispute on a fulfilled sale" do
      order, _item, payment = fulfilled_order!(at: guam("2027-02-10T10:00:00"), bearer: "platform")
      lose_dispute!(order, payment, at: guam("2027-02-20T12:00:00"))

      feb = event_row(fetch_csv(2))
      expect(feb).to include("chargebacks" => "13.60", "closing_custodial_liability" => "-1.60",
        "closing_organizer_deficits" => "1.60", "buyer_refunds_paid" => "0.00")
      attributes = Settlements::Calculator.call(event).attributes
      expect(attributes).to include(adjustment_cents: -1_360, negative_balance_cents: 160)
      expect(PayoutStatement.call(event: event)[:closing][:total_cents]).to eq(-160)
    end
  end
end
