# frozen_string_literal: true

require "spec_helper"
require "resend"

RSpec.describe "Resend SDK HTTP response compatibility" do
  let(:payload) { { from: "sender@example.invalid", to: "recipient@example.invalid", subject: "SDK rehearsal", html: "Synthetic" } }
  let(:http) { instance_double(Net::HTTP) }

  before do
    allow(Resend).to receive(:api_key).and_return("re_synthetic_sdk_key")
    allow(HTTParty::ConnectionAdapter).to receive(:call).and_return(http)
  end

  def respond_with(status, body)
    response = Net::HTTPResponse::CODE_TO_OBJ.fetch(status.to_s).new("1.1", status.to_s, "Fixture")
    response["content-type"] = "application/json"
    response.body = body
    response.instance_variable_set(:@read, true)
    allow(http).to receive(:request).and_return(response)
  end

  it "parses actual SDK acceptance and sends the original idempotency header" do
    respond_with(200, '{"id":"sdk_accepted_message"}')
    result = Resend::Emails.send(payload, options: { idempotency_key: "sdk-original-operation" })
    expect(result[:id]).to eq("sdk_accepted_message")
    expect(http).to have_received(:request) do |request|
      expect(request).to be_a(Net::HTTP::Post)
      expect(request["Idempotency-Key"]).to eq("sdk-original-operation")
      expect(JSON.parse(request.body)).to eq(payload.transform_keys(&:to_s))
    end
  end

  it "parses provider rejection into the SDK error rather than a JSON keyword error" do
    respond_with(429, '{"statusCode":429,"message":"Fixture rate limit","name":"rate_limit_exceeded"}')
    expect { Resend::Emails.send(payload, options: { idempotency_key: "sdk-rejected-operation" }) }
      .to raise_error(Resend::Error::RateLimitExceededError, /Fixture rate limit/)
  end

  it "reports malformed acceptance as unknown SDK output" do
    respond_with(200, 'not-json')
    expect { Resend::Emails.send(payload, options: { idempotency_key: "sdk-unknown-operation" }) }
      .to raise_error(Resend::Error::InternalServerError, /unexpected response/)
  end
end
