# frozen_string_literal: true

# Real provider transport against isolated staging fixtures. This never grants
# production capability approval or permits live Stripe money/payouts.
class ProviderRehearsal
  class << self
    def requested?
      ActiveModel::Type::Boolean.new.cast(ENV["HAFAPASS_PROVIDER_REHEARSAL"])
    end

    def enabled?
      Rails.env.staging? && requested?
    end

    def services
      ENV.fetch("PROVIDER_REHEARSAL_SERVICES", "").split(",").map(&:strip).reject(&:blank?).uniq
    end

    def configuration_valid?
      return !requested? unless enabled?

      services.any? && (services - %w[stripe resend]).empty? &&
        (!services.include?("stripe") || stripe_configured?) &&
        (!services.include?("resend") || email_configured?)
    end

    def stripe_enabled?
      enabled? && services.include?("stripe") && configuration_valid?
    end

    def email_enabled?
      enabled? && services.include?("resend") && configuration_valid?
    end

    def email_recipients
      ENV.fetch("PROVIDER_REHEARSAL_EMAIL_RECIPIENTS", "").split(",").map { |value| value.strip.downcase }.reject(&:blank?).uniq
    end

    def email_payload_allowed?(payload)
      return false unless email_enabled?

      recipients = %w[to cc bcc].flat_map { |key| Array(payload[key] || payload[key.to_sym]) }.map { |value| value.to_s.strip.downcase }
      recipients.any? && recipients.all? { |value| email_recipients.include?(value) }
    end

    private

    def stripe_configured?
      secret = ENV["STRIPE_TEST_SECRET_KEY"].presence || ENV["STRIPE_SECRET_KEY"]
      public_key = ENV["STRIPE_TEST_PUBLISHABLE_KEY"].presence || ENV["STRIPE_PUBLISHABLE_KEY"]
      secret.to_s.match?(/\A(?:sk|rk)_test_/) && public_key.to_s.start_with?("pk_test_") &&
        ENV["STRIPE_TEST_PLATFORM_ACCOUNT_ID"].to_s.match?(/\Aacct_[a-zA-Z0-9]+\z/) &&
        ENV["STRIPE_WEBHOOK_SECRET"].present? && ENV["PROVIDER_CONFIGURATION_REVISION"].present?
    end

    def email_configured?
      email_recipients.any? && email_recipients.length <= 10 &&
        email_recipients.all? { |value| value.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/) } &&
        %w[RESEND_API_KEY RESEND_WEBHOOK_SECRET MAILER_FROM_EMAIL PROVIDER_CONFIGURATION_REVISION].all? { |key| ENV[key].present? }
    end
  end
end
