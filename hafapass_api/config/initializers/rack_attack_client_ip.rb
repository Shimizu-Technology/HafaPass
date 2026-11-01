# frozen_string_literal: true

# Every Rack::Attack IP throttle keys on req.ip. Behind Render's Cloudflare
# edge the socket peer is an edge address shared by many buyers, so derive the
# client from the edge headers instead (see ClientIp). IPv6 clients are keyed
# by their /64 prefix. Checkout's per-network caps use the same ClientIp.bucket.
class Rack::Attack::Request
  def ip
    ClientIp.bucket(env) || super
  end
end
