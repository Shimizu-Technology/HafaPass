require "rails_helper"

RSpec.describe MessageDeliveryJob do
  let(:delivery) { create(:message_delivery) }

  it "records the provider id and sends with one durable delivery" do
    allow(EmailService).to receive(:send_delivery_payload).and_return({ id: "email_provider_123" })

    described_class.new.perform(delivery.id)

    expect(EmailService).to have_received(:send_delivery_payload).with(delivery)
    expect(delivery.reload).to have_attributes(status: "sent", provider_id: "email_provider_123", attempts: 1)
  end

  it "records a failure without changing the idempotency key" do
    original_key = delivery.idempotency_key
    allow(EmailService).to receive(:send_delivery_payload).and_raise(StandardError, "provider unavailable")

    expect { described_class.new.perform(delivery.id) }.to raise_error(StandardError, "provider unavailable")

    expect(delivery.reload).to have_attributes(status: "failed", attempts: 1, idempotency_key: original_key)
    expect(delivery.last_error).to include("provider unavailable")
  end

  it "suppresses a recipient after a prior hard bounce" do
    create(:message_delivery, order: delivery.order, recipient: delivery.recipient.upcase, status: :bounced)
    allow(EmailService).to receive(:send_delivery_payload)

    described_class.new.perform(delivery.id)

    expect(delivery.reload).to be_suppressed
    expect(EmailService).not_to have_received(:send_delivery_payload)
  end

  it "sends transactional mail after a waitlist complaint" do
    complaint = create(:message_delivery, order: delivery.order, event: delivery.order.event,
      recipient: delivery.recipient.upcase, template: "waitlist_notification", status: :complained)
    expect(complaint).to be_complained
    change = delivery.order.event.event_changes.create!(change_type: "rescheduled", occurred_at: Time.current)
    allow(EmailService).to receive(:prepare_delivery_payload).and_return({ "subject" => "Update", "html" => "Update" })
    allow(EmailService).to receive(:send_delivery_payload).and_return({ simulated: true })

    %w[order_confirmation ticket_delivery refund_notification event_change].each do |template|
      message = create(:message_delivery, order: delivery.order, event: delivery.order.event,
        recipient: delivery.recipient, template: template,
        metadata: template == "event_change" ? { event_change_id: change.id } : {})
      described_class.new.perform(message.id)
      expect(message.reload).to be_sent
    end
    expect(EmailService).to have_received(:send_delivery_payload).exactly(4).times
  end

  it "keeps a marketing unsubscribe scoped to commercial templates" do
    event = delivery.order.event
    MarketingUnsubscribe.create!(organization: event.organization, email: delivery.recipient.downcase,
      unsubscribed_at: Time.current)
    commercial = create(:message_delivery, order: delivery.order, event: event,
      recipient: delivery.recipient, template: "communication_campaign")
    expect(commercial.marketing_unsubscribed?).to be(true)
    delivery.update!(event: event)
    allow(EmailService).to receive(:prepare_delivery_payload).and_return({ "subject" => "Receipt", "html" => "Receipt" })
    allow(EmailService).to receive(:send_delivery_payload).and_return({ simulated: true })

    described_class.new.perform(delivery.id)

    expect(delivery.reload).to be_sent
    expect(EmailService).to have_received(:send_delivery_payload).once
  end

  it "suppresses every template after a hard bounce" do
    create(:message_delivery, order: delivery.order, recipient: delivery.recipient, status: :bounced)
    allow(EmailService).to receive(:send_delivery_payload)

    MessageDelivery::EMAIL_TEMPLATE_CLASSIFICATION.each_key do |template|
      message = create(:message_delivery, order: delivery.order, event: delivery.order.event,
        recipient: delivery.recipient, template: template)
      expect(message.suppressed_recipient?).to be(true), template
    end
    described_class.new.perform(delivery.id)
    expect(delivery.reload).to be_suppressed
    expect(EmailService).not_to have_received(:send_delivery_payload)
  end

  it "propagates a provider-rejected address to transactional mail without a provider message id" do
    rejected = create(:message_delivery, order: delivery.order, recipient: delivery.recipient)
    allow(EmailService).to receive(:send_delivery_payload)
      .and_raise(Resend::Error::InvalidRequestError.new("Recipient address does not exist", 422))

    expect { described_class.new.perform(rejected.id) }.to raise_error(Resend::Error::InvalidRequestError)
    expect(rejected.reload).to be_suppressed
    expect(rejected.metadata["provider_address_invalid"]).to be(true)

    candidate = create(:message_delivery, order: delivery.order, recipient: delivery.recipient,
      template: "refund_notification")
    expect(candidate.suppressed_recipient?).to be(true)
    described_class.new.perform(candidate.id)
    expect(candidate.reload).to be_suppressed
    expect(EmailService).to have_received(:send_delivery_payload).once
  end

  it "never sends to a reserved placeholder address" do
    delivery.update_columns(recipient: GuestListEntry::PLACEHOLDER_EMAIL)
    allow(EmailService).to receive(:send_delivery_payload)

    described_class.new.perform(delivery.id)

    expect(delivery.reload).to have_attributes(status: "cancelled", attempts: 0)
    expect(EmailService).not_to have_received(:send_delivery_payload)
  end

  it "cancels a queued legacy cosmetic event-change email before delivery" do
    change = delivery.order.event.event_changes.create!(change_type: "rescheduled", occurred_at: Time.current)
    EventChange.where(id: change.id).update_all(change_type: "customized")
    delivery.update!(template: "event_change", metadata: { event_change_id: change.id })
    allow(EmailService).to receive(:send_delivery_payload)

    described_class.new.perform(delivery.id)

    expect(delivery.reload).to have_attributes(status: "cancelled", attempts: 0)
    expect(EmailService).not_to have_received(:send_delivery_payload)
  end
end
