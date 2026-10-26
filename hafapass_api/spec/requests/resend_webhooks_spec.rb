require "rails_helper"
require "base64"
require "openssl"

RSpec.describe "Resend webhooks", :webmock, type: :request do
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

  describe "signed application provenance" do
    def send_event(tags:, type: "email.delivered", id: event_id, message: "foreign-message", valid_signature: true)
      body = { "type" => type, "created_at" => 1.day.ago.iso8601,
        "data" => { "email_id" => message, "tags" => tags, "to" => ["private@example.test"], "subject" => "private subject" } }.to_json
      headers = signed_headers(body).merge("svix-id" => id)
      headers["svix-signature"] = "v1,#{Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', secret_bytes, "#{id}.#{timestamp}.#{body}"))}"
      headers["svix-signature"] = "v1,invalid" unless valid_signature
      post "/webhooks/resend", params: body, headers: headers
    end

    [{ "application" => "csg_learn" }, [{ "name" => "application", "value" => "csg_learn" }]].each do |tags|
      it "audits known foreign #{tags.class} provenance once and preserves the receipt on replay" do
        send_event(tags: tags)
        expect(response).to have_http_status(:ok)
        row = MessageProviderEvent.sole
        original = row.attributes
        expect(ExternalMessageReceipts.resolved).to include(row)
        audit = AuditLog.find_by!(action: ExternalMessageReceipts::SOURCE_ACTION)
        expect(audit).to have_attributes(source: "provider", actor_user_id: nil, auditable: row)
        expect(row.payload).to eq("provenance" => { "application" => "csg_learn" })
        send_event(tags: tags)
        expect(response).to have_http_status(:ok)
        expect(row.reload.attributes).to eq(original)
        expect(AuditLog.where(action: ExternalMessageReceipts::SOURCE_ACTION).count).to eq(1)
        expect(row.processed_at).to be_nil
        expect(MessageDelivery.count).to eq(0)
      end
    end

    [nil, {}, "csg_learn", { "application" => ["csg_learn"] }, { "application" => "unregistered_app" },
      { "application" => "hafapass" }, { "application" => " csg_learn" }, { "application" => "csg_learn", "category" => {} },
      [{ "name" => "application", "value" => "csg_learn" }, { "name" => "application", "value" => "hafapass" }],
      [{ "name" => "application", "value" => "csg_learn" }, { "name" => "application", "value" => "csg_learn" }],
      [{ "name" => "application", "value" => "csg_learn", "extra" => "unknown" }]].each do |tags|
      it "retains missing, own, unregistered or ambiguous marker #{tags.inspect} for review" do
        send_event(tags: tags)
        expect(response).to have_http_status(:ok)
        expect(ExternalMessageReceipts.resolved).to be_empty
        expect(AuditLog.where(action: ExternalMessageReceipts::ACTIONS)).not_to exist
        MessageProviderEvent.where(id: MessageProviderEvent.sole.id).update_all(received_at: 10.minutes.ago)
        expect(OperationalReview.new.signals[:stale_message_events]).to eq(1)
      end
    end

    it "requires a signature and never classifies an unsigned foreign tag" do
      send_event(tags: { "application" => "csg_learn" }, valid_signature: false)
      expect(response).to have_http_status(:bad_request)
      expect(MessageProviderEvent.count).to eq(0)
      expect(AuditLog.where(action: ExternalMessageReceipts::ACTIONS)).not_to exist
    end

    it "processes an exact saved HafaPass ID even when a foreign marker contradicts it" do
      delivery = create(:message_delivery, provider: "resend", provider_id: "foreign-message", status: :sent)
      send_event(tags: { "application" => "csg_learn" })
      expect(response).to have_http_status(:ok)
      expect(delivery.reload).to be_delivered
      expect(MessageProviderEvent.sole.message_delivery_id).to eq(delivery.id)
      expect(AuditLog.where(action: ExternalMessageReceipts::ACTIONS)).not_to exist
    end

    it "does not inherit a prior decision for new unknown or adverse events on the same message" do
      send_event(tags: { "application" => "csg_learn" })
      first = MessageProviderEvent.sole
      send_event(tags: nil, id: "new-unknown-event")
      %w[email.bounced email.failed email.complained email.suppressed email.delivery_delayed].each do |type|
        send_event(tags: { "application" => "csg_learn" }, id: type, type: type)
        expect(response).to have_http_status(:ok)
      end
      MessageProviderEvent.update_all(received_at: 10.minutes.ago)
      expect(ExternalMessageReceipts.resolved.pluck(:id)).to eq([first.id])
      expect(OperationalReview.new.signals[:stale_message_events]).to eq(6)
    end

    it "rejects event replay with a different provider identity and retains the original classification" do
      send_event(tags: { "application" => "csg_learn" })
      row = MessageProviderEvent.sole
      original = row.attributes
      send_event(tags: { "application" => "csg_learn" }, message: "different-message")
      expect(response).to have_http_status(:bad_request)
      expect(row.reload.attributes).to eq(original)
      expect(ExternalMessageReceipts.resolved.pluck(:id)).to eq([row.id])
    end

    it "does not upgrade a legacy receipt's missing provenance from replay parameters" do
      send_event(tags: nil)
      row = MessageProviderEvent.sole
      send_event(tags: { "application" => "csg_learn" })
      expect(response).to have_http_status(:ok)
      expect(row.reload.payload).to eq({})
      expect(ExternalMessageReceipts.resolved).to be_empty
    end

    it "returns a conflict for a source replay after a manually audited decision" do
      allow(AuditLogger).to receive(:record!).and_raise(AuditLogger::WriteError, "synthetic source audit failure")
      expect { send_event(tags: { "application" => "csg_learn" }) }.to raise_error(AuditLogger::WriteError)
      row = MessageProviderEvent.sole
      original = row.attributes
      allow(AuditLogger).to receive(:record!).and_call_original
      admin = create(:user, :admin)
      decision = ExternalMessageReceipts.call(actor: admin,
        receipts: [row.attributes.slice(*ExternalMessageReceipts::IDENTITY_KEYS)],
        proof_reference: "receipt-origin:request-regression").sole

      2.times do
        send_event(tags: { "application" => "csg_learn" })
        expect(response).to have_http_status(:conflict)
        expect(response.parsed_body).to eq("error" => "Receipt already has a different external decision")
      end
      expect(row.reload.attributes).to eq(original)
      expect(AuditLog.where(action: ExternalMessageReceipts::ACTIONS).pluck(:id)).to eq([decision.id])
      expect(ExternalMessageReceipts.resolved.pluck(:id)).to eq([row.id])
      expect(MessageDelivery.count).to eq(0)
    end

    it "retains errors for review and does not turn an audit failure into a successful callback" do
      send_event(tags: { "application" => "csg_learn" })
      row = MessageProviderEvent.sole
      row.update!(processing_error: "synthetic error")
      send_event(tags: { "application" => "csg_learn" })
      expect(response).to have_http_status(:ok)
      expect(ExternalMessageReceipts.resolved).to be_empty
      allow(AuditLogger).to receive(:record!).and_raise(AuditLogger::WriteError, "synthetic failure")
      expect { send_event(tags: { "application" => "csg_learn" }, id: "another-event") }.to raise_error(AuditLogger::WriteError)
      expect(ExternalMessageReceipts.resolved).to be_empty
    end
  end
end
