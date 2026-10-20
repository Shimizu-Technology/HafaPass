# frozen_string_literal: true

require "uri"

# Every public link HåfaPass emits (emails, share links, sitemap, OG pages,
# wallet origins) comes from configuration so moving the site to another domain
# is an environment change, never a code change. Development and test fall back
# to the local Vite server; deployed environments refuse to boot without the
# configured HTTPS URLs instead of sending people to localhost.
module PublicSiteUrl
  class ConfigurationError < StandardError; end

  LOCAL_FRONTEND_URL = "http://localhost:5173"
  REQUIRED_KEYS = %w[FRONTEND_URL PUBLIC_WEB_URL].freeze

  class << self
    # Where the web app runs: account, ticket, order and organizer links.
    def frontend
      configured("FRONTEND_URL") || local_fallback("FRONTEND_URL")
    end

    # Canonical public site for SEO, sitemaps and share previews.
    def base
      configured("PUBLIC_WEB_URL") || (local? && configured("FRONTEND_URL")) || local_fallback("PUBLIC_WEB_URL")
    end

    def event(event)
      "#{base}/events/#{event.slug}"
    end

    def validate!
      return if local?

      invalid = REQUIRED_KEYS.reject { |key| https_url?(ENV[key]) }
      return if invalid.empty?

      raise ConfigurationError, "#{invalid.join(', ')} must be set to the public HTTPS site URL in #{Rails.env}"
    end

    private

    def configured(key)
      ENV[key].to_s.strip.sub(%r{/+\z}, "").presence
    end

    def local_fallback(key)
      return LOCAL_FRONTEND_URL if local?

      raise ConfigurationError, "#{key} is not configured in #{Rails.env}"
    end

    def local?
      Rails.env.local?
    end

    def https_url?(value)
      uri = URI.parse(value.to_s.strip)
      uri.is_a?(URI::HTTPS) && uri.host.present?
    rescue URI::InvalidURIError
      false
    end
  end
end
