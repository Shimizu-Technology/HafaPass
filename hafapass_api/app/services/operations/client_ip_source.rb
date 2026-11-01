# frozen_string_literal: true

module Operations
  # Describes where Rack's req.ip came from, without recording any address.
  # Render's proxy reaches the app from a private address, so Rack skips it as
  # a trusted proxy and takes the last untrusted X-Forwarded-For entry. If a
  # public CDN edge sits in that chain, req.ip is the edge, not the visitor,
  # and every IP throttle would share one bucket per edge. "differs" against
  # CF-Connecting-IP/True-Client-IP is the signal to investigate.
  module ClientIpSource
    LOGGED = Concurrent::AtomicBoolean.new(false)

    module_function

    def log_once(request)
      return unless LOGGED.make_true

      Rails.logger.info({ event: "rack_attack_client_ip_source" }.merge(describe(request)).to_json)
    end

    def describe(request)
      ip = request.ip.to_s
      forwarded = Array(request.forwarded_for)
      source = if ip.empty? then "none"
      elsif forwarded.include?(ip) then "x_forwarded_for"
      elsif ip == request.get_header("REMOTE_ADDR").to_s then "remote_addr"
      else "other"
      end
      {
        source: source,
        forwarded_hops: forwarded.size,
        position_from_right: forwarded.reverse.index(ip),
        cf_connecting_ip: compare(request.get_header("HTTP_CF_CONNECTING_IP"), ip),
        true_client_ip: compare(request.get_header("HTTP_TRUE_CLIENT_IP"), ip)
      }
    rescue StandardError
      { source: "unavailable" }
    end

    def compare(value, ip)
      return "absent" if value.to_s.strip.empty?

      value.to_s.strip == ip ? "matches" : "differs"
    end
  end
end
