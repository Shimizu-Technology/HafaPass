require "rails_helper"

RSpec.describe "Organizer retained cash accounting" do
  let(:profile) { create(:organizer_profile, :verified) }
  let(:actor) { profile.user }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 1000, quantity_available: 10) }
  let(:cash_order) do
    Commerce::CashSaleCreator.call(event: event, user: actor,
      parameters: { line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }], payment_method: "door_cash" },
      idempotency_key: "cash-sale").order
  end
  let(:online_order) do
    order = create(:order, event: event, subtotal_cents: 10_000, service_fee_cents: 0, total_cents: 10_000)
    create(:order_item, order: order, unit_price_cents: 10_000, subtotal_cents: 10_000,
      fee_cents: 0, organizer_proceeds_cents: 10_000)
    create(:payment, :succeeded, order: order, provider_environment: "simulate",
      provider_payment_id: "sim_pi_online", provider_payload: { simulated: true })
    order
  end
  let(:evidence) { { reference: "Drawer 2 return receipt 17", returned_at: Time.current.utc.iso8601(6) } }

  before do
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeService).to receive(:refund_payment).and_raise("Cash must not use a provider refund")
  end

  def record_return(amount: 300, key: "cash-return", **overrides)
    cash_order
    Commerce::RefundCreator.call(order: cash_order, amount_cents: amount, requested_by: actor,
      reason: "Cash physically returned at the door", idempotency_key: key, cash_return: evidence, **overrides)
  end

  it "keeps cash revenue on the statement while excluding it from platform and organization payables" do
    cash_order
    online_order
    calculation = Settlements::Calculator.call(event)
    expect(calculation.attributes).to include(organizer_proceeds_cents: 11_000, adjustment_cents: -1000,
      payable_cents: 10_000, net_cents: 11_000)
    offset = calculation.items.find { |item| item[:metadata][:adjustment_kind] == "organizer_retained_cash" }
    expect(offset).to include(kind: "adjustment", amount_cents: -1000)
    expect(offset[:metadata]).to include(cash_custodian: "organizer", order_id: cash_order.id)
    expect(Commerce::LedgerTotals.call(event.orders)).to include(organizer_proceeds_cents: 11_000, payout_ready_cents: 10_000)

    event.update!(status: :completed)
    settlement = Settlements::Finalizer.call(event: event, actor: actor)
    create(:connected_account, organization: event.organization)
    expect(OrganizationPayoutBalance.available_cents(event.organization)).to eq(10_000)
    payout = PayoutCreator.call(settlement: settlement, actor: actor, idempotency_key: "online-funds-only")
    expect(payout.amount_cents).to eq(10_000)
    expect(OrganizationPayoutBalance.available_cents(event.organization)).to eq(0)
    expect(settlement.settlement_items.where("metadata->>'adjustment_kind' = ?", "organizer_retained_cash").sum(:amount_cents)).to eq(-1000)
  end

  it "atomically records partial and full cash returns with evidence and never calls Stripe" do
    cash_order
    first = record_return
    expect(first).to have_attributes(provider: "door_cash", status: "succeeded", amount_cents: 300,
      provider_refund_id: "cash_return_#{first.id}", requested_by_id: actor.id)
    expect(first.provider_payload).to include("manual_record" => true,
      "cash_return" => evidence.stringify_keys.merge("recorded_by_user_id" => actor.id, "cash_custodian" => "organizer"))
    expect(first.refund_items.sum(:organizer_proceeds_cents)).to eq(300)
    expect(cash_order.reload).to have_attributes(status: "partially_refunded", stripe_refund_id: nil)
    expect(cash_order.payments.first).to have_attributes(status: "partially_refunded", refunded_cents: 300)
    expect(Settlements::Calculator.call(event).attributes).to include(organizer_proceeds_cents: 700,
      adjustment_cents: -700, payable_cents: 0, negative_balance_cents: 0)
    expect(cash_order.tickets.first).to be_issued

    second = record_return(amount: 700, key: "cash-final-return")
    expect(second).to be_succeeded
    expect(cash_order.reload).to have_attributes(status: "refunded", refunded_cents: 1000)
    expect(cash_order.payments.first).to be_refunded
    expect(cash_order.tickets.first).to be_cancelled
    expect(ticket_type.reload.quantity_sold).to eq(0)
    expect(Settlements::Calculator.call(event).attributes).to include(organizer_proceeds_cents: 0,
      adjustment_cents: 0, payable_cents: 0, negative_balance_cents: 0)
    expect(StripeService).not_to have_received(:refund_payment)
  end

  it "uses immutable payment provenance if an order's display method changes" do
    cash_order.update!(payment_method: "door_card")
    online_order
    expect(Settlements::Calculator.call(event).attributes).to include(payable_cents: 10_000, adjustment_cents: -1000)
    expect(Commerce::LedgerTotals.call(event.orders)).to include(payout_ready_cents: 10_000)
  end

  it "does not charge organizer-returned cash against previously finalized online funds" do
    cash_order
    online_order
    event.update!(status: :completed)
    settlement = Settlements::Finalizer.call(event: event, actor: actor)
    record_return(amount: 1000)
    expect(OrganizationPayoutBalance.available_cents(event.organization)).to eq(10_000)
    expect(Settlements::Calculator.call(event).attributes).to include(payable_cents: 10_000, negative_balance_cents: 0)
    expect(Commerce::LedgerTotals.call(event.orders)).to include(organizer_proceeds_cents: 10_000, payout_ready_cents: 10_000)
    expect(settlement.reload.payable_cents).to eq(10_000)
    revised = Settlements::Finalizer.call(event: event, actor: actor)
    expect(revised.version).to eq(2)
    expect(revised.payable_cents).to eq(10_000)
  end

  it "refuses automated cash refunds without a return attestation" do
    cash_order
    expect do
      Commerce::RefundCreator.call(order: cash_order, requested_by: actor, idempotency_key: "no-cash-evidence")
    end.to raise_error(Commerce::RefundCreator::RefundError, /Automated refunds are not supported/)
    expect(cash_order.refunds).to be_empty
    expect(cash_order.reload).to be_completed
  end

  it "replays the exact cash return once and rejects changed evidence or an excessive amount" do
    cash_order
    first = record_return
    expect(record_return).to eq(first)
    expect(cash_order.refunds.count).to eq(1)
    expect do
      record_return(cash_return: evidence.merge(reference: "different receipt"))
    end.to raise_error(Commerce::RefundCreator::RefundError, /different refund request/)
    expect { record_return(amount: 701, key: "too-much") }
      .to raise_error(Commerce::RefundCreator::RefundError, /exceeds refundable balance/)
    expect(cash_order.reload.refunded_cents).to eq(300)
  end

  it "requires an actor, reason, bounded reference and a valid past return timestamp" do
    cash_order
    invalid = [
      { requested_by: nil }, { reason: nil }, { cash_return: evidence.merge(reference: " ") },
      { cash_return: evidence.merge(reference: "x" * 256) },
      { cash_return: evidence.merge(returned_at: 1.day.from_now.iso8601) },
      { cash_return: evidence.merge(returned_at: 1.day.ago.iso8601) },
      { cash_return: evidence.merge(returned_at: "unknown") }
    ]
    invalid.each do |arguments|
      expect { record_return(**arguments) }.to raise_error(Commerce::RefundCreator::RefundError)
    end
    expect(cash_order.refunds).to be_empty
  end

  it "refuses a manual cash return against an online payment" do
    cash_order
    online_order
    expect { record_return(order: online_order) }
      .to raise_error(Commerce::RefundCreator::RefundError, /organizer-collected cash/)
    expect(online_order.refunds).to be_empty
  end

  it "rolls back cash evidence and allocations together if finalization fails" do
    cash_order
    allow(EmailService).to receive(:send_refund_notification_async).and_raise("local record interrupted")
    expect { record_return(amount: 1000) }.to raise_error("local record interrupted")
    expect(cash_order.refunds).to be_empty
    expect(cash_order.reload).to be_completed
    expect(cash_order.payments.first).to be_succeeded
    expect(cash_order.tickets.first).to be_issued
    expect(ticket_type.reload.quantity_sold).to eq(1)
  end
end
