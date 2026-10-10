require "rails_helper"

RSpec.describe OrderPresenter do
  it "preserves original allocations while reporting cancelled tickets as non-refundable" do
    order = create(:order, subtotal_cents: 2_000, service_fee_cents: 200, total_cents: 2_200)
    ticket_type = create(:ticket_type, event: order.event, price_cents: 1_000)
    item = create(:order_item, order: order, ticket_type: ticket_type, quantity: 2,
      unit_price_cents: 1_000, subtotal_cents: 2_000, fee_cents: 200, organizer_proceeds_cents: 2_000)
    cancelled = create(:ticket, order: order, order_item: item, event: order.event,
      ticket_type: ticket_type, status: :cancelled)
    issued = create(:ticket, order: order, order_item: item, event: order.event, ticket_type: ticket_type)

    tickets = described_class.call(order, include_tickets: true)[:tickets].index_by { |ticket| ticket[:id] }

    expect(tickets.fetch(cancelled.id)[:refundable_cents]).to eq(0)
    expect(tickets.fetch(issued.id)[:refundable_cents]).to eq(1_100)
  end

  [false, true].each do |preloaded|
    it "shows only the safe latest confirmation or fulfillment status with deliveries preloaded=#{preloaded}" do
      order = create(:order)
      create(:message_delivery, order: order, template: "order_confirmation", status: :delivered)
      resend = create(:message_delivery, order: order, template: "fulfillment_resend", status: :queued,
        provider_id: "private-provider-id", idempotency_key: "private-provider-operation",
        outbound_payload: { "html" => "private-token-content" })
      create(:message_delivery, order: order, template: "communication_campaign", status: :failed)
      order.message_deliveries.load if preloaded

      expect(described_class.call(order)[:confirmation_delivery]).to eq(
        status: "queued", simulated: false, updated_at: resend.updated_at
      )
      resend.update!(status: :delivered)
      order.message_deliveries.reload if preloaded
      expect(described_class.call(order)[:confirmation_delivery]).to eq(
        status: "delivered", simulated: false, updated_at: resend.updated_at
      )
    end
  end
end
