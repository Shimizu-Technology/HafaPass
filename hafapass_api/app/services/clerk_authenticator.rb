require "net/http"
require "json"

class ClerkAuthenticator
  JWKS_URL = "https://api.clerk.com/.well-known/jwks.json"
  JWKS_CACHE_TTL = 1.hour

  class << self
    def verify(token)
      return nil if token.blank?

      jwks = fetch_jwks
      return nil if jwks.nil?

      # Try each key until one works (Clerk may rotate keys)
      jwks["keys"].each do |jwk_data|
        begin
          jwk = JWT::JWK.new(jwk_data)
          decoded = JWT.decode(token, jwk.public_key, true, { algorithms: ["RS256"] })
          return decoded.first # Return the payload
        rescue JWT::DecodeError
          next
        end
      end

      nil # No key could verify the token
    rescue StandardError => e
      Rails.logger.error("ClerkAuthenticator error: #{e.message}")
      nil
    end

    private

    def fetch_jwks
      if cached_jwks_valid?
        @cached_jwks
      else
        response = fetch_jwks_from_clerk
        return nil unless response

        @cached_jwks = response
        @cached_at = Time.current
        @cached_jwks
      end
    end

    def cached_jwks_valid?
      @cached_jwks.present? && @cached_at.present? && (Time.current - @cached_at) < JWKS_CACHE_TTL
    end

    def fetch_jwks_from_clerk
      uri = URI.parse(JWKS_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 5

      request = Net::HTTP::Get.new(uri.request_uri)
      response = http.request(request)

      if response.code == "200"
        JSON.parse(response.body)
      else
        Rails.logger.error("Failed to fetch Clerk JWKS: HTTP #{response.code}")
        nil
      end
    rescue StandardError => e
      Rails.logger.error("Failed to fetch Clerk JWKS: #{e.message}")
      nil
    end
  end
end
