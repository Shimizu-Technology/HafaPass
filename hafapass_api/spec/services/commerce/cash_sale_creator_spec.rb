require "rails_helper"

RSpec.describe Commerce::CashSaleCreator do
  let(:event) { create(:event, :published, starts_at: 3.days.from_now) }
  let(:user) { event.organizer_profile.user }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 500, quantity_available: 10) }
  let(:parameters) { { line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }], payment_method: "door_cash" } }

  def sell(**overrides)
    described_class.call(event: event, user: user, parameters: parameters, idempotency_key: "cash-receipt", **overrides)
  end

  before { allow(EmailService).to receive(:send_order_confirmation_async) }

  it "binds a cash receipt to the initiating user" do
    sell
    expect { sell(user: create(:user)) }.to raise_error(described_class::Conflict)
    expect(Order.count).to eq(1)
    expect(ticket_type.reload.quantity_sold).to eq(1)
  end

  it "does not expose another organization's receipt" do
    sell
    other_event = create(:event, :published, starts_at: 3.days.from_now)
    other_type = create(:ticket_type, event: other_event)
    expect {
      sell(event: other_event, user: other_event.organizer_profile.user,
        parameters: { line_items: [{ ticket_type_id: other_type.id, quantity: 1 }], payment_method: "door_cash" })
    }.to raise_error(described_class::Conflict)
    expect(Order.count).to eq(1)
  end

  it "canonicalizes object key order without changing the requested inventory" do
    first = sell
    retry_parameters = { "payment_method" => "door_cash", "line_items" => [{ "quantity" => 1, "ticket_type_id" => ticket_type.id }] }
    expect(sell(parameters: retry_parameters).order.id).to eq(first.order.id)
    expect(Order.count).to eq(1)
  end

  it "rolls back the receipt, inventory and payment together when completion fails" do
    allow(Commerce::OrderLifecycle).to receive(:complete!).and_raise("completion interrupted")
    expect { sell }.to raise_error("completion interrupted")
    expect(Order.count).to eq(0)
    expect(Payment.count).to eq(0)
    expect(OrderItem.count).to eq(0)
    expect(InventoryHold.count).to eq(0)
    expect(ticket_type.reload.quantity_sold).to eq(0)

    allow(Commerce::OrderLifecycle).to receive(:complete!).and_call_original
    expect(sell.order).to be_completed
    expect(Order.count).to eq(1)
    expect(ticket_type.reload.quantity_sold).to eq(1)
  end
end
