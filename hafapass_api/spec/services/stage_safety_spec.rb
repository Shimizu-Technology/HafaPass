require "rails_helper"

RSpec.describe StageSafety do
  let(:settings) { SiteSetting.instance }
  let(:stage_env) do
    {
      "DATABASE_URL" => "postgresql://localhost/hafapass_staging",
      "STAGING_DATABASE_URL" => "postgresql://localhost/hafapass_staging",
      "REDIS_URL" => "redis://localhost:6379/12",
      "STAGING_REDIS_URL" => "redis://localhost:6379/12",
      "CLERK_PUBLISHABLE_KEY" => "pk_test_#{Base64.strict_encode64('fixture.clerk.accounts.dev$')}",
      "CLERK_SECRET_KEY" => "sk_test_fixture",
      "CLERK_ISSUER" => "https://fixture.clerk.accounts.dev",
      "CLERK_JWKS_URL" => nil,
      "FRONTEND_URL" => "https://staging.hafapass.example",
      "PUBLIC_WEB_URL" => "https://staging.hafapass.example",
      "PUBLIC_API_URL" => "https://api-staging.hafapass.example",
      "SECRET_KEY_BASE" => SecureRandom.hex(64),
      "ADMISSION_MANIFEST_PRIVATE_KEY_PEM" => OpenSSL::PKey::RSA.generate(2048).to_pem,
      "ALLOWED_ORIGINS" => "https://staging.hafapass.example",
      "CLERK_AUTHORIZED_PARTIES" => nil,
      "ENABLE_FIRST_USER_ADMIN_BOOTSTRAP" => "false",
      "HAFAPASS_LAUNCH_SCOPE" => nil,
      "STRIPE_LIVE_SECRET_KEY" => nil,
      "STRIPE_LIVE_PUBLISHABLE_KEY" => nil,
      "STRIPE_SECRET_KEY" => nil,
      "STRIPE_TEST_SECRET_KEY" => nil,
      "STRIPE_PUBLISHABLE_KEY" => nil,
      "STRIPE_TEST_PUBLISHABLE_KEY" => nil
    }
  end

  it "rejects missing or short application secrets without disclosing them" do
    [nil, "", " " * 65, "a" * 64].each do |value|
      value.nil? ? ENV.delete("SECRET_KEY_BASE") : ENV["SECRET_KEY_BASE"] = value
      expect(described_class.call.dig(:checks, :application_secret)).to be(false)
      expect { described_class.validate! }.to raise_error(
        described_class::ConfigurationError, "Staging configuration failed: application_secret"
      )
    end
    ENV["SECRET_KEY_BASE"] = SecureRandom.hex(33)
    expect(described_class.call.dig(:checks, :application_secret)).to be(true)
  end

  it "requires a persistent RSA private admission key with at least 2048 bits" do
    valid_key = OpenSSL::PKey::RSA.new(ENV.fetch("ADMISSION_MANIFEST_PRIVATE_KEY_PEM"))
    invalid_keys = [nil, "not a private key", valid_key.public_key.to_pem,
      OpenSSL::PKey::RSA.generate(1024).to_pem, OpenSSL::PKey::EC.generate("prime256v1").to_pem]
    invalid_keys.each do |pem|
      pem.nil? ? ENV.delete("ADMISSION_MANIFEST_PRIVATE_KEY_PEM") : ENV["ADMISSION_MANIFEST_PRIVATE_KEY_PEM"] = pem
      expect(described_class.call.dig(:checks, :admission_signing)).to be(false)
      expect { described_class.validate! }.to raise_error(
        described_class::ConfigurationError, "Staging configuration failed: admission_signing"
      )
      expect(described_class.call.to_json).not_to include("BEGIN", "not a private key")
    end
    ENV["ADMISSION_MANIFEST_PRIVATE_KEY_PEM"] = valid_key.to_pem
    expect(described_class.call.dig(:checks, :admission_signing)).to be(true)
  end

  around do |example|
    original = stage_env.keys.index_with { |key| ENV[key] }
    stage_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    example.run
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  it "accepts a separate simulation runtime without requiring optional S3 or production provider credentials" do
    expect(described_class.call).to include(ready: true, status: "simulation_only")
    expect { described_class.validate! }.not_to raise_error
    expect(described_class.call.to_json).not_to include("sk_test_", "postgresql://", "clerk.accounts.dev")
  end

  it "rejects missing explicit data isolation, live identity, unsafe origins, bootstrap, live credentials and expanded scope at boot" do
    {
      "STAGING_DATABASE_URL" => nil,
      "STAGING_REDIS_URL" => nil,
      "DATABASE_URL" => "postgresql://localhost/hafapass_production",
      "REDIS_URL" => "redis://localhost:6379/0",
      "CLERK_SECRET_KEY" => "sk_live_fixture",
      "CLERK_PUBLISHABLE_KEY" => "pk_live_fixture",
      "CLERK_ISSUER" => "https://untrusted.example",
      "CLERK_JWKS_URL" => "https://untrusted.example/.well-known/jwks.json",
      "ALLOWED_ORIGINS" => "http://localhost:5173",
      "CLERK_AUTHORIZED_PARTIES" => "https://untrusted.example",
      "FRONTEND_URL" => "http://staging.hafapass.example",
      "PUBLIC_API_URL" => nil,
      "ENABLE_FIRST_USER_ADMIN_BOOTSTRAP" => "true",
      "STRIPE_LIVE_SECRET_KEY" => "sk_live_fixture",
      "STRIPE_TEST_SECRET_KEY" => "sk_live_fixture",
      "HAFAPASS_LAUNCH_SCOPE" => "full"
    }.each do |key, invalid_value|
      original = ENV[key]
      invalid_value.nil? ? ENV.delete(key) : ENV[key] = invalid_value
      expect { described_class.validate! }.to raise_error(described_class::ConfigurationError), key
      original.nil? ? ENV.delete(key) : ENV[key] = original
    end
  end

  context "when staging is running" do
    before do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("staging"))
      allow(SiteSetting).to receive(:instance).and_return(settings)
      allow(ActiveJob::Base).to receive(:queue_adapter_name).and_return("sidekiq")
    end

    it "defaults to general admission and fails readiness after an unsafe persisted payment mode change" do
      allow(settings).to receive(:simulate_mode?).and_return(false)
      allow(SystemReadiness).to receive_messages(
        database_check: { ready: true }, job_queue_check: { ready: true }, worker_check: { ready: true }
      )
      expect(LaunchCapabilities.scope).to eq("general_admission")
      expect(SystemReadiness.call[:status]).to eq("not_ready")
      expect(described_class.call(runtime: true).dig(:checks, :simulated_payments)).to be(false)
    end

    it "fails readiness if persistent application or admission secrets disappear after boot" do
      allow(SystemReadiness).to receive_messages(
        database_check: { ready: true }, job_queue_check: { ready: true }, worker_check: { ready: true }
      )
      %w[SECRET_KEY_BASE ADMISSION_MANIFEST_PRIVATE_KEY_PEM].each do |name|
        original = ENV.delete(name)
        result = SystemReadiness.call
        expect(result[:status]).to eq("not_ready")
        expect(result.dig(:checks, :configuration, :ready)).to be(false)
        ENV[name] = original
      end
    end

    it "requires a durable queue and a registered worker" do
      allow(ActiveJob::Base).to receive(:queue_adapter_name).and_return("async")
      expect(described_class.call(runtime: true).dig(:checks, :durable_jobs)).to be(false)
      allow(ActiveJob::Base).to receive(:queue_adapter_name).and_return("sidekiq")
      require "sidekiq/api"
      allow(Sidekiq::ProcessSet).to receive(:new).and_return(instance_double(Sidekiq::ProcessSet, size: 0))
      expect(SystemReadiness.send(:worker_check)).to include(ready: false)
    end

    it "reports unavailable runtime data as not ready without leaking an exception" do
      allow(SiteSetting).to receive(:instance).and_raise(ActiveRecord::ConnectionNotEstablished, "private database URL")
      result = described_class.call(runtime: true)
      expect(result).to include(ready: false)
      expect(result.dig(:checks, :simulated_payments)).to be(false)
      expect(result.to_json).not_to include("private database URL")
    end

    it "vetoes every production provider even with stale matching approvals" do
      approval = double("copied approval")
      allow(PlatformCapabilities).to receive(:active_approval).and_return(approval)
      (PlatformCapabilities.names - ["policy_register"]).each do |name|
        expect(PlatformCapabilities.configured?(name)).to be(false)
        expect(PlatformCapabilities.enabled?(name)).to be(false)
      end
      expect(EmailService.configured?).to be(false)
      expect(Resend::Emails).not_to receive(:send)
      expect(EmailService.send(:deliver, to: "tester@example.com", subject: "Test", html: "test"))
        .to include(simulated: true)
    end

    it "blocks SDK calls and payout submissions even if persisted settings say live with approval" do
      allow(settings).to receive_messages(simulate_mode?: false, live_mode?: true, can_enable_live?: true)
      expect(Stripe::PaymentIntent).not_to receive(:create)
      expect(Stripe::PaymentIntent).not_to receive(:cancel)
      expect(Stripe::Refund).not_to receive(:create)
      expect { StripeService.create_payment_intent(double("order"), idempotency_key: "stage") }
        .to raise_error(StripeService::PaymentError, /disabled in staging/)
      expect { StripeService.refund_payment("pi_external", idempotency_key: "stage") }
        .to raise_error(StripeService::PaymentError, /disabled in staging/)
      expect { StripeService.cancel_payment_intent("pi_external", idempotency_key: "stage") }
        .to raise_error(StripeService::PaymentError, /cannot cancel/)
      expect(StripeService.payment_enabled?).to be(false)
      expect(StripeService.publishable_key).to be_nil
      expect { PayoutGateway.submit(double("copied payout")) }.to raise_error(PayoutGateway::PayoutError, /disabled in staging/)
    end

    it "still supports simulated refunds and cancellation while rejecting copied real payment identifiers" do
      expect(StripeService.refund_payment("sim_pi_fixture", idempotency_key: "stage").id).to start_with("sim_re_")
      expect(StripeService.cancel_payment_intent("sim_pi_fixture", idempotency_key: "stage").status).to eq("canceled")
      expect { StripeService.refund_payment("pi_external", idempotency_key: "stage") }
        .to raise_error(StripeService::PaymentError, /real payment cannot be refunded/)
    end
  end
end
