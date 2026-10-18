# frozen_string_literal: true

require "rails_helper"

RSpec.describe Operations::PostgresThrottleStore do
  it "retains atomic counts across separate instances without copying addresses into storage" do
    first = described_class.new
    expect(first.increment("person@example.invalid", 1, expires_in: 1.minute)).to eq(1)
    expect(described_class.new.increment("person@example.invalid", 1, expires_in: 1.minute)).to eq(2)
    expect(RuntimeThrottleBucket.first.key_hash).not_to include("person", "@")
    expect(described_class.new.read("person@example.invalid")).to eq(2)
  end

  it "resets an expired counter instead of extending a live window on every request" do
    store = described_class.new
    store.increment("fixture", 1, expires_in: 1.minute)
    expiry = RuntimeThrottleBucket.first.expires_at
    store.increment("fixture", 1, expires_in: 5.minutes)
    expect(RuntimeThrottleBucket.first.expires_at).to eq(expiry)
    RuntimeThrottleBucket.update_all(expires_at: 1.second.ago)
    expect(store.increment("fixture", 1, expires_in: 1.minute)).to eq(1)
  end
end
