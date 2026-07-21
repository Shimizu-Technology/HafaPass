# frozen_string_literal: true

module Seating
  module Credential
    module_function

    def issue
      token = SecureRandom.urlsafe_base64(32)
      [token, digest(token)]
    end

    def find_session(token)
      return if token.blank?

      SeatHoldSession.find_by(token_digest: digest(token.to_s))
    end

    def digest(token)
      Digest::SHA256.hexdigest(token)
    end
  end
end
