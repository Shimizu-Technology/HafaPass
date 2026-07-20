require "rails_helper"

RSpec.describe "Commerce ledger invariants" do
  it "prevents order item updates and deletion" do
    item = create(:order_item)

    expect(item.update(name: "Rewritten history")).to be(false)
    expect(item.destroy).to be(false)
    expect(OrderItem.exists?(item.id)).to be(true)
  end

  it "enforces money constraints in PostgreSQL" do
    order = create(:order)

    expect do
      order.update_columns(total_cents: -1)
    end.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "enforces currency constraints in PostgreSQL" do
    order = create(:order)

    expect do
      order.update_columns(currency: "dollars")
    end.to raise_error(ActiveRecord::StatementInvalid, /orders_currency_length/)
  end

  it "enforces inventory constraints in PostgreSQL" do
    ticket_type = create(:ticket_type)

    expect do
      ticket_type.update_columns(quantity_sold: -1)
    end.to raise_error(ActiveRecord::StatementInvalid, /ticket_types_sold_nonnegative/)
  end

  it "enforces unique provider and idempotency identifiers" do
    payment = create(:payment)

    expect do
      create(:payment, provider_payment_id: payment.provider_payment_id)
    end.to raise_error(ActiveRecord::RecordInvalid, /Provider payment has already been taken/)

    expect do
      create(:payment, idempotency_key: payment.idempotency_key)
    end.to raise_error(ActiveRecord::RecordInvalid, /Idempotency key has already been taken/)
  end

  it "prevents deleting an event with financial history" do
    event = create(:event, :published)
    create(:order, event: event)

    expect(event.destroy).to be(false)
    expect(Event.exists?(event.id)).to be(true)
  end

  it "calculates separate gross, discounts, refunds, net, fees, and proceeds" do
    order = create(
      :order,
      subtotal_cents: 5000,
      discount_cents: 500,
      service_fee_cents: 250,
      total_cents: 4750,
      status: :partially_refunded
    )
    item = create(
      :order_item,
      order: order,
      unit_price_cents: 5000,
      subtotal_cents: 5000,
      discount_cents: 500,
      fee_cents: 250,
      organizer_proceeds_cents: 4500
    )
    create(:fee_component, order: order, amount_cents: 250, kind: "platform")
    refund = create(:refund, order: order, amount_cents: 1000)
    create(:refund_item, refund: refund, order_item: item, amount_cents: 1000)

    expect(Commerce::LedgerTotals.call(Order.where(id: order.id))).to eq(
      gross_cents: 5000,
      discount_cents: 500,
      refund_cents: 1000,
      net_cents: 3750,
      fee_cents: 250,
      organizer_proceeds_cents: 3500,
      payout_ready_cents: 3500
    )
  end

  it "excludes pending, cancelled, and expired checkouts from financial totals" do
    event = create(:event)
    settled = create(:order, event: event, status: :completed, subtotal_cents: 1000, service_fee_cents: 100,
      total_cents: 1100)
    create(:order_item, order: settled, unit_price_cents: 1000, subtotal_cents: 1000, fee_cents: 100,
      organizer_proceeds_cents: 1000)
    create(:fee_component, order: settled, amount_cents: 100)

    [:pending, :cancelled, :expired].each do |status|
      abandoned = create(:order, event: event, status: status, subtotal_cents: 9000, service_fee_cents: 900,
        total_cents: 9900)
      create(:order_item, order: abandoned, unit_price_cents: 9000, subtotal_cents: 9000, fee_cents: 900,
        organizer_proceeds_cents: 9000)
      create(:fee_component, order: abandoned, amount_cents: 900)
    end

    expect(Commerce::LedgerTotals.call(event.orders)).to include(
      gross_cents: 1000,
      net_cents: 1100,
      fee_cents: 100,
      organizer_proceeds_cents: 1000
    )
  end
end
