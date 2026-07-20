# frozen_string_literal: true

require "base64"
require "digest"
require "openssl"

module Admissions
  class ManifestSigner
    class ConfigurationError < StandardError; end

    ALGORITHM = "PS256"
    SALT_LENGTH = 32

    class << self
      def sign(digest)
        Base64.urlsafe_encode64(
          private_key.sign_pss("SHA256", digest.to_s, salt_length: SALT_LENGTH, mgf1_hash: "SHA256"),
          padding: false
        )
      end

      def verify(digest:, signature:)
        public_key.verify_pss(
          "SHA256",
          Base64.urlsafe_decode64(signature.to_s),
          digest.to_s,
          salt_length: SALT_LENGTH,
          mgf1_hash: "SHA256"
        )
      rescue ArgumentError, OpenSSL::PKey::PKeyError
        false
      end

      def key_id
        Digest::SHA256.hexdigest(public_key.to_der)
      end

      def public_key_spki
        Base64.strict_encode64(public_key.to_der)
      end

      def production_configured?
        ENV["ADMISSION_MANIFEST_PRIVATE_KEY_PEM"].present?
      end

      private

      def private_key
        return @private_key if defined?(@private_key)

        key_mutex.synchronize do
          return @private_key if defined?(@private_key)

          pem = ENV["ADMISSION_MANIFEST_PRIVATE_KEY_PEM"].presence
          if pem.nil? && Rails.env.production?
            raise ConfigurationError, "ADMISSION_MANIFEST_PRIVATE_KEY_PEM is required in production"
          end

          @private_key = pem ? OpenSSL::PKey::RSA.new(pem) : OpenSSL::PKey::RSA.generate(2048)
          unless @private_key.private?
            raise ConfigurationError, "Admission manifest signing key must contain an RSA private key"
          end
        rescue OpenSSL::PKey::PKeyError => e
          raise ConfigurationError, "Admission manifest signing key is invalid: #{e.message}"
        end
        @private_key
      end

      def public_key
        private_key.public_key
      end

      def key_mutex
        @key_mutex ||= Mutex.new
      end
    end
  end
end
