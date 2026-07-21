# frozen_string_literal: true

require "rails_helper"

RSpec.describe Operations::CommerceClockLease do
  let(:connection) { instance_double(RedisClient) }

  before do
    allow(Sidekiq).to receive(:redis).and_yield(connection)
  end

  it "acquires, renews, and releases only its own singleton lease" do
    lease = described_class.new(token: "clock-owner")
    allow(connection).to receive(:call)
      .with("SET", described_class::KEY, "clock-owner", "NX", "EX", described_class::TTL_SECONDS)
      .and_return("OK")
    allow(connection).to receive(:call)
      .with("EVAL", described_class::RENEW_SCRIPT, 1, described_class::KEY, "clock-owner",
        described_class::TTL_SECONDS)
      .and_return(1)
    allow(connection).to receive(:call)
      .with("EVAL", described_class::RELEASE_SCRIPT, 1, described_class::KEY, "clock-owner")
      .and_return(1)

    expect(lease.acquire!).to be(true)
    expect(lease.renew!).to be(true)
    expect(lease.release!).to be(true)
    expect(lease.renew!).to be(false)
  end

  it "refuses to start a second clock while the lease is held" do
    allow(connection).to receive(:call).and_return(nil)

    expect(described_class.new(token: "second-clock").acquire!).to be(false)
  end

  it "reports a redacted heartbeat without exposing the owner token" do
    allow(connection).to receive(:call).with("TTL", described_class::KEY).and_return(72)

    expect(described_class.status).to eq(ready: true, status: "active", lease_ttl_seconds: 72)
  end

  it "fails closed without raising when Redis becomes unavailable" do
    allow(connection).to receive(:call).and_raise(RedisClient::CannotConnectError, "unavailable")

    expect(described_class.new.acquire!).to be(false)
    expect(described_class.status).to eq(ready: false, status: "unavailable", lease_ttl_seconds: 0)
  end
end
