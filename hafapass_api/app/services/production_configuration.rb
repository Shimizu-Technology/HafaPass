# frozen_string_literal: true

require "uri"
require Rails.root.join("config/runtime_configuration").to_s

class ProductionConfiguration
  class << self
    def call
      checks = {
        database: configured?(*%w[DATABASE_URL]),
        redis: RuntimeConfiguration.solid_queue? || configured?(*%w[REDIS_URL]),
        clerk: configured?(*%w[CLERK_SECRET_KEY CLERK_PUBLISHABLE_KEY]) && ClerkAuthenticator.configured?,
        public_urls: secure_public_urls?,
        release: ApplicationRevision.configured?,
        monitoring: configured?(*%w[SENTRY_DSN]),
        email: configured?(*%w[RESEND_API_KEY RESEND_WEBHOOK_SECRET MAILER_FROM_EMAIL]),
        provider_configuration_revision: configured?(*%w[PROVIDER_CONFIGURATION_REVISION]),
        stripe_payment_context: stripe_payment_context?,
        object_storage: configured?(*%w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_BUCKET AWS_REGION]),
        admission_signing: configured?(*%w[ADMISSION_MANIFEST_PRIVATE_KEY_PEM]),
        launch_scope: LaunchCapabilities.configured?,
        runtime_capacity: runtime_capacity?,
        admin_bootstrap_disabled: !ActiveModel::Type::Boolean.new.cast(ENV["ENABLE_FIRST_USER_ADMIN_BOOTSTRAP"])
      }

      {
        ready: checks.values.all?,
        status: checks.values.all? ? "configured" : "incomplete",
        checks: checks
      }
    end

    def stripe_mode_configured?(mode)
      return false unless %w[test live].include?(mode)

      secret = ENV["STRIPE_#{mode.upcase}_SECRET_KEY"].presence
      public_key = ENV["STRIPE_#{mode.upcase}_PUBLISHABLE_KEY"].presence
      if mode == "test"
        secret ||= ENV["STRIPE_SECRET_KEY"]
        public_key ||= ENV["STRIPE_PUBLISHABLE_KEY"]
      end
      secret.to_s.match?(/\A(?:sk|rk)_#{mode}_/) && public_key.to_s.start_with?("pk_#{mode}_") &&
        ENV["STRIPE_#{mode.upcase}_PLATFORM_ACCOUNT_ID"].to_s.match?(/\Aacct_[a-zA-Z0-9]+\z/)
    end

    private

    def configured?(*keys)
      keys.all? { |key| ENV[key].present? }
    end

    def release_identifier
      ApplicationRevision.current
    end

    def stripe_payment_context?
      mode = SiteSetting.instance.payment_mode
      mode == "simulate" || stripe_mode_configured?(mode)
    rescue ActiveRecord::ActiveRecordError
      false
    end

    def secure_public_urls?
      api = parse_https_url(ENV["PUBLIC_API_URL"])
      frontend = parse_https_url(ENV["FRONTEND_URL"])
      public_web = parse_https_url(ENV["PUBLIC_WEB_URL"])
      origins = ENV["ALLOWED_ORIGINS"].to_s.split(",").map(&:strip).reject(&:blank?)
      parsed_origins = origins.map { |origin| parse_https_url(origin) }

      api.present? && frontend.present? && public_web.present? && origins.present? && parsed_origins.all?(&:present?) &&
        parsed_origins.map(&:origin).include?(frontend.origin)
    end

    def runtime_capacity?
      RuntimeConfiguration.database_pool.positive?
    rescue ArgumentError
      false
    end

    def parse_https_url(value)
      uri = URI.parse(value.to_s.delete_suffix("/"))
      return unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.blank? && uri.path.blank? &&
        uri.query.blank? && uri.fragment.blank?

      uri
    rescue URI::InvalidURIError
      nil
    end
  end
end
