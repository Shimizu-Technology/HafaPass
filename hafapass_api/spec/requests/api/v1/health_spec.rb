require "rails_helper"

RSpec.describe "Health endpoints", type: :request do
  describe "GET /api/v1/health" do
    it "returns a lightweight unauthenticated liveness response" do
      get "/api/v1/health"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("status" => "ok")
    end

    it "identifies the running release without querying database or queue readiness" do
      allow(ApplicationRevision).to receive(:current).and_return("B" * 40)
      expect(SystemReadiness).not_to receive(:call)
      get "/api/v1/health"
      expect(response.parsed_body["revision"]).to eq("b" * 40)
    end

    it "does not expose an invalid revision environment value" do
      allow(ApplicationRevision).to receive(:current).and_return("invalid-private-configuration")
      get "/api/v1/health"
      expect(response.parsed_body["revision"]).to be_nil
      expect(response.body).not_to include("invalid-private-configuration")
    end
  end

  describe "GET /api/v1/readiness" do
    let(:token) { "readiness-#{SecureRandom.hex(16)}" }

    def readiness(token: nil, configured: self.token)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("READINESS_TOKEN").and_return(configured)
      get "/api/v1/readiness", headers: token ? { "X-Readiness-Token" => token } : {}
    end

    it "gives the public only the verdict and timestamp" do
      readiness

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.keys).to contain_exactly("status", "timestamp")
      expect(response.parsed_body).to include("status" => "ready")
    end

    it "keeps detail private without a matching token, including when no token is configured" do
      readiness(token: "wrong-#{token}")
      expect(response.parsed_body.keys).to contain_exactly("status", "timestamp")
      readiness(token: token, configured: nil)
      expect(response.parsed_body.keys).to contain_exactly("status", "timestamp")
      readiness(token: "", configured: "")
      expect(response.parsed_body.keys).to contain_exactly("status", "timestamp")
    end

    it "returns dependency checks to the token holder without exposing configuration values" do
      readiness(token: token)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body).to include("status" => "ready")
      expect(body.dig("checks", "database")).to include("ready" => true, "status" => "connected",
        "statement_timeout" => a_kind_of(String), "idle_in_transaction_session_timeout" => a_kind_of(String),
        "server_major_version" => a_kind_of(Integer))
      expect(body.dig("checks", "job_queue")).to include("ready" => true, "status" => "test")
      expect(body.dig("checks", "providers")).to include(
        "clerk", "email", "error_monitoring", "object_storage", "stripe_test", "stripe_live"
      )
      expect(body.dig("request_ip_source", "source")).to be_present
      expect(response.body).not_to include("secret", "sk_test_", "pk_test_", token)
    end

    it "reports the database ready even when its settings can't be read" do
      allow_any_instance_of(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter).to receive(:database_version).and_raise(StandardError)
      readiness(token: token)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("checks", "database")).to eq("ready" => true, "status" => "connected")
    end

    it "returns service unavailable to everyone when a required dependency is unavailable" do
      allow(SystemReadiness).to receive(:call).and_return(
        status: "not_ready",
        timestamp: Time.current.iso8601,
        checks: { database: { ready: false, status: "unavailable" } }
      )

      readiness
      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body.keys).to contain_exactly("status", "timestamp")
      expect(response.parsed_body).to include("status" => "not_ready")

      readiness(token: token)
      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body.dig("checks", "database")).to include("status" => "unavailable")
    end
  end
end
