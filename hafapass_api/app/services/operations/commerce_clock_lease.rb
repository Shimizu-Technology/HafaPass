# frozen_string_literal: true

require "securerandom"

module Operations
  class CommerceClockLease
    KEY = "hafapass:operations:commerce-clock"
    TTL_SECONDS = 90
    RENEW_SCRIPT = <<~LUA.squish
      if redis.call('get', KEYS[1]) == ARGV[1] then
        return redis.call('expire', KEYS[1], ARGV[2])
      end
      return 0
    LUA
    RELEASE_SCRIPT = <<~LUA.squish
      if redis.call('get', KEYS[1]) == ARGV[1] then
        return redis.call('del', KEYS[1])
      end
      return 0
    LUA

    def initialize(token: SecureRandom.hex(24))
      @token = token
      @held = false
    end

    def acquire!
      @held = with_redis { |connection| connection.call("SET", KEY, @token, "NX", "EX", TTL_SECONDS) == "OK" }
    rescue StandardError
      @held = false
    end

    def renew!
      return false unless @held

      @held = with_redis do |connection|
        connection.call("EVAL", RENEW_SCRIPT, 1, KEY, @token, TTL_SECONDS).to_i == 1
      end
    rescue StandardError
      @held = false
    end

    def release!
      return false unless @held

      with_redis do |connection|
        connection.call("EVAL", RELEASE_SCRIPT, 1, KEY, @token).to_i == 1
      end
    rescue StandardError
      false
    ensure
      @held = false
    end

    def self.status
      ttl = Sidekiq.redis { |connection| connection.call("TTL", KEY).to_i }
      {
        ready: ttl.positive?,
        status: ttl.positive? ? "active" : "missing",
        lease_ttl_seconds: [ttl, 0].max
      }
    rescue StandardError
      { ready: false, status: "unavailable", lease_ttl_seconds: 0 }
    end

    private

    def with_redis(&)
      Sidekiq.redis(&)
    end
  end
end
