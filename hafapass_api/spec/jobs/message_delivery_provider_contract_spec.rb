require "rails_helper"

RSpec.describe MessageDeliveryJob do
  include ActiveSupport::Testing::TimeHelpers
  let(:order) { create(:order, user: nil) }
  let(:delivery) { create(:message_delivery, order: order, template: "order_recovery", provider: "resend") }

  before do
    allow(EmailService).to receive(:configured?).and_return(true)
    allow(Resend::Emails).to receive(:send).and_return({ id: "email_contract" })
  end

  it "retries a lost response with identical HTML, original recipient, and provider key" do
    requests = []
    allow(Resend::Emails).to receive(:send) do |params, options:|
      requests << [params.deep_dup, options.deep_dup]
      raise IOError, "response lost" if requests.one?

      { id: "email_contract" }
    end
    expect { described_class.new.perform(delivery.id) }.to raise_error(IOError)
    first_marker = delivery.reload.provider_attempted_at
    order.update!(buyer_email: "changed@example.com", buyer_name: "Changed buyer")
    order.event.update!(title: "Changed event")
    travel 1.hour do
      described_class.new.perform(delivery.id)
    end

    expect(requests.length).to eq(2)
    expect(requests.last).to eq(requests.first)
    expect(requests.first[0].fetch("to")).to eq(delivery.recipient)
    expect(delivery.reload).to have_attributes(provider_attempted_at: first_marker, provider_outcome_unknown: false,
      provider_id: "email_contract", attempts: 2)
  end

  it "does not turn cancellation of one reminder into recipient-wide suppression" do
    create(:message_delivery, order: order, recipient: delivery.recipient, status: :cancelled)
    described_class.new.perform(delivery.id)
    expect(delivery.reload).to be_sent
    expect(Resend::Emails).to have_received(:send).once
  end

  it "does not treat a historical local suppression as provider evidence" do
    create(:message_delivery, order: order, recipient: delivery.recipient, status: :suppressed,
      last_error: "Recipient has a prior bounce, complaint, or suppression")
    described_class.new.perform(delivery.id)
    expect(delivery.reload).to be_sent
  end

  it "defers duplicate jobs while a live send lease owns the request" do
    delivery.update!(send_lease_token: "another-worker", send_lease_expires_at: 1.minute.from_now)
    expect { described_class.new.perform(delivery.id) }
      .to have_enqueued_job(described_class).with(delivery.id)
    expect(Resend::Emails).not_to have_received(:send)
    expect(delivery.reload.attempts).to eq(0)
  end

  it "bounds stalled requests and keeps their acceptance unknown" do
    stub_const("MessageDeliveryJob::PROVIDER_TIMEOUT", 0.01)
    allow(Resend::Emails).to receive(:send) { sleep 0.1 }
    expect { described_class.new.perform(delivery.id) }.to raise_error(Timeout::Error)
    expect(delivery.reload).to have_attributes(status: "failed", provider_outcome_unknown: true,
      send_lease_token: nil, send_lease_expires_at: nil)
    expect(delivery.provider_attempted_at).to be_present
  end

  it "does not permanently suppress a mailbox after an explicitly transient bounce" do
    prior = create(:message_delivery, order: order, recipient: delivery.recipient,
      provider: "resend", provider_id: "soft_bounce", status: :sent)
    MessageProviderEventProcessor.call(provider_event_id: "transient", event: {
      "type" => "email.bounced", "created_at" => Time.current.iso8601,
      "data" => { "email_id" => prior.provider_id, "bounce" => { "type" => "Transient", "subType" => "MailboxFull" } }
    })
    described_class.new.perform(delivery.id)
    expect(delivery.reload).to be_sent
  end

  it "keeps genuine provider suppression effective" do
    create(:message_delivery, order: order, recipient: delivery.recipient, status: :suppressed, provider_id: "suppression_event")
    described_class.new.perform(delivery.id)
    expect(delivery.reload).to be_suppressed
    expect(Resend::Emails).not_to have_received(:send)
  end

  it "requires a real provider message ID and retains uncertainty" do
    allow(Resend::Emails).to receive(:send).and_return({})
    expect { described_class.new.perform(delivery.id) }.to raise_error(described_class::UnknownProviderResult)
    expect(delivery.reload).to have_attributes(status: "failed", provider_id: nil, provider_outcome_unknown: true,
      attempts: 1)
  end

  it "blocks unknown acceptance beyond the provider replay window" do
    delivery.update!(status: :failed, attempts: 1, provider_attempted_at: 24.hours.ago,
      provider_outcome_unknown: true)
    expect(delivery).not_to be_retryable
    expect { described_class.new.perform(delivery.id) }.to raise_error(described_class::ReplayExpired)
    expect(Resend::Emails).not_to have_received(:send)
  end

  it "blocks legacy attempted rows whose acceptance may have been lost" do
    delivery.update!(status: :failed, attempts: 1, created_at: 2.days.ago)
    expect { described_class.new.perform(delivery.id) }.to raise_error(described_class::ReplayExpired)
    expect(Resend::Emails).not_to have_received(:send)
  end

  it "allows a definite rejection to retry later without inventing acceptance" do
    allow(Resend::Emails).to receive(:send).and_raise(Resend::Error::RateLimitExceededError.new("limited", 429))
    expect { described_class.new.perform(delivery.id) }.to raise_error(Resend::Error::RateLimitExceededError)
    expect(delivery.reload.provider_outcome_unknown).to be(false)
    travel 25.hours do
      allow(Resend::Emails).to receive(:send).and_return({ id: "email_contract" })
      described_class.new.perform(delivery.id)
    end
    expect(delivery.reload).to be_sent
  end

  it "does not let a later authentication rejection erase an earlier unknown outcome" do
    allow(Resend::Emails).to receive(:send).and_raise(IOError, "response lost")
    expect { described_class.new.perform(delivery.id) }.to raise_error(IOError)
    allow(Resend::Emails).to receive(:send).and_raise(Resend::Error::InvalidRequestError.new("unauthorized", 401))
    expect { described_class.new.perform(delivery.id) }.to raise_error(Resend::Error::InvalidRequestError)
    expect(delivery.reload.provider_outcome_unknown).to be(true)
    travel 25.hours do
      expect { described_class.new.perform(delivery.id) }.to raise_error(described_class::ReplayExpired)
    end
  end

  it "binds previously disabled mail to Resend so early webhooks reconcile" do
    delivery.update!(provider: "disabled", status: :failed, attempts: 5, created_at: 2.days.ago)
    allow(Resend::Emails).to receive(:send) do
      MessageProviderEventProcessor.call(provider_event_id: "early", event: {
        "type" => "email.delivered", "created_at" => Time.current.iso8601,
        "data" => { "email_id" => "email_contract" }
      })
      { id: "email_contract" }
    end
    described_class.new.perform(delivery.id)
    expect(delivery.reload).to have_attributes(provider: "resend", status: "delivered")
  end

  it "does not redispatch accepted mail after a delayed or failed webhook" do
    delivery.update!(status: :delayed, provider_id: "email_contract")
    described_class.new.perform(delivery.id)
    delivery.update!(status: :failed)
    described_class.new.perform(delivery.id)
    expect(Resend::Emails).not_to have_received(:send)
  end

  it "rejects edits to the prepared provider request and recipient" do
    described_class.new.perform(delivery.id)
    expect(delivery.reload.update(recipient: "different@example.com")).to be(false)
    delivery.reload
    expect(delivery.update(outbound_payload: delivery.outbound_payload.merge("html" => "Changed"))).to be(false)
    delivery.reload
    expect(delivery.update(idempotency_key: "new-key")).to be(false)
  end

  it "does not send a simulated prepared request when configuration later changes" do
    delivery.update!(provider: "simulated", outbound_payload: { "to" => delivery.recipient, "html" => "test" })
    expect(EmailService.send_delivery_payload(delivery)).to eq(simulated: true)
    expect(Resend::Emails).not_to have_received(:send)
  end

  it "retains production disablement without contacting Resend" do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(EmailService).to receive(:configured?).and_return(false)
    expect { described_class.new.perform(delivery.id) }.to raise_error(EmailService::ProviderDisabled)
    expect(delivery.reload.provider_attempted_at).to be_nil
    expect(Resend::Emails).not_to have_received(:send)
  end
end
