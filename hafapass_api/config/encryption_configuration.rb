# frozen_string_literal: true

require "digest"

module EncryptionConfiguration
  def self.keys(environment:, env: ENV)
    %w[PRIMARY_KEY DETERMINISTIC_KEY KEY_DERIVATION_SALT].to_h do |suffix|
      name = "ACTIVE_RECORD_ENCRYPTION_#{suffix}"
      value = env[name].presence
      if value.nil?
        raise "#{name} is required" unless %w[development test].include?(environment.to_s)

        value = Digest::SHA256.hexdigest("hafapass-local-only-#{suffix}")
      end
      [suffix.downcase, value]
    end
  end
end
