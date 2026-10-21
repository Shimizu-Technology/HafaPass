# frozen_string_literal: true

require_relative "../encryption_configuration"

# Only local environments may use public, stable fallback keys.
EncryptionConfiguration.keys(environment: Rails.env)&.each do |name, value|
  Rails.application.config.active_record.encryption.public_send("#{name}=", value)
end
