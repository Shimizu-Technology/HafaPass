# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProviderRehearsal do
  around do |example|
    keys = %w[HAFAPASS_PROVIDER_REHEARSAL PROVIDER_REHEARSAL_SERVICES PROVIDER_REHEARSAL_EMAIL_RECIPIENTS
      STRIPE_TEST_SECRET_KEY STRIPE_TEST_PUBLISHABLE_KEY STRIPE_TEST_PLATFORM_ACCOUNT_ID STRIPE_WEBHOOK_SECRET
      PROVIDER_CONFIGURATION_REVISION RESEND_API_KEY RESEND_WEBHOOK_SECRET MAILER_FROM_EMAIL]
    previous = keys.to_h { |key| [key, ENV[key]] }
    ENV.update("HAFAPASS_PROVIDER_REHEARSAL" => "true", "PROVIDER_REHEARSAL_SERVICES" => "stripe,resend",
      "PROVIDER_REHEARSAL_EMAIL_RECIPIENTS" => "owned@example.invalid",
      "STRIPE_TEST_SECRET_KEY" => "rk_test_fixture", "STRIPE_TEST_PUBLISHABLE_KEY" => "pk_test_fixture",
      "STRIPE_TEST_PLATFORM_ACCOUNT_ID" => "acct_fixture", "STRIPE_WEBHOOK_SECRET" => "whsec_fixture",
      "PROVIDER_CONFIGURATION_REVISION" => "fixture-1", "RESEND_API_KEY" => "re_fixture",
      "RESEND_WEBHOOK_SECRET" => "fixture", "MAILER_FROM_EMAIL" => "tickets@example.invalid")
    example.run
  ensure
    previous.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  before { allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("staging")) }

  it "permits only the named, configured stage transports" do
    expect(described_class.configuration_valid?).to be true
    expect(described_class.stripe_enabled?).to be true
    expect(described_class.email_enabled?).to be true
    ENV["PROVIDER_REHEARSAL_SERVICES"] = "unknown"
    expect(described_class.configuration_valid?).to be false
    expect(described_class.stripe_enabled?).to be false
  end

  it "never enables provider rehearsal in production" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    expect(described_class.enabled?).to be false
    expect(described_class.configuration_valid?).to be false
  end

  it "rejects live credentials even when placed in a test slot" do
    ENV["STRIPE_TEST_SECRET_KEY"] = "rk_live_fixture"
    expect(described_class.configuration_valid?).to be false
    expect(described_class.stripe_enabled?).to be false
  end

  it "reports test payment readiness as unavailable when its database lookup fails" do
    allow(SiteSetting).to receive(:instance).and_raise(ActiveRecord::StatementInvalid)
    expect(StageSafety.call(runtime: true)).to include(ready: false)
    expect(StageSafety.call(runtime: true)[:checks][:test_provider_payments]).to be(false)
  end

  it "requires every frozen recipient including cc and bcc to be approved" do
    expect(described_class.email_payload_allowed?({ to: "OWNED@example.invalid" })).to be true
    expect(described_class.email_payload_allowed?({ to: "owned@example.invalid", cc: "other@example.invalid" })).to be false
    expect(described_class.email_payload_allowed?({ to: "owned@example.invalid", bcc: "other@example.invalid" })).to be false
    expect(described_class.email_payload_allowed?({})).to be false
  end

  it "blocks sending if the rehearsal flag or allowlist is removed" do
    ENV["HAFAPASS_PROVIDER_REHEARSAL"] = "false"
    expect(described_class.email_payload_allowed?({ to: "owned@example.invalid" })).to be false
    ENV["HAFAPASS_PROVIDER_REHEARSAL"] = "true"
    ENV["PROVIDER_REHEARSAL_EMAIL_RECIPIENTS"] = ""
    expect(described_class.email_enabled?).to be false
  end

  it "allows scoped Stripe test creation but rejects live operation context" do
    SiteSetting.instance.update!(payment_mode: "test")
    order = create(:order, :pending)
    payment = create(:payment, order: order, provider_environment: "test", provider_platform_account_id: "acct_fixture")
    accounts = double(retrieve_current: double(id: "acct_fixture"))
    intents = double
    client = double(v1: double(accounts: accounts, payment_intents: intents))
    allow(Stripe::StripeClient).to receive(:new).and_return(client)
    expect(intents).to receive(:create).with(hash_including(amount: order.total_cents), hash_including(idempotency_key: "rehearsal"))
      .and_return(double(id: "pi_fixture", client_secret: "fixture"))
    StripeService.create_payment_intent(order, idempotency_key: "rehearsal", payment: payment)

    live = build(:payment, order: order, provider_environment: "live", provider_platform_account_id: "acct_fixture")
    expect { StripeService.cancel_payment_intent("pi_real", idempotency_key: "live", payment: live) }
      .to raise_error(StripeService::PaymentError, /only configured test-provider/)
  end

  it "rechecks every actual Resend payload before sending" do
    params = { from: "tickets@example.invalid", to: "owned@example.invalid", subject: "Test", html: "Synthetic" }
    expect(Resend::Emails).to receive(:send).with(params, options: {}).and_return({ "id" => "provider-fixture" })
    EmailService.send(:deliver_payload, params)
    expect { EmailService.send(:deliver_payload, params.merge(bcc: "other@example.invalid")) }
      .to raise_error(EmailService::ProviderDisabled, /restricted/)
  end
end
