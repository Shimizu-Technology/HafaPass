# frozen_string_literal: true

# Explains, item by item, whether the platform may switch to Stripe test or
# live payments. Admin Settings shows this checklist next to the switch, and
# the settings endpoint refuses a switch while any item is unmet. Values are
# never returned, only whether each requirement is met.
class PaymentModeReadiness
  class << self
    def call(mode)
      mode = mode.to_s
      checks = case mode
      when "live" then live_checks
      when "test" then test_checks
      else []
      end
      { mode: mode, ready: checks.any? && checks.all? { |check| check[:met] }, checks: checks }
    end

    def ready?(mode)
      call(mode)[:ready]
    end

    def all
      { "test" => call("test"), "live" => call("live") }
    end

    private

    def live_checks
      [
        check("production_environment", "Server runs with RAILS_ENV=production",
          !Rails.env.staging?, "Staging never takes real money. Change RAILS_ENV to production on Render first."),
        credential_check("live", :secret_key, "Live secret key", StripeCredentials.secret_key_valid?("live"),
          "an sk_live_ or rk_live_ key"),
        credential_check("live", :publishable_key, "Live publishable key", StripeCredentials.publishable_key_valid?("live"),
          "a pk_live_ key"),
        credential_check("live", :platform_account_id, "Live Stripe account ID",
          StripeCredentials.platform_account_id("live").present?, "the acct_ ID of Shimizu Technology's Stripe account"),
        credential_check("live", :webhook_secret, "Live webhook signing secret", StripeCredentials.webhook_secret_valid?("live"),
          "the whsec_ secret of the live-mode webhook endpoint"),
        check("provider_configuration_revision", "Provider configuration revision recorded",
          ENV["PROVIDER_CONFIGURATION_REVISION"].present?,
          "Set PROVIDER_CONFIGURATION_REVISION, and increase it whenever provider settings change."),
        check("stripe_live_approved", "Stripe live payments approved in Provider readiness",
          live_capability_approved?,
          "Open Provider readiness, submit the Stripe live payments evidence, then approve it. One admin can do both.")
      ]
    end

    def test_checks
      checks = []
      if Rails.env.staging?
        checks << check("staging_provider_rehearsal", "Staging Stripe rehearsal enabled",
          ProviderRehearsal.stripe_enabled?,
          "Staging only uses Stripe when HAFAPASS_PROVIDER_REHEARSAL is on with stripe in PROVIDER_REHEARSAL_SERVICES.")
      end
      checks + [
        credential_check("test", :secret_key, "Test secret key", StripeCredentials.secret_key_valid?("test"),
          "an sk_test_ or rk_test_ key"),
        credential_check("test", :publishable_key, "Test publishable key", StripeCredentials.publishable_key_valid?("test"),
          "a pk_test_ key"),
        credential_check("test", :platform_account_id, "Test Stripe account ID",
          StripeCredentials.platform_account_id("test").present?, "the acct_ ID of the Stripe sandbox account"),
        credential_check("test", :webhook_secret, "Test webhook signing secret", StripeCredentials.webhook_secret_valid?("test"),
          "the whsec_ secret of the test-mode webhook endpoint")
      ]
    end

    def live_capability_approved?
      PlatformCapabilities.enabled?("stripe_live")
    end

    def credential_check(environment, credential, label, met, expected)
      name = StripeCredentials.env_name(environment, credential)
      check("#{environment}_#{credential}", label, met, "Set #{name} on the API service to #{expected}.")
    end

    def check(key, label, met, help)
      { key: key, label: label, met: met ? true : false, help: met ? nil : help }
    end
  end
end
