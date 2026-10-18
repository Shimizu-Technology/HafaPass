require "rails_helper"

RSpec.describe "Legacy Resend Rails wire encoder" do
  let(:payload) do
    { "from" => "sender@synthetic.invalid", "to" => "recipient@synthetic.invalid", "subject" => "Håfa <fixture>",
      "html" => "<p>Frozen & fixture \u2028\u2029</p>", "reply_to" => "reply@synthetic.invalid",
      "tags" => [{ "name" => "category", "value" => "communication_campaign" }] }
  end
  let(:historical_wire) do
    '{"from":"sender@synthetic.invalid","to":"recipient@synthetic.invalid","subject":"Håfa \u003cfixture\u003e","html":"\u003cp\u003eFrozen \u0026 fixture \u2028\u2029\u003c/p\u003e","reply_to":"reply@synthetic.invalid","tags":[{"name":"category","value":"communication_campaign"}]}'
  end

  around do |example|
    original_html = ActiveSupport.escape_html_entities_in_json
    original_js = ActiveSupport.escape_js_separators_in_json
    ActiveSupport.escape_html_entities_in_json = true
    ActiveSupport.escape_js_separators_in_json = true
    example.run
  ensure
    ActiveSupport.escape_html_entities_in_json = original_html
    ActiveSupport.escape_js_separators_in_json = original_js
  end

  it "hydrates the exact real SDK body produced with Rails' historical escaping" do
    allow(Resend).to receive(:api_key).and_return("synthetic-original-key")
    http = instance_double(Net::HTTP)
    allow(HTTParty::ConnectionAdapter).to receive(:call).and_return(http)
    response = Net::HTTPOK.new("1.1", "200", "Fixture")
    response["content-type"] = "application/json"
    response.body = '{"id":"synthetic-legacy-provider-id"}'
    response.instance_variable_set(:@read, true)
    captured = nil
    allow(http).to receive(:request) do |request|
      captured = request.body.dup
      response
    end
    Resend::Emails.send(payload, options: { idempotency_key: "synthetic-legacy-key" })
    expect(captured.b).to eq(historical_wire.b)
    delivery = create(:message_delivery, recipient: payload.fetch("to"), template: "communication_campaign",
      provider: "resend", status: :failed, attempts: 4, provider_outcome_unknown: true,
      provider_attempted_at: 1.hour.ago, outbound_payload: payload,
      payload_digest: Digest::SHA256.hexdigest(JSON.generate(payload.sort.to_h)),
      transport_context_digest: EmailService.transport_context_digest)
    original = delivery.attributes.except("outbound_wire_body", "wire_body_digest", "updated_at")
    # Future Rails JSON configuration must never change an original request.
    ActiveSupport.escape_html_entities_in_json = false
    ActiveSupport.escape_js_separators_in_json = false
    MessageWirePayload.hydrate_legacy!(delivery, profile: MessageWirePayload::LEGACY_PROFILE,
      verified_wire_body: captured, verified_wire_digest: Digest::SHA256.hexdigest(captured))
    expect(delivery.reload.outbound_wire_body.b).to eq(historical_wire.b)
    expect(delivery.attributes.except("outbound_wire_body", "wire_body_digest", "updated_at")).to eq(original)
  end
end
