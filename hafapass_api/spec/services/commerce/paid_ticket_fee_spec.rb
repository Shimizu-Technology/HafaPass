# frozen_string_literal: true

require "rails_helper"

# The flat part of the service fee is charged per paid ticket: a ticket whose
# selected unit price (tier or seat price, before promo discounts) is above zero.
RSpec.describe Commerce::OrderCreator, "per-paid-ticket flat fee" do
  let(:event) { create(:event, :published) }
  let(:paid) { create(:ticket_type, event: event, name: "General", price_cents: 2500, quantity_available: 10) }
  let(:free) { create(:ticket_type, event: event, name: "Child", price_cents: 0, quantity_available: 10) }

  before { SiteSetting.instance.update!(service_fee_percent: 5.0, service_fee_flat_cents: 100) }

  def place(line_items)
    described_class.call(event: event, line_items: line_items, buyer_email: "buyer@example.com", buyer_name: "Buyer",
      payment_required: false).order.reload
  end

  it "charges the flat fee only on paid tickets in a mixed order and allocates no fee to free lines" do
    order = place([{ ticket_type_id: paid.id, quantity: 2 }, { ticket_type_id: free.id, quantity: 2 }])

    # 5% of $50.00 + 2 paid tickets × $1.00 = $4.50 (not $6.50 for four tickets).
    expect(order).to have_attributes(subtotal_cents: 5000, service_fee_cents: 450, total_cents: 5450)
    items = order.order_items.index_by(&:ticket_type_id)
    expect(items[paid.id]).to have_attributes(fee_cents: 450, organizer_proceeds_cents: 5000)
    expect(items[free.id]).to have_attributes(fee_cents: 0, organizer_proceeds_cents: 0)
    expect(order.fee_components.find_by!(kind: "platform")).to have_attributes(amount_cents: 450)
    expect(order.fee_components.find_by!(kind: "platform").metadata).to include("paid_ticket_count" => 2)
  end

  it "charges no fee on an all-free order" do
    order = place([{ ticket_type_id: free.id, quantity: 3 }])

    expect(order).to have_attributes(service_fee_cents: 0, organizer_fee_cents: 0, total_cents: 0)
    expect(order.fee_components.find_by!(kind: "platform").amount_cents).to eq(0)
  end

  it "applies the per-paid-ticket fee to the organizer share when the organizer absorbs it" do
    event.update!(fee_policy: :organizer_absorbs, buyer_fee_percent: 0)
    order = place([{ ticket_type_id: paid.id, quantity: 1 }, { ticket_type_id: free.id, quantity: 1 }])

    expect(order).to have_attributes(service_fee_cents: 0, organizer_fee_cents: 225, total_cents: 2500)
    expect(order.order_items.find_by!(ticket_type: paid)).to have_attributes(organizer_fee_cents: 225,
      organizer_proceeds_cents: 2275)
    expect(order.order_items.find_by!(ticket_type: free)).to have_attributes(organizer_fee_cents: 0)
  end

  it "refunds one paid ticket of a mixed order with exactly that ticket's share of the fee" do
    order = place([{ ticket_type_id: paid.id, quantity: 2 }, { ticket_type_id: free.id, quantity: 2 }])
    paid_ticket = order.tickets.find_by!(ticket_type: paid)
    free_ticket = order.tickets.find_by!(ticket_type: free)
    expect(free_ticket.refundable_cents).to eq(0)

    refund = Commerce::RefundCreator.call(order: order, tickets: [paid_ticket], idempotency_key: "mixed-paid-refund")

    expect(refund).to be_succeeded
    expect(refund.amount_cents).to eq(2725)
    expect(refund.refund_items.sole).to have_attributes(organizer_proceeds_cents: 2500, fee_cents: 225, quantity: 1)
    expect(Settlements::Calculator.call(event).attributes).to include(organizer_proceeds_cents: 2500, platform_fee_cents: 225)
  end
end
