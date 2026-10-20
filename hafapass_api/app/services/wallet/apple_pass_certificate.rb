# frozen_string_literal: true

require "base64"
require "openssl"

module Wallet
  # The Pass Type ID certificate signs passes and authenticates APNs pushes.
  module ApplePassCertificate
    Credentials = Struct.new(:certificate, :key, keyword_init: true)

    def self.load
      p12 = OpenSSL::PKCS12.new(
        Base64.strict_decode64(ENV.fetch("APPLE_PASS_CERTIFICATE_BASE64")),
        ENV.fetch("APPLE_PASS_CERTIFICATE_PASSWORD", "")
      )
      Credentials.new(certificate: p12.certificate, key: p12.key)
    end
  end
end
