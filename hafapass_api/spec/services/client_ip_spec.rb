# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClientIp do
  def env(headers = {}, remote = "10.1.2.3")
    Rack::MockRequest.env_for("/api/v1/orders", { "REMOTE_ADDR" => remote }.merge(headers))
  end

  it "prefers CF-Connecting-IP over True-Client-IP and the socket address" do
    request = env({ "HTTP_CF_CONNECTING_IP" => "203.0.113.5", "HTTP_TRUE_CLIENT_IP" => "198.51.100.9" })
    expect(described_class.from_env(request)).to eq("203.0.113.5")
    expect(described_class.bucket(request)).to eq("203.0.113.5")
    expect(described_class.source(request)).to eq("cf-connecting-ip")
  end

  it "uses True-Client-IP when it is the only edge header" do
    request = env({ "HTTP_TRUE_CLIENT_IP" => " 198.51.100.9 " })
    expect(described_class.from_env(request)).to eq("198.51.100.9")
    expect(described_class.source(request)).to eq("true-client-ip")
  end

  it "falls back to Rails remote_ip without edge headers" do
    request = env
    expect(described_class.from_env(request)).to eq("10.1.2.3")
    expect(described_class.source(request)).to eq("remote_ip")
  end

  it "ignores malformed edge headers and tries the next source" do
    ["not-an-ip", "203.0.113.5, 198.51.100.1", "203.0.113.0/24", "999.1.1.1", "", "1" * 80].each do |bad|
      request = env({ "HTTP_CF_CONNECTING_IP" => bad, "HTTP_TRUE_CLIENT_IP" => "198.51.100.9" })
      expect(described_class.from_env(request)).to eq("198.51.100.9"), bad
    end
    request = env({ "HTTP_CF_CONNECTING_IP" => "garbage", "HTTP_TRUE_CLIENT_IP" => "also garbage" })
    expect(described_class.from_env(request)).to eq("10.1.2.3")
  end

  it "groups IPv6 clients by their /64 prefix and unwraps IPv4-mapped addresses" do
    first = env({ "HTTP_CF_CONNECTING_IP" => "2001:db8:abcd:12:1::7" })
    second = env({ "HTTP_CF_CONNECTING_IP" => "2001:DB8:ABCD:12:ffff:ffff:ffff:ffff" })
    expect(described_class.from_env(first)).to eq("2001:db8:abcd:12:1::7")
    expect(described_class.bucket(first)).to eq("2001:db8:abcd:12::/64")
    expect(described_class.bucket(second)).to eq(described_class.bucket(first))
    expect(described_class.bucket(env({ "HTTP_CF_CONNECTING_IP" => "2001:db8:abcd:13::7" }))).not_to eq(described_class.bucket(first))
    expect(described_class.bucket(env({ "HTTP_CF_CONNECTING_IP" => "::ffff:203.0.113.8" }))).to eq("203.0.113.8")
    expect(described_class.bucket(env({}, "::1"))).to eq("::1")
  end

  it "keys every Rack::Attack IP throttle on the same bucket" do
    request = Rack::Attack::Request.new(env({ "HTTP_CF_CONNECTING_IP" => "2001:db8:abcd:12:1::7" }))
    expect(request.ip).to eq("2001:db8:abcd:12::/64")
    expect(Rack::Attack::Request.new(env).ip).to eq("10.1.2.3")
  end
end
