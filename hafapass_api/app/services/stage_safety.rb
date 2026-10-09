# frozen_string_literal: true

require "uri"
require "base64"
require "openssl"
require_relative "provider_rehearsal"

# Staging runs the production runtime against separate data, with real test
# identity and simulated commerce. It never supplies production approvals.
class StageSafety
  class ConfigurationError < StandardError; end

  class << self
    def call(runtime: false)
      checks = {
        database: staging_database?,
        redis: staging_redis?,
        clerk_test_identity: clerk_test_identity?,
        public_urls: public_urls?,
        application_secret: application_secret?,
        admission_signing: admission_signing?,
        admin_bootstrap_disabled: !ActiveModel::Type::Boolean.new.cast(ENV["ENABLE_FIRST_USER_ADMIN_BOOTSTRAP"]),
        no_live_stripe_credentials: no_live_stripe_credentials?,
        provider_rehearsal: ProviderRehearsal.configuration_valid?,
        launch_scope: ENV.fetch("HAFAPASS_LAUNCH_SCOPE", "general_admission") == "general_admission"
      }
      if runtime
        if ProviderRehearsal.stripe_enabled?
          checks[:test_provider_payments] = SiteSetting.instance.test_mode?
        else
          checks[:simulated_payments] = simulated_payments?
        end
        checks[:durable_jobs] = ActiveJob::Base.queue_adapter_name == "sidekiq"
      end
      ready = checks.values.all?
      status = ProviderRehearsal.enabled? ? "provider_rehearsal" : "simulation_only"
      { ready: ready, status: ready ? status : "unsafe_staging_configuration", checks: checks }
    end

    def validate!
      result = call
      return if result[:ready]

      failures = result[:checks].reject { |_key, passed| passed }.keys.join(", ")
      raise ConfigurationError, "Staging configuration failed: #{failures}"
    end

    def application_secret?
      secret = ENV["SECRET_KEY_BASE"].to_s
      secret.length > 64 && secret == secret.strip
    end

    private

    def admission_signing?
      pem = ENV["ADMISSION_MANIFEST_PRIVATE_KEY_PEM"]
      return false if pem.blank?

      key = OpenSSL::PKey::RSA.new(pem)
      key.private? && key.n.num_bits >= 2048
    rescue OpenSSL::PKey::PKeyError, ArgumentError
      false
    end

    def simulated_payments?
      SiteSetting.instance.simulate_mode?
    rescue ActiveRecord::ActiveRecordError
      false
    end

    def staging_database?
      value = ENV["STAGING_DATABASE_URL"]
      uri = URI.parse(value.to_s)
      value.present? && value == ENV["DATABASE_URL"] && %w[postgres postgresql].include?(uri.scheme) &&
        uri.host.present? && uri.path.match?(/\A\/[a-zA-Z0-9_]*staging[a-zA-Z0-9_]*\z/)
    rescue URI::InvalidURIError
      false
    end

    def staging_redis?
      value = ENV["STAGING_REDIS_URL"]
      uri = URI.parse(value.to_s)
      value.present? && value == ENV["REDIS_URL"] && %w[redis rediss].include?(uri.scheme) &&
        uri.host.present? && uri.path.match?(/\A\/[1-9]\d*\z/) && uri.query.nil? && uri.fragment.nil?
    rescue URI::InvalidURIError
      false
    end

    def clerk_test_identity?
      key = ENV["CLERK_PUBLISHABLE_KEY"].to_s
      return false unless key.start_with?("pk_test_") && ENV["CLERK_SECRET_KEY"].to_s.match?(/\Ask_test_[A-Za-z0-9]+\z/)

      encoded = key.delete_prefix("pk_test_")
      encoded += "=" * ((4 - encoded.length % 4) % 4)
      domain = Base64.strict_decode64(encoded).delete_suffix("$")
      return false unless domain.match?(/\A[a-zA-Z0-9.-]+\z/)

      issuer = https_origin(ENV["CLERK_ISSUER"])
      return false unless issuer && issuer.to_s == "https://#{domain}"

      jwks = ENV["CLERK_JWKS_URL"].presence
      return true unless jwks

      jwks == "#{issuer}/.well-known/jwks.json"
    rescue ArgumentError
      false
    end

    def public_urls?
      urls = %w[FRONTEND_URL PUBLIC_WEB_URL PUBLIC_API_URL].map { |key| https_origin(ENV[key]) }
      origins = origins_for("ALLOWED_ORIGINS")
      parties = ENV["CLERK_AUTHORIZED_PARTIES"].present? ? origins_for("CLERK_AUTHORIZED_PARTIES") : origins
      urls.all? && origins.present? && origins.all? && parties.present? && parties.all? &&
        origins.include?(urls.first) && parties.include?(urls.first) && (parties - origins).empty?
    end

    def origins_for(key)
      ENV[key].to_s.split(",").map { |value| https_origin(value.strip) }
    end

    def https_origin(value)
      uri = URI.parse(value.to_s.delete_suffix("/"))
      return unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.path.empty? &&
        uri.query.nil? && uri.fragment.nil?

      uri
    rescue URI::InvalidURIError
      nil
    end

    def no_live_stripe_credentials?
      %w[STRIPE_LIVE_SECRET_KEY STRIPE_LIVE_PUBLISHABLE_KEY].all? { |key| ENV[key].blank? } &&
        %w[STRIPE_SECRET_KEY STRIPE_TEST_SECRET_KEY STRIPE_PUBLISHABLE_KEY STRIPE_TEST_PUBLISHABLE_KEY].none? do |key|
          ENV[key].to_s.match?(/\A(?:sk|rk|pk)_live_/)
        end
    end
  end
end
