require "rails_helper"

RSpec.describe MessageProviderEventProcessor do
  let(:delivery) { create(:message_delivery, provider: "resend", provider_id: "email_123", status: :sent) }

  def provider_event(type, at: Time.current)
    {
      "type" => type,
      "created_at" => at.iso8601,
      "data" => {
        "email_id" => "email_123",
        "to" => [delivery.recipient],
        "subject" => "private subject",
        "bounce" => { "type" => "Permanent", "message" => "Mailbox does not exist" }
      }
    }
  end

  it "records provider events idempotently and applies a hard bounce" do
    event = provider_event("email.bounced")
    first = described_class.call(provider_event_id: "msg_unique", event: event)
    second = described_class.call(provider_event_id: "msg_unique", event: event)

    expect(second.id).to eq(first.id)
    expect(MessageProviderEvent.where(provider_event_id: "msg_unique").count).to eq(1)
    expect(delivery.reload).to be_bounced
    expect(delivery.bounced_at).to be_present
    expect(first.payload.to_json).not_to include(delivery.recipient, "private subject")
  end

  it "does not let an older delayed event regress a newer delivered state" do
    delivered_at = Time.current
    described_class.call(provider_event_id: "delivered", event: provider_event("email.delivered", at: delivered_at))
    described_class.call(provider_event_id: "older-delay",
      event: provider_event("email.delivery_delayed", at: delivered_at - 1.minute))

    expect(delivery.reload).to be_delivered
  end

  it "keeps an early webhook pending and reconciles it when the provider id is known" do
    delivery.update!(provider_id: nil)
    event = provider_event("email.delivered", at: 1.minute.ago)

    receipt = described_class.call(provider_event_id: "early-delivery", event: event)
    expect(receipt).to have_attributes(message_delivery_id: nil, processed_at: nil)

    delivery.update!(provider_id: "email_123")
    described_class.reconcile_for!(delivery)

    expect(receipt.reload.message_delivery_id).to eq(delivery.id)
    expect(receipt.processed_at).to be_present
    expect(delivery.reload).to be_delivered
  end
end
