# frozen_string_literal: true

# One place that maps a Stripe environment ("test" or "live") to its
# credentials. Callers pass the environment of the current payment mode for new
# work, or the environment a payment was charged in for anything that touches
# an existing payment, so an old test order keeps using test credentials after
# the platform switches to live.
#
#   test → STRIPE_TEST_SECRET_KEY, STRIPE_TEST_PUBLISHABLE_KEY,
#          STRIPE_TEST_PLATFORM_ACCOUNT_ID, STRIPE_WEBHOOK_SECRET
#   live → STRIPE_LIVE_SECRET_KEY, STRIPE_LIVE_PUBLISHABLE_KEY,
#          STRIPE_LIVE_PLATFORM_ACCOUNT_ID, STRIPE_LIVE_WEBHOOK_SECRET
#
# The unprefixed STRIPE_SECRET_KEY / STRIPE_PUBLISHABLE_KEY pair is a
# deprecated fallback for test mode only; it never supplies live credentials.
module StripeCredentials
  ENVIRONMENTS = %w[test live].freeze
  ACCOUNT_PATTERN = /\Aacct_[a-zA-Z0-9]+\z/
  ENV_NAMES = {
    "test" => {
      secret_key: "STRIPE_TEST_SECRET_KEY", publishable_key: "STRIPE_TEST_PUBLISHABLE_KEY",
      platform_account_id: "STRIPE_TEST_PLATFORM_ACCOUNT_ID", webhook_secret: "STRIPE_WEBHOOK_SECRET"
    },
    "live" => {
      secret_key: "STRIPE_LIVE_SECRET_KEY", publishable_key: "STRIPE_LIVE_PUBLISHABLE_KEY",
      platform_account_id: "STRIPE_LIVE_PLATFORM_ACCOUNT_ID", webhook_secret: "STRIPE_LIVE_WEBHOOK_SECRET"
    }
  }.freeze
  LEGACY_TEST_FALLBACKS = { secret_key: "STRIPE_SECRET_KEY", publishable_key: "STRIPE_PUBLISHABLE_KEY" }.freeze

  module_function

  def env_name(environment, credential)
    ENV_NAMES.fetch(environment.to_s).fetch(credential)
  end

  def secret_key(environment)
    fetch(environment, :secret_key)
  end

  def publishable_key(environment)
    fetch(environment, :publishable_key)
  end

  def platform_account_id(environment)
    value = fetch(environment, :platform_account_id)
    value if value&.match?(ACCOUNT_PATTERN)
  end

  def webhook_secret(environment)
    fetch(environment, :webhook_secret)
  end

  # Prefix checks only; they never reveal a value.
  def secret_key_valid?(environment)
    ENVIRONMENTS.include?(environment.to_s) && secret_key(environment).to_s.match?(/\A(?:sk|rk)_#{environment}_/)
  end

  def publishable_key_valid?(environment)
    ENVIRONMENTS.include?(environment.to_s) && publishable_key(environment).to_s.start_with?("pk_#{environment}_")
  end

  def webhook_secret_valid?(environment)
    ENVIRONMENTS.include?(environment.to_s) && webhook_secret(environment).to_s.start_with?("whsec_")
  end

  def configured?(environment)
    secret_key_valid?(environment) && publishable_key_valid?(environment) &&
      platform_account_id(environment).present? && webhook_secret_valid?(environment)
  end

  def fetch(environment, credential)
    environment = environment.to_s
    return unless ENVIRONMENTS.include?(environment)

    value = ENV[env_name(environment, credential)].presence
    value ||= ENV[LEGACY_TEST_FALLBACKS[credential]].presence if environment == "test" && LEGACY_TEST_FALLBACKS.key?(credential)
    value
  end
  private_class_method :fetch
end
