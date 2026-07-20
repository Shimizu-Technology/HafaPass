require "rails_helper"
require "ostruct"

RSpec.describe Commerce::OrderCreator do
  let(:event) { create(:event, :published) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 1000) }

  it "cancels the provider intent and releases inventory when attaching it fails" do
    intent = OpenStruct.new(id: "pi_orphan_candidate", client_secret: "secret")
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:create_payment_intent).and_return(intent)
    allow(StripeService).to receive(:cancel_payment_intent).and_return(
      OpenStruct.new(id: intent.id, status: "canceled")
    )
    allow_any_instance_of(Order).to receive(:update!).and_wrap_original do |original, attributes|
      raise ActiveRecord::StatementInvalid, "attach failed" if attributes.key?(:stripe_payment_intent_id)

      original.call(attributes)
    end

    expect do
      described_class.call(
        event: event,
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
        buyer_email: "buyer@example.com",
        buyer_name: "Buyer"
      )
    end.to raise_error(described_class::CheckoutError, "Payment setup failed")

    order = event.orders.last
    expect(StripeService).to have_received(:cancel_payment_intent).with(
      intent.id,
      idempotency_key: "cancel:payment-setup:#{order.payments.first.id}"
    )
    expect(order.reload).to be_cancelled
    expect(order.inventory_holds).to all(be_released)
  end

  it "rejects a checkout that exceeds the active pricing tier allocation before payment setup" do
    create(
      :pricing_tier,
      ticket_type: ticket_type,
      tier_type: :quantity_based,
      quantity_limit: 2,
      quantity_sold: 1,
      price_cents: 500
    )
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:create_payment_intent)

    expect do
      described_class.call(
        event: event,
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 2 }],
        buyer_email: "buyer@example.com",
        buyer_name: "Buyer"
      )
    end.to raise_error(described_class::CheckoutError, /Only 1 ticket remains at the/)

    expect(StripeService).not_to have_received(:create_payment_intent)
    expect(event.orders).to be_empty
  end

  it "keeps the purchased name and price when current ticket inventory is edited" do
    allow(StripeService).to receive(:payment_enabled?).and_return(false)
    purchased_name = ticket_type.name

    result = described_class.call(
      event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "buyer@example.com",
      buyer_name: "Buyer"
    )
    item = result.order.order_items.first

    ticket_type.update!(name: "Renamed admission", price_cents: 9000)

    expect(item.reload).to have_attributes(name: purchased_name, unit_price_cents: 1000)
  end
end
