# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::Monitoring", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:organizer) { create(:user) }

  before { allow(Sentry).to receive(:capture_message).and_return(instance_double(Sentry::Event, event_id: "abc123")) }

  def with_dsn
    original = ENV["SENTRY_DSN"]
    ENV["SENTRY_DSN"] = "https://public@example.invalid/1"
    yield
  ensure
    original.nil? ? ENV.delete("SENTRY_DSN") : ENV["SENTRY_DSN"] = original
  end

  describe "GET /api/v1/admin/monitoring" do
    it "shows webhook health, the summary and the test kinds to admins" do
      get "/api/v1/admin/monitoring", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("stripe_webhooks", "summary", "sentry", "test_alert_kinds")
      expect(response.parsed_body["sentry"]).to include("configured", "sending_enabled")
      expect(response.parsed_body["test_alert_kinds"]).to include("stripe_webhooks_silent", "checkout", "sentry_connectivity")
    end

    it "is closed to everyone else" do
      get "/api/v1/admin/monitoring"
      expect(response).to have_http_status(:unauthorized)
      get "/api/v1/admin/monitoring", headers: auth_headers(organizer)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/admin/monitoring/test_alert" do
    it "sends one labelled test event that matches the real alert's tag but not its fingerprint" do
      with_dsn { post "/api/v1/admin/monitoring/test_alert", params: { kind: "stripe_webhooks_silent" }, headers: auth_headers(admin) }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("sent" => true, "sentry_event_id" => "abc123")
      expect(Sentry).to have_received(:capture_message).with("[TEST] HafaPass monitoring test alert: stripe_webhooks_silent",
        level: :error, fingerprint: ["monitoring-test-alert", "stripe_webhooks_silent"],
        tags: { monitoring_test: "true", test_alert_kind: "stripe_webhooks_silent", operational_signal: "stripe_webhooks_silent" },
        hint: { background: false }, extra: hash_including(:note)).once
      expect(AuditLog.find_by!(action: "monitoring.test_alert_sent")).to have_attributes(actor_user_id: admin.id)
    end

    it "tags area tests and the webhook error the way the real events are tagged" do
      with_dsn do
        post "/api/v1/admin/monitoring/test_alert", params: { kind: "webhook" }, headers: auth_headers(admin)
        travel_to_after_cooldown
        post "/api/v1/admin/monitoring/test_alert", params: { kind: "scanner" }, headers: auth_headers(admin)
      end
      expect(Sentry).to have_received(:capture_message).with(anything, hash_including(
        tags: hash_including(area: "webhook", integration: "stripe_webhook", operation: "webhook_processing", monitoring_test: "true")))
      expect(Sentry).to have_received(:capture_message).with(anything, hash_including(tags: hash_including(area: "scanner")))
    end

    it "fails, does not audit and frees the cooldown when Sentry queues nothing (e.g. environment not enabled)" do
      allow(Sentry).to receive(:capture_message).and_return(nil)
      with_dsn { post "/api/v1/admin/monitoring/test_alert", params: { kind: "checkout" }, headers: auth_headers(admin) }
      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body).to include("sent" => false)
      expect(response.parsed_body["error"]).to include("SENTRY_ENABLED_ENVIRONMENTS")
      expect(AuditLog.where(action: "monitoring.test_alert_sent")).to be_empty

      allow(Sentry).to receive(:capture_message).and_return(instance_double(Sentry::Event, event_id: "later"))
      with_dsn { post "/api/v1/admin/monitoring/test_alert", params: { kind: "checkout" }, headers: auth_headers(admin) }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("sent" => true, "accepted" => true)
      expect(response.parsed_body["message"]).to start_with("Sentry accepted the test alert")
      expect(AuditLog.find_by!(action: "monitoring.test_alert_sent").metadata).to include("kind" => "checkout", "sentry_event_id" => "later")
    end

    it "does not change the app's real alert state" do
      with_dsn { post "/api/v1/admin/monitoring/test_alert", params: { kind: "stripe_webhooks_silent" }, headers: auth_headers(admin) }
      expect(RuntimeAlertState.where(signal: Operations::StripeWebhookHealth::SIGNALS)).to be_empty
    end

    it "is admin only" do
      with_dsn do
        post "/api/v1/admin/monitoring/test_alert", params: { kind: "checkout" }
        expect(response).to have_http_status(:unauthorized)
        post "/api/v1/admin/monitoring/test_alert", params: { kind: "checkout" }, headers: auth_headers(organizer)
        expect(response).to have_http_status(:forbidden)
      end
      expect(Sentry).not_to have_received(:capture_message)
    end

    it "rejects unknown kinds and refuses when Sentry isn't configured" do
      with_dsn do
        post "/api/v1/admin/monitoring/test_alert", params: { kind: "drop_database" }, headers: auth_headers(admin)
        expect(response).to have_http_status(:unprocessable_entity)
      end
      ENV.delete("SENTRY_DSN")
      post "/api/v1/admin/monitoring/test_alert", params: { kind: "checkout" }, headers: auth_headers(admin)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("SENTRY_DSN")
      expect(Sentry).not_to have_received(:capture_message)
    end

    it "limits repeat sends to one per 30 seconds" do
      with_dsn do
        post "/api/v1/admin/monitoring/test_alert", params: { kind: "checkout" }, headers: auth_headers(admin)
        post "/api/v1/admin/monitoring/test_alert", params: { kind: "checkout" }, headers: auth_headers(admin)
      end
      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"]).to eq("30")
      expect(Sentry).to have_received(:capture_message).once
    end
  end

  def travel_to_after_cooldown
    RuntimeAlertState.where(signal: described_class_cooldown).update_all(last_alerted_at: 1.minute.ago)
  end

  def described_class_cooldown = MonitoringTestAlert::COOLDOWN_SIGNAL
end
