require "rails_helper"

RSpec.describe "Admin settings", type: :request do
  let(:admin) { create(:user, :admin) }

  it "does not enable live payments from credentials without current evidence approval" do
    allow(PlatformCapabilities).to receive(:configured?).with("stripe_live").and_return(true)
    allow(PlatformCapabilities).to receive(:enabled?).with("stripe_live").and_return(false)

    patch "/api/v1/admin/settings", params: { payment_mode: "live" }, headers: auth_headers(admin)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("Cannot switch to live payments yet",
      "Stripe live payments approved in Provider readiness")
    expect(SiteSetting.instance.reload.payment_mode).not_to eq("live")
    expect(AuditLog.where(action: "site_settings.payment_mode_changed")).not_to exist
  end

  describe "test and live payment switch" do
    let(:live_env) do
      {
        "STRIPE_LIVE_SECRET_KEY" => "sk_live_switch_secret", "STRIPE_LIVE_PUBLISHABLE_KEY" => "pk_live_switch",
        "STRIPE_LIVE_PLATFORM_ACCOUNT_ID" => "acct_liveplatform", "STRIPE_LIVE_WEBHOOK_SECRET" => "whsec_live_switch",
        "STRIPE_TEST_SECRET_KEY" => "sk_test_switch_secret", "STRIPE_TEST_PUBLISHABLE_KEY" => "pk_test_switch",
        "STRIPE_TEST_PLATFORM_ACCOUNT_ID" => "acct_testplatform", "STRIPE_WEBHOOK_SECRET" => "whsec_test_switch",
        "PROVIDER_CONFIGURATION_REVISION" => "rev-7"
      }
    end
    let(:headers) { auth_headers(admin) }

    before do
      allow(ENV).to receive(:[]).and_call_original
      live_env.each { |key, value| allow(ENV).to receive(:[]).with(key).and_return(value) }
      { "sk_live_switch_secret" => "acct_liveplatform", "sk_test_switch_secret" => "acct_testplatform" }.each do |key, account|
        accounts = double(retrieve_current: OpenStruct.new(id: account))
        allow(Stripe::StripeClient).to receive(:new).with(key).and_return(double(v1: double(accounts: accounts)))
      end
    end

    def approve_stripe_live_as(user)
      payload = { evidence_reference: "restricted/stripe-live/2026-10", evidence_digest: "e" * 64,
        controls: PlatformCapabilities.required_controls("stripe_live").index_with { true },
        effective_at: 1.minute.ago.iso8601, expires_at: 90.days.from_now.iso8601 }
      post "/api/v1/admin/platform_capabilities/stripe_live/reviews", params: payload, headers: auth_headers(user)
      expect(response).to have_http_status(:created), response.body
      post "/api/v1/admin/platform_capability_reviews/#{response.parsed_body.fetch('id')}/approve", headers: auth_headers(user)
      expect(response).to have_http_status(:created), response.body
    end

    it "explains every unmet live requirement without exposing credential values" do
      get "/api/v1/admin/settings", headers: headers

      readiness = response.parsed_body.fetch("payment_mode_readiness")
      expect(readiness.fetch("test")).to include("ready" => true)
      live = readiness.fetch("live")
      expect(live).to include("ready" => false)
      expect(live.fetch("checks").reject { |check| check["met"] }.pluck("key")).to eq(["stripe_live_approved"])
      expect(response.body).not_to include("sk_live_switch_secret", "whsec_live_switch", "sk_test_switch_secret")
    end

    it "lets one admin approve Stripe live, switch to live, and switch back, with an audit for each change" do
      SiteSetting.instance.update!(payment_mode: "test")
      approve_stripe_live_as(admin)

      get "/api/v1/admin/settings", headers: headers
      expect(response.parsed_body.dig("payment_mode_readiness", "live", "ready")).to be(true)

      patch "/api/v1/admin/settings", params: { payment_mode: "live" }, headers: headers
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body).to include("payment_mode" => "live")
      audit = AuditLog.where(action: "site_settings.payment_mode_changed").sole
      expect(audit).to have_attributes(actor_user: admin, before_data: { "payment_mode" => "test" },
        after_data: { "payment_mode" => "live" })
      expect(audit.metadata).to include("platform_account_id" => "acct_liveplatform", "provider_configuration_revision" => "rev-7")
      expect(AuditLog.where(action: %w[platform_capability.submitted platform_capability.approved]).pluck(:actor_user_id).uniq)
        .to eq([admin.id])

      get "/api/v1/config"
      expect(response.parsed_body).to include("payment_mode" => "live", "stripe_publishable_key" => "pk_live_switch")

      patch "/api/v1/admin/settings", params: { payment_mode: "test" }, headers: headers
      expect(response).to have_http_status(:ok), response.body
      expect(SiteSetting.instance.reload.payment_mode).to eq("test")
      expect(AuditLog.where(action: "site_settings.payment_mode_changed").order(:id).last.after_data)
        .to eq("payment_mode" => "test")
      get "/api/v1/config"
      expect(response.parsed_body).to include("stripe_publishable_key" => "pk_test_switch")
    end

    it "refuses a switch when the secret key belongs to a different Stripe account" do
      SiteSetting.instance.update!(payment_mode: "test")
      approve_stripe_live_as(admin)
      accounts = double(retrieve_current: OpenStruct.new(id: "acct_someoneelse"))
      allow(Stripe::StripeClient).to receive(:new).with("sk_live_switch_secret").and_return(double(v1: double(accounts: accounts)))

      patch "/api/v1/admin/settings", params: { payment_mode: "live" }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("different account than STRIPE_LIVE_PLATFORM_ACCOUNT_ID")
      expect(SiteSetting.instance.reload.payment_mode).to eq("test")
    end

    it "refuses test mode until every test credential is present" do
      allow(ENV).to receive(:[]).with("STRIPE_WEBHOOK_SECRET").and_return(nil)

      patch "/api/v1/admin/settings", params: { payment_mode: "test" }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("Test webhook signing secret")
      expect(SiteSetting.instance.reload.payment_mode).to eq("simulate")
    end

    it "keeps an old test payment on test credentials after switching to live" do
      SiteSetting.instance.update!(payment_mode: "test")
      payment = create(:payment, provider: "stripe", provider_environment: "test",
        provider_platform_account_id: "acct_testplatform", provider_payment_id: "pi_old_test")
      approve_stripe_live_as(admin)
      patch "/api/v1/admin/settings", params: { payment_mode: "live" }, headers: headers
      expect(response).to have_http_status(:ok), response.body

      expect(StripeService.publishable_key(payment: payment)).to eq("pk_test_switch")
      expect(StripeService.verify_payment_context!(payment)).to be(true)
      expect(Stripe::StripeClient).to have_received(:new).with("sk_test_switch_secret").at_least(:once)
    end
  end

  it "reports configuration and evidence approval separately" do
    allow(PlatformCapabilities).to receive(:configured?).with("stripe_live").and_return(true)
    allow(PlatformCapabilities).to receive(:enabled?).with("stripe_live").and_return(false)

    get "/api/v1/admin/settings", headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("stripe_live_configured" => true, "stripe_live_approved" => false)
  end

  describe "fee terms" do
    it "updates the fee, processing bearer and payout schedule with an audit record" do
      patch "/api/v1/admin/settings", params: { service_fee_percent: "4.5", service_fee_flat_cents: 75,
        processing_fee_bearer: "organizer", payout_schedule_text: "  within 5 business days  " }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("service_fee_percent" => "4.5", "service_fee_flat_cents" => 75,
        "processing_fee_bearer" => "organizer", "payout_schedule_text" => "within 5 business days")
      audit = AuditLog.find_by!(action: "site_settings.fee_terms_updated")
      expect(audit.actor_user).to eq(admin)
      expect(audit.before_data).to include("service_fee_percent" => "5.0", "processing_fee_bearer" => "platform")
      expect(audit.after_data).to include("service_fee_percent" => "4.5", "service_fee_flat_cents" => "75",
        "processing_fee_bearer" => "organizer", "payout_schedule_text" => "within 5 business days")
    end

    it "does not audit a save that leaves fee terms unchanged" do
      patch "/api/v1/admin/settings", params: { platform_phone: "671-555-0100" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(AuditLog.where(action: "site_settings.fee_terms_updated")).to be_empty
    end

    [
      { processing_fee_bearer: "buyer" },
      { service_fee_percent: "-1" },
      { service_fee_percent: "25.01" },
      { service_fee_percent: "abc" },
      { service_fee_flat_cents: "1001" },
      { service_fee_flat_cents: "1.5" },
      { payout_schedule_text: " " },
      { payout_schedule_text: "x" * 201 }
    ].each do |invalid|
      it "rejects #{invalid.keys.first} #{invalid.values.first.to_s.first(12).inspect} without changing settings" do
        patch "/api/v1/admin/settings", params: invalid, headers: auth_headers(admin)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.fetch("errors")).not_to be_empty
        expect(SiteSetting.instance.reload).to have_attributes(service_fee_percent: 5.0, service_fee_flat_cents: 100,
          processing_fee_bearer: "platform", payout_schedule_text: "within 3 business days after your event")
        expect(AuditLog.where(action: "site_settings.fee_terms_updated")).to be_empty
      end
    end

    it "keeps fee terms admin-only" do
      patch "/api/v1/admin/settings", params: { service_fee_percent: "1" }, headers: auth_headers(create(:user))

      expect(response).to have_http_status(:forbidden)
      expect(SiteSetting.instance.reload.service_fee_percent).to eq(5.0)
    end
  end
end
