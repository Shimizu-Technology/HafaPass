# frozen_string_literal: true

require "rails_helper"

RSpec.describe MessageDeliveryJob do
  let(:delivery) { create(:message_delivery, template: "order_recovery", provider: "resend") }
  let(:http) { instance_double(Net::HTTP) }

  before do
    allow(EmailService).to receive(:configured?).and_return(true)
    allow(Resend).to receive(:api_key).and_return("re_synthetic_sdk_key")
    allow(HTTParty::ConnectionAdapter).to receive(:call).and_return(http)
  end

  def provider_response(status, body)
    response = Net::HTTPResponse::CODE_TO_OBJ.fetch(status.to_s).new("1.1", status.to_s, "Fixture")
    response["content-type"] = "application/json"
    response.body = body
    response.instance_variable_set(:@read, true)
    response
  end

  it "records acceptance from the real SDK response parser" do
    allow(http).to receive(:request).and_return(provider_response(200, '{"id":"sdk_message"}'))

    described_class.new.perform(delivery.id)

    expect(delivery.reload).to have_attributes(status: "sent", provider_id: "sdk_message", attempts: 1,
      provider_outcome_unknown: false, send_lease_token: nil)
    expect(delivery.transport_context_digest).to eq(EmailService.transport_context_digest)
    expect(http).to have_received(:request) do |request|
      expect(request["Idempotency-Key"]).to eq(delivery.idempotency_key)
      expect(JSON.parse(request.body)).to eq(delivery.outbound_payload)
    end
  end

  it "replays the frozen request after an HTTP acknowledgement is lost" do
    requests = []
    allow(http).to receive(:request) do |request|
      requests << [JSON.parse(request.body), request["Idempotency-Key"]]
      raise IOError, "synthetic response lost after acceptance" if requests.one?

      provider_response(200, '{"id":"sdk_original_message"}')
    end
    expect { described_class.new.perform(delivery.id) }.to raise_error(IOError)
    original = delivery.reload.attributes.slice("outbound_payload", "payload_digest", "idempotency_key",
      "transport_context_digest", "provider_attempted_at")
    expect(delivery).to have_attributes(status: "failed", provider_id: nil, provider_outcome_unknown: true)
    delivery.order.update!(buyer_email: "changed@example.invalid", buyer_name: "Changed fixture")

    described_class.new.perform(delivery.id)

    expect(requests.length).to eq(2)
    expect(requests.last).to eq(requests.first)
    expect(delivery.reload.attributes.slice(*original.keys)).to eq(original)
    expect(delivery).to have_attributes(status: "sent", provider_id: "sdk_original_message", attempts: 2,
      provider_outcome_unknown: false)
  end

  it "records a first explicit SDK rate-limit rejection without inventing acceptance" do
    allow(http).to receive(:request).and_return(provider_response(429,
      '{"statusCode":429,"message":"Fixture rate limit","name":"rate_limit_exceeded"}'))

    expect { described_class.new.perform(delivery.id) }.to raise_error(Resend::Error::RateLimitExceededError)

    expect(delivery.reload).to have_attributes(status: "failed", provider_id: nil, attempts: 1,
      provider_outcome_unknown: false, send_lease_token: nil)
  end
end
