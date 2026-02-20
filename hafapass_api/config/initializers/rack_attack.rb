# frozen_string_literal: true

# Rate limiting configuration using Rack::Attack
# https://github.com/rack/rack-attack

class Rack::Attack
  # Use Redis for throttle store if available, otherwise use memory store
  if ENV["REDIS_URL"].present?
    Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(url: ENV["REDIS_URL"])
  else
    Rails.logger.warn("[Rack::Attack] REDIS_URL not set — falling back to in-memory store (not suitable for multi-process)")
  end

  # ─── Safelist ─────────────────────────────────────────────────────────────
  # Allow all requests from localhost in development
  safelist("allow-localhost") do |req|
    req.ip == "127.0.0.1" || req.ip == "::1" if Rails.env.development?
  end

  # ─── General Throttles ────────────────────────────────────────────────────

  # Throttle all requests by IP (300 requests per 5 minutes)
  throttle("req/ip", limit: 300, period: 5.minutes) do |req|
    req.ip unless req.path.start_with?("/assets")
  end

  # ─── Authentication Throttles ─────────────────────────────────────────────

  # Throttle user sync/auth endpoints more strictly (20 per minute)
  throttle("users/ip", limit: 20, period: 1.minute) do |req|
    req.ip if req.path == "/api/v1/users/sync" && req.post?
  end

  # ─── Order Creation Throttles ─────────────────────────────────────────────

  # Throttle order creation by IP (10 orders per minute)
  throttle("orders/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.path == "/api/v1/orders" && req.post?
  end

  # Throttle order creation by email (5 orders per minute per email)
  throttle("orders/email", limit: 5, period: 1.minute) do |req|
    if req.path == "/api/v1/orders" && req.post?
      # Extract email from request body
      begin
        raw = req.body.read
        req.body.rewind
        body = JSON.parse(raw)
        body["buyer_email"]&.downcase
      rescue JSON::ParserError, IOError
        nil
      end
    end
  end

  # ─── Check-in Throttles ───────────────────────────────────────────────────

  # Throttle check-in attempts (60 per minute per IP - for scanning)
  throttle("checkin/ip", limit: 60, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/api/v1/check_in") && req.post?
  end

  # ─── Promo Code Validation Throttles ──────────────────────────────────────

  # Throttle promo code validation (30 per minute per IP)
  throttle("promo/ip", limit: 30, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/api/v1/promo_codes/validate") && req.post?
  end

  # ─── Upload Presign Throttles ─────────────────────────────────────────────

  # Throttle presign requests (20 per minute per IP)
  throttle("uploads/ip", limit: 20, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/api/v1/uploads/presign") && req.post?
  end

  # ─── Blocklist ────────────────────────────────────────────────────────────

  # Block requests from known bad IPs (configured via environment)
  blocklist("block-bad-ips") do |req|
    blocked_ips = ENV.fetch("BLOCKED_IPS", "").split(",").map(&:strip)
    blocked_ips.include?(req.ip)
  end

  # ─── Throttle Response ────────────────────────────────────────────────────

  # Customize throttled response
  self.throttled_responder = lambda do |req|
    match_data = req.env["rack.attack.match_data"]
    now = match_data[:epoch_time]

    headers = {
      "Content-Type" => "application/json",
      "Retry-After" => (match_data[:period] - (now % match_data[:period])).to_s
    }

    body = {
      error: "Rate limit exceeded",
      retry_after: headers["Retry-After"].to_i
    }.to_json

    [429, headers, [body]]
  end
end

# Log throttled requests
ActiveSupport::Notifications.subscribe("throttle.rack_attack") do |_name, _start, _finish, _id, payload|
  req = payload[:request]
  Rails.logger.warn(
    "[Rack::Attack] Throttled #{req.ip} on #{req.path} - #{payload[:match_type]}: #{payload[:match_key]}"
  )
end
