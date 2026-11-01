require "net/http"
require "json"
require "base64"

class ClerkAuthenticator
  # A fresh key set is refetched hourly. When Clerk is unreachable the last
  # good set keeps verifying sessions for up to a day, and the failure itself
  # is remembered briefly so every request doesn't wait on a dead endpoint.
  JWKS_CACHE_TTL = 1.hour
  JWKS_STALE_TTL = 24.hours
  JWKS_FAILURE_TTL = 30.seconds
  # A token signed by a key we haven't seen (Clerk rotated) may refetch early,
  # but no more than this often, so forged kids can't hammer Clerk.
  UNKNOWN_KID_REFETCH_INTERVAL = 5.minutes
  JWKS_MUTEX = Mutex.new
  JWKS_REFRESHED = ConditionVariable.new
  # Longest a request with no usable keys waits on another thread's fetch;
  # the fetch itself gives up after 5 s to connect plus 5 s to read.
  JWKS_REFRESH_WAIT = 11 # seconds

  class << self
    def verify(token)
      return nil if token.blank?

      return nil unless configured?

      keys = signing_keys(token_kid(token))
      return nil if keys.empty?

      keys.each do |jwk_data|
        begin
          jwk = JWT::JWK.new(jwk_data)
          options = { algorithms: ["RS256"], verify_iss: true, iss: issuer,
            required_claims: %w[iss sub exp], verify_expiration: true, verify_not_before: true }
          options.merge!(verify_aud: true, aud: audiences) if audiences.any?
          payload = JWT.decode(token, jwk.public_key, true, options).first
          next if payload["sub"].blank?
          # Clerk permits azp to be absent (no frontend Origin was supplied).
          # When present it must match our explicit allowed frontend origins.
          next if payload.key?("azp") && !authorized_parties.include?(payload["azp"])

          return payload
        rescue JWT::DecodeError
          next
        end
      end

      nil # No key could verify the token
    rescue StandardError => e
      Rails.logger.error("ClerkAuthenticator error: #{e.message}")
      nil
    end

    def issuer
      explicit = ENV["CLERK_ISSUER"].presence
      return explicit if explicit

      key = ENV["CLERK_PUBLISHABLE_KEY"].to_s
      return nil unless key.match?(/\Apk_(?:test|live)_/)

      encoded = key.split("_", 3).last
      encoded += "=" * ((4 - encoded.length % 4) % 4)
      domain = Base64.strict_decode64(encoded).delete_suffix("$")
      return nil unless domain.match?(/\A[a-zA-Z0-9.-]+\z/)

      "https://#{domain}"
    rescue ArgumentError
      nil
    end

    def authorized_parties
      configured = ENV["CLERK_AUTHORIZED_PARTIES"].presence
      configured ||= ENV["ALLOWED_ORIGINS"].presence unless Rails.env.production?
      configured ||= "http://localhost:5173,http://localhost:5174,http://localhost:5175,http://localhost:5176" if Rails.env.local?
      configured.to_s.split(",").map { |origin| origin.strip.delete_suffix("/") }.reject(&:empty?)
    end

    def configured?
      valid_origin?(issuer, https_only: true) && authorized_parties.any? &&
        authorized_parties.all? { |origin| valid_origin?(origin, https_only: Rails.env.production?) } &&
        jwks_url.present?
    end

    private

    def audiences
      ENV["CLERK_AUDIENCE"].to_s.split(",").map(&:strip).reject(&:empty?)
    end

    def valid_origin?(value, https_only:)
      uri = URI.parse(value.to_s)
      schemes = https_only ? ["https"] : %w[http https]
      schemes.include?(uri.scheme) && uri.host.present? && uri.userinfo.nil? &&
        uri.path.empty? && uri.query.nil? && uri.fragment.nil?
    rescue URI::InvalidURIError
      false
    end

    def jwks_url
      value = ENV["CLERK_JWKS_URL"].presence || ("#{issuer}/.well-known/jwks.json" if issuer.present?)
      uri = URI.parse(value.to_s)
      value if uri.scheme == "https" && uri.host.present? && uri.userinfo.nil? && uri.fragment.nil?
    rescue URI::InvalidURIError
      nil
    end

    def token_kid(token)
      header = JWT::EncodedToken.new(token).header
      header["kid"].presence if header.is_a?(Hash)
    rescue StandardError
      nil # A malformed token fails signature verification below.
    end

    # Tokens name their signing key; Clerk always sets kid. A token without
    # one may still be tried against every published key.
    def signing_keys(kid)
      jwks = fetch_jwks
      return [] if jwks.nil?

      keys = matching_keys(jwks, kid)
      return keys if keys.any? || kid.nil?

      matching_keys(fetch_jwks(unknown_kid: true), kid)
    end

    def matching_keys(jwks, kid)
      keys = Array(jwks&.dig("keys")).select { |key| key.is_a?(Hash) }
      kid.nil? ? keys : keys.select { |key| key["kid"] == kid }
    end

    # Single-flight refresh: one thread fetches from Clerk, outside the lock.
    # Meanwhile other threads keep verifying with the stale (but still usable)
    # set. Only a thread with no usable keys, or one whose token names a key the
    # stale set lacks, waits for the fetch in flight.
    def fetch_jwks(unknown_kid: false)
      url = jwks_url
      now = Time.current
      JWKS_MUTEX.synchronize do
        reset_jwks_cache! unless @jwks_url == url

        if unknown_kid
          return usable_jwks(now) if @jwks_kid_refetched_at && now - @jwks_kid_refetched_at < UNKNOWN_KID_REFETCH_INTERVAL
        elsif @jwks && now - @jwks_fetched_at < JWKS_CACHE_TTL
          return @jwks
        end
        return usable_jwks(now) if @jwks_failed_at && now - @jwks_failed_at < JWKS_FAILURE_TTL

        if @jwks_refreshing
          stale = usable_jwks(now)
          return stale if stale && !unknown_kid

          return await_jwks_refresh
        end

        @jwks_refreshing = true
        @jwks_url = url
        @jwks_kid_refetched_at = now if unknown_kid
      end

      response = nil
      begin
        response = fetch_jwks_from_clerk
      ensure
        JWKS_MUTEX.synchronize do
          @jwks_refreshing = false
          store_jwks_result(response, url, now)
          JWKS_REFRESHED.broadcast
        end
      end
      JWKS_MUTEX.synchronize { usable_jwks(now) }
    end

    # Called with JWKS_MUTEX held. Bounded by the fetch's own timeouts.
    def await_jwks_refresh
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + JWKS_REFRESH_WAIT
      while @jwks_refreshing
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if remaining <= 0

        JWKS_REFRESHED.wait(JWKS_MUTEX, remaining)
      end
      usable_jwks(Time.current)
    end

    # Called with JWKS_MUTEX held.
    def store_jwks_result(response, url, now)
      return unless @jwks_url == url # the configured URL changed mid-fetch

      if response.is_a?(Hash) && response["keys"].is_a?(Array)
        @jwks, @jwks_fetched_at, @jwks_failed_at = response, now, nil
      else
        @jwks_failed_at = now
        Rails.logger.warn("ClerkAuthenticator serving cached JWKS after a failed fetch") if usable_jwks(now)
      end
    end

    def usable_jwks(now)
      @jwks if @jwks && now - @jwks_fetched_at < JWKS_STALE_TTL
    end

    public

    def reset_jwks_cache!
      @jwks = @jwks_url = @jwks_fetched_at = @jwks_failed_at = @jwks_kid_refetched_at = nil
      @jwks_refreshing = false
    end

    private

    def fetch_jwks_from_clerk
      uri = URI.parse(jwks_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
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
