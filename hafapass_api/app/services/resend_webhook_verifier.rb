# frozen_string_literal: true

require "base64"
require "openssl"

class ResendWebhookVerifier
  TOLERANCE = 5.minutes

  class VerificationError < StandardError; end

  def self.verify!(payload:, headers:, now: Time.current)
    secret = ENV["RESEND_WEBHOOK_SECRET"].to_s
    raise VerificationError, "Webhook verification is not configured" if secret.blank?

    event_id = headers.fetch("svix-id").to_s
    timestamp_value = headers.fetch("svix-timestamp").to_s
    signatures = headers.fetch("svix-signature").to_s.split
    timestamp = Time.at(Integer(timestamp_value)).utc
    raise VerificationError, "Webhook timestamp is outside the replay window" if (now - timestamp).abs > TOLERANCE

    key = Base64.strict_decode64(secret.delete_prefix("whsec_"))
    expected = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", key, "#{event_id}.#{timestamp_value}.#{payload}"))
    valid = signatures.any? do |signature|
      version, value = signature.split(",", 2)
      version == "v1" && value.present? && value.bytesize == expected.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(value, expected)
    end
    raise VerificationError, "Webhook signature is invalid" unless valid

    JSON.parse(payload)
  rescue KeyError, ArgumentError, JSON::ParserError
    raise VerificationError, "Webhook request is invalid"
  end
end
