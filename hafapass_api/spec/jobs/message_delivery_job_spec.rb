require "rails_helper"

RSpec.describe MessageDeliveryJob do
  let(:delivery) { create(:message_delivery) }

  it "records the provider id and sends with one durable delivery" do
    allow(EmailService).to receive(:send_order_confirmation).and_return({ id: "email_provider_123" })

    described_class.new.perform(delivery.id)

    expect(EmailService).to have_received(:send_order_confirmation).with(delivery.order, delivery: delivery)
    expect(delivery.reload).to have_attributes(status: "sent", provider_id: "email_provider_123", attempts: 1)
  end

  it "records a failure without changing the idempotency key" do
    original_key = delivery.idempotency_key
    allow(EmailService).to receive(:send_order_confirmation).and_raise(StandardError, "provider unavailable")

    expect { described_class.new.perform(delivery.id) }.to raise_error(StandardError, "provider unavailable")

    expect(delivery.reload).to have_attributes(status: "failed", attempts: 1, idempotency_key: original_key)
    expect(delivery.last_error).to include("provider unavailable")
  end

  it "suppresses a recipient after a prior hard bounce" do
    create(:message_delivery, order: delivery.order, recipient: delivery.recipient, status: :bounced)
    allow(EmailService).to receive(:send_order_confirmation)

    described_class.new.perform(delivery.id)

    expect(delivery.reload).to be_suppressed
    expect(EmailService).not_to have_received(:send_order_confirmation)
  end
end
