# frozen_string_literal: true

class PrivacyEmailSuppression < ApplicationRecord
  validates :email_digest, presence: true, uniqueness: true

  def self.for?(email)
    exists?(email_digest: digest(email))
  end

  def self.suppress!(email)
    find_or_create_by!(email_digest: digest(email))
  end

  def self.digest(email)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, email.to_s.strip.downcase)
  end
end
