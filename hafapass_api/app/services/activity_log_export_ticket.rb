# frozen_string_literal: true

# An encrypted, expiring query ticket avoids keeping duplicate CSVs or raw
# search filters in storage. It is bound to its requester and access grants.
class ActivityLogExportTicket
  TTL = 1.day
  PURPOSE = "activity-log-export"

  def self.issue(**attributes)
    encryptor.encrypt_and_sign(attributes.merge("export_request_id" => SecureRandom.uuid),
      purpose: PURPOSE, expires_in: TTL)
  end

  def self.read(token)
    encryptor.decrypt_and_verify(token, purpose: PURPOSE)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    nil
  end

  def self.encryptor
    key = Rails.application.key_generator.generate_key(PURPOSE, 32)
    ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm", serializer: JSON, url_safe: true)
  end
  private_class_method :encryptor
end
