# frozen_string_literal: true

require "rails_helper"

RSpec.describe PaymentModeReadiness do
  let(:env) do
    {
      "STRIPE_LIVE_SECRET_KEY" => "rk_live_fixture", "STRIPE_LIVE_PUBLISHABLE_KEY" => "pk_live_fixture",
      "STRIPE_LIVE_PLATFORM_ACCOUNT_ID" => "acct_live", "STRIPE_LIVE_WEBHOOK_SECRET" => "whsec_live",
      "STRIPE_TEST_SECRET_KEY" => nil, "STRIPE_TEST_PUBLISHABLE_KEY" => nil,
      "STRIPE_SECRET_KEY" => "sk_test_legacy", "STRIPE_PUBLISHABLE_KEY" => "pk_test_legacy",
      "STRIPE_TEST_PLATFORM_ACCOUNT_ID" => "acct_test", "STRIPE_WEBHOOK_SECRET" => "whsec_test",
      "PROVIDER_CONFIGURATION_REVISION" => "rev-1"
    }
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    env.each { |key, value| allow(ENV).to receive(:[]).with(key).and_return(value) }
  end

  it "lists live requirements and needs the stripe_live approval" do
    allow(PlatformCapabilities).to receive(:enabled?).with("stripe_live").and_return(false)
    result = described_class.call("live")

    expect(result[:ready]).to be(false)
    expect(result[:checks].pluck(:key)).to eq(%w[production_environment live_secret_key live_publishable_key
      live_platform_account_id live_webhook_secret provider_configuration_revision stripe_live_approved])
    expect(result[:checks].reject { |check| check[:met] }.pluck(:key)).to eq(["stripe_live_approved"])
    expect(result[:checks].last[:help]).to include("One admin can do both")

    allow(PlatformCapabilities).to receive(:enabled?).with("stripe_live").and_return(true)
    expect(described_class.ready?("live")).to be(true)
  end

  it "never readies live payments on staging, even with every credential and approval" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("staging"))
    allow(PlatformCapabilities).to receive(:enabled?).with("stripe_live").and_return(true)

    check = described_class.call("live")[:checks].find { |item| item[:key] == "production_environment" }
    expect(check).to include(met: false)
    expect(check[:help]).to include("RAILS_ENV to production")
  end

  it "never readies live payments on a development machine either" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("development"))

    check = described_class.call("live")[:checks].find { |item| item[:key] == "production_environment" }
    expect(check).to include(met: false)
  end

  it "flags a live key in the live slot that is really a test key, without echoing it" do
    allow(ENV).to receive(:[]).with("STRIPE_LIVE_SECRET_KEY").and_return("sk_test_wrong_slot")
    result = described_class.call("live")

    expect(result[:checks].find { |check| check[:key] == "live_secret_key" }).to include(met: false)
    expect(result.to_json).not_to include("sk_test_wrong_slot")
  end

  it "accepts the legacy unprefixed pair for test mode only" do
    expect(described_class.ready?("test")).to be(true)
    expect(StripeCredentials.secret_key("test")).to eq("sk_test_legacy")

    allow(ENV).to receive(:[]).with("STRIPE_LIVE_SECRET_KEY").and_return(nil)
    expect(StripeCredentials.secret_key("live")).to be_nil
  end

  it "requires the staging Stripe rehearsal for test payments on staging" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("staging"))
    allow(ProviderRehearsal).to receive(:stripe_enabled?).and_return(false)

    expect(described_class.call("test")[:checks].first).to include(key: "staging_provider_rehearsal", met: false)
  end
end
