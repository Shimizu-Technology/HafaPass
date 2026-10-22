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

  def signed_headers(body)
    signature = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret_bytes,
      "#{event_id}.#{timestamp}.#{body}"))
    {
      "CONTENT_TYPE" => "application/json", "svix-id" => event_id,
      "svix-timestamp" => timestamp, "svix-signature" => "v1,#{signature}"
    }
  end

  [nil, "", " \t\n", 123, true, false, [], ["email_provider_123"], { "id" => "email_provider_123" }, :missing].each do |message_id|
    it "rejects signed email_id #{message_id.inspect} without changing delivery or receipt state", :aggregate_failures do
      unsent = create(:message_delivery, provider: "resend", provider_id: nil)
      sent = create(:message_delivery, provider: "resend", provider_id: "email_provider_123", status: :sent)
      before_deliveries = [unsent, sent].map(&:attributes)
      event = JSON.parse(payload)
      if message_id == :missing
        event["data"].delete("email_id")
      else
        event["data"]["email_id"] = message_id
      end
      body = event.to_json

      post "/webhooks/resend", params: body, headers: signed_headers(body)

      expect(response).to have_http_status(:bad_request)
      expect(MessageProviderEvent.count).to eq(0)
      expect([unsent.reload, sent.reload].map(&:attributes)).to eq(before_deliveries)
    end
  end

  it "applies a signed exact-ID event once while leaving an unsent delivery unchanged" do
    unsent = create(:message_delivery, provider: "resend", provider_id: nil)
    sent = create(:message_delivery, provider: "resend", provider_id: "email_provider_123", status: :sent)
    unsent_before = unsent.attributes

    post "/webhooks/resend", params: payload, headers: signed_headers(payload)
    expect(response).to have_http_status(:ok)
    receipt = MessageProviderEvent.find_by!(provider_event_id: event_id)
    receipt_before = receipt.attributes
    sent_after_first = sent.reload.attributes

    post "/webhooks/resend", params: payload, headers: signed_headers(payload)

    expect(response).to have_http_status(:ok)
    expect(MessageProviderEvent.count).to eq(1)
    expect(receipt.reload.attributes).to eq(receipt_before)
    expect(receipt).to have_attributes(message_delivery_id: sent.id, provider_message_id: sent.provider_id)
    expect(receipt.processed_at).to be_present
    expect(sent.reload).to be_delivered
    expect(sent.attributes).to eq(sent_after_first)
    expect(unsent.reload.attributes).to eq(unsent_before)
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
