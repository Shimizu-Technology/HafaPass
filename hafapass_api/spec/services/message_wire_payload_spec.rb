require "rails_helper"

RSpec.describe MessageWirePayload do
  let(:payload) do
    { "from" => "sender@example.invalid", "to" => "fixture@example.invalid", "subject" => "Håfa <fixture>",
      "html" => "<p>Frozen & fixture \u2028</p>", "reply_to" => "reply@example.invalid",
      "tags" => [{ "name" => "category", "value" => "communication_campaign" }] }
  end
  let(:body) { JSON.generate(payload) }
  let(:digest) { Digest::SHA256.hexdigest(body) }
  let(:delivery) do
    create(:message_delivery, recipient: payload.fetch("to"), template: "communication_campaign",
      provider: "resend", status: :failed, attempts: 4, provider_outcome_unknown: true,
      provider_attempted_at: 1.hour.ago, outbound_payload: payload,
      payload_digest: Digest::SHA256.hexdigest(JSON.generate(payload.sort.to_h)),
      transport_context_digest: EmailService.transport_context_digest)
  end

  before do
    allow(Resend).to receive(:api_key).and_return("synthetic-original-key")
    allow(EmailService).to receive(:configured?).and_return(true)
    allow(Resend::Emails).to receive(:send).and_return({ id: "synthetic-email" })
  end

  def hydrate(**options)
    described_class.hydrate_legacy!(delivery, profile: described_class::LEGACY_PROFILE,
      verified_wire_body: body, verified_wire_digest: digest, **options)
  end

  it "fails closed before networking when an attempted legacy delivery has no verified wire body" do
    original = delivery.attributes.slice("attempts", "outbound_payload", "idempotency_key", "transport_context_digest",
      "provider_attempted_at", "provider_outcome_unknown")
    expect { MessageDeliveryJob.new.perform(delivery.id) }.to raise_error(described_class::Unavailable)
    expect(Resend::Emails).not_to have_received(:send)
    expect(delivery.reload.attributes.slice(*original.keys)).to eq(original)
  end

  it "never renders new HTML or access links when an attempted legacy payload is missing" do
    delivery.update_columns(outbound_payload: {})
    allow(EmailService).to receive(:prepare_delivery_payload)
    expect { MessageDeliveryJob.new.perform(delivery.id) }.to raise_error(described_class::Unavailable, /before rendering/)
    expect(EmailService).not_to have_received(:prepare_delivery_payload)
    expect(Resend::Emails).not_to have_received(:send)
    expect(delivery.reload).to have_attributes(attempts: 4, provider_outcome_unknown: true, outbound_wire_body: nil)
  end

  it "hydrates independently verified legacy bytes without changing the unknown request identity" do
    original = delivery.attributes.except("outbound_wire_body", "wire_body_digest", "updated_at")
    hydrate(verified_wire_body: body.b)
    expect(delivery.reload.attributes.except("outbound_wire_body", "wire_body_digest", "updated_at")).to eq(original)
    expect(delivery).to have_attributes(outbound_wire_body: body, wire_body_digest: digest, provider_id: nil,
      provider_outcome_unknown: true)
    MessageDeliveryJob.new.perform(delivery.id)
    expect(delivery.reload).to have_attributes(provider_id: "synthetic-email", provider_outcome_unknown: false, attempts: 5)
    expect(Resend::Emails).to have_received(:send) do |params, options:|
      expect(params.to_json.b).to eq(body.b)
      expect(options).to eq(idempotency_key: delivery.idempotency_key)
    end
  end

  it "rejects an unverified digest" do
    expect { hydrate(verified_wire_digest: "0" * 64) }.to raise_error(described_class::Unavailable)
    expect(delivery.reload.outbound_wire_body).to be_nil
  end

  it "rejects a different schema or encoder even when its supplied digest matches" do
    different = ActiveSupport::JSON.encode(payload)
    expect(different).not_to eq(body)
    expect { hydrate(verified_wire_body: different, verified_wire_digest: Digest::SHA256.hexdigest(different)) }
      .to raise_error(described_class::Unavailable, /documented original schema/)
    expect(delivery.reload.outbound_wire_body).to be_nil
  end

  it "rejects fields outside the known original schema" do
    payload["attachments"] = []
    expect { hydrate }.to raise_error(described_class::Unavailable, /outside the documented/)
    expect(delivery.reload.outbound_wire_body).to be_nil
  end

  it "rejects an unsupported legacy source profile" do
    expect { hydrate(profile: "unknown-release") }.to raise_error(described_class::Unavailable)
    expect(delivery.reload.outbound_wire_body).to be_nil
  end

  it "rejects hydration while an in-flight lease owns the send" do
    delivery.update!(send_lease_token: "live-worker", send_lease_expires_at: 1.minute.from_now)
    expect { hydrate }.to raise_error(described_class::Unavailable, /inactive request/)
    expect(delivery.reload.outbound_wire_body).to be_nil
  end

  it "rejects hydration after the replay fence" do
    delivery.update!(provider_attempted_at: 24.hours.ago)
    expect { hydrate }.to raise_error(described_class::Unavailable, /replay window/)
    expect(delivery.reload.provider_outcome_unknown).to be(true)
  end

  it "does not use unknown-outcome recovery to retry an old definite rejection" do
    delivery.update!(provider_attempted_at: 25.hours.ago, provider_outcome_unknown: false)
    expect { hydrate }.to raise_error(described_class::Unavailable)
    expect(delivery.reload.outbound_wire_body).to be_nil
  end

  it "rejects changed provider context before hydration" do
    delivery
    allow(Resend).to receive(:api_key).and_return("synthetic-different-account-key")
    expect { hydrate }.to raise_error(EmailService::TransportContextChanged)
    expect(delivery.reload.outbound_wire_body).to be_nil
  end

  it "keeps prepared wire bytes immutable even for equivalent JSON" do
    hydrate
    changed = body + " "
    expect { delivery.update!(outbound_wire_body: changed, wire_body_digest: Digest::SHA256.hexdigest(changed)) }
      .to raise_error(ActiveRecord::RecordInvalid, /cannot change/)
    expect(delivery.reload.outbound_wire_body).to eq(body)
  end

  it "has a database constraint against mismatched wire bytes and digest" do
    hydrate
    expect { delivery.update_columns(wire_body_digest: "0" * 64) }
      .to raise_error(ActiveRecord::StatementInvalid, /message_deliveries_wire_digest_matches/)
  end

  it "guards a direct prepared send against wire bytes that no longer represent the frozen payload" do
    hydrate
    delivery.update!(send_lease_token: "fixture-worker", send_lease_expires_at: 1.minute.from_now)
    different = JSON.generate(payload.merge("html" => "tampered fixture"))
    delivery.update_columns(outbound_wire_body: different, wire_body_digest: Digest::SHA256.hexdigest(different))
    expect { EmailService.send_delivery_payload(delivery.reload) }.to raise_error(described_class::Unavailable)
    expect(Resend::Emails).not_to have_received(:send)
    expect(delivery.reload.provider_outcome_unknown).to be(true)
  end

  it "blocks a direct legacy send outside the canonical attempt lifecycle" do
    hydrate
    delivery.update!(provider_attempted_at: 24.hours.ago)
    expect { EmailService.send_delivery_payload(delivery.reload) }
      .to raise_error(described_class::Unavailable, /durable active send attempt/)
    expect(Resend::Emails).not_to have_received(:send)
    expect(delivery.reload.provider_outcome_unknown).to be(true)
  end

  it "requires the unknown attempt and lease to be committed before a direct prepared send" do
    hydrate
    delivery.assign_attributes(send_lease_token: "fixture-worker", send_lease_expires_at: 1.minute.from_now)
    expect { EmailService.send_delivery_payload(delivery) }
      .to raise_error(described_class::Unavailable, /durable active send attempt/)
    expect(Resend::Emails).not_to have_received(:send)
  end
end
