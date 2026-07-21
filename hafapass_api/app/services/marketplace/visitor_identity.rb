# frozen_string_literal: true

module Marketplace
  class VisitorIdentity
    class InvalidIdentifier < StandardError; end

    def self.hash(raw_identifier)
      value = raw_identifier.to_s.strip
      raise InvalidIdentifier, "anonymous_id is required" unless value.match?(/\A[a-zA-Z0-9_-]{16,128}\z/)

      OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, value)
    end
  end
end
