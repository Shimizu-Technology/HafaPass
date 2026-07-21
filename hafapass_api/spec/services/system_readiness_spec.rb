require "rails_helper"

RSpec.describe SystemReadiness do
  describe ".call" do
    it "reports the test queue adapter as ready without requiring Redis" do
      result = described_class.call

      expect(result[:status]).to eq("ready")
      expect(result.dig(:checks, :job_queue)).to include(
        ready: true,
        status: "test",
        adapter: "test"
      )
      expect(result.dig(:checks, :worker)).to include(
        ready: true,
        status: "not_required",
        processes: 0
      )
      expect(result.dig(:checks, :commerce_clock)).to include(
        ready: true,
        status: "not_required",
        lease_ttl_seconds: 0
      )
    end

    it "reports only boolean provider configuration state" do
      result = described_class.call
      providers = result.dig(:checks, :providers)

      expect(providers.keys).to contain_exactly(
        :clerk, :email, :email_webhook, :error_monitoring, :object_storage, :stripe_test, :stripe_live
      )
      expect(providers.values).to all(be(true).or(be(false)))
    end

    it "exposes persisted operational failure signals" do
      result = described_class.call

      expect(result.dig(:checks, :operations)).to include(
        ready: true,
        status: "observable",
        failed_messages_last_hour: 0,
        stale_message_events: 0,
        failed_payment_webhooks: 0,
        open_reconciliation_exceptions: 0,
        unknown_card_present_results: 0
      )
    end

    it "exposes provider and policy enablement without configuration values" do
      result = described_class.call
      controls = result.dig(:checks, :provider_policy_controls)

      expect(controls).to include(ready: false, status: "approval_required")
      expect(controls.dig(:capabilities, "policy_register")).to include(
        configured: true, approved: false, enabled: false, status: "disabled_pending_approval"
      )
      expect(controls.to_json).not_to include("RESEND_API_KEY", "STRIPE_LIVE_SECRET_KEY")
    end

    context "with the production Sidekiq adapter" do
      around do |example|
        original_redis_url = ENV["REDIS_URL"]
        ENV["REDIS_URL"] = "redis://127.0.0.1:6379/15"
        example.run
      ensure
        ENV["REDIS_URL"] = original_redis_url
      end

      before do
        require "sidekiq/api"
        allow(Rails.env).to receive(:production?).and_return(true)
        allow(ActiveJob::Base).to receive(:queue_adapter_name).and_return("sidekiq")
        allow(Sidekiq).to receive(:redis).and_yield(instance_double(RedisClient, call: "PONG"))
        allow(ProductionConfiguration).to receive(:call).and_return(
          ready: true, status: "configured", checks: {}
        )
        allow(PlatformCapabilities).to receive(:readiness).and_return(
          ready: true, status: "approved", capabilities: {}
        )
        allow(Operations::CommerceClockLease).to receive(:status).and_return(
          ready: true, status: "active", lease_ttl_seconds: 60
        )
      end

      it "is not ready when no worker process is registered" do
        allow(Sidekiq::ProcessSet).to receive(:new).and_return(instance_double(Sidekiq::ProcessSet, size: 0))

        result = described_class.call

        expect(result[:status]).to eq("not_ready")
        expect(result.dig(:checks, :worker)).to include(
          ready: false,
          status: "no_active_process",
          processes: 0
        )
      end

      it "is ready when Redis and a worker process are available" do
        allow(Sidekiq::ProcessSet).to receive(:new).and_return(instance_double(Sidekiq::ProcessSet, size: 1))

        result = described_class.call

        expect(result[:status]).to eq("ready")
        expect(result.dig(:checks, :worker)).to include(
          ready: true,
          status: "active",
          processes: 1
        )
      end

      it "is not ready when the singleton commerce clock heartbeat is missing" do
        allow(Sidekiq::ProcessSet).to receive(:new).and_return(instance_double(Sidekiq::ProcessSet, size: 1))
        allow(Operations::CommerceClockLease).to receive(:status).and_return(
          ready: false, status: "missing", lease_ttl_seconds: 0
        )

        result = described_class.call

        expect(result[:status]).to eq("not_ready")
        expect(result.dig(:checks, :commerce_clock)).to include(ready: false, status: "missing")
      end

      it "checks Redis through Sidekiq's shared connection pool" do
        connection = instance_double(RedisClient)
        allow(connection).to receive(:call).with("PING").and_return("PONG")
        allow(Sidekiq).to receive(:redis).and_yield(connection)
        allow(Sidekiq::ProcessSet).to receive(:new).and_return(instance_double(Sidekiq::ProcessSet, size: 1))

        described_class.call

        expect(Sidekiq).to have_received(:redis).at_least(:once)
        expect(connection).to have_received(:call).with("PING")
      end

      it "logs dependency failures without reporting each probe to Sentry or exposing the exception" do
        connection = instance_double(RedisClient)
        allow(connection).to receive(:call).and_raise(RedisClient::CannotConnectError, "connection refused")
        allow(Sidekiq).to receive(:redis).and_yield(connection)
        allow(Sidekiq::ProcessSet).to receive(:new).and_return(instance_double(Sidekiq::ProcessSet, size: 1))
        allow(Rails.logger).to receive(:error)
        allow(Sentry).to receive(:capture_exception)

        result = described_class.call

        expect(result[:status]).to eq("not_ready")
        expect(result.dig(:checks, :job_queue)).to eq(ready: false, status: "unavailable", adapter: "sidekiq")
        expect(result.dig(:checks, :job_queue)).not_to have_key(:error)
        expect(result.to_json).not_to include("RedisClient", "connection refused")
        expect(Rails.logger).to have_received(:error).with(include("readiness_check_failed", "RedisClient"))
        expect(Sentry).not_to have_received(:capture_exception)
      end
    end
  end
end
