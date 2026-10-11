# frozen_string_literal: true

require "digest"

module Operations
  # Atomic counters survive restarts and rolling deployment overlap. Hashing
  # keys prevents the throttle table from duplicating raw addresses/IPs.
  class PostgresThrottleStore
    def increment(name, amount = 1, expires_in: 1.minute, **)
      connection = RuntimeThrottleBucket.connection
      sql = <<~SQL
        INSERT INTO runtime_throttle_buckets (key_hash, value, expires_at)
        VALUES ($1, $2, $3)
        ON CONFLICT (key_hash) DO UPDATE SET
          value = CASE WHEN runtime_throttle_buckets.expires_at <= CURRENT_TIMESTAMP
            THEN EXCLUDED.value ELSE runtime_throttle_buckets.value + EXCLUDED.value END,
          expires_at = CASE WHEN runtime_throttle_buckets.expires_at <= CURRENT_TIMESTAMP
            THEN EXCLUDED.expires_at ELSE runtime_throttle_buckets.expires_at END
        RETURNING value
      SQL
      binds = [["key_hash", Digest::SHA256.hexdigest(name.to_s)], ["value", Integer(amount)],
        ["expires_at", Time.current + expires_in]].map do |key, value|
        ActiveRecord::Relation::QueryAttribute.new(key, value, RuntimeThrottleBucket.type_for_attribute(key))
      end
      connection.exec_query(sql, "Atomic throttle counter", binds).rows.first.first.to_i
    end

    def read(name)
      RuntimeThrottleBucket.where(key_hash: Digest::SHA256.hexdigest(name.to_s))
        .where("expires_at > ?", Time.current).pick(:value)
    end

    def write(name, value, expires_in: 1.minute, **)
      RuntimeThrottleBucket.upsert({ key_hash: Digest::SHA256.hexdigest(name.to_s), value: Integer(value),
        expires_at: Time.current + expires_in }, unique_by: :key_hash)
      true
    end

    def delete(name)
      RuntimeThrottleBucket.where(key_hash: Digest::SHA256.hexdigest(name.to_s)).delete_all
    end

    def delete_matched(*)
      raise "Throttle reset is available only in isolated tests" unless Rails.env.test?

      RuntimeThrottleBucket.delete_all
    end
  end
end
