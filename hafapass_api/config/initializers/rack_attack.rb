# frozen_string_literal: true

# Rate limiting configuration using Rack::Attack
# https://github.com/rack/rack-attack

class Rack::Attack
  # SQL profiles persist atomic counters in PostgreSQL; legacy profiles use Redis.
  if RuntimeConfiguration.solid_queue?
    require Rails.root.join("app/services/operations/postgres_throttle_store").to_s
    Rack::Attack.cache.store = Operations::PostgresThrottleStore.new
  elsif ENV["REDIS_URL"].present?
    Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(url: ENV["REDIS_URL"])
  else
    Rails.logger.warn("[Rack::Attack] REDIS_URL not set — falling back to in-memory store (not suitable for multi-process)")
  end

  # ─── Safelist ─────────────────────────────────────────────────────────────
  safelist("boot-liveness") do |req|
    req.get? && req.path == "/up"
  end
  # Allow all requests from localhost in development
  safelist("allow-localhost") do |req|
    req.ip == "127.0.0.1" || req.ip == "::1" if Rails.env.development?
  end

  # ─── General Throttles ────────────────────────────────────────────────────

  # Throttle all requests by IP (300 requests per 5 minutes)
  # Wallet devices and the email provider's PDF fetches share venue/carrier NAT
  # or a small provider IP pool, so they have their own limits below.
  throttle("req/ip", limit: 300, period: 5.minutes) do |req|
    req.ip unless req.path.start_with?("/assets", "/api/v1/wallet/apple/", "/api/v1/ticket_email_attachments/")
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

  # Recovery is intentionally enumeration-safe, but still expensive because it may queue email.
  throttle("order-recovery/ip", limit: 5, period: 10.minutes) do |req|
    req.ip if req.path == "/api/v1/order_lookup" && req.post?
  end

  throttle("order-recovery/email", limit: 3, period: 10.minutes) do |req|
    if req.path == "/api/v1/order_lookup" && req.post?
      begin
        raw = req.body.read
        req.body.rewind
        JSON.parse(raw)["buyer_email"]&.strip&.downcase
      rescue JSON::ParserError, IOError
        nil
      end
    end
  end

  throttle("order-resend/ip", limit: 10, period: 10.minutes) do |req|
    req.ip if req.path.match?(%r{\A/api/v1/orders/\d+/resend\z}) && req.post?
  end

  throttle("payment-resume/ip", limit: 20, period: 1.minute) do |req|
    req.ip if req.path.match?(%r{\A/api/v1/orders/\d+/payment_resume\z}) && req.post?
  end

  # ─── Check-in Throttles ───────────────────────────────────────────────────

  # Throttle check-in attempts (60 per minute per IP - for scanning)
  throttle("checkin/ip", limit: 60, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/api/v1/check_in") && req.post?
  end

  # ─── Wallet Throttles ─────────────────────────────────────────────────────

  # Apple Wallet devices poll and register for pass updates. One event edit
  # pushes every device at a venue, often behind one shared Wi-Fi or carrier
  # NAT address, so limits are per device and per pass with a high IP ceiling.
  APPLE_WALLET_PREFIX = "/api/v1/wallet/apple/v1/"
  throttle("apple-wallet/device", limit: 30, period: 1.minute) do |req|
    req.path[%r{\A#{APPLE_WALLET_PREFIX}devices/([^/]+)/}, 1] if req.path.start_with?(APPLE_WALLET_PREFIX)
  end

  throttle("apple-wallet/pass", limit: 60, period: 1.minute) do |req|
    req.path[%r{\A#{APPLE_WALLET_PREFIX}(?:passes/[^/]+|devices/[^/]+/registrations/[^/]+)/([^/]+)\z}, 1] if
      req.path.start_with?(APPLE_WALLET_PREFIX)
  end

  throttle("apple-wallet/ip", limit: 1200, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/api/v1/wallet/apple/")
  end

  # The email provider fetches ticket PDFs from a small pool of addresses, so
  # each signed link is limited on its own under a high IP ceiling.
  throttle("ticket-email-attachment/token", limit: 10, period: 10.minutes) do |req|
    Digest::SHA256.hexdigest(req.path) if req.path.start_with?("/api/v1/ticket_email_attachments/") && req.get?
  end

  throttle("ticket-email-attachment/ip", limit: 1200, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/api/v1/ticket_email_attachments/") && req.get?
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

  # Funnel telemetry is intentionally anonymous but still write-heavy.
  throttle("marketplace-funnel/ip", limit: 60, period: 1.minute) do |req|
    req.ip if req.path == "/api/v1/marketplace_funnel_events" && req.post?
  end

  throttle("marketplace-landing/ip", limit: 60, period: 1.minute) do |req|
    marketplace_landing = req.path.start_with?("/api/v1/distribution_links/", "/api/v1/event_referrals/")
    req.ip if marketplace_landing && req.get?
  end

  # Seat holds lock scarce, named inventory before checkout.
  throttle("seat-holds/ip", limit: 20, period: 1.minute) do |req|
    seat_hold_path = req.path.match?(%r{\A/api/v1/events/[^/]+/seat_holds\z})
    req.ip if seat_hold_path && req.post?
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
