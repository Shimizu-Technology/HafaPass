# frozen_string_literal: true

require "ipaddr"

# The buyer's network address as seen at the edge.
#
# Production traffic reaches Render through Render's Cloudflare edge, so the
# socket peer and X-Forwarded-For end in a small pool of edge addresses that
# thousands of buyers share. Cloudflare sets CF-Connecting-IP (overwriting any
# client-supplied value) to the real client, and some edge configurations add
# True-Client-IP. Read those first, then fall back to Rails' remote_ip for
# direct traffic (local development, tests, health checks).
#
# Each header is validated with IPAddr; a malformed value is ignored and the
# next source is tried.
#
# Rate limits and per-network checkout caps use .bucket: an IPv4 address as is,
# an IPv6 address reduced to its /64 prefix, because one subscriber or device
# usually controls a whole /64 and can rotate addresses inside it.
module ClientIp
  HEADERS = {
    "HTTP_CF_CONNECTING_IP" => "cf-connecting-ip",
    "HTTP_TRUE_CLIENT_IP" => "true-client-ip"
  }.freeze
  IPV6_PREFIX = 64
  ENV_KEY = "hafapass.client_ip"

  Result = Struct.new(:address, :bucket, :source, keyword_init: true)

  module_function

  # The full client address (string), or nil when none can be determined.
  def from_env(env)
    resolve(env)&.address
  end

  # The address used for throttles and checkout caps (IPv6 → its /64).
  def bucket(env)
    resolve(env)&.bucket
  end

  # Which source supplied the address: "cf-connecting-ip", "true-client-ip"
  # or "remote_ip". For operational logging only.
  def source(env)
    resolve(env)&.source
  end

  def resolve(env)
    return env[ENV_KEY] if env.key?(ENV_KEY)

    env[ENV_KEY] = compute(env)
  end

  def compute(env)
    HEADERS.each do |header, label|
      address = parse(env[header])
      return build(address, label) if address
    end
    address = parse(ActionDispatch::Request.new(env).remote_ip)
    address && build(address, "remote_ip")
  end

  def parse(value)
    text = value.to_s.strip
    return if text.empty? || text.length > 64 || text.include?("/") || text.include?(",")

    address = IPAddr.new(text)
    address.ipv4_mapped? ? address.native : address
  rescue IPAddr::Error
    nil
  end

  def build(address, source)
    bucket = if address.ipv6? && !address.loopback?
      "#{address.mask(IPV6_PREFIX)}/#{IPV6_PREFIX}"
    else
      address.to_s
    end
    Result.new(address: address.to_s, bucket: bucket, source: source)
  end
end
