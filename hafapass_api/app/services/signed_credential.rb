# frozen_string_literal: true

require "concurrent/map"

class SignedCredential
  VERIFIERS = Concurrent::Map.new

  class << self
    def issue(namespace:, payload:, expires_at: nil)
      verifier(namespace).generate(payload, expires_at: expires_at, purpose: namespace)
    end

    def verify(namespace:, token:)
      verifier(namespace).verified(token.to_s, purpose: namespace)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, JSON::ParserError
      nil
    end

    private

    def verifier(namespace)
      VERIFIERS.compute_if_absent(namespace) do
        secret = Rails.application.key_generator.generate_key("hafapass/#{namespace}", 32)
        ActiveSupport::MessageVerifier.new(secret, digest: "SHA256", serializer: JSON, url_safe: true)
      end
    end
  end
end
