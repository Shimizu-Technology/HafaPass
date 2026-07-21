# frozen_string_literal: true

require "uri"

class ProductionConfiguration
  class << self
    def call
      checks = {
        database: configured?(*%w[DATABASE_URL]),
        redis: configured?(*%w[REDIS_URL]),
        clerk: configured?(*%w[CLERK_SECRET_KEY CLERK_PUBLISHABLE_KEY]),
        public_urls: secure_public_urls?,
        release: release_identifier.to_s.match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/i),
        monitoring: configured?(*%w[SENTRY_DSN]),
        email: configured?(*%w[RESEND_API_KEY RESEND_WEBHOOK_SECRET MAILER_FROM_EMAIL]),
        object_storage: configured?(*%w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_BUCKET AWS_REGION]),
        admission_signing: configured?(*%w[ADMISSION_MANIFEST_PRIVATE_KEY_PEM]),
        admin_bootstrap_disabled: !ActiveModel::Type::Boolean.new.cast(ENV["ENABLE_FIRST_USER_ADMIN_BOOTSTRAP"])
      }

      {
        ready: checks.values.all?,
        status: checks.values.all? ? "configured" : "incomplete",
        checks: checks
      }
    end

    private

    def configured?(*keys)
      keys.all? { |key| ENV[key].present? }
    end

    def release_identifier
      ENV["GIT_SHA"].presence || ENV["COMMIT_REF"].presence
    end

    def secure_public_urls?
      frontend = parse_https_url(ENV["FRONTEND_URL"])
      public_web = parse_https_url(ENV["PUBLIC_WEB_URL"])
      origins = ENV["ALLOWED_ORIGINS"].to_s.split(",").map(&:strip).reject(&:blank?)
      parsed_origins = origins.map { |origin| parse_https_url(origin) }

      frontend.present? && public_web.present? && origins.present? && parsed_origins.all?(&:present?) &&
        parsed_origins.map(&:origin).include?(frontend.origin)
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
