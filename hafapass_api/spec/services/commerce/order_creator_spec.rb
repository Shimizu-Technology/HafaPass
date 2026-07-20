require "rails_helper"
require "ostruct"

RSpec.describe Commerce::OrderCreator do
  let(:event) { create(:event, :published) }
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 1000) }

  it "rejects checkout for events that ended or are no longer published" do
    allow(StripeService).to receive(:payment_enabled?).and_return(false)
    checkout = lambda do
      described_class.call(
        event: event,
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
        buyer_email: "buyer@example.com",
        buyer_name: "Buyer"
      )
    end

    event.update!(starts_at: 2.days.ago, ends_at: 1.day.ago, doors_open_at: 2.days.ago - 30.minutes)
    expect(&checkout).to raise_error(described_class::CheckoutError, /not currently on sale/)

    event.update!(starts_at: 2.days.from_now, ends_at: 2.days.from_now + 2.hours,
      doors_open_at: 2.days.from_now - 30.minutes, status: :postponed)
    expect(&checkout).to raise_error(described_class::CheckoutError, /not currently on sale/)
    expect(event.orders).to be_empty
  end

  it "does not create a Stripe intent for an immediately settled box-office payment" do
    allow(StripeService).to receive(:payment_enabled?).and_return(true)
    allow(StripeService).to receive(:create_payment_intent)

    result = described_class.call(
      event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
      buyer_email: "walkin@example.com",
      buyer_name: "Walk-in",
      payment_required: false,
      service_fee: false,
      source: "box_office",
      payment_method: "door_cash"
    )

    expect(StripeService).not_to have_received(:create_payment_intent)
    expect(result.order).to be_completed
    expect(result.payment).to have_attributes(provider: "door_cash", status: "succeeded")
    expect(result.payment_intent).to be_nil
  end

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

  it "keeps a free ticket fully free with no flat service fee" do
    ticket_type.update!(price_cents: 0)
    allow(StripeService).to receive(:payment_enabled?).and_return(true)

    result = described_class.call(
      event: event,
      line_items: [{ ticket_type_id: ticket_type.id, quantity: 2 }],
      buyer_email: "free@example.com",
      buyer_name: "Free Buyer"
    )

    expect(result.order).to have_attributes(subtotal_cents: 0, service_fee_cents: 0, total_cents: 0, status: "completed")
    expect(result.payment).to be_nil
    expect(result.payment_intent).to be_nil
  end

  it "enforces a buyer limit across prior purchases using normalized email" do
    ticket_type.update!(max_per_buyer: 2, quantity_sold: 1)
    previous_order = create(:order, event: event, buyer_email: "BUYER@EXAMPLE.COM")
    create(:ticket, order: previous_order, event: event, ticket_type: ticket_type)
    allow(StripeService).to receive(:payment_enabled?).and_return(false)

    expect do
      described_class.call(
        event: event,
        line_items: [{ ticket_type_id: ticket_type.id, quantity: 2 }],
        buyer_email: " buyer@example.com ",
        buyer_name: "Buyer"
      )
    end.to raise_error(described_class::CheckoutError, /Purchase limit is 2/)
  end
end
