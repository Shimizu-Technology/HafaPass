# frozen_string_literal: true

module Commerce
  # A keyed digest of the buyer's IP address for per-network checkout caps.
  # Orders store only this digest, never the address itself.
  module CheckoutIpDigest
    def self.call(ip)
      return if ip.blank?

      OpenSSL::HMAC.hexdigest("SHA256", key, ip.to_s)
    end

    def self.key
      Rails.application.key_generator.generate_key("hafapass/checkout-ip-digest/v1", 32)
    end
    private_class_method :key
  end
end
