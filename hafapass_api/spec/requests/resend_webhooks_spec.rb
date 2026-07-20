require "rails_helper"
require "base64"
require "openssl"

RSpec.describe "Resend webhooks", type: :request do
  let(:secret_bytes) { "resend-test-signing-secret" }
  let(:secret) { "whsec_#{Base64.strict_encode64(secret_bytes)}" }
  let(:event_id) { "msg_webhook_123" }
  let(:timestamp) { Time.current.to_i.to_s }
  let(:payload) do
    {
      type: "email.delivered",
      created_at: Time.current.iso8601,
      data: { email_id: "email_provider_123", to: ["buyer@example.com"], subject: "Tickets" }
    }.to_json
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("RESEND_WEBHOOK_SECRET").and_return(secret)
  end

  it "verifies the raw signed payload and deduplicates at-least-once delivery" do
    signature = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret_bytes,
      "#{event_id}.#{timestamp}.#{payload}"))
    headers = {
      "CONTENT_TYPE" => "application/json",
      "svix-id" => event_id,
      "svix-timestamp" => timestamp,
      "svix-signature" => "v1,#{signature}"
    }

    2.times { post "/webhooks/resend", params: payload, headers: headers }

    expect(response).to have_http_status(:ok)
    expect(MessageProviderEvent.where(provider_event_id: event_id).count).to eq(1)
  end

  it "rejects an invalid signature without persisting the payload" do
    post "/webhooks/resend", params: payload, headers: {
      "CONTENT_TYPE" => "application/json", "svix-id" => event_id,
      "svix-timestamp" => timestamp, "svix-signature" => "v1,invalid"
    }

    expect(response).to have_http_status(:bad_request)
    expect(MessageProviderEvent.count).to eq(0)
  end
end
