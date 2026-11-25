# frozen_string_literal: true

# Safety guard shared by every script in scripts/rush_test/ that touches a database.
# The scripts are meant for an isolated copy of the API (or a local throwaway database).
# They refuse to run unless every check below passes, and none of them can be bypassed
# by a flag: change the environment to satisfy a check, not the check.
#
#   require_relative "guard"
#   RushTest::Guard.check_environment!        # before reading or writing anything
#   RushTest::Guard.check_no_real_data!       # additionally, before seeding
require "uri"

module RushTest
  class Refused < StandardError; end

  module Guard
    # Same list as load_tests/fd_championship_rush.js. HAFAPASS_PRODUCTION_HOSTS adds more.
    PRODUCTION_HOST_PATTERNS = [
      /(\A|\.)hafapass\.com\z/i,
      /\Ahafapass-api\.onrender\.com\z/i,
      /(\A|\.)shimizu-technology\.com\z/i,
      /\Ahafapass\.netlify\.app\z/i
    ].freeze
    LOCAL_HOSTS = %w[localhost 127.0.0.1].freeze

    module_function

    # Host of a URL with userinfo, port and trailing dot removed, lowercased.
    def host_of(url)
      match = url.to_s.strip.match(%r{\Ahttps?://([^/?#]+)}i)
      return "" unless match

      authority = match[1]
      host_port = authority.include?("@") ? authority[(authority.rindex("@") + 1)..] : authority
      host = host_port.start_with?("[") ? host_port[0..host_port.index("]")] : host_port.split(":").first.to_s
      host.sub(/\.+\z/, "").downcase
    end

    def production_host?(host, env: ENV)
      extra = env.fetch("HAFAPASS_PRODUCTION_HOSTS", "").split(",").map { |item| item.strip.downcase }.reject(&:empty?)
      PRODUCTION_HOST_PATTERNS.any? { |pattern| pattern.match?(host.to_s) } || extra.include?(host.to_s.downcase)
    end

    def database_name(url)
      URI.parse(url.to_s).path.to_s.delete_prefix("/")
    rescue URI::InvalidURIError
      ""
    end

    def database_host(url)
      URI.parse(url.to_s).host.to_s.downcase
    rescue URI::InvalidURIError
      ""
    end

    # Returns the list of failed checks (empty when the environment is safe).
    def violations(env: ENV, rails_env: nil)
      problems = []
      rails_env = rails_env.to_s
      problems << "RAILS_ENV must be staging (got #{rails_env.inspect}); the isolated copy runs as staging so StageSafety applies" unless rails_env == "staging"

      target = env["HAFAPASS_RUSH_TARGET"].to_s.strip.downcase
      api_host = host_of(env["PUBLIC_API_URL"])
      if target.empty?
        problems << "HAFAPASS_RUSH_TARGET is not set; set it to the isolated API's exact host (for example rush-copy.onrender.com)"
      elsif target != api_host
        problems << "HAFAPASS_RUSH_TARGET #{target.inspect} does not equal the host of PUBLIC_API_URL #{api_host.inspect}"
      end
      problems << "target host #{api_host.inspect} is a production host" if production_host?(api_host, env: env) || production_host?(target, env: env)

      url = env["DATABASE_URL"].to_s
      name = database_name(url)
      problems << "database name #{name.inspect} must contain both 'rush' and 'staging'" unless name.match?(/rush/i) && name.match?(/staging/i)
      problems << "DATABASE_URL and STAGING_DATABASE_URL must be identical" unless url == env["STAGING_DATABASE_URL"].to_s
      if production_host?(database_host(url), env: env)
        problems << "database host is a production host"
      end

      live_keys = %w[STRIPE_LIVE_SECRET_KEY STRIPE_LIVE_PUBLISHABLE_KEY].select { |key| !env[key].to_s.empty? }
      live_keys += %w[STRIPE_SECRET_KEY STRIPE_TEST_SECRET_KEY STRIPE_PUBLISHABLE_KEY STRIPE_TEST_PUBLISHABLE_KEY].select do |key|
        env[key].to_s.match?(/\A(?:sk|rk|pk)_live_/)
      end
      problems << "live Stripe credentials present (#{live_keys.join(', ')})" unless live_keys.empty?
      problems
    end

    def check_environment!(env: ENV, rails_env: (defined?(Rails) ? Rails.env : env["RAILS_ENV"]))
      problems = violations(env: env, rails_env: rails_env)
      return true if problems.empty?

      raise Refused, "Refusing to run (isolated-copy guard):\n  - #{problems.join("\n  - ")}"
    end

    # Before seeding: the database must hold nothing but load-test fixtures, so a copy
    # of production data (real buyers, real events) can never be seeded into or hammered.
    def check_no_real_data!
      problems = []
      problems << "payment_mode is live" if SiteSetting.instance.payment_mode.to_s == "live"
      real_orders = Order.where.not("buyer_email LIKE ?", "%@example.invalid").count
      problems << "#{real_orders} order(s) with a real buyer email" if real_orders.positive?
      real_events = Event.where.not("title LIKE ?", "[LOAD TEST]%").count
      problems << "#{real_events} event(s) not titled [LOAD TEST]" if real_events.positive?
      live_payments = Payment.where(provider_environment: "live").count
      problems << "#{live_payments} live-mode payment(s)" if live_payments.positive?
      return true if problems.empty?

      raise Refused, "Refusing to continue: this database does not look like an empty isolated copy:\n  - #{problems.join("\n  - ")}"
    end
  end
end
