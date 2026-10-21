# frozen_string_literal: true

class MarketingUnsubscribe < ApplicationRecord
  belongs_to :organization
  normalizes :email, with: ->(value) { value.strip.downcase }
  validates :email, presence: true, uniqueness: { scope: :organization_id }

  def self.token(organization:, email:)
    Rails.application.message_verifier(:marketing_unsubscribe).generate(
      [organization.id, email.to_s.strip.downcase], purpose: :marketing_unsubscribe
    )
  end

  def self.from_token(token)
    id, email = Rails.application.message_verifier(:marketing_unsubscribe).verified(
      token, purpose: :marketing_unsubscribe
    )
    return unless id.is_a?(Integer) && email.is_a?(String) && email.match?(URI::MailTo::EMAIL_REGEXP)

    [Organization.find_by(id: id), email.downcase]
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    nil
  end
end
