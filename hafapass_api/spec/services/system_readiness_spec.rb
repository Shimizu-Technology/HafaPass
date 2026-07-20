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
    end

    it "reports only boolean provider configuration state" do
      result = described_class.call
      providers = result.dig(:checks, :providers)

      expect(providers.keys).to contain_exactly(
        :clerk, :email, :error_monitoring, :object_storage, :stripe_test, :stripe_live
      )
      expect(providers.values).to all(be(true).or(be(false)))
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
        allow(Redis).to receive(:new).and_return(instance_double(Redis, ping: "PONG"))
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
    end
  end
end
