require "rails_helper"

RSpec.describe "Health endpoints", type: :request do
  describe "GET /api/v1/health" do
    it "returns a lightweight unauthenticated liveness response" do
      get "/api/v1/health"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("status" => "ok")
    end
  end

  describe "GET /api/v1/readiness" do
    it "returns dependency checks without exposing configuration values" do
      get "/api/v1/readiness"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body).to include("status" => "ready")
      expect(body.dig("checks", "database")).to include("ready" => true, "status" => "connected")
      expect(body.dig("checks", "job_queue")).to include("ready" => true, "status" => "test")
      expect(body.dig("checks", "providers")).to include(
        "clerk", "email", "error_monitoring", "object_storage", "stripe_test", "stripe_live"
      )
      expect(response.body).not_to include("secret", "sk_test_", "pk_test_")
    end

    it "returns service unavailable when a required dependency is unavailable" do
      allow(SystemReadiness).to receive(:call).and_return(
        status: "not_ready",
        timestamp: Time.current.iso8601,
        checks: { database: { ready: false, status: "unavailable" } }
      )

      get "/api/v1/readiness"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to include("status" => "not_ready")
    end
  end
end
