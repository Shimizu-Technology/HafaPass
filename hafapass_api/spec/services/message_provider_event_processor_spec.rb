require "rails_helper"

RSpec.describe MessageProviderEventProcessor do
  let(:delivery) { create(:message_delivery, provider: "resend", provider_id: "email_123", status: :sent) }

  def provider_event(type, at: Time.current, message: "Temporary transport failure", code: nil, bounce_type: "Permanent")
    {
      "type" => type,
      "created_at" => at.iso8601,
      "data" => {
        "email_id" => "email_123",
        "to" => [delivery.recipient],
        "subject" => "private subject",
        "bounce" => { "type" => bounce_type, "message" => message },
        "error" => { "code" => code, "message" => message }
      }
    }
  end

  def persisted_receipt(message_id:, event_id: "persisted-event", **attributes)
    MessageProviderEvent.create!({
      provider: "resend", provider_event_id: event_id, provider_message_id: message_id,
      event_type: "email.delivered", occurred_at: 1.minute.ago, received_at: Time.current
    }.merge(attributes))
  end

  [nil, "", " \t\n", 123, true, false, [], ["email_123"], { "id" => "email_123" }].each do |message_id|
    it "rejects email_id #{message_id.inspect} without changing an unsent delivery or receipts", :aggregate_failures do
      unsent = create(:message_delivery, provider: "resend", provider_id: nil)
      event = provider_event("email.delivered")
      event["data"]["email_id"] = message_id
      deliveries_before = [unsent, delivery].map(&:attributes)

      expect do
        described_class.call(provider_event_id: "invalid-event", event: event)
      end.to raise_error(ResendWebhookVerifier::VerificationError, /email_id/)

      expect([unsent.reload, delivery.reload].map(&:attributes)).to eq(deliveries_before)
      expect(MessageProviderEvent.count).to eq(0)
    end
  end

  it "rejects a missing email_id without recording a receipt" do
    event = provider_event("email.delivered")
    event["data"].delete("email_id")

    expect do
      described_class.call(provider_event_id: "missing-id", event: event)
    end.to raise_error(ResendWebhookVerifier::VerificationError, /email_id/)

    expect(MessageProviderEvent.count).to eq(0)
  end

  [nil, Time.utc(2026, 10, 1)].each do |processed_at|
    it "does not change an existing #{processed_at ? 'processed' : 'pending'} receipt on malformed input", :aggregate_failures do
      receipt = persisted_receipt(message_id: "email_123", processed_at: processed_at, processing_error: "prior evidence")
      event = provider_event("email.delivered")
      event["data"]["email_id"] = nil
      receipt_before = receipt.attributes
      delivery_before = delivery.attributes

      expect do
        described_class.call(provider_event_id: receipt.provider_event_id, event: event)
      end.to raise_error(ResendWebhookVerifier::VerificationError, /email_id/)

      expect(receipt.reload.attributes).to eq(receipt_before)
      expect(delivery.reload.attributes).to eq(delivery_before)
    end
  end

  [nil, "", " \t\n", "another-email"].each do |message_id|
    [nil, Time.utc(2026, 10, 1)].each do |processed_at|
      it "preserves a #{processed_at ? 'processed' : 'pending'} stored receipt for #{message_id.inspect} on a conflicting replay" do
        receipt = persisted_receipt(message_id: message_id, processed_at: processed_at, processing_error: "prior evidence")
        receipt_before = receipt.attributes
        delivery_before = delivery.attributes

        expect do
          described_class.call(provider_event_id: receipt.provider_event_id, event: provider_event("email.delivered"))
        end.to raise_error(ResendWebhookVerifier::VerificationError, /email_id/)

        expect(receipt.reload.attributes).to eq(receipt_before)
        expect(delivery.reload.attributes).to eq(delivery_before)
        expect(MessageProviderEvent.count).to eq(1)
      end
    end
  end

  [nil, "", " \t\n", "another-email"].each do |message_id|
    it "rejects direct processing of a persisted receipt for #{message_id.inspect}" do
      receipt = persisted_receipt(message_id: message_id)
      receipt_before = receipt.attributes
      delivery_before = delivery.attributes

      expect do
        described_class.new(provider_event_id: receipt.provider_event_id, event: nil).process_receipt!(receipt, delivery)
      end.to raise_error(ResendWebhookVerifier::VerificationError, /email_id/)

      expect(receipt.reload.attributes).to eq(receipt_before)
      expect(delivery.reload.attributes).to eq(delivery_before)
    end
  end

  it "rejects processing a receipt against a delivery from another provider" do
    delivery.update!(provider: "simulated")
    receipt = persisted_receipt(message_id: delivery.provider_id)
    receipt_before = receipt.attributes
    delivery_before = delivery.attributes

    expect do
      described_class.new(provider_event_id: receipt.provider_event_id, event: nil).process_receipt!(receipt, delivery)
    end.to raise_error(ResendWebhookVerifier::VerificationError, /email_id/)

    expect(receipt.reload.attributes).to eq(receipt_before)
    expect(delivery.reload.attributes).to eq(delivery_before)
  end

  [nil, "", " \t\n"].each do |message_id|
    it "leaves legacy receipts and an unsent delivery with #{message_id.inspect} unchanged during recovery" do
      delivery.update!(provider_id: message_id, status: :queued)
      receipt = persisted_receipt(message_id: message_id)
      receipt_before = receipt.attributes
      delivery_before = delivery.attributes

      described_class.reconcile_for!(delivery)

      expect(receipt.reload.attributes).to eq(receipt_before)
      expect(delivery.reload.attributes).to eq(delivery_before)
    end
  end

  {
    "email.sent" => "sent", "email.delivered" => "delivered", "email.delivery_delayed" => "delayed",
    "email.failed" => "failed", "email.bounced" => "bounced", "email.complained" => "complained",
    "email.suppressed" => "suppressed"
  }.each do |event_type, status|
    it "applies #{event_type} only to the exact provider message ID" do
      unsent = create(:message_delivery, provider: "resend", provider_id: nil)
      other = create(:message_delivery, provider: "resend", provider_id: "email_123-other")
      untouched = [unsent, other].map(&:attributes)

      receipt = described_class.call(provider_event_id: "valid-event", event: provider_event(event_type))

      expect(receipt).to have_attributes(message_delivery_id: delivery.id, provider_message_id: "email_123")
      expect(receipt.processed_at).to be_present
      expect(delivery.reload.status).to eq(status)
      expect([unsent.reload, other.reload].map(&:attributes)).to eq(untouched)
    end
  end

  it "continues to record an unsupported event without changing delivery state" do
    event = provider_event("email.opened")
    delivery_before = delivery.attributes

    receipt = described_class.call(provider_event_id: "opened-event", event: event)

    expect(receipt.processed_at).to be_present
    expect(delivery.reload.attributes).to eq(delivery_before)
  end

  it "still reports and raises unexpected processing errors" do
    allow_any_instance_of(MessageDelivery).to receive(:with_lock).and_raise(RuntimeError, "unexpected failure")
    expect(Sentry).to receive(:capture_exception).with(instance_of(RuntimeError), anything)

    expect do
      described_class.call(provider_event_id: "failed-processing", event: provider_event("email.delivered"))
    end.to raise_error(RuntimeError, "unexpected failure")

    expect(MessageProviderEvent.find_by!(provider_event_id: "failed-processing"))
      .to have_attributes(processed_at: nil, processing_error: "RuntimeError: unexpected failure")
  end

  it "records provider events idempotently and applies a hard bounce" do
    event = provider_event("email.bounced", message: "Mailbox does not exist")
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

  it "keeps a hard bounce terminal when a newer delivered receipt arrives" do
    described_class.call(provider_event_id: "hard-bounce",
      event: provider_event("email.bounced", message: "Mailbox does not exist"))
    described_class.call(provider_event_id: "contradictory-delivery",
      event: provider_event("email.delivered", at: 1.minute.from_now))

    expect(delivery.reload).to be_bounced
    expect(delivery.metadata["provider_address_invalid"]).to be(true)
    expect(MessageProviderEvent.find_by!(provider_event_id: "contradictory-delivery").processed_at).to be_present
    refund_notice = create(:message_delivery, recipient: delivery.recipient, template: "refund_notification")
    allow(EmailService).to receive(:send_delivery_payload)
    MessageDeliveryJob.perform_now(refund_notice.id)
    expect(refund_notice.reload).to be_suppressed
    expect(EmailService).not_to have_received(:send_delivery_payload)
  end

  it "suppresses every later template after an invalid-address failed webhook" do
    event = provider_event("email.failed")
    event["data"].except!("bounce", "error")
    event["data"]["failed"] = { "reason" => "Mailbox does not exist" }
    described_class.call(provider_event_id: "invalid-address",
      event: event)

    expect(delivery.reload).to be_suppressed
    expect(delivery.metadata["provider_address_invalid"]).to be(true)
    refund_notice = create(:message_delivery, recipient: delivery.recipient, template: "refund_notification")
    allow(EmailService).to receive(:send_delivery_payload)
    MessageDeliveryJob.perform_now(refund_notice.id)
    expect(refund_notice.reload).to be_suppressed
    expect(EmailService).not_to have_received(:send_delivery_payload)
  end

  it "does not suppress a refund for a transient failed webhook" do
    event = provider_event("email.failed")
    event["data"].except!("bounce", "error")
    event["data"]["failed"] = { "reason" => "reached_daily_quota" }
    described_class.call(provider_event_id: "temporary-failure",
      event: event)

    expect(delivery.reload).to be_failed
    expect(delivery.metadata["provider_address_invalid"]).not_to be(true)
    refund_notice = create(:message_delivery, recipient: delivery.recipient, template: "refund_notification")
    allow(EmailService).to receive(:prepare_delivery_payload).and_return({ "subject" => "Refund", "html" => "Refund" })
    allow(EmailService).to receive(:send_delivery_payload).and_return({ simulated: true })
    MessageDeliveryJob.perform_now(refund_notice.id)
    expect(refund_notice.reload).to be_sent
    expect(EmailService).to have_received(:send_delivery_payload).once
  end

  it "keeps an early webhook pending and reconciles it when the provider id is known" do
    delivery.update!(provider_id: nil, status: :queued)
    delivery_before = delivery.attributes
    event = provider_event("email.delivered", at: 1.minute.ago)

    receipt = described_class.call(provider_event_id: "early-delivery", event: event)
    expect(receipt).to have_attributes(message_delivery_id: nil, processed_at: nil)
    receipt_before = receipt.attributes

    duplicate = described_class.call(provider_event_id: "early-delivery", event: event)
    expect(duplicate.id).to eq(receipt.id)
    expect(receipt.reload.attributes).to eq(receipt_before)
    expect(delivery.reload.attributes).to eq(delivery_before)

    delivery.update!(provider_id: "email_123", status: :sent)
    described_class.reconcile_for!(delivery)

    expect(receipt.reload.message_delivery_id).to eq(delivery.id)
    expect(receipt.processed_at).to be_present
    expect(delivery.reload).to be_delivered
  end
end
